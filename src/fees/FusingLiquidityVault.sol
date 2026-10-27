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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IFusingFeeEscrow, IFusingLaunchFactory} from "../v2/interfaces/ILaunchpadV2.sol";
import {Hop} from "../v2/libraries/Hop.sol";
import {FusingSwapGuard} from "../v2/libraries/FusingSwapGuard.sol";
import {IBurnVaultLaunchFactory, IQuotePricerRoute, IFusingFeeHookFee} from "./FusingBurnVault.sol";

/// @dev The only two FusingRouter entry points a liquidity vault uses.
interface ILiquidityRouter {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
    function ethToQuote(Currency quote, Hop[] calldata leg, uint256 minQuoteOut, address recipient)
        external
        payable
        returns (uint256 quoteOut);
}

/// @dev The only two FusingLaunchLocker entry points a liquidity vault uses.
interface ILiquidityLocker {
    function addLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount)
        external
        payable
        returns (uint128 liquidity, uint256 used0, uint256 used1);
    function positionLiquidity(address token) external view returns (uint128);
}

/// @notice Maps a vault address to its launch. Set once by the deploying factory and never touched again.
interface ILiquidityVaultRegistry {
    function tokenOf(address vault) external view returns (address token);
}

/// @dev The launch factory's router of the moment, which the factory can rotate.
interface IForwarderOf {
    function launchForwarder() external view returns (address);
}

/**
 * @title FusingLiquidityVault
 * @notice The auto-liquidity choice for a V2 launch. A creator lists this
 * address as a payee in the launch's payout plan (for example 50% wallet,
 * 30% burn, 20% liquidity) and from that point on that slice of each fee
 * collection becomes permanent depth in the launch's own pool.
 *
 * ## One vault per launch
 *
 * Built the same way as FusingBurnVault: one EIP-1167 clone per launch at
 * an address derived from the launch token
 * (`FusingLiquidityVaultFactory.vaultFor`), which makes the fee escrow's
 * per-recipient balances per-launch balances and lets the address be known
 * before the launch transaction goes out. There is no owner, no setter, no
 * withdrawal and no arbitrary call: what arrives can only leave as liquidity
 * in the launch's locked position, and the locker can never pull that out.
 *
 * ## What `addLiquidity` does
 *
 *   1. claims everything the escrow owes this vault: ETH (every V2 payout),
 *      the launch token (TOKEN_AND_QUOTE launches) and the quote asset
 *      (QUOTE and TOKEN_AND_QUOTE launches on pools not quoted in ETH);
 *   2. on a pool quoted in an ERC-20, sells the ETH for that quote along the
 *      pricer's route through FusingRouter, halving the amount and trying
 *      again when the route cannot fill within `ROUTE_TOLERANCE_BPS` of
 *      spot;
 *   3. works out from the position's range and the pool's current price
 *      what fraction of the value must be launch token, and buys exactly
 *      that through the launch pool under the burn vault's bounds: no more
 *      than `MAX_SQRT_MOVE_BPS` of price movement per call, and never under
 *      the pool's own pre-swap valuation less `SWAP_TOLERANCE_BPS`;
 *   4. passes both sides to `FusingLaunchLocker.addLiquidity`, which grows
 *      the launch's locked position and hands back what it did not use.
 *
 * Anything a step could not place stays here for the next call: a swap the
 * cap trimmed, a side the position did not want at this price, dust below
 * `MIN_QUOTE`. Nothing is ever stuck by design, only postponed. A call that
 * ends with no liquidity added reverts `NothingToAdd` and leaves no trace,
 * so a keeper's wasted call costs gas and nothing more; that covers a call
 * made inside a launch's limits window, when the vault's own buy or its
 * transfer to the locker can hit a cap, and it simply waits the window out.
 *
 * Fees the position has already earned are collected (and paid out through
 * the converter) inside the locker call before the increase, so growing the
 * position never absorbs a fee that was owed to somebody.
 */
contract FusingLiquidityVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Raw quote units below which nothing is swapped or added.
    uint256 public constant MIN_QUOTE = 1000;
    /// @notice Upper bound on how far one buy may shift the square root of the pool's price, in bps.
    uint256 public constant MAX_SQRT_MOVE_BPS = 50;
    /// @notice How far under the pool's pre-swap valuation a buy may fill, in bps.
    uint256 public constant SWAP_TOLERANCE_BPS = 100;
    /// @notice How far under the pricer's spot valuation the ETH-to-quote leg may fill, in bps.
    uint256 public constant ROUTE_TOLERANCE_BPS = 300;

    uint256 private constant BPS = 10_000;
    uint256 private constant PIPS = 1_000_000;
    /// @dev The liquidity amount the position's side ratio is sampled at. Any figure would do; this one keeps the maths in range.
    uint128 private constant PROBE = uint128(1) << 96;

    ILiquidityVaultRegistry public immutable vaults;
    IFusingFeeEscrow public immutable escrow;
    ILiquidityRouter public immutable router;
    IBurnVaultLaunchFactory public immutable factory;
    ILiquidityLocker public immutable locker;
    IPoolManager public immutable poolManager;

    /// @notice Cumulative liquidity this vault has added to its launch's position.
    uint128 public addedTotal;

    /**
     * @notice One `addLiquidity` call. `quoteSpent` is the quote sold for
     * tokens along the way, `tokensAdded`/`quoteAdded` what the position
     * accepted, `liquidity` how much it grew and `addedTotal` this vault's
     * running total.
     */
    event LiquidityAdded(
        address indexed token,
        address quote,
        uint256 quoteSpent,
        uint256 tokensAdded,
        uint256 quoteAdded,
        uint128 liquidity,
        uint128 addedTotal
    );
    /// @notice ETH converted into the quote asset of a pool that is not quoted in ETH.
    event EthConverted(address indexed token, uint256 ethIn, uint256 quoteOut);

    error ZeroAddress();
    error NotAVault();
    error UnknownLaunch(address token);
    error NothingToAdd(address token);
    /// @dev The router returned less than the floor it was handed. Only a router other than ours could do that.
    error ShortFill(uint256 got, uint256 minOut);

    constructor(
        ILiquidityVaultRegistry vaults_,
        IFusingFeeEscrow escrow_,
        ILiquidityRouter router_,
        IBurnVaultLaunchFactory factory_,
        ILiquidityLocker locker_,
        IPoolManager poolManager_
    ) {
        if (
            address(vaults_) == address(0) || address(escrow_) == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || address(locker_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        vaults = vaults_;
        escrow = escrow_;
        router = router_;
        factory = factory_;
        locker = locker_;
        poolManager = poolManager_;
    }

    /// @dev Claimed ETH arrives here from the escrow; the router and the locker send back whatever they could not use.
    receive() external payable {}

    /**
     * @notice The router every trade goes through: the factory's launch
     * forwarder, which can be rotated there, so a router fix reaches all
     * vaults without touching any of them. The router set at construction
     * is the fallback while no forwarder is configured. Every trade checks
     * what it received against its floor.
     */
    function activeRouter() public view returns (ILiquidityRouter) {
        address forwarder = IForwarderOf(address(factory)).launchForwarder();
        return forwarder == address(0) ? router : ILiquidityRouter(forwarder);
    }

    /// @notice The launch this vault supplies liquidity to, and the only one it ever can.
    function token() public view returns (address launchToken) {
        launchToken = vaults.tokenOf(address(this));
        if (launchToken == address(0)) revert NotAVault();
    }

    /// @dev All that one round needs to know about its launch.
    struct Round {
        address token;
        PoolKey key;
        address quote;
        bool tokenIs0;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @notice Converts everything this vault holds and can claim into
     * liquidity in its launch's locked position. Anyone may call it.
     * @return liquidity How much the position grew by.
     */
    function addLiquidity() external nonReentrant returns (uint128 liquidity) {
        Round memory r = _round();

        _tryClaim(r.token);
        _tryClaim(address(0));
        if (r.quote != address(0)) {
            _tryClaim(r.quote);
            _ethToQuote(r);
        }

        uint256 spent = _balanceSides(r);

        uint256 cash = _held(r.quote);
        uint256 tokens = _held(r.token);
        if (cash < MIN_QUOTE && tokens == 0) revert NothingToAdd(r.token);

        (uint128 added, uint256 used0, uint256 used1) = _add(r, cash, tokens);
        if (added == 0) revert NothingToAdd(r.token);
        liquidity = added;
        uint128 total = addedTotal + added;
        addedTotal = total;
        (uint256 tokensAdded, uint256 quoteAdded) = r.tokenIs0 ? (used0, used1) : (used1, used0);
        emit LiquidityAdded(r.token, r.quote, spent, tokensAdded, quoteAdded, added, total);
    }

    /**
     * @notice What the next call would have to work with: ETH, the quote
     * asset and the launch token, both held here and owed by the escrow.
     */
    function pendingAdd() external view returns (uint256 eth, uint256 quoteSide, uint256 tokenSide) {
        Round memory r = _round();
        eth = address(this).balance + escrow.balanceOf(address(this));
        if (r.quote != address(0)) quoteSide = _held(r.quote) + escrow.balanceOfToken(address(this), r.quote);
        tokenSide = _held(r.token) + escrow.balanceOfToken(address(this), r.token);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _round() private view returns (Round memory r) {
        r.token = token();
        IFusingLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(r.token);
        if (!launch.exists) revert UnknownLaunch(r.token);
        r.key = factory.poolKeyFor(r.token);
        r.quote = launch.pairToken;
        r.tokenIs0 = Currency.unwrap(r.key.currency0) == r.token;
        r.tickLower = launch.tickLower;
        r.tickUpper = launch.tickUpper;
    }

    /// @dev Claims this vault's escrow balance in `asset`, if any, and moves on quietly when the claim fails.
    function _tryClaim(address asset) private {
        if (asset == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) {
                try escrow.claim() {} catch {}
            }
        } else if (escrow.balanceOfToken(address(this), asset) > 0) {
            try escrow.claimToken(asset) {} catch {}
        }
    }

    /**
     * @dev Converts the ETH held here into the quote along the pricer's
     * route, with a floor of spot less `ROUTE_TOLERANCE_BPS`. If the route
     * is too thin for the full amount it is offered half, then a quarter,
     * then an eighth; whatever remains waits.
     */
    function _ethToQuote(Round memory r) private {
        uint256 eth = address(this).balance;
        if (eth < MIN_QUOTE) return;
        IQuotePricerRoute pricer = IQuotePricerRoute(factory.quotePricer());
        (Hop[] memory hops, bool qualifies) = pricer.route(r.quote);
        if (!qualifies || hops.length == 0) return;
        // The pricer records hops in the quote-to-ETH direction; a buy traverses them in reverse.
        Hop[] memory leg = new Hop[](hops.length);
        for (uint256 k = 0; k < hops.length; k++) {
            leg[k] = hops[hops.length - 1 - k];
        }
        ILiquidityRouter rt = activeRouter();
        for (uint256 attempt = 0; attempt < 4 && eth >= MIN_QUOTE; attempt++) {
            uint256 atSpot;
            try pricer.priceEthAmountInQuote(r.quote, eth) returns (uint256 q) {
                atSpot = q;
            } catch {
                return;
            }
            if (atSpot == 0) return;
            uint256 minOut = atSpot * (BPS - ROUTE_TOLERANCE_BPS) / BPS;
            uint256 before = _held(r.quote);
            try rt.ethToQuote{value: eth}(Currency.wrap(r.quote), leg, minOut, address(this)) returns (uint256) {
                uint256 out = _held(r.quote) - before;
                if (out < minOut) revert ShortFill(out, minOut);
                emit EthConverted(r.token, eth, out);
                return;
            } catch {
                eth /= 2;
            }
        }
    }

    /**
     * @dev Buys however much launch token the position needs at the current
     * price, paid for out of the cash held. Over [tickLower, tickUpper] the
     * position holds token and quote in a ratio the price dictates; the
     * vault matches that ratio so as little as possible is returned unused.
     * Bounded exactly as the burn vault's buyback is.
     * @return spent Cash the buy actually used up.
     */
    function _balanceSides(Round memory r) private returns (uint256 spent) {
        uint256 cash = _held(r.quote);
        if (cash < MIN_QUOTE) return 0;
        PoolId id = r.key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 poolLiquidity = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || poolLiquidity == 0) return 0;

        (uint256 tokenValue, uint256 quoteSide) = _mix(r, sqrtPriceX96);
        uint256 total = tokenValue + quoteSide;
        if (tokenValue == 0 || total == 0) return 0;

        uint256 tokens = _held(r.token);
        uint256 heldValue = tokens == 0 ? 0 : _valueInQuote(sqrtPriceX96, tokens, r.tokenIs0);
        uint256 wantValue = FullMath.mulDiv(cash + heldValue, tokenValue, total);
        if (wantValue <= heldValue) return 0;
        uint256 toSpend = wantValue - heldValue;
        if (toSpend > cash) toSpend = cash;
        return _buyTokens(r, toSpend, sqrtPriceX96, poolLiquidity);
    }

    /// @dev Value (in quote units) of the token side and of the quote side that `PROBE` liquidity would hold at `sqrtPriceX96`.
    function _mix(Round memory r, uint160 sqrtPriceX96) private pure returns (uint256 tokenValue, uint256 quoteSide) {
        uint160 lo = TickMath.getSqrtPriceAtTick(r.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(r.tickUpper);
        uint256 a0;
        uint256 a1;
        if (sqrtPriceX96 <= lo) {
            a0 = SqrtPriceMath.getAmount0Delta(lo, hi, PROBE, false);
        } else if (sqrtPriceX96 < hi) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, hi, PROBE, false);
            a1 = SqrtPriceMath.getAmount1Delta(lo, sqrtPriceX96, PROBE, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(lo, hi, PROBE, false);
        }
        uint256 tokenSide = r.tokenIs0 ? a0 : a1;
        quoteSide = r.tokenIs0 ? a1 : a0;
        tokenValue = tokenSide == 0 ? 0 : _valueInQuote(sqrtPriceX96, tokenSide, r.tokenIs0);
    }

    /// @dev `amount` of the launch token expressed in the quote at `sqrtRatioX96`, with no curve impact. FusingSwapGuard's maths, for any size.
    function _valueInQuote(uint160 sqrtRatioX96, uint256 amount, bool tokenIs0) private pure returns (uint256) {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return tokenIs0 ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return tokenIs0 ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
    }

    /// @dev A single bounded buy of the launch token through its pool; the output stays here.
    function _buyTokens(Round memory r, uint256 toSpend, uint160 sqrtPriceX96, uint128 poolLiquidity)
        private
        returns (uint256 spent)
    {
        uint24 fee = _fee(r.key);
        if (fee >= PIPS) return 0;
        bool zeroForOne = !r.tokenIs0; // the quote is the input side
        uint256 amountIn =
            FusingSwapGuard.cappedInput(sqrtPriceX96, poolLiquidity, fee, zeroForOne, toSpend, MAX_SQRT_MOVE_BPS);
        if (amountIn < MIN_QUOTE) return 0;
        (uint256 minOut, bool ok) = FusingSwapGuard.floor(sqrtPriceX96, fee, zeroForOne, amountIn, SWAP_TOLERANCE_BPS);
        if (!ok) return 0;

        ILiquidityRouter rt = activeRouter();
        uint256 before = _held(r.quote);
        uint256 tokensBefore = _held(r.token);
        if (r.quote == address(0)) {
            try rt.swapExactIn{value: amountIn}(r.key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                return 0;
            }
        } else {
            IERC20(r.quote).forceApprove(address(rt), amountIn);
            try rt.swapExactIn(r.key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                IERC20(r.quote).forceApprove(address(rt), 0);
                return 0;
            }
            IERC20(r.quote).forceApprove(address(rt), 0);
        }
        uint256 got = _held(r.token) - tokensBefore;
        if (got < minOut) revert ShortFill(got, minOut);
        uint256 remaining = _held(r.quote);
        return before > remaining ? before - remaining : 0;
    }

    /// @dev The pool's fee right now: the static one, or whatever the V2 hook's schedule says. PIPS means "do not trade".
    function _fee(PoolKey memory key) private view returns (uint24 fee) {
        fee = key.fee;
        if (fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && address(key.hooks) != address(0)) {
            try IFusingFeeHookFee(address(key.hooks)).currentFee(key.toId()) returns (uint24 f) {
                fee = f;
            } catch {
                fee = uint24(PIPS);
            }
        }
    }

    /// @dev Passes both sides to the locker; if the increase fails, everything stays here.
    function _add(Round memory r, uint256 cash, uint256 tokens)
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        if (tokens > 0) IERC20(r.token).forceApprove(address(locker), tokens);
        uint256 value;
        if (r.quote == address(0)) value = cash;
        else if (cash > 0) IERC20(r.quote).forceApprove(address(locker), cash);

        try locker.addLiquidity{value: value}(r.token, tokens, cash) returns (uint128 l, uint256 u0, uint256 u1) {
            liquidity = l;
            used0 = u0;
            used1 = u1;
        } catch {}

        if (tokens > 0) IERC20(r.token).forceApprove(address(locker), 0);
        if (r.quote != address(0) && cash > 0) IERC20(r.quote).forceApprove(address(locker), 0);
    }

    /// @dev This vault's balance of `asset`; zero when the asset's own code will not answer.
    function _held(address asset) private view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        try IERC20(asset).balanceOf(address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }
}

/**
 * @title FusingLiquidityVaultFactory
 * @notice Deploys and addresses the liquidity vaults, one per launch, at an
 * address derived from the launch token. Built like FusingBurnVaultFactory:
 * a single implementation deployed here, EIP-1167 clones at CREATE2
 * addresses salted with the token, `vaultFor` answers before the clone
 * exists, `deploy` is open and idempotent, and there is nothing to
 * configure.
 */
contract FusingLiquidityVaultFactory is ILiquidityVaultRegistry {
    address public immutable implementation;
    bytes32 public immutable proxyInitCodeHash;

    IFusingFeeEscrow public immutable escrow;
    ILiquidityRouter public immutable router;
    IBurnVaultLaunchFactory public immutable factory;
    ILiquidityLocker public immutable locker;
    IPoolManager public immutable poolManager;

    mapping(address vault => address token) public tokenOf;

    event VaultDeployed(address indexed token, address indexed vault);

    error ZeroAddress();
    error DeployFailed(address token);

    constructor(
        IFusingFeeEscrow escrow_,
        ILiquidityRouter router_,
        IBurnVaultLaunchFactory factory_,
        ILiquidityLocker locker_,
        IPoolManager poolManager_
    ) {
        if (
            address(escrow_) == address(0) || address(router_) == address(0) || address(factory_) == address(0)
                || address(locker_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        escrow = escrow_;
        router = router_;
        factory = factory_;
        locker = locker_;
        poolManager = poolManager_;
        address impl = address(new FusingLiquidityVault(this, escrow_, router_, factory_, locker_, poolManager_));
        implementation = impl;
        proxyInitCodeHash = keccak256(_proxyInitCode(impl));
    }

    /// @notice The vault address for `token`, whether or not it has been deployed.
    function vaultFor(address token) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(token))), proxyInitCodeHash)
        );
        return address(uint160(uint256(hash)));
    }

    function isDeployed(address token) public view returns (bool) {
        return vaultFor(token).code.length != 0;
    }

    /// @notice Deploys `token`'s vault if it is not there yet and returns it in either case.
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

    /// @notice One liquidity round for `token`, deploying its vault first when needed. What a keeper calls.
    function addLiquidity(address token) external returns (uint128 liquidity) {
        return FusingLiquidityVault(payable(deploy(token))).addLiquidity();
    }

    /// @notice Total liquidity `token`'s vault has added; zero until it exists.
    function addedTotal(address token) external view returns (uint128) {
        address vault = vaultFor(token);
        if (vault.code.length == 0) return 0;
        return FusingLiquidityVault(payable(vault)).addedTotal();
    }

    /// @notice ETH the escrow owes `token`'s vault plus what the vault holds; works before the vault exists.
    function pendingEth(address token) external view returns (uint256) {
        address vault = vaultFor(token);
        return vault.balance + escrow.balanceOf(vault);
    }

    function _proxyInitCode(address impl) private pure returns (bytes memory) {
        return
            abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
