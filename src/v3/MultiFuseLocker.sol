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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IERC721ReceiverLike, IFusingFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";
import {IMultiFuseFactory} from "./interfaces/ILaunchpadV3.sol";

/**
 * @title MultiFuseLocker
 * @notice Holds the Uniswap V4 position NFTs behind a MultiFuse launch
 * for good, and harvests the LP fees those positions earn.
 *
 * It plays the role FusingLaunchLocker plays for single-market launches,
 * extended to several markets: one position per market, every one of them
 * locked here, all harvested in a single call and divided on the terms the
 * factory fixed at launch. The creator's portion of every currency is
 * credited to the shared FusingFeeEscrow. The protocol's portion of each
 * quote asset is sent to the protocol fee recipient (falling back to an
 * escrow credit if that transfer fails), and the protocol's portion of the
 * launch token is burned.
 *
 * The one and only position action this contract ever encodes is a
 * zero-liquidity decrease, the Uniswap V4 idiom for collecting fees while
 * leaving the liquidity untouched. There is no withdraw function and no
 * arbitrary-call function, so nobody can ever pull the liquidity out from
 * under a launch.
 */
contract MultiFuseLocker is Ownable2Step, ReentrancyGuard, IERC721ReceiverLike {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant COLLECT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionAlreadyLocked();
    error PositionNotHeld();
    error NotPositionManager();
    error OwnershipCannotBeRenounced();
    error TokenNotLaunched();
    error InexactTransfer(address token, uint256 expected, uint256 received);
    error NoPositions();

    event FactorySet(address factory);
    event PositionLocked(address indexed token, uint256 indexed tokenId, uint256 marketIndex);
    /// @notice Fees earned in the launch token that fell to the protocol were burned.
    event ProtocolShareBurned(address indexed token, uint256 amount);
    /**
     * @notice Emitted for every market where there was something to
     * harvest. Amounts follow the pool's currency order, and for each
     * currency `protocol*` plus `creator*` equals what the position paid
     * out.
     */
    event FeesCollected(
        address indexed token,
        uint256 indexed marketIndex,
        address currency0,
        address currency1,
        uint256 protocolAmount0,
        uint256 protocolAmount1,
        uint256 creatorAmount0,
        uint256 creatorAmount1
    );

    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IFusingFeeEscrow public immutable feeEscrow;
    IMultiFuseFactory public factory;

    mapping(address token => uint256[] tokenIds) private _lockedPositions;

    /**
     * @param initialOwner Admin address whose only job is the one-off factory wiring.
     * @param positionManager_ The canonical Uniswap V4 PositionManager on this chain.
     * @param feeEscrow_ The ledger harvested fees are credited to, shared with the single-market launches.
     */
    constructor(address initialOwner, IPositionManager positionManager_, IFusingFeeEscrow feeEscrow_)
        Ownable(initialOwner)
    {
        if (address(positionManager_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        feeEscrow = feeEscrow_;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert NotFactory();
        _;
    }

    /**
     * @notice Wires in the factory exactly once, after both contracts exist
     * on chain.
     */
    function setFactory(address factory_) external onlyOwner {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IMultiFuseFactory(factory_);
        emit FactorySet(factory_);
    }

    /**
     * @notice Always reverts. The owner role exists solely for the one-off
     * factory wiring, so there is nothing to renounce.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /**
     * @notice Accepts safe transfers only from the canonical PositionManager;
     * any other NFT is refused.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Records a launch's positions, in market order, and confirms
     * that this contract really owns each of them. The factory calls it
     * once per launch, immediately after minting the positions here.
     */
    function lockPositions(address token, uint256[] calldata tokenIds) external onlyFactory {
        if (_lockedPositions[token].length != 0) revert PositionAlreadyLocked();
        if (tokenIds.length == 0) revert NoPositions();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (IERC721(address(positionManager)).ownerOf(tokenIds[i]) != address(this)) revert PositionNotHeld();
            _lockedPositions[token].push(tokenIds[i]);
            emit PositionLocked(token, tokenIds[i], i);
        }
    }

    function isLocked(address token) external view returns (bool) {
        return _lockedPositions[token].length != 0;
    }

    function lockedPositions(address token) external view returns (uint256[] memory) {
        return _lockedPositions[token];
    }

    // ---------------------------------------------------------------------
    // Harvesting fees
    // ---------------------------------------------------------------------

    /**
     * @notice Fees accrued but not yet harvested on market `index` of
     * `token`, in the pool's currency order. Matches the harvested amounts
     * to the wei.
     */
    function pendingFees(address token, uint256 index) public view returns (uint256 amount0, uint256 amount1) {
        _requireLaunched(token);
        IMultiFuseFactory.Market memory m = factory.getMarket(token, index);
        PoolId poolId = factory.poolKeyFor(token, index).toId();
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, m.tickLower, m.tickUpper);
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(
            poolId, address(positionManager), m.tickLower, m.tickUpper, bytes32(m.positionId)
        );
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @notice Unharvested fees across all markets of `token`, listed in
     * market order with each pool's own currency order.
     */
    function pendingFeesAll(address token) external view returns (uint256[] memory amount0, uint256[] memory amount1) {
        uint256 n = _requireLaunched(token).marketCount;
        amount0 = new uint256[](n);
        amount1 = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (amount0[i], amount1[i]) = pendingFees(token, i);
        }
    }

    /**
     * @notice Harvests the accrued fees of every market, sends the protocol
     * its cut of each quote asset, burns its cut of the launch token and
     * credits the creator's cut of everything to the fee escrow. Anyone may
     * call it, because the launch record already dictates who gets paid.
     * @return collected Total paid out per market in each pool's currency
     * order, flattened as [m0.amount0, m0.amount1, m1.amount0, ...].
     */
    function collectFees(address token) external nonReentrant returns (uint256[] memory collected) {
        IMultiFuseFactory.LaunchedToken memory launch = _requireLaunched(token);
        uint256[] storage ids = _lockedPositions[token];
        uint256 n = ids.length;
        collected = new uint256[](2 * n);
        for (uint256 i = 0; i < n; i++) {
            (collected[2 * i], collected[2 * i + 1]) = _collectMarket(token, i, ids[i], launch);
        }
    }

    /**
     * @notice Harvests a single market. Handy when one pool is seeing all
     * the volume and the others have nothing to collect.
     */
    function collectMarketFees(address token, uint256 index)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        IMultiFuseFactory.LaunchedToken memory launch = _requireLaunched(token);
        return _collectMarket(token, index, _lockedPositions[token][index], launch);
    }

    function _collectMarket(
        address token,
        uint256 index,
        uint256 tokenId,
        IMultiFuseFactory.LaunchedToken memory launch
    ) private returns (uint256 amount0, uint256 amount1) {
        PoolKey memory key = factory.poolKeyFor(token, index);

        uint256 before0 = _balance(key.currency0);
        uint256 before1 = _balance(key.currency1);

        // Decreasing by zero liquidity turns the fees the position is owed
        // into deltas on this call, and TAKE_PAIR then pays them to us.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + COLLECT_DEADLINE_WINDOW);

        amount0 = _balance(key.currency0) - before0;
        amount1 = _balance(key.currency1) - before1;
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        // protocol cut of the total fee = its share of the base fee, scaled by base / (base + creator tax)
        uint256 totalFeeBps = uint256(launch.baseFeeBps) + launch.creatorTaxBps;
        uint256 protocol0 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount0, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);
        uint256 protocol1 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount1, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);

        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        if (tokenIs0) _burn(token, protocol0);
        else _payProtocol(key.currency0, launch.protocolFeeRecipient, protocol0);
        _credit(key.currency0, launch.creatorFeeRecipient, amount0 - protocol0);
        if (tokenIs0) _payProtocol(key.currency1, launch.protocolFeeRecipient, protocol1);
        else _burn(token, protocol1);
        _credit(key.currency1, launch.creatorFeeRecipient, amount1 - protocol1);

        emit FeesCollected(
            token,
            index,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            protocol0,
            protocol1,
            amount0 - protocol0,
            amount1 - protocol1
        );
    }

    function _requireLaunched(address token)
        private
        view
        returns (IMultiFuseFactory.LaunchedToken memory launch)
    {
        launch = factory.getLaunchedToken(token);
        if (!launch.exists || _lockedPositions[token].length == 0) revert TokenNotLaunched();
    }

    function _balance(Currency currency) private view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /**
     * @dev Pays the protocol's cut directly to its wallet. ETH goes out with
     * a capped gas stipend so a badly behaved recipient cannot block the
     * harvest; when the send fails, the amount is credited to the escrow
     * instead and the recipient can claim it from there.
     */
    function _payProtocol(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool ok,) = recipient.call{value: amount, gas: 50_000}("");
            if (!ok) feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
    }

    /// @notice Where the protocol's launch-token share goes: the dead address, so the supply figure never moves.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /**
     * @dev Sends the protocol's cut of fees earned in the launch token to the
     * dead address. A transfer rather than a supply reduction, so explorers
     * and bots keep showing the launch supply and count the burn at 0x...dEaD.
     */
    function _burn(address token, uint256 amount) private {
        if (amount == 0) return;
        IERC20(token).safeTransfer(DEAD, amount);
        emit ProtocolShareBurned(token, amount);
    }

    function _credit(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            feeEscrow.credit{value: amount}(recipient);
            return;
        }
        address asset = Currency.unwrap(currency);
        uint256 escrowBefore = IERC20(asset).balanceOf(address(feeEscrow));
        IERC20(asset).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, asset, amount);
        uint256 received = IERC20(asset).balanceOf(address(feeEscrow)) - escrowBefore;
        if (received != amount) revert InexactTransfer(asset, amount, received);
    }

    /// @notice Receives the native ETH the pool manager pays out.
    receive() external payable {}
}
