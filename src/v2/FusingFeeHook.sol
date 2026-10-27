// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 *
 *  Fusing V2 contracts. Every launch pays 1.1% per trade, 60% to the creator
 *  and 40% to the protocol, paid out in ETH. V2 puts the terms in the
 *  creator's hands: token limits, fee schedules, anti-sniper windows, holder
 *  rewards, five-way fee splits and the payout mode.
 */

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title FusingFeeHook
 * @notice A single hook shared by every V2 launch pool. On each swap it
 * works out the LP fee from the terms the creator fixed at launch:
 *
 *   fee(t) = resting + schedulePremium(t) + sniperPremium(t)
 *
 *   resting          the fee V1 charged: the 1.1% protocol base plus the
 *                    creator tax.
 *   schedulePremium  the "time-based LP fee": equals `startPremium` at the
 *                    instant the pool opens and declines in a straight line
 *                    to zero across `decaySeconds`. The creator earns more
 *                    from the volatile first minutes, and the pool relaxes to
 *                    its resting fee without anyone touching it.
 *   sniperPremium    the "anti-sniper tax": a fixed surcharge on each swap in
 *                    the launch block and the `sniperBlocks - 1` blocks that
 *                    follow, meant for bots that buy before a human can. Zero
 *                    `sniperBlocks` turns it off. The single swap bundled into
 *                    the launch transaction (the creator's opening buy) is
 *                    excused when the factory flags it.
 *
 * Each premium is charged as an LP fee, so it accrues to the launch's locked
 * position and is collected with every other fee. The hook counts what each
 * swap paid above the resting fee (afterSwap, bookkeeping only), and the
 * locker splits those premiums a tenth to the protocol and the rest to the
 * creator; the resting fee keeps its own 60/40 split of the base and leaves
 * the creator tax entirely to the creator.
 *
 * A whitelisted launch opens behind a window in which only the list can
 * receive the token; the schedule starts when that window ends and only the
 * resting fee applies inside it. The sniper tax and the whitelist window are
 * never both on: the factory refuses that pairing.
 *
 * The launch factory writes the terms once, before the pool is initialised,
 * and they are permanent. A pool that names this hook without terms on file
 * cannot be initialised, which stops anyone from spinning up a pool under the
 * fusi.ng hook that did not go through the factory.
 *
 * The hook's address has to encode BEFORE_INITIALIZE, BEFORE_SWAP and AFTER_SWAP in its
 * low-order bits, so it is deployed at a mined CREATE2 salt (the deploy
 * script handles the search). `validateHookAddress` in BaseHook rejects any
 * other address.
 */
/// @dev The two factory views this hook reads: which router may vouch for a trader's identity, and which locker collects the fees.
interface IForwarderView {
    function launchForwarder() external view returns (address);
    function locker() external view returns (address);
}

contract FusingFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    struct Terms {
        /// @dev The V1 fee in pips (base plus creator tax): what remains once both premiums have run out.
        uint24 restingFee;
        /// @dev Surcharge in pips at the start of the schedule; shrinks linearly to nothing across `decaySeconds`.
        uint24 startPremium;
        uint32 decaySeconds;
        /// @dev Surcharge in pips on each swap in the launch block and the `sniperBlocks - 1` blocks that follow.
        uint24 sniperPremium;
        uint32 sniperBlocks;
        /// @dev When the schedule starts. On input, the factory passes the delay in seconds (a whitelisted launch's
        /// window, during which only the resting fee applies); `setTerms` turns it into the absolute time.
        uint64 launchedAt;
        uint64 launchBlock;
        /// @dev The creator's opening buy is bundled into the launch transaction and should not count as a snipe.
        bool devBuyExempt;
        bool set;
    }

    error NotFactory();
    error TermsAlreadySet(PoolId id);
    error TermsNotSet(PoolId id);
    error FeeTooHigh(uint24 fee, uint24 max);
    error ScheduleTooLong(uint32 seconds_, uint32 max);
    error ZeroAddress();

    event TermsSet(PoolId indexed id, Terms terms);

    /// @notice Ceiling on the fee of one swap with every premium added: 95%.
    uint24 public constant MAX_TOTAL_FEE = 950_000;
    /// @notice Longest possible fee schedule: 7 days. The factory imposes a stricter limit of its own.
    uint32 public constant MAX_SCHEDULE_SECONDS = 7 days;
    /// @notice Longest possible sniper window: 10 blocks.
    uint32 public constant MAX_SNIPER_BLOCKS = 10;

    /// @notice The one address permitted to write terms.
    address public immutable factory;

    mapping(PoolId id => Terms) private _terms;

    /**
     * @notice The premium fees a pool's swaps have paid since the last
     * collection, per currency: the part of each swap's fee above the resting
     * fee, in the currency the swap paid with. Bookkeeping only; the pool's
     * balances are never touched, so any router can still trade it. The
     * locker reads and resets these when it collects, and pays the protocol
     * a tenth of the premiums instead of its usual share of the base fee.
     */
    mapping(PoolId id => uint256) public premium0;
    mapping(PoolId id => uint256) public premium1;

    error NotLocker();

    /// @notice Hands the accrued premiums to the locker and zeroes them. Locker only.
    function consumePremium(PoolId id) external returns (uint256 p0, uint256 p1) {
        if (msg.sender != IForwarderView(factory).locker()) revert NotLocker();
        p0 = premium0[id];
        p1 = premium1[id];
        premium0[id] = 0;
        premium1[id] = 0;
    }
    /// @notice Wallets exempt from the launch-block premium: the creator's chosen circle.
    mapping(PoolId id => mapping(address wallet => bool)) public whitelisted;
    mapping(PoolId id => bool) private _whitelistSet;

    error WhitelistAlreadySet(PoolId id);

    event WhitelistSet(PoolId indexed id, uint256 count);

    /// @notice Records the wallets exempt from the launch-block premium. Factory only, one time.
    function setWhitelist(PoolId id, address[] calldata list) external {
        if (msg.sender != factory) revert NotFactory();
        if (_whitelistSet[id]) revert WhitelistAlreadySet(id);
        _whitelistSet[id] = true;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] != address(0)) whitelisted[id][list[i]] = true;
        }
        emit WhitelistSet(id, list.length);
    }

    constructor(IPoolManager manager_, address factory_) BaseHook(manager_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Fee terms
    // ---------------------------------------------------------------------

    /**
     * @notice Stores a pool's fee terms. Factory only, one time, ahead of
     * pool initialisation. The `launchedAt` supplied is a delay in seconds:
     * zero for a launch whose schedule starts at once, the window length for
     * a whitelisted launch. It is stored as the absolute time the schedule
     * starts; `launchBlock` is stamped with the current block regardless.
     */
    function setTerms(PoolId id, Terms calldata terms) external {
        if (msg.sender != factory) revert NotFactory();
        if (_terms[id].set) revert TermsAlreadySet(id);
        // The two premiums never stack: the sniper premium alone applies in
        // its blocks, the schedule alone afterwards. The peak is the larger.
        uint24 larger = terms.startPremium > terms.sniperPremium ? terms.startPremium : terms.sniperPremium;
        uint24 peak = terms.restingFee + larger;
        if (peak > MAX_TOTAL_FEE) revert FeeTooHigh(peak, MAX_TOTAL_FEE);
        if (terms.decaySeconds > MAX_SCHEDULE_SECONDS) revert ScheduleTooLong(terms.decaySeconds, MAX_SCHEDULE_SECONDS);
        if (terms.sniperBlocks > MAX_SNIPER_BLOCKS) revert ScheduleTooLong(terms.sniperBlocks, MAX_SNIPER_BLOCKS);

        Terms memory t = terms;
        // The input carries the delay before the schedule starts; store the moment it starts.
        t.launchedAt = uint64(block.timestamp) + terms.launchedAt;
        t.launchBlock = uint64(block.number);
        t.set = true;
        _terms[id] = t;
        emit TermsSet(id, t);
    }

    function termsOf(PoolId id) external view returns (Terms memory) {
        return _terms[id];
    }

    /**
     * @notice What a swap in pool `id` would be charged at this moment, in pips.
     */
    function currentFee(PoolId id) public view returns (uint24) {
        Terms memory t = _terms[id];
        if (!t.set) revert TermsNotSet(id);
        return _feeAt(t, block.timestamp, block.number, false);
    }

    /**
     * @notice What the pool would charge at `timestamp` in block `blockNumber`.
     * Plain arithmetic over the stored terms, meant for front ends plotting the curve.
     */
    function feeAt(PoolId id, uint256 timestamp, uint256 blockNumber) external view returns (uint24) {
        Terms memory t = _terms[id];
        if (!t.set) revert TermsNotSet(id);
        return _feeAt(t, timestamp, blockNumber, false);
    }

    /// @notice True while the sniper premium is still being applied.
    function sniperWindowOpen(PoolId id) public view returns (bool) {
        Terms memory t = _terms[id];
        return t.set && t.sniperBlocks > 0 && block.number < uint256(t.launchBlock) + t.sniperBlocks;
    }

    function _feeAt(Terms memory t, uint256 timestamp, uint256 blockNumber, bool skipSniper) private pure returns (uint24) {
        uint256 fee = t.restingFee;
        // In the sniper blocks the sniper premium is the whole story: the
        // creator's schedule only starts once that window has closed, so the
        // two never add up. A wallet spared the sniper premium pays the
        // schedule like anyone else.
        if (!skipSniper && t.sniperBlocks > 0 && blockNumber < uint256(t.launchBlock) + t.sniperBlocks) {
            fee += t.sniperPremium;
        } else {
            // The schedule counts from `launchedAt`, which is the end of any
            // launch window (a whitelisted launch's first minute); inside the
            // window only the resting fee applies.
            if (timestamp >= t.launchedAt) {
                uint256 elapsed = timestamp - t.launchedAt;
                if (t.startPremium > 0 && elapsed < t.decaySeconds) {
                    // Straight-line decay: all of the premium at t=0, nothing left at t=decaySeconds.
                    fee += uint256(t.startPremium) * (t.decaySeconds - elapsed) / t.decaySeconds;
                }
            }
        }
        // setTerms already guarantees each peak fits under the cap; the clamp is cheap insurance anyway.
        return fee > MAX_TOTAL_FEE ? MAX_TOTAL_FEE : uint24(fee);
    }

    // ---------------------------------------------------------------------
    // PoolManager callbacks
    // ---------------------------------------------------------------------

    /// @dev No pool may initialise under this hook unless the factory has written its terms beforehand.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolId id = key.toId();
        if (!_terms[id].set) revert TermsNotSet(id);
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev On each swap, return the fee for this instant to the pool manager
     * with the override flag set. If the factory flagged the launch as
     * carrying the creator's own buy, the first swap of the launch block is
     * spared the sniper premium exactly once; every later swap in that block
     * pays the full amount.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Terms storage t = _terms[id];
        if (!t.set) revert TermsNotSet(id);
        bool exempt = t.devBuyExempt && block.number == t.launchBlock;
        if (exempt) t.devBuyExempt = false;
        // Whitelisted wallets swapping via the fusi.ng router are also
        // spared. The router itself encodes the actual trader into hookData,
        // and that is the only source believed: hookData from any other
        // sender is disregarded no matter what it contains.
        if (!exempt && _whitelistSet[id] && hookData.length == 32 && sender == IForwarderView(factory).launchForwarder()) {
            address trader = abi.decode(hookData, (address));
            if (whitelisted[id][trader]) exempt = true;
        }
        uint24 fee = _feeAt(t, block.timestamp, block.number, exempt);
        // Remembered for afterSwap, which knows the amounts, in transient
        // storage so it costs nothing after the transaction.
        bytes32 slot = PoolId.unwrap(id);
        assembly {
            tstore(slot, fee)
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /**
     * @dev Counts the premium part of the fee the swap just paid. The pool
     * manager charges the fee on the input, so the premium is the input
     * amount times the fee above the resting fee. Nothing here changes any
     * balance: no delta is returned.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        bytes32 slot = PoolId.unwrap(id);
        uint256 fee;
        assembly {
            fee := tload(slot)
            tstore(slot, 0)
        }
        uint256 resting = _terms[id].restingFee;
        if (fee > resting) {
            int128 paid = params.zeroForOne ? BalanceDeltaLibrary.amount0(delta) : BalanceDeltaLibrary.amount1(delta);
            uint256 input = paid < 0 ? uint256(uint128(-paid)) : 0;
            uint256 premium = input * (fee - resting) / 1_000_000;
            if (params.zeroForOne) premium0[id] += premium;
            else premium1[id] += premium;
        }
        return (BaseHook.afterSwap.selector, 0);
    }
}
