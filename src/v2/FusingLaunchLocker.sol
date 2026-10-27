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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev The fee hook premium counter: what the pool swaps paid above the resting fee since the last collection.
interface IFusingFeeHookPremium {
    function consumePremium(PoolId id) external returns (uint256 p0, uint256 p1);
}
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IERC721ReceiverLike, IFusingFeeEscrow, IFusingLaunchFactory, IFusingFeeConverter} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice The parts of the factory the locker needs to read: the record of
 * a launch and its pool key.
 */
interface IFusingLaunchFactoryView is IFusingLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/**
 * @title FusingLaunchLocker
 * @notice Holds, for good, the Uniswap V4 position NFT that makes up each
 * fusi.ng launch's market, and collects the LP fees the position earns.
 *
 * A launch pool's hook only sets the LP fee, so a trade's fee accrues to the
 * position the way it does on any Uniswap pool: in the currency the trader
 * paid with. Buys pay it in the quote asset, sells pay it in the launch
 * token. `collectFees` is open to anyone; what it collects is split on the
 * terms the factory fixed at launch and handed to the converter, which pays
 * the protocol in ETH and the creator by the launch's payout mode, through
 * FusingFeeEscrow. Should the converter ever fail, the collection does not:
 * this contract then credits the raw fees to the escrow itself, the
 * protocol's quote paid directly where it can be, so nothing is lost and no
 * collection is ever blocked.
 *
 * Only two position actions are ever encoded by this contract: a decrease of
 * zero liquidity, which is V4's way of collecting fees without touching the
 * liquidity itself, and (new in V2) an increase, `addLiquidity`, through
 * which anyone can add more of both sides to a launch's locked position.
 * That is the mechanism by which a launch's auto-liquidity vault turns fees
 * into permanent depth. There is no withdraw function and no arbitrary-call
 * function, so nobody can ever pull the liquidity behind a launch; it can
 * only grow.
 */
contract FusingLaunchLocker is Ownable2Step, ReentrancyGuard, IERC721ReceiverLike {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 private constant BASIS_POINTS = 10_000;
    /// @notice The protocol share of every premium fee (sniper tax, opening fee): 10%. The creator keeps the rest.
    uint256 public constant PREMIUM_PROTOCOL_BPS = 1_000;
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
    /// @dev `addLiquidity`: msg.value must equal the native quote amount, no more and no less.
    error NativeMismatch(uint256 expected, uint256 actual);
    /// @dev `addLiquidity`: the amounts supplied are too small to buy even one unit of liquidity.
    error NothingToAdd();
    error AmountTooLarge();
    error EthTransferFailed(address to);

    /**
     * @notice V2: emitted when liquidity is added to a launch's locked
     * position post-launch. `amount0`/`amount1` are the amounts the position
     * really consumed, in the pool's currency order; `positionLiquidity` is
     * the position's total once the add is done.
     */
    event LiquidityAdded(
        address indexed token, address indexed from, uint128 liquidity, uint256 amount0, uint256 amount1, uint128 positionLiquidity
    );

    /// @dev Mirrors ActionConstants.OPEN_DELTA in the PositionManager: settle whatever is owed in full.
    uint256 private constant OPEN_DELTA = 0;

    event FactorySet(address factory);
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event TokenSupplyLocked(address indexed token, uint256 amount);
    /// @notice Burn of the protocol's share of fees that came in as launch tokens.
    event ProtocolShareBurned(address indexed token, uint256 amount);
    /**
     * @notice Emitted by each `collectFees` call that collected a nonzero
     * amount. Amounts follow the pool's currency order; for each currency,
     * `protocol*` plus `creator*` equals what the position paid out.
     */
    event FeesCollected(
        address indexed token,
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
    IFusingLaunchFactoryView public factory;

    mapping(address token => uint256 tokenId) public lockedPositions;
    mapping(address token => uint256 amount) public lockedTokenSupply;
    mapping(address token => bool locked) private _locked;

    /**
     * @param initialOwner Admin owner; its only job is the one-time factory wiring.
     * @param positionManager_ Uniswap's canonical V4 PositionManager on this chain.
     * @param feeEscrow_ The ledger that collected fees are credited into.
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
     * @notice Points the locker at the factory. Can be done once, after both contracts exist.
     */
    function setFactory(address factory_) external onlyOwner {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IFusingLaunchFactoryView(factory_);
        emit FactorySet(factory_);
    }

    /**
     * @notice V2: each collection is passed to the converter, which pays every
     * recipient according to the launch's payout mode. The owner can swap it
     * out, so a faulty converter is replaced for all launches in one go; and
     * if the current one reverts, the collection still succeeds: see
     * `_collectFees`, which falls back to crediting the fees unconverted.
     */
    IFusingFeeConverter public converter;

    event ConverterSet(address converter);
    /// @notice The converter reverted during this collection, so the fees were credited unconverted.
    event ConverterFallback(address indexed token, bytes reason);

    error ConverterNotSet();
    error NotSelf();

    function setConverter(address converter_) external onlyOwner {
        if (converter_ == address(0)) revert ZeroAddress();
        converter = IFusingFeeConverter(converter_);
        emit ConverterSet(converter_);
    }

    /**
     * @notice Always reverts. The owner role exists solely for the one-time
     * factory wiring, so giving it up is not an option.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /**
     * @notice Refuses any safe transfer that is not a canonical position NFT.
     * @dev The launch flow never hits this: the launch sets this locker as the
     * `MINT_POSITION` owner, and the PositionManager mints with a bare `_mint`
     * that triggers no receiver callback. Custody is proven instead by the
     * `ownerOf` check inside `lockPosition`.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Records a launch position and confirms this contract holds it
     * for good. The factory calls it once per launch, immediately after the
     * position has been minted to this contract.
     */
    function lockPosition(address token, uint256 tokenId) external onlyFactory {
        if (_locked[token]) revert PositionAlreadyLocked();
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert PositionNotHeld();

        _locked[token] = true;
        lockedPositions[token] = tokenId;
        emit PositionLocked(token, tokenId);
    }

    /**
     * @notice Locks forever any launch tokens the position could not absorb.
     * Rounding dust usually just gets transferred here; this function lets
     * the factory lock larger leftovers explicitly and on record.
     */
    function lockTokenSupply(address token, uint256 amount) external onlyFactory {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lockedTokenSupply[token] += amount;
        emit TokenSupplyLocked(token, amount);
    }

    function isLocked(address token) external view returns (bool) {
        return _locked[token];
    }

    // ---------------------------------------------------------------------
    // Collecting fees
    // ---------------------------------------------------------------------

    /**
     * @notice Fees earned by the launch position that have not been collected
     * yet, in the pool's currency order. Computed from the pool's fee growth,
     * so the figure matches to the wei what a collection would pay out.
     */
    function pendingFees(address token) external view returns (uint256 amount0, uint256 amount1) {
        IFusingLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolId poolId = factory.poolKeyFor(token).toId();
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, launch.tickLower, launch.tickUpper);
        // Every managed position is owned by the PositionManager, keyed
        // with the NFT id as its salt.
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(
            poolId, address(positionManager), launch.tickLower, launch.tickUpper, bytes32(launch.positionId)
        );
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @notice Collects the fees the launch position has accrued and hands
     * them to the converter, which pays the protocol in ETH and the creator
     * by the launch's payout mode. Anyone may call it: the recipients come
     * from the launch record, so an outsider calling it can only ever help
     * the beneficiaries.
     * @dev Split according to the fee terms fixed at launch. The pool fee is
     * base plus creator tax; the protocol takes its share of the base portion
     * and the creator gets the rest, the same way for both currencies.
     */
    function collectFees(address token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        IFusingLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolKey memory key = factory.poolKeyFor(token);
        return _collectFees(token, launch, key);
    }

    function _collectFees(address token, IFusingLaunchFactory.LaunchedToken memory launch, PoolKey memory key)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 tokenId = lockedPositions[token];

        uint256 before0 = _balance(key.currency0);
        uint256 before1 = _balance(key.currency1);

        // Decreasing by zero liquidity turns the position's owed fees into
        // deltas for this call; TAKE_PAIR then pays them out to this contract.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + COLLECT_DEADLINE_WINDOW);

        amount0 = _balance(key.currency0) - before0;
        amount1 = _balance(key.currency1) - before1;
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        // Premiums (sniper tax, opening fee) are split a tenth to the
        // protocol and the rest to the creator. The hook counted them per
        // swap; they can never exceed what was actually collected.
        uint256 prem0;
        uint256 prem1;
        if (address(key.hooks) != address(0)) {
            (prem0, prem1) = IFusingFeeHookPremium(address(key.hooks)).consumePremium(PoolIdLibrary.toId(key));
            if (prem0 > amount0) prem0 = amount0;
            if (prem1 > amount1) prem1 = amount1;
        }
        // protocol's cut of the resting fee = its share of the base fee * base / (base + tax); the creator tax is all the creator's
        uint256 totalFeeBps = uint256(launch.baseFeeBps) + launch.creatorTaxBps;
        uint256 protocol0 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount0 - prem0, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);
        uint256 protocol1 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount1 - prem1, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);
        protocol0 += prem0 * PREMIUM_PROTOCOL_BPS / BASIS_POINTS;
        protocol1 += prem1 * PREMIUM_PROTOCOL_BPS / BASIS_POINTS;

        // V2: the whole collection goes to the converter, which converts it
        // and pays the protocol and the creator by the launch's payout mode.
        // The split computed above is still emitted for the indexer. The
        // hand-off is a single external call on this contract, so when the
        // converter reverts its transfers are rolled back with it, and the
        // collection credits the unconverted fees as V1 did rather than fail:
        // a broken converter never blocks a collection, nothing is lost meanwhile.
        if (address(converter) == address(0)) revert ConverterNotSet();
        {
            bool tokenIs0 = Currency.unwrap(key.currency0) == token;
            uint256 tokenAmount = tokenIs0 ? amount0 : amount1;
            uint256 quoteAmount = tokenIs0 ? amount1 : amount0;
            Currency quote = tokenIs0 ? key.currency1 : key.currency0;
            try this.settleThroughConverter(token, quote, tokenAmount, quoteAmount) {}
            catch (bytes memory reason) {
                emit ConverterFallback(token, reason);
                _payRaw(token, launch, key, amount0, amount1, protocol0, protocol1);
            }
        }

        emit FeesCollected(
            token,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            protocol0,
            protocol1,
            amount0 - protocol0,
            amount1 - protocol1
        );
    }

    // ---------------------------------------------------------------------
    // V2: adding to the locked position
    // ---------------------------------------------------------------------

    /// @notice Current liquidity of the launch position, straight from the pool.
    function positionLiquidity(address token) public view returns (uint128 liquidity) {
        IFusingLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolId poolId = factory.poolKeyFor(token).toId();
        (liquidity,,) = poolManager.getPositionInfo(
            poolId, address(positionManager), launch.tickLower, launch.tickUpper, bytes32(launch.positionId)
        );
    }

    /**
     * @notice Puts `tokenAmount` of the launch token and `quoteAmount` of the
     * quote into the launch's locked position, using as much of each as the
     * position accepts at the current price, and refunds the remainder to
     * the caller. Anyone may call it: the position is locked permanently, so
     * whatever goes in is a gift to every holder, and nothing can come back
     * out.
     *
     * A native quote is sent as msg.value; an ERC-20 quote and the launch
     * token are pulled via allowance. Any uncollected fees are collected
     * first, because otherwise a Uniswap V4 increase would roll them into
     * the new liquidity rather than paying them out.
     * @return liquidity How much the position grew.
     * @return used0 How much currency0 it consumed.
     * @return used1 How much currency1 it consumed.
     */
    function addLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount)
        external
        payable
        nonReentrant
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        IFusingLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolKey memory key = factory.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        Currency quote = tokenIs0 ? key.currency1 : key.currency0;
        if (quote.isAddressZero() ? msg.value != quoteAmount : msg.value != 0) {
            revert NativeMismatch(quote.isAddressZero() ? quoteAmount : 0, msg.value);
        }
        if (tokenAmount == 0 && quoteAmount == 0) revert NothingToAdd();

        _collectFees(token, launch, key);

        // Whatever this contract held before the call (mostly locked dust) is left alone.
        uint256 base0 = _balance(key.currency0) - (key.currency0.isAddressZero() ? msg.value : 0);
        uint256 base1 = _balance(key.currency1) - (key.currency1.isAddressZero() ? msg.value : 0);
        if (tokenAmount > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        if (!quote.isAddressZero() && quoteAmount > 0) {
            IERC20(Currency.unwrap(quote)).safeTransferFrom(msg.sender, address(this), quoteAmount);
        }
        uint256 have0 = _balance(key.currency0) - base0;
        uint256 have1 = _balance(key.currency1) - base1;
        if (have0 > type(uint128).max || have1 > type(uint128).max) revert AmountTooLarge();

        liquidity = _fit(launch, key, have0, have1);
        if (liquidity == 0) revert NothingToAdd();

        // Each ERC-20 side is transferred to the PositionManager up front
        // and it settles from its own balance (payerIsUser = false); the
        // native side comes from the attached value. The two sweeps return
        // whatever the increase left unused.
        if (!key.currency0.isAddressZero() && have0 > 0) {
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(positionManager), have0);
        }
        if (!key.currency1.isAddressZero() && have1 > 0) {
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(positionManager), have1);
        }
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](5);
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(lockedPositions[token], uint256(liquidity), uint128(have0), uint128(have1), bytes(""));
        params[1] = abi.encode(key.currency0, OPEN_DELTA, false);
        params[2] = abi.encode(key.currency1, OPEN_DELTA, false);
        params[3] = abi.encode(key.currency0, address(this));
        params[4] = abi.encode(key.currency1, address(this));
        positionManager.modifyLiquidities{value: msg.value}(
            abi.encode(actions, params), block.timestamp + COLLECT_DEADLINE_WINDOW
        );

        uint256 left0 = _balance(key.currency0) - base0;
        uint256 left1 = _balance(key.currency1) - base1;
        used0 = have0 - left0;
        used1 = have1 - left1;
        if (left0 > 0) _payOut(key.currency0, msg.sender, left0);
        if (left1 > 0) _payOut(key.currency1, msg.sender, left1);
        emit LiquidityAdded(token, msg.sender, liquidity, used0, used1, positionLiquidity(token));
    }

    /**
     * @dev The largest liquidity `have0`/`have1` can buy across the launch's
     * range at the pool's present price. The pool rounds a minter's cost up
     * while the library rounds down, so the figure is stepped down until
     * both sides are affordable; the launch itself uses the same loop.
     */
    function _fit(IFusingLaunchFactory.LaunchedToken memory launch, PoolKey memory key, uint256 have0, uint256 have1)
        private
        view
        returns (uint128 liquidity)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return 0;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(launch.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(launch.tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, have0, have1);
        while (liquidity != 0) {
            (uint256 need0, uint256 need1) = _needed(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
            if (need0 <= have0 && need1 <= have1) break;
            liquidity -= 1;
        }
    }

    /// @dev The cost the pool charges for `liquidity` across the range at `sqrtPriceX96`, rounded up the way the pool does.
    function _needed(uint160 sqrtPriceX96, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        private
        pure
        returns (uint256 need0, uint256 need1)
    {
        if (sqrtPriceX96 <= sqrtLower) {
            need0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtPriceX96 < sqrtUpper) {
            need0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            need1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            need1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _payOut(Currency currency, address to, uint256 amount) private {
        if (currency.isAddressZero()) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed(to);
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    function _launch(address token) private view returns (IFusingLaunchFactory.LaunchedToken memory launch) {
        launch = factory.getLaunchedToken(token);
        if (!launch.exists || !_locked[token]) revert TokenNotLaunched();
    }

    function _balance(Currency currency) private view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /**
     * @dev Pays the protocol's share directly to its wallet. ETH goes out
     * with a capped gas stipend so a misbehaving recipient cannot stall the
     * collection; when the send fails the amount is credited to the escrow,
     * where the recipient can still claim it.
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

    /**
     * @notice Hands a collection to the converter. Exposed as an external
     * call on this contract purely so `_collectFees` can wrap it in
     * try/catch. Only this contract itself may call it.
     */
    function settleThroughConverter(address token, Currency quote, uint256 tokenAmount, uint256 quoteAmount) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (tokenAmount > 0) IERC20(token).safeTransfer(address(converter), tokenAmount);
        if (quote.isAddressZero()) {
            converter.settle{value: quoteAmount}(token, tokenAmount, quoteAmount);
        } else {
            if (quoteAmount > 0) IERC20(Currency.unwrap(quote)).safeTransfer(address(converter), quoteAmount);
            converter.settle(token, tokenAmount, quoteAmount);
        }
    }

    /**
     * @dev The fallback payout, taken only when the converter fails: the V1
     * payout without the burn. The protocol's quote is paid directly (escrow
     * if refused), the protocol's launch tokens are credited to the protocol
     * recipient in the escrow (this contract never sells, and as of V2 never
     * burns), and the creator's share of both is credited through the payout
     * plan. Nothing gets converted and nothing is lost; the treasury collects
     * the tokens later.
     */
    function _payRaw(
        address token,
        IFusingLaunchFactory.LaunchedToken memory launch,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        uint256 protocol0,
        uint256 protocol1
    ) private {
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        if (tokenIs0) _creditProtocolToken(token, launch.protocolFeeRecipient, protocol0);
        else _payProtocol(key.currency0, launch.protocolFeeRecipient, protocol0);
        _credit(key.currency0, token, launch.creatorFeeRecipient, amount0 - protocol0);
        if (tokenIs0) _payProtocol(key.currency1, launch.protocolFeeRecipient, protocol1);
        else _creditProtocolToken(token, launch.protocolFeeRecipient, protocol1);
        _credit(key.currency1, token, launch.creatorFeeRecipient, amount1 - protocol1);
    }

    function _creditProtocolToken(address token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        IERC20(token).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, token, amount);
    }

    /**
     * @dev Credits the creator's portion of `token`'s fees. In V2 the escrow
     * applies the launch's payout plan (up to five payees, X handles, holder
     * rewards); a launch with no plan pays `recipient`, exactly as V1 did.
     */
    function _credit(Currency currency, address token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            feeEscrow.creditFor{value: amount}(token, recipient);
            return;
        }
        address asset = Currency.unwrap(currency);
        IERC20(asset).forceApprove(address(feeEscrow), amount);
        // The escrow returns the amount that really arrived; when a
        // holder-rewards payee is in the plan some of it leaves the escrow
        // again within this call, so its balance delta would be the wrong check.
        uint256 received = feeEscrow.creditTokenFor(token, recipient, asset, amount);
        if (received != amount) revert InexactTransfer(asset, amount, received);
    }

    /// @notice Receives native ETH the PoolManager pays out.
    receive() external payable {}
}
