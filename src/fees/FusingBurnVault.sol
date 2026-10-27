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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IFusingFeeEscrow, IFusingLaunchFactory} from "../v2/interfaces/ILaunchpadV2.sol";
import {Hop} from "../v2/libraries/Hop.sol";
import {IMultiFuseFactory} from "../v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice The single-market factory as seen from a burn vault: a launch's
 * record together with the key of its pool. The locker reads the same shape.
 */
interface IBurnVaultLaunchFactory is IFusingLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
    /// @dev V2: the pricer. Its route is what lets a vault spend ETH buying back on a pool quoted in another asset.
    function quotePricer() external view returns (address);
    /// @dev V2: the router of the moment, rotatable on the factory, that every vault trades through.
    function launchForwarder() external view returns (address);
}

/// @dev V2: the route the pricer holds for a quote asset, plus its spot valuation.
interface IQuotePricerRoute {
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies);
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) external view returns (uint256);
}

/// @dev V2: the router's ETH bolt. ETH travels `leg` into the quote and from there into the pool.
interface IEthBuyer {
    function buyWithEth(PoolKey calldata key, Hop[] calldata leg, uint256 minTokensOut, address recipient)
        external
        payable
        returns (uint256 tokensOut);
}

/**
 * @notice The single call a deployed vault makes on its own factory: which
 * launch this vault address belongs to. Written once at deployment and
 * never again.
 */
/// @dev The only view of the V2 fee hook a vault needs.
interface IFusingFeeHookFee {
    function currentFee(PoolId id) external view returns (uint24);
}

interface IBurnVaultRegistry {
    function tokenOf(address vault) external view returns (address token);
}

/**
 * @notice The single call this vault makes on FusingRouter. A launch pool is
 * an ordinary V4 pool whose hook only sets the fee, so the router's one-pool
 * exact-input swap is all the plumbing a buyback requires; MultiFuse
 * pools have the same shape and use the same call.
 */
interface ISwapper {
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut);
}

/**
 * @notice Reads that a vault and the factory deploying vaults both need, so
 * the factory can answer for a launch whose vault is not deployed yet
 * without duplicating the logic.
 */
library FusingBurnVaultLib {
    /// @dev Neither factory knows this token.
    error UnknownLaunch(address token);

    /**
     * @dev A launch's pools and their quote assets, in market order. The
     * single-market factory is checked first because that is the common
     * case; any token belongs to exactly one of the two factories.
     */
    function marketsOf(IBurnVaultLaunchFactory factory, IMultiFuseFactory multiFactory, address token)
        internal
        view
        returns (PoolKey[] memory keys, address[] memory quotes)
    {
        IFusingLaunchFactory.LaunchedToken memory single = factory.getLaunchedToken(token);
        if (single.exists) {
            keys = new PoolKey[](1);
            quotes = new address[](1);
            keys[0] = factory.poolKeyFor(token);
            quotes[0] = single.pairToken;
            return (keys, quotes);
        }
        IMultiFuseFactory.LaunchedToken memory multi = multiFactory.getLaunchedToken(token);
        if (!multi.exists) revert UnknownLaunch(token);
        IMultiFuseFactory.Market[] memory markets = multiFactory.getMarkets(token);
        keys = multiFactory.poolKeysFor(token);
        quotes = new address[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            quotes[i] = markets[i].pairToken;
        }
    }

    /**
     * @dev What `who` holds of `asset` plus what the escrow owes it. The
     * escrow's side can always be read; the asset's own `balanceOf` is a
     * call into code nobody has vetted and may revert, so it is wrapped and
     * treated as zero when it does. A keeper looking at a launch with one
     * frozen quote still gets figures for everything else.
     */
    function pending(IFusingFeeEscrow escrow, address who, address asset) internal view returns (uint256) {
        if (asset == address(0)) return who.balance + escrow.balanceOf(who);
        uint256 held;
        try IERC20(asset).balanceOf(who) returns (uint256 b) {
            held = b;
        } catch {}
        return held + escrow.balanceOfToken(who, asset);
    }
}

/**
 * @title FusingBurnVault
 * @notice The creator fee recipient for a launch whose creator decided, at
 * creation, to burn the creator's share of trading fees rather than keep it
 * ("buyback and burn"). The creator sets this address as
 * `creatorFeeRecipient` in the launch params like any other recipient, so
 * neither the factories nor the launch transaction need to know about it.
 *
 * ## One vault per launch
 *
 * This contract is the implementation behind an EIP-1167 minimal proxy that
 * FusingBurnVaultFactory deploys with CREATE2 at an address derived from the
 * launch token: one clone for each launch. That matters. FusingFeeEscrow
 * keys claimable balances by recipient address and nothing else, so a vault
 * shared between launches would merge every launch's quote-side fees into a
 * single balance per asset, and whoever called `burn` first would spend the
 * merged balance, including what other launches' traders had paid, buying
 * back their own token. One address per launch turns the escrow's
 * per-recipient accounting into per-launch accounting, exactly and for free.
 *
 * The address is known before the launch transaction is sent
 * (`FusingBurnVaultFactory.vaultFor`), so the launch form can put it in the
 * params, and anyone may deploy the clone itself at any time, before or
 * after the launch: fees credited to an address that has no code yet wait
 * in the escrow until the clone that claims them is there.
 *
 * ## Naming it cannot be undone, and that is the point
 *
 * By inspection:
 *
 * - No owner, no `Ownable`, no admin role, no initializer.
 * - Every stored address is `immutable`, set once when the implementation
 *   is constructed and shared by all clones. A clone keeps no addresses of
 *   its own: it asks its factory which launch it belongs to, and the factory
 *   writes that answer once, at deployment.
 * - No setter, no `transferCreatorFeeRecipient` forwarder, no `withdraw`,
 *   no `rescue`, no `sweep`, no arbitrary-call path and no upgrade hook, so
 *   nothing that lands here can leave except as a swap into the launch
 *   token followed by a burn of that token.
 * - `burn` is open to anyone and always finishes with the tokens at 0x...dEaD.
 *
 * A minimal proxy does delegatecall, of course, to a single address the
 * deploying factory hard-codes into the proxy's own runtime code, readable
 * in the 45 bytes at the clone's address. There is no admin slot, no beacon
 * and no function that can redirect where the clone delegates, so the code
 * behind a vault address is as fixed as the code at a plain deployment.
 *
 * The factories let only a launch's current recipient pass the recipient
 * role on, and this contract contains no code able to make that call, so
 * once a launch names its vault the decision stands. (The factory owner
 * keeps the timelocked `setCreatorFeeRecipient` path every launch is
 * subject to; that is a property of the factory, not of this vault.)
 *
 * ## What `burn` does
 *
 * The lockers credit the creator share of every collection to the fee
 * escrow under this address, in the pool's two currencies: launch token for
 * sells, quote asset for buys. `burn()`:
 *
 *   1. claims this vault's escrow balance in the launch token,
 *   2. claims its escrow balance in each of the launch's quote assets and
 *      swaps it into the launch token through that market's own pool (one
 *      pool for a single-market launch, up to five for a MultiFuse one),
 *      via FusingRouter,
 *   3. burns all of the launch token the vault then holds.
 *
 * Both sides belong to this launch alone: nothing else is ever paid in this
 * token, and no other launch's fees are ever credited to this address.
 *
 * Burning means a transfer to 0x...dEaD, an address nobody holds a key to,
 * rather than a call that lowers `totalSupply`. Explorers and trading bots
 * report supply and the burnt share from exactly that: the launch supply
 * stays the figure everyone saw at launch, and the dead balance is the burn.
 * `burnedTotal` on the vault is the same number, kept for the interface.
 *
 * ## What the buyback pays
 *
 * Every swap has a floor: at least what the pool's own pre-swap price says
 * the input is worth, minus the pool's fee and `SWAP_TOLERANCE_BPS`. On top
 * of that, no single call may shift the pool's price by more than
 * `MAX_SQRT_MOVE_BPS` of the square root of the price, roughly 1% of the
 * price; a quote balance bigger than that is bought in slices, one per
 * call, with the rest waiting. The cap is what makes sandwiching a buyback
 * pointless, because a sandwich's entire profit is the price impact of the
 * trade it wraps and both of its legs pay the pool's fee, which is 1.1% at
 * minimum and up to 11.1% on a launch with the full creator tax. The floor
 * catches everything else: a broken pool, a misbehaving router, an input
 * that would fill at a price the pool's own state cannot justify.
 *
 * ## The awkward cases, none of them reverting except the last
 *
 * - Nothing to claim: `burn` reverts with `NothingToBurn` and no state
 *   changes, so a keeper's wasted call costs gas and nothing more.
 * - A market without a usable pool (never initialized, or no liquidity in
 *   range): no swap is attempted, and that market's quote stays here for a
 *   later call.
 * - A quote asset that rejects this address, or reverts on `balanceOf`, at
 *   any of the three points where this contract touches it: the escrow
 *   claim, the balance read and the swap are each wrapped in `try`, so that
 *   market is skipped while every other market, and the launch-token side,
 *   finish normally. Whatever could not be claimed remains claimable in the
 *   escrow and whatever is already held here remains here, for a call that
 *   can move it. `burnMarket(index)` runs one market for the same reason the
 *   multi locker has `collectMarketFees`: a healthy market should never
 *   have to wait on a sick one.
 * - A swap that reverts, including on its own slippage floor (an empty or
 *   broken pool): the quote stays in this contract and the next `burn`
 *   picks it up together with whatever has accrued since. The vault's own
 *   balance is swept every call, not only what the escrow just paid out.
 *
 * One thing is deliberately NOT promised, and it is easy to assume
 * otherwise: value is not unstrandable. A quote asset that rejects this
 * address permanently leaves its own balance stuck permanently, in the
 * escrow or here, because this contract has no withdrawal path and never
 * will. What is promised is that the failure stays contained to the market
 * that caused it.
 * - A swap that takes less than it was offered (the price cap above, or a
 *   pool that ran out of range): the router sends the remainder back here
 *   and it waits for the next call.
 * - Dust: anything under `MIN_QUOTE_SWAP` raw units is left to accumulate
 *   rather than swapped, since the swap would burn more gas than the value
 *   it moves.
 * - A launch neither factory knows: `UnknownLaunch`. An address that is not
 *   a vault this factory deployed, the implementation included: `NotAVault`.
 */
contract FusingBurnVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Raw quote units below which the quote side is allowed to
     * accumulate rather than be swapped. 1000 units is 1000 wei of ETH or
     * 0.001 of a six-decimal dollar: negligible either way, and well under
     * what a swap costs in gas.
     */
    uint256 public constant MIN_QUOTE_SWAP = 1000;
    /// @notice Where burned tokens go. A transfer, not a supply reduction, so explorers and bots keep the launch supply and count the burn.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /**
     * @notice The furthest one call may shift the square root of a pool's
     * price, in basis points: 50 bps of the square root is roughly 100 bps
     * (1%) of the price itself. A bigger quote balance gets spent in slices,
     * one per call, and whatever a slice leaves behind waits for the next.
     *
     * This is the figure that makes sandwiching a buyback a losing trade. A
     * sandwich collects the price impact of the trade it wraps and pays the
     * pool's fee on both of its own legs; a launch pool charges 1.1% at
     * minimum (the base fee with no creator tax) and up to 11.1%, so a 2.2%
     * round trip against at most 1% of impact to capture loses money before
     * the attacker's gas is counted. It also limits what a single call can
     * give away when the price is somewhere odd for reasons of its own,
     * since `burn` is open to anyone and its caller picks the moment.
     */
    uint256 public constant MAX_SQRT_MOVE_BPS = 50;

    /**
     * @notice How far under the pool's own pre-swap valuation of the input a
     * swap may fill before being refused, in basis points.
     *
     * The floor is the input, net of the pool's fee, valued at the pool's
     * current price, less this. A swap that shifts the square root of the
     * price by the full `MAX_SQRT_MOVE_BPS` fills exactly 50 bps under that
     * valuation (the average price along the curve versus the price at its
     * start), so 100 bps is the cap plus 50 bps of headroom for rounding and
     * for the tick crossings of any liquidity someone else has added to the
     * pool. Tighter and honest burns would start being refused; looser and
     * the headroom would be worth more than the swap it guards.
     */
    uint256 public constant SWAP_TOLERANCE_BPS = 100;

    uint256 private constant BASIS_POINTS = 10_000;
    /// @dev Uniswap expresses fees in hundredths of a bip: 1% is 10_000 out of 1_000_000.
    uint256 private constant PIPS = 1_000_000;

    /// @notice The factory that deployed this vault and records which launch it serves.
    IBurnVaultRegistry public immutable vaults;
    /// @notice The ledger the lockers credit this vault's fee share to.
    IFusingFeeEscrow public immutable escrow;
    /// @notice FusingRouter, used for nothing but exact-input swaps into launch pools.
    ISwapper public immutable router;
    /// @notice The single-market factory, for launch records and pool keys.
    IBurnVaultLaunchFactory public immutable factory;
    /// @notice The MultiFuse factory, for the same data per market.
    IMultiFuseFactory public immutable multiFactory;
    /// @notice Uniswap's PoolManager, consulted for the price a swap has to beat.
    IPoolManager public immutable poolManager;

    /// @notice Cumulative amount of its launch token this vault has burned.
    uint256 public burnedTotal;

    /**
     * @notice One `burn` call. `quotes` lists the launch's quote assets in
     * market order (address zero for native ETH) and `quoteSpent` what each
     * swap really consumed, so a market that was skipped or whose swap
     * reverted reads zero. `amount` is what this call burned, `totalBurned`
     * the running total for the token, which is the figure a token page
     * displays.
     */
    event Burned(address indexed token, address[] quotes, uint256[] quoteSpent, uint256 amount, uint256 totalBurned);

    error ZeroAddress();
    /// @dev This address is no vault: either the implementation or an impostor.
    error NotAVault();
    /// @dev The router returned less than the floor it was handed. Only a router other than ours could do that.
    error ShortFill(uint256 got, uint256 minOut);
    /// @dev Nothing claimable and nothing held: the call would do nothing.
    error NothingToBurn(address token);
    /// @dev `burnMarket` received an index this launch does not have.
    error MarketOutOfRange(address token, uint256 index, uint256 markets);

    constructor(
        IBurnVaultRegistry vaults_,
        IFusingFeeEscrow escrow_,
        ISwapper router_,
        IBurnVaultLaunchFactory factory_,
        IMultiFuseFactory multiFactory_,
        IPoolManager poolManager_
    ) {
        if (
            address(vaults_) == address(0) || address(escrow_) == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || address(multiFactory_) == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        vaults = vaults_;
        escrow = escrow_;
        router = router_;
        factory = factory_;
        multiFactory = multiFactory_;
        poolManager = poolManager_;
    }

    /// @dev Claimed ETH arrives here from the escrow, and the router sends
    /// back whatever a swap could not consume.
    receive() external payable {}

    /**
     * @notice The router swaps are sent through: the factory's launch
     * forwarder, which can be rotated there, so a router fix reaches every
     * vault without touching any of them. The router given at construction
     * is the fallback while the factory names none. Every swap checks what
     * arrived against its floor, so a forwarder that is not our router
     * cannot deliver short; it can only fail outright.
     */
    function activeRouter() public view returns (ISwapper) {
        address forwarder;
        try factory.launchForwarder() returns (address f) {
            forwarder = f;
        } catch {}
        return forwarder == address(0) ? router : ISwapper(forwarder);
    }

    /**
     * @notice The launch this vault burns, and the only one it ever can: the
     * factory recorded it when deploying this clone and has no means of
     * changing it. Reverts on the implementation itself, which belongs to
     * no launch and so can never burn or spend anything.
     */
    function token() public view returns (address launchToken) {
        launchToken = vaults.tokenOf(address(this));
        if (launchToken == address(0)) revert NotAVault();
    }

    /**
     * @notice Buys this launch's token back with everything the vault holds
     * and can claim for it, then burns the lot. Anyone may call it: there is
     * no recipient to pick and no parameter to tune, so a stranger calling
     * it only pays the gas for a burn that was going to happen regardless.
     * @return amount Tokens burned by this call.
     */
    function burn() external nonReentrant returns (uint256 amount) {
        return _burn(_everyMarket());
    }

    /**
     * @notice `burn()` limited to one of the launch's markets, for working
     * around a market whose quote asset has stopped functioning. The
     * launch-token side is claimed and burned exactly as in a full round;
     * the other markets are left alone, so nothing they hold is spent or
     * exposed.
     * @param index The market's position in `pendingBurn`'s `quotes`.
     */
    function burnMarket(uint256 index) external nonReentrant returns (uint256 amount) {
        uint256[] memory only = new uint256[](1);
        only[0] = index;
        return _burn(only);
    }

    /// @notice `burnMarket` across a chosen set of markets, in the order supplied.
    function burnMarkets(uint256[] calldata indexes) external nonReentrant returns (uint256 amount) {
        return _burn(indexes);
    }

    /**
     * @dev The body of every burn. Nothing outside this contract is trusted
     * to behave: the escrow claim, the balance read and the swap are each
     * wrapped, so a quote asset that reverts on a transfer to this address
     * or on `balanceOf` costs its own market its turn and costs the other
     * markets, and the launch-token side, nothing whatsoever.
     */
    function _burn(uint256[] memory indexes) private returns (uint256 amount) {
        address launchToken = token();
        (PoolKey[] memory keys, address[] memory quotes) =
            FusingBurnVaultLib.marketsOf(factory, multiFactory, launchToken);
        uint256 n = quotes.length;
        uint256[] memory spent = new uint256[](n);

        _tryClaim(launchToken);

        for (uint256 j = 0; j < indexes.length; j++) {
            uint256 i = indexes[j];
            if (i >= n) revert MarketOutOfRange(launchToken, i, n);
            address quote = quotes[i];
            _tryClaim(quote);
            (uint256 available, bool readable) = _tryBalanceOf(quote);
            if (!readable || available < MIN_QUOTE_SWAP) continue;
            spent[i] = _swap(keys[i], quote, available);
        }

        // Every V2 fee is paid in ETH, so a vault on a pool quoted in another
        // asset holds ETH it cannot swap in that pool directly. It buys along
        // the pricer's route instead: ETH to the quote, quote into the pool.
        _tryClaim(address(0)); // the ETH that every V2 collection pays, whatever asset the pool is quoted in
        for (uint256 j = 0; j < indexes.length; j++) {
            uint256 i = indexes[j];
            if (quotes[i] == address(0)) continue;
            uint256 ethAvailable = address(this).balance;
            if (ethAvailable < MIN_QUOTE_SWAP) break;
            uint256 ethSpent = _spendEth(keys[i], quotes[i], ethAvailable);
            if (ethSpent > 0) emit EthBuyback(launchToken, i, ethSpent);
        }

        amount = IERC20(launchToken).balanceOf(address(this));
        if (amount == 0) revert NothingToBurn(launchToken);

        // Sent to the dead address rather than destroyed: the supply figure
        // every explorer and bot shows stays at the launch figure, and the
        // burnt share is what they count at 0x...dEaD.
        IERC20(launchToken).safeTransfer(DEAD, amount);
        uint256 total = burnedTotal + amount;
        burnedTotal = total;
        emit Burned(launchToken, quotes, spent, amount, total);
    }

    /// @dev The index of every market, in market order.
    function _everyMarket() private view returns (uint256[] memory indexes) {
        (, address[] memory quotes) = FusingBurnVaultLib.marketsOf(factory, multiFactory, token());
        indexes = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            indexes[i] = i;
        }
    }

    /**
     * @notice What the next `burn()` would have to work with: the launch
     * token already claimable or held, and the same for each quote asset in
     * market order. A quote side under `MIN_QUOTE_SWAP` is left alone, and
     * one above the price cap is spent across several calls.
     */
    function pendingBurn()
        external
        view
        returns (uint256 tokenSide, address[] memory quotes, uint256[] memory quoteSides)
    {
        address launchToken = token();
        (, quotes) = FusingBurnVaultLib.marketsOf(factory, multiFactory, launchToken);
        tokenSide = _pending(launchToken);
        quoteSides = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            quoteSides[i] = _pending(quotes[i]);
        }
    }

    /// @notice This vault's balance of `asset` plus what the escrow owes it.
    function pending(address asset) public view returns (uint256) {
        return _pending(asset);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /**
     * @dev Claims this vault's escrow balance in `asset`, if there is one,
     * and moves on quietly when it cannot. The escrow's own ledger is sound,
     * but a claim ends in a transfer of `asset` to this address, and a quote
     * asset may refuse it: USDC and USDT can blacklist an address, an
     * upgradeable token can begin refusing at any moment, and a frozen token
     * refuses everyone. Unwrapped, any of those would take the whole burn
     * down with it, including the launch-token side, which has nothing to
     * do with the asset that failed. What is not claimed stays claimable.
     */
    function _tryClaim(address asset) private {
        if (asset == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) {
                try escrow.claim() {} catch {}
            }
        } else if (escrow.balanceOfToken(address(this), asset) > 0) {
            try escrow.claimToken(asset) {} catch {}
        }
    }

    /// @notice ETH spent on a buyback along the pricer's route, per market.
    event EthBuyback(address indexed token, uint256 indexed market, uint256 ethSpent);

    /**
     * @dev Buys the launch token with ETH on a market quoted in another
     * asset: the ETH follows the pricer's route to the quote and then goes
     * into the pool, in a single router call. Bounded exactly like `_swap`,
     * with the cap and the floor computed on the pool's quote side and the
     * ETH input sized from the pricer's spot valuation. On failure the ETH
     * stays here for the next call.
     */
    function _spendEth(PoolKey memory key, address quote, uint256 ethAvailable) private returns (uint256 consumed) {
        IQuotePricerRoute pricer = IQuotePricerRoute(factory.quotePricer());
        (Hop[] memory hops, bool qualifies) = pricer.route(quote);
        if (!qualifies || hops.length == 0) return 0;
        uint256 quotePerEth;
        try pricer.priceEthAmountInQuote(quote, 1 ether) returns (uint256 q) {
            quotePerEth = q;
        } catch {
            return 0;
        }
        if (quotePerEth == 0) return 0;

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || liquidity == 0) return 0;
        uint24 fee = key.fee;
        if (fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && address(key.hooks) != address(0)) {
            try IFusingFeeHookFee(address(key.hooks)).currentFee(id) returns (uint24 f) {
                fee = f;
            } catch {
                return 0;
            }
        }
        if (fee >= PIPS) return 0;

        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        uint256 quoteEquivalent = FullMath.mulDiv(ethAvailable, quotePerEth, 1 ether);
        uint256 quoteIn = _cappedInput(sqrtPriceX96, liquidity, fee, zeroForOne, quoteEquivalent);
        if (quoteIn < MIN_QUOTE_SWAP) return 0;
        (uint256 minOut, bool ok) = _floor(sqrtPriceX96, fee, zeroForOne, quoteIn);
        if (!ok) return 0;
        // A second leg brings a second spread; grant it the same tolerance once more.
        minOut = (minOut * (BASIS_POINTS - SWAP_TOLERANCE_BPS)) / BASIS_POINTS;
        uint256 ethIn = FullMath.mulDiv(quoteIn, 1 ether, quotePerEth);
        if (ethIn == 0) return 0;
        if (ethIn > ethAvailable) ethIn = ethAvailable;

        // The pricer records hops in the quote-to-ETH direction; a buy traverses them in reverse.
        Hop[] memory leg = new Hop[](hops.length);
        for (uint256 k = 0; k < hops.length; k++) {
            leg[k] = hops[hops.length - 1 - k];
        }
        uint256 before = address(this).balance;
        uint256 tokensBefore = IERC20(token()).balanceOf(address(this));
        try IEthBuyer(address(activeRouter())).buyWithEth{value: ethIn}(key, leg, minOut, address(this)) returns (uint256) {}
        catch {
            return 0;
        }
        uint256 got = IERC20(token()).balanceOf(address(this)) - tokensBefore;
        if (got < minOut) revert ShortFill(got, minOut);
        return before > address(this).balance ? before - address(this).balance : 0;
    }

    /**
     * @dev One quote-side buyback through the launch pool, with the output
     * kept here for the burn. The input is capped so the swap cannot move
     * the pool by more than `MAX_SQRT_MOVE_BPS` and carries a floor derived
     * from the pool's pre-swap price; a failure of either sort leaves the
     * quote where it is for the next call instead of sinking the whole burn.
     * @return consumed The quote the swap really took.
     */
    function _swap(PoolKey memory key, address quote, uint256 available) private returns (uint256 consumed) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        // No pool, no liquidity in range, or a fee that is not a plain static
        // one: there is nothing to price the swap against, so nothing is
        // attempted and the quote waits for a call that can.
        if (sqrtPriceX96 == 0 || liquidity == 0) return 0;
        // V2 pools carry the dynamic-fee flag and the fee hook sets the fee
        // on every swap; ask it what this moment's fee is. A static fee that
        // is not a plain one is still turned away.
        uint24 fee = key.fee;
        if (fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && address(key.hooks) != address(0)) {
            try IFusingFeeHookFee(address(key.hooks)).currentFee(id) returns (uint24 f) {
                fee = f;
            } catch {
                return 0;
            }
        }
        if (fee >= PIPS) return 0;

        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        uint256 amountIn = _cappedInput(sqrtPriceX96, liquidity, fee, zeroForOne, available);
        if (amountIn < MIN_QUOTE_SWAP) return 0;
        (uint256 minOut, bool ok) = _floor(sqrtPriceX96, fee, zeroForOne, amountIn);
        if (!ok) return 0;

        (uint256 before, bool readable) = _tryBalanceOf(quote);
        if (!readable) return 0;
        ISwapper r = activeRouter();
        uint256 tokensBefore = IERC20(token()).balanceOf(address(this));
        if (quote == address(0)) {
            try r.swapExactIn{value: amountIn}(key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                return 0;
            }
        } else {
            IERC20(quote).forceApprove(address(r), amountIn);
            try r.swapExactIn(key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                IERC20(quote).forceApprove(address(r), 0);
                return 0;
            }
            IERC20(quote).forceApprove(address(r), 0);
        }
        uint256 got = IERC20(token()).balanceOf(address(this)) - tokensBefore;
        if (got < minOut) revert ShortFill(got, minOut);
        (uint256 remaining, bool stillReadable) = _tryBalanceOf(quote);
        if (!stillReadable) return 0;
        return before > remaining ? before - remaining : 0;
    }

    /**
     * @dev `available`, or however much of it shifts the square root of the
     * pool's price by no more than `MAX_SQRT_MOVE_BPS`, whichever is less.
     * The band is priced with the pool's own maths at the liquidity in
     * range, then grossed up by the pool's fee, because the fee comes off
     * the input before any of it reaches the curve.
     */
    function _cappedInput(uint160 sqrtPriceX96, uint128 liquidity, uint24 fee, bool zeroForOne, uint256 available)
        private
        pure
        returns (uint256)
    {
        uint256 move = (uint256(sqrtPriceX96) * MAX_SQRT_MOVE_BPS) / BASIS_POINTS;
        if (move == 0) return 0;
        uint256 net;
        if (zeroForOne) {
            // Selling currency0 into the pool pushes the price down.
            uint160 target = uint160(uint256(sqrtPriceX96) - move);
            if (target < TickMath.MIN_SQRT_PRICE) target = TickMath.MIN_SQRT_PRICE;
            net = SqrtPriceMath.getAmount0Delta(target, sqrtPriceX96, liquidity, true);
        } else {
            uint256 raised = uint256(sqrtPriceX96) + move;
            uint160 target = raised > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(raised);
            net = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, target, liquidity, true);
        }
        if (net == 0) return 0;
        uint256 cap = FullMath.mulDiv(net, PIPS, PIPS - fee);
        return available < cap ? available : cap;
    }

    /**
     * @dev The minimum a swap of `amountIn` may return: the input net of the
     * pool's fee, valued at the pool's current price, less
     * `SWAP_TOLERANCE_BPS`. `ok` is false when no figure can be computed at
     * all, in which case the swap is skipped rather than sent out without a
     * floor.
     */
    function _floor(uint160 sqrtPriceX96, uint24 fee, bool zeroForOne, uint256 amountIn)
        private
        pure
        returns (uint256 minOut, bool ok)
    {
        uint256 net = amountIn - FullMath.mulDivRoundingUp(amountIn, fee, PIPS);
        if (net == 0 || net > type(uint128).max) return (0, false);
        uint256 valued = _valueAtSqrtPrice(sqrtPriceX96, uint128(net), zeroForOne);
        if (valued == 0) return (0, false);
        return ((valued * (BASIS_POINTS - SWAP_TOLERANCE_BPS)) / BASIS_POINTS, true);
    }

    /**
     * @dev What `amount` of the pool's input side is worth in its output
     * side at `sqrtRatioX96`, with no curve impact. The same maths as
     * Uniswap V3's OracleLibrary.getQuoteAtTick, taking the square root
     * price directly, and the same FusingQuotePricer uses; `zeroForOne`
     * says which side the amount sits on, so no address ordering is needed.
     */
    function _valueAtSqrtPrice(uint160 sqrtRatioX96, uint128 amount, bool zeroForOne) private pure returns (uint256) {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return
                zeroForOne ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return zeroForOne ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
    }

    /**
     * @dev This vault's balance of `asset`. `balanceOf` is a call into the
     * asset's own code and a frozen or hostile token can revert from it,
     * one step before a refused transfer would, and without the wrapper it
     * would take the whole burn down the same way. `ok` false means the
     * market is skipped.
     */
    function _tryBalanceOf(address asset) private view returns (uint256 balance, bool ok) {
        if (asset == address(0)) return (address(this).balance, true);
        try IERC20(asset).balanceOf(address(this)) returns (uint256 b) {
            return (b, true);
        } catch {
            return (0, false);
        }
    }

    function _pending(address asset) private view returns (uint256) {
        return FusingBurnVaultLib.pending(escrow, address(this), asset);
    }
}

/**
 * @title FusingBurnVaultFactory
 * @notice Deploys and addresses the burn vaults: one per launch, at an
 * address derived from the launch token, which makes the fee escrow's
 * per-recipient accounting per-launch accounting.
 *
 * A vault is an EIP-1167 minimal proxy over a single shared implementation
 * that this contract deploys in its own constructor and can never swap out.
 * The salt is the launch token address, so `vaultFor(token)` gives the
 * vault's address whether or not it exists yet: a launch form can compute
 * it ahead of the launch transaction and name it as `creatorFeeRecipient`,
 * and anyone can deploy the clone itself, before or after that launch.
 * Deploying late loses nothing, because fees credited to an address with
 * no code wait in the escrow until the code that claims them exists.
 *
 * There is no owner and nothing to configure. `deploy` is open and
 * idempotent, `tokenOf` is written once per vault and never again, and the
 * only other thing this contract can do is forward `burn` to a vault, where
 * it is open to anyone as well.
 */
contract FusingBurnVaultFactory is IBurnVaultRegistry {
    /// @notice The implementation every vault delegates to, deployed from here.
    address public immutable implementation;
    /// @notice keccak256 of a vault's creation code, so addresses can be derived off chain.
    bytes32 public immutable proxyInitCodeHash;

    /// @notice The ledger the lockers credit vault fees to.
    IFusingFeeEscrow public immutable escrow;
    /// @notice FusingRouter, the only venue the vaults swap on.
    ISwapper public immutable router;
    /// @notice The single-market factory, for launch records and pool keys.
    IBurnVaultLaunchFactory public immutable factory;
    /// @notice The MultiFuse factory, for the same data per market.
    IMultiFuseFactory public immutable multiFactory;
    /// @notice Uniswap's PoolManager, consulted for the price a buyback has to beat.
    IPoolManager public immutable poolManager;

    /// @notice The launch a deployed vault serves. Written once, when it is deployed.
    mapping(address vault => address token) public tokenOf;

    event VaultDeployed(address indexed token, address indexed vault);

    error ZeroAddress();
    error DeployFailed(address token);

    constructor(
        IFusingFeeEscrow escrow_,
        ISwapper router_,
        IBurnVaultLaunchFactory factory_,
        IMultiFuseFactory multiFactory_,
        IPoolManager poolManager_
    ) {
        if (
            address(escrow_) == address(0) || address(router_) == address(0) || address(factory_) == address(0)
                || address(multiFactory_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        escrow = escrow_;
        router = router_;
        factory = factory_;
        multiFactory = multiFactory_;
        poolManager = poolManager_;
        // The implementation is deployed right here, so a vault's code is
        // pinned by this contract's own construction: no address to pass in,
        // and nothing that can be pointed elsewhere later.
        address impl = address(new FusingBurnVault(this, escrow_, router_, factory_, multiFactory_, poolManager_));
        implementation = impl;
        proxyInitCodeHash = keccak256(_proxyInitCode(impl));
    }

    /**
     * @notice The vault address for `token`, deployed or not. CREATE2 salted
     * with the token address, so it can also be derived off chain from this
     * contract's address and `proxyInitCodeHash` alone.
     */
    function vaultFor(address token) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(token))), proxyInitCodeHash)
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Whether `token`'s vault exists on chain yet.
    function isDeployed(address token) public view returns (bool) {
        return vaultFor(token).code.length != 0;
    }

    /**
     * @notice Deploys `token`'s vault if it is not there yet and returns it
     * in either case. Open to anyone and harmless to call twice; the launch
     * itself does not depend on it having happened.
     */
    function deploy(address token) public returns (address vault) {
        vault = vaultFor(token);
        if (vault.code.length != 0) return vault;
        if (token == address(0)) revert ZeroAddress();

        bytes memory initCode = _proxyInitCode(implementation);
        bytes32 salt = bytes32(uint256(uint160(token)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (deployed != vault) revert DeployFailed(token);
        tokenOf[deployed] = token;
        emit VaultDeployed(token, deployed);
    }

    /**
     * @notice One buyback-and-burn round for `token`, deploying its vault
     * first if this is the first round. A keeper's entire job in one call.
     * @return amount Tokens burned by this call.
     */
    function burn(address token) external returns (uint256 amount) {
        return FusingBurnVault(payable(deploy(token))).burn();
    }

    /**
     * @notice One buyback-and-burn round for `token` on a single market,
     * the counterpart of MultiFuseLocker's `collectMarketFees`. The
     * way around a market whose quote asset no longer accepts transfers to
     * the vault: the rest of the launch, and the launch-token side, carry
     * on regardless.
     * @param index The market's position in `pendingBurn`'s `quotes`.
     */
    function burnMarket(address token, uint256 index) external returns (uint256 amount) {
        return FusingBurnVault(payable(deploy(token))).burnMarket(index);
    }

    /// @notice `burnMarket` across a chosen set of markets, in the order supplied.
    function burnMarkets(address token, uint256[] calldata indexes) external returns (uint256 amount) {
        return FusingBurnVault(payable(deploy(token))).burnMarkets(indexes);
    }

    /**
     * @notice What the next `burn(token)` would have to work with: the
     * launch token already claimable or held by the vault, and the same for
     * each quote asset in market order. Works for a vault that is not
     * deployed yet as well, because the escrow credits the address, not the
     * code.
     */
    function pendingBurn(address token)
        external
        view
        returns (uint256 tokenSide, address[] memory quotes, uint256[] memory quoteSides)
    {
        address vault = vaultFor(token);
        (, quotes) = FusingBurnVaultLib.marketsOf(factory, multiFactory, token);
        tokenSide = FusingBurnVaultLib.pending(escrow, vault, token);
        quoteSides = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            quoteSides[i] = FusingBurnVaultLib.pending(escrow, vault, quotes[i]);
        }
    }

    /// @notice Total `token`'s vault has burned; zero until it exists.
    function burnedTotal(address token) external view returns (uint256) {
        address vault = vaultFor(token);
        if (vault.code.length == 0) return 0;
        return FusingBurnVault(payable(vault)).burnedTotal();
    }

    /**
     * @dev The 55 bytes of EIP-1167: 10 bytes returning the 45-byte runtime,
     * followed by the runtime itself with the implementation address in the
     * middle.
     */
    function _proxyInitCode(address impl) private pure returns (bytes memory) {
        return
            abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
