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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FusingLaunchFactory} from "./FusingLaunchFactory.sol";
import {Hop} from "./libraries/Hop.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";

/// @dev The single FusingTokenLock entry point the router depends on.
interface IFusingTokenLock {
    function lock(address token, address beneficiary, uint256 amount, uint64 unlockAt, uint32 vestSeconds) external returns (uint256 id);
}

/// @dev The part of Uniswap's SwapRouter02 this router calls. When ETH is
/// attached as value and `tokenIn` is WETH9, SwapRouter02 does the wrapping.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title FusingRouter
 * @notice The router behind the fusi.ng frontend. It does three things:
 *
 * - Exact-input swaps through a launch pool. Launch pools are ordinary V4
 *   pools whose hook only sets the fee, so any V4 router could trade them;
 *   this contract exists so the frontend talks to one address for every
 *   flow listed here.
 * - Moving ETH into and out of pools quoted in an ERC-20, over a route of
 *   Uniswap V3 and V4 pools in any order. The route is the same hop list the
 *   quote pricer uses to value the asset, so no matter how many pools sit
 *   between a quote asset and ETH, buyers pay plain ETH and sellers get
 *   plain ETH back. The whole route runs inside a single PoolManager unlock:
 *   V4 hops net their deltas against each other there, and a V3 hop in the
 *   middle is fed by taking the previous hop's output out of the manager and
 *   settling the next hop's input back in.
 * - Atomic launch-and-buy, in its role as the factory's trusted launch
 *   forwarder: the token is launched on behalf of the real caller and their
 *   opening buy fills in the same transaction, before anyone else can trade.
 *
 * Nothing is held here between transactions.
 */
contract FusingRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    FusingLaunchFactory public immutable factory;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;

    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();
    error NativeValueMismatch();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error EthTransferFailed();
    error NativeQuoteNeedsNoBolt();
    error InsufficientLaunchValue();
    /// @dev The pool at hop `index` has no side matching the asset the previous hop output.
    error RouteBroken(uint256 index);
    /// @dev The asset at the end of the route is not the one the caller expected.
    error RouteEndMismatch(address expected, address actual);

    event BoltBuy(bytes32 indexed poolId, address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event BoltSell(bytes32 indexed poolId, address indexed seller, uint256 tokensIn, uint256 ethOut);

    /// @dev Tracks the current location of the asset moving through a route.
    enum Where {
        /// @dev Not yet taken from the caller: either native value already
        /// sent with the call, or an ERC-20 still to be pulled via allowance.
        Caller,
        /// @dev Sitting as a positive delta (a credit) inside the PoolManager.
        Manager,
        /// @dev In this contract's own balance, whether native ETH or an ERC-20.
        Router
    }

    /// @dev Everything one unlock needs: send `amountIn` of `currencyIn` through `hops`, first to last.
    struct Route {
        Hop[] hops;
        Currency currencyIn;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev The account doing the trade. It supplies the input and gets
        /// back whatever a hop could not take.
        address payer;
        /// @dev Destination of the route's final output.
        address recipient;
        /// @dev When true, the route ends in native ETH, and WETH coming out
        /// of the last hop is unwrapped to get there. When false, the output
        /// has to be `currencyOut` exactly.
        bool ethOut;
        Currency currencyOut;
    }

    constructor(IPoolManager manager_, FusingLaunchFactory factory_, ISwapRouter02 swapRouter_, IWETH9 weth_) {
        if (
            address(manager_) == address(0) || address(factory_) == address(0) || address(swapRouter_) == address(0)
                || address(weth_) == address(0)
        ) revert ZeroAddress();
        manager = manager_;
        factory = factory_;
        swapRouter = swapRouter_;
        weth = weth_;
    }

    // ---------------------------------------------------------------------
    // Swapping through one pool
    // ---------------------------------------------------------------------

    /**
     * @param key        Pool key of the launch pool to trade.
     * @param zeroForOne Trade direction; true spends currency0 and receives currency1.
     * @param amountIn   The exact amount to spend. When the input is native
     *                   ETH it must match msg.value exactly; when it is an
     *                   ERC-20, msg.value must be zero and the caller must
     *                   have approved the router for at least this amount.
     */
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        if (currencyIn.isAddressZero()) {
            if (msg.value != amountIn) revert NativeValueMismatch();
        } else if (msg.value != 0) {
            revert NativeValueMismatch();
        }

        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, v3: false});
        (amountOut,) = _route(
            Route({
                hops: hops,
                currencyIn: currencyIn,
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: zeroForOne ? key.currency1 : key.currency0
            })
        );
    }

    // ---------------------------------------------------------------------
    // Native ETH into and out of ERC-20-quoted pools
    // ---------------------------------------------------------------------

    /**
     * @notice Buys the launch token in pool `key` with native ETH. The value
     * sent with the call is routed along `leg` (starting from ETH, ending at
     * the quote asset), then through the launch pool, and the tokens land
     * with `recipient`. On an ETH-quoted pool, pass an empty leg and this is
     * simply a direct buy.
     */
    function buyWithEth(PoolKey calldata key, Hop[] calldata leg, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        tokensOut = _buyAlongLeg(key, leg, msg.value, minTokensOut, recipient);
        emit BoltBuy(_poolId(key), msg.sender, msg.value, tokensOut);
    }

    /**
     * @notice Sells the launch token in pool `key` and pays `recipient` in
     * native ETH. The trade goes through the launch pool first and then
     * along `leg` (starting from the quote asset, ending at ETH). The caller
     * must have approved the router to spend the launch token.
     */
    function sellToEth(
        PoolKey calldata key,
        bool tokenIsCurrency0,
        uint256 tokensIn,
        Hop[] calldata leg,
        uint256 minEthOut,
        address recipient
    ) external nonReentrant returns (uint256 ethOut) {
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Hop[] memory hops = new Hop[](1 + leg.length);
        hops[0] = Hop({key: key, v3: false});
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i + 1] = leg[i];
        }

        (ethOut,) = _route(
            Route({
                hops: hops,
                currencyIn: tokenIsCurrency0 ? key.currency0 : key.currency1,
                amountIn: tokensIn,
                minAmountOut: minEthOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: true,
                currencyOut: Currency.wrap(address(0))
            })
        );
        emit BoltSell(_poolId(key), msg.sender, tokensIn, ethOut);
    }

    /**
     * @notice Sells `amountIn` of a quote asset along `leg` (quote first, ETH
     * last, the order the pricer keeps it in) and sends the resulting native
     * ETH to `recipient`. The caller must have approved the router for the
     * quote. This is how V2 pays fees in ETH regardless of what the pool is
     * quoted in.
     */
    function quoteToEth(Currency quote, uint256 amountIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (leg.length == 0) revert ZeroAmount();
        Hop[] memory hops = new Hop[](leg.length);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        (ethOut,) = _route(
            Route({
                hops: hops,
                currencyIn: quote,
                amountIn: amountIn,
                minAmountOut: minEthOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: true,
                currencyOut: Currency.wrap(address(0))
            })
        );
    }

    /**
     * @notice Spends the ETH sent with the call along `leg` (ETH first, quote
     * asset last, which is the pricer's route walked backwards) and sends the
     * `quote` it buys to `recipient`. A liquidity vault does this before it
     * adds to a pool quoted in an ERC-20: the vault holds ETH but the pool
     * needs the quote.
     */
    function ethToQuote(Currency quote, Hop[] calldata leg, uint256 minQuoteOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (msg.value == 0 || leg.length == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (quote.isAddressZero() || Currency.unwrap(quote) == address(weth)) revert NativeQuoteNeedsNoBolt();
        Hop[] memory hops = new Hop[](leg.length);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        (quoteOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: msg.value,
                minAmountOut: minQuoteOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: quote
            })
        );
    }

    // ---------------------------------------------------------------------
    // Launch-and-buy in one transaction (as the factory's launch forwarder)
    // ---------------------------------------------------------------------

    /**
     * @notice Launches a token and fills the caller's opening buy in the same
     * transaction, with native ETH covering both. Whatever value is left
     * after the launch fee is routed along `leg` into the quote asset and
     * then into the new pool. When the launch is quoted in ETH, `leg` is
     * not used.
     * @param minTokensOut Minimum tokens the opening buy must return.
     */
    function launchAndBuyWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        Hop[] calldata leg,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        uint256 launchFee = factory.launchFee();
        if (msg.value < launchFee) revert InsufficientLaunchValue();
        uint256 buyValue = msg.value - launchFee;

        // Launching clears the creator's staged terms, so the dev-lock choice has to be read before the launch call.
        (uint32 lockSecs, uint32 vestSecs) = _devLockTerms(msg.sender);
        (token, poolId) = factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairToken, msg.sender);
        if (buyValue == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        address to = lockSecs == 0 ? msg.sender : address(this);
        if (pairToken == address(0)) {
            Hop[] memory none;
            tokensOut = _buyAlongLeg(key, none, buyValue, minTokensOut, to);
        } else {
            tokensOut = _buyAlongLeg(key, leg, buyValue, minTokensOut, to);
            emit BoltBuy(PoolId.unwrap(poolId), msg.sender, buyValue, tokensOut);
        }
        _settleDevBuy(token, launchConfigId, tokensOut, lockSecs, vestSecs);
    }

    /**
     * @notice Launch-and-buy for a creator who already has the quote asset in
     * hand. The launch fee is sent as value; the opening buy is funded
     * straight from the caller's quote balance, so no swap leg is involved.
     */
    function launchAndBuyWithQuote(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        if (pairToken == address(0)) revert NativeQuoteNeedsNoBolt();
        if (msg.value != factory.launchFee()) revert InsufficientLaunchValue();

        (uint32 lockSecs, uint32 vestSecs) = _devLockTerms(msg.sender);
        (token, poolId) = factory.launchTokenFor{value: msg.value}(params, launchConfigId, pairToken, msg.sender);
        if (quoteIn == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, v3: false});
        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(pairToken),
                amountIn: quoteIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: lockSecs == 0 ? msg.sender : address(this),
                ethOut: false,
                currencyOut: Currency.unwrap(key.currency0) == token ? key.currency0 : key.currency1
            })
        );
        _settleDevBuy(token, launchConfigId, tokensOut, lockSecs, vestSecs);
    }

    // ---------------------------------------------------------------------
    // Creator opening-buy cap
    // ---------------------------------------------------------------------

    error DevBuyTooLarge(uint256 tokens, uint256 cap);
    error TokenLockNotWired();

    event DevBuyLocked(address indexed token, address indexed creator, uint256 amount, uint64 unlockAt, uint32 vestSeconds, uint256 lockId);

    /// @dev Reads the lock and vest lengths the creator staged, ahead of the launch clearing those terms.
    function _devLockTerms(address launcher) private view returns (uint32 lockSecs, uint32 vestSecs) {
        FusingTerms.LaunchTerms memory t = factory.termsOf(launcher);
        return (t.devLockSeconds, t.devVestSeconds);
    }

    /**
     * @dev Enforces the opening-buy cap. Up to DEV_BUY_FREE_BPS of supply may
     * go directly to the creator's wallet; up to DEV_BUY_LOCKED_BPS may be
     * bought if the whole amount goes into FusingTokenLock for no less than
     * the minimum lock. When a lock is staged the buy is delivered to this
     * contract and passed to the lock within the same transaction, so at no
     * point do the tokens rest in the creator's wallet.
     */
    function _settleDevBuy(address token, uint256 launchConfigId, uint256 tokensOut, uint32 lockSecs, uint32 vestSecs) private {
        uint256 supply = factory.getLaunchConfig(launchConfigId).supply;
        if (lockSecs == 0) {
            uint256 free = supply * factory.DEV_BUY_FREE_BPS() / 10_000;
            if (tokensOut > free) revert DevBuyTooLarge(tokensOut, free);
            return;
        }
        uint256 cap = supply * factory.DEV_BUY_LOCKED_BPS() / 10_000;
        if (tokensOut > cap) revert DevBuyTooLarge(tokensOut, cap);
        address lockAddr = factory.tokenLock();
        if (lockAddr == address(0)) revert TokenLockNotWired();
        uint64 unlockAt = uint64(block.timestamp) + lockSecs;
        IERC20(token).forceApprove(lockAddr, tokensOut);
        uint256 id = IFusingTokenLock(lockAddr).lock(token, msg.sender, tokensOut, unlockAt, vestSecs);
        emit DevBuyLocked(token, msg.sender, tokensOut, unlockAt, vestSecs, id);
    }

    // ---------------------------------------------------------------------
    // Building the hop list
    // ---------------------------------------------------------------------

    /// @dev Routes `ethIn` down `leg` and then through launch pool `key`.
    function _buyAlongLeg(
        PoolKey memory key,
        Hop[] memory leg,
        uint256 ethIn,
        uint256 minTokensOut,
        address recipient
    ) private returns (uint256 tokensOut) {
        Hop[] memory hops = new Hop[](leg.length + 1);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        hops[leg.length] = Hop({key: key, v3: false});
        Currency tokenCurrency = _launchTokenOf(key, leg);

        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: ethIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: tokenCurrency
            })
        );
    }

    /**
     * @dev Which side of the launch pool is the launch token: the one the
     * leg does not deliver into. Without a leg the buy arrives in ETH, so
     * the token is whichever side is not ETH.
     */
    function _launchTokenOf(PoolKey memory key, Hop[] memory leg) private view returns (Currency) {
        if (leg.length == 0) return _isEth(key.currency0) ? key.currency1 : key.currency0;
        PoolKey memory last = leg[leg.length - 1].key;
        bool quoteIs0 = key.currency0 == last.currency0 || key.currency0 == last.currency1;
        return quoteIs0 ? key.currency1 : key.currency0;
    }

    // ---------------------------------------------------------------------
    // Walking a route
    // ---------------------------------------------------------------------

    function _route(Route memory r) private returns (uint256 amountOut, Currency currencyOut) {
        bytes memory result = manager.unlock(abi.encode(r));
        (amountOut, currencyOut) = abi.decode(result, (uint256, Currency));
    }

    /**
     * @dev Runs the route one hop at a time while keeping track of where the
     * asset is. A V4 hop swaps inside the PoolManager, and its input is paid
     * from wherever the asset currently sits: offset against a credit
     * already in the manager, sent from this contract, or pulled from the
     * caller. A V3 hop can only trade what this contract holds, so any
     * manager credit is taken out beforehand, and its output stays here for
     * the following hop to settle in. Native ETH and WETH count as the same
     * asset and are converted whenever a hop needs the other form. If a hop
     * exhausts its liquidity it consumes less than it was offered, and the
     * remainder is returned to the payer immediately.
     */
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));

        Currency cur = r.currencyIn;
        uint256 amt = r.amountIn;
        Where at = Where.Caller;
        uint256 n = r.hops.length;
        for (uint256 i = 0; i < n; i++) {
            Hop memory hop = r.hops[i];
            (Currency hopIn, Currency hopOut, bool ok) = _sides(hop, cur);
            if (!ok) revert RouteBroken(i);

            if (hop.v3) {
                (cur, amt, at) = _v3Hop(hop, cur, hopOut, amt, at, r.payer);
            } else {
                (cur, amt, at) = _v4Hop(hop, cur, hopIn, hopOut, amt, at, r.payer);
            }
        }
        if (amt < r.minAmountOut) revert SlippageExceeded(amt, r.minAmountOut);

        if (r.ethOut) {
            if (!_isEth(cur)) revert RouteEndMismatch(address(0), Currency.unwrap(cur));
            (cur, amt, at) = _asNative(cur, amt, at);
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else _sendEth(r.recipient, amt);
        } else {
            if (!(cur == r.currencyOut)) revert RouteEndMismatch(Currency.unwrap(r.currencyOut), Currency.unwrap(cur));
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else if (cur.isAddressZero()) _sendEth(r.recipient, amt);
            else IERC20(Currency.unwrap(cur)).safeTransfer(r.recipient, amt);
        }
        return abi.encode(amt, cur);
    }

    /**
     * @dev A single V4 swap. The input is settled from wherever the asset is
     * at that moment; the output is left as a PoolManager credit for the
     * hop after it.
     */
    function _v4Hop(
        Hop memory hop,
        Currency cur,
        Currency hopIn,
        Currency hopOut,
        uint256 amt,
        Where at,
        address payer
    ) private returns (Currency, uint256, Where) {
        if (!(cur == hopIn)) {
            // This pool wants ETH in the other form, so bring it here and convert.
            (cur, amt, at) = _bring(cur, amt, at, payer);
            (cur, amt) = hopIn.isAddressZero() ? _toNative(cur, amt) : _toWeth(cur, amt);
        }

        bool zeroForOne = cur == hop.key.currency0;
        BalanceDelta delta = manager.swap(
            hop.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            // V2: passes the real trader to the fee hook, so a whitelisted wallet
            // is spared the launch-block premium. Only this contract sets it; the caller never does.
            abi.encode(payer)
        );
        int128 inSigned = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outSigned = zeroForOne ? delta.amount1() : delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 consumed = uint256(uint128(-inSigned));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(uint128(outSigned));
        uint256 leftover = amt - consumed;

        if (at == Where.Manager) {
            // Paid out of the previous hop's credit; anything the swap left
            // unused is still a credit, so it is taken out to the payer.
            if (leftover != 0) manager.take(cur, payer, leftover);
        } else if (at == Where.Router) {
            _settleFromRouter(cur, consumed);
            if (leftover != 0) _payOut(cur, payer, leftover);
        } else {
            // Funded by the caller: attached native value is already in this
            // contract, while an ERC-20 is pulled directly into the PoolManager.
            if (cur.isAddressZero()) {
                _settleFromRouter(cur, consumed);
                if (leftover != 0) _sendEth(payer, leftover);
            } else {
                manager.sync(cur);
                IERC20(Currency.unwrap(cur)).safeTransferFrom(payer, address(manager), consumed);
                manager.settle();
            }
        }
        return (hopOut, out, Where.Manager);
    }

    /**
     * @dev A single V3 swap via SwapRouter02. The input must already be in
     * this contract, and the output is delivered back here.
     */
    function _v3Hop(Hop memory hop, Currency cur, Currency hopOut, uint256 amt, Where at, address payer)
        private
        returns (Currency, uint256, Where)
    {
        (cur, amt, at) = _bring(cur, amt, at, payer);
        address tokenOut = Currency.unwrap(hopOut);
        uint256 value;
        if (cur.isAddressZero()) {
            // With tokenIn set to WETH9, SwapRouter02 wraps the attached value itself.
            value = amt;
        } else {
            IERC20(Currency.unwrap(cur)).forceApprove(address(swapRouter), amt);
        }
        uint256 out = swapRouter.exactInputSingle{value: value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: cur.isAddressZero() ? address(weth) : Currency.unwrap(cur),
                tokenOut: tokenOut,
                fee: hop.key.fee,
                recipient: address(this),
                amountIn: amt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        return (hopOut, out, Where.Router);
    }

    /// @dev Brings the asset into this contract's balance, whatever its current location.
    function _bring(Currency cur, uint256 amt, Where at, address payer) private returns (Currency, uint256, Where) {
        if (at == Where.Manager) {
            manager.take(cur, address(this), amt);
        } else if (at == Where.Caller && !cur.isAddressZero()) {
            IERC20(Currency.unwrap(cur)).safeTransferFrom(payer, address(this), amt);
        }
        // Native ETH sent by the caller already sits in this contract.
        return (cur, amt, Where.Router);
    }

    /// @dev Settles `amt` of `cur` from this contract's balance into the PoolManager.
    function _settleFromRouter(Currency cur, uint256 amt) private {
        manager.sync(cur);
        if (cur.isAddressZero()) {
            manager.settle{value: amt}();
        } else {
            IERC20(Currency.unwrap(cur)).safeTransfer(address(manager), amt);
            manager.settle();
        }
    }

    function _payOut(Currency cur, address to, uint256 amt) private {
        if (cur.isAddressZero()) _sendEth(to, amt);
        else IERC20(Currency.unwrap(cur)).safeTransfer(to, amt);
    }

    /// @dev Takes ETH in whichever form it currently has and makes sure it ends up native.
    function _asNative(Currency cur, uint256 amt, Where at) private returns (Currency, uint256, Where) {
        if (cur.isAddressZero()) return (cur, amt, at);
        if (at == Where.Manager) {
            manager.take(cur, address(this), amt);
            at = Where.Router;
        }
        (cur, amt) = _toNative(cur, amt);
        return (cur, amt, at);
    }

    function _toNative(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (cur.isAddressZero()) return (cur, amt);
        weth.withdraw(amt);
        return (Currency.wrap(address(0)), amt);
    }

    function _toWeth(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (!cur.isAddressZero()) return (cur, amt);
        weth.deposit{value: amt}();
        return (Currency.wrap(address(weth)), amt);
    }

    /**
     * @dev Works out the entry and exit sides of `hop` for the asset. Native
     * ETH and WETH are accepted for each other, which lets a route cross
     * between V3 pools (WETH) and native-ETH V4 pools; the caller does the
     * conversion.
     */
    function _sides(Hop memory hop, Currency cur) private view returns (Currency hopIn, Currency hopOut, bool ok) {
        Currency c0 = hop.key.currency0;
        Currency c1 = hop.key.currency1;
        if (cur == c0) return (c0, c1, true);
        if (cur == c1) return (c1, c0, true);
        if (_isEth(cur)) {
            if (_isEth(c0)) return (c0, c1, true);
            if (_isEth(c1)) return (c1, c0, true);
        }
        return (hopIn, hopOut, false);
    }

    function _isEth(Currency c) private view returns (bool) {
        return c.isAddressZero() || Currency.unwrap(c) == address(weth);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _poolId(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }

    /// @notice Receives ETH coming back from the PoolManager and from WETH withdrawals.
    receive() external payable {}
}
