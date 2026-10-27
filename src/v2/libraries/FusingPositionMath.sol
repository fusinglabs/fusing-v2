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

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/**
 * @title FusingPositionMath
 * @notice The arithmetic underneath a fusi.ng launch pool.
 *
 * Take a constant-product bonding curve with phantom quote reserve P and
 * token supply S. Its invariant is (P + q) * t = P * S, with q the real
 * quote paid in and t the tokens remaining. Now take a Uniswap V3-style
 * position of liquidity L = sqrt(P * S) ranging from the opening price
 * P / S up to the top of the tick space: it has the identical invariant.
 * At the opening price its virtual reserves are S tokens and P quote, no
 * part of that quote is real, and the quote it holds after trading is
 * exactly what buyers put in. A single one-sided position seeded with the
 * whole supply therefore *is* the curve, with no extra contract and no
 * migration afterwards.
 *
 * `plan` converts launch terms into the pool's opening sqrt price, the
 * position's tick range and its liquidity. `amountsForLiquidity` reads a
 * position's holdings at any price, which is how the hook measures the
 * quote raised toward the graduation milestone.
 */
library FusingPositionMath {
    error ZeroAmount();
    error UnsupportedPrice();
    error PositionTooSmall();
    error InvalidTickSpacing();

    // The outermost ticks any spacing can use; the same values as v4-core's MIN_TICK and MAX_TICK.
    int24 private constant MIN_USABLE_TICK = -887272;
    int24 private constant MAX_USABLE_TICK = 887272;

    struct Plan {
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /**
     * @notice Plans the launch position for `supply` tokens over a phantom
     * reserve of `phantomQuote`.
     * @dev The opening tick snaps to the closest multiple of the tick
     * spacing, so the price actually opened at is within half a spacing of
     * P / S. The pool must be initialised at precisely the sqrt price
     * returned: that puts the current tick on the edge of the position, so
     * the mint takes only tokens and not a single unit of quote.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        internal
        pure
        returns (Plan memory p)
    {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        if (supply == 0 || phantomQuote == 0) revert ZeroAmount();

        // A pool's price is currency1 in terms of currency0, always.
        uint160 openingSqrtPrice = tokenIsCurrency0
            ? sqrtPriceX96FromAmounts(supply, phantomQuote)
            : sqrtPriceX96FromAmounts(phantomQuote, supply);
        if (openingSqrtPrice <= TickMath.MIN_SQRT_PRICE || openingSqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert UnsupportedPrice();
        }
        int24 openingTick = _nearestUsableTick(TickMath.getTickAtSqrtPrice(openingSqrtPrice), tickSpacing);

        if (tokenIsCurrency0) {
            // Buying raises the price, so the position lies above the current tick.
            p.tickLower = openingTick;
            p.tickUpper = _floorToSpacing(MAX_USABLE_TICK, tickSpacing);
            if (p.tickLower >= p.tickUpper) revert UnsupportedPrice();
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount0(p.sqrtPriceX96, sqrtUpper, supply);
            // The pool rounds up what it charges a minter, while the
            // liquidity figure above came from a slightly different formula
            // rounding down, so the amount demanded can overshoot the supply
            // by a wei or two.
            while (p.liquidity != 0 && SqrtPriceMath.getAmount0Delta(p.sqrtPriceX96, sqrtUpper, p.liquidity, true) > supply)
            {
                p.liquidity -= 1;
            }
        } else {
            // Here buying (quote comes in as currency0) lowers the price, so
            // the position lies below the current tick.
            p.tickUpper = openingTick;
            p.tickLower = _ceilToSpacing(MIN_USABLE_TICK, tickSpacing);
            if (p.tickLower >= p.tickUpper) revert UnsupportedPrice();
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickUpper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(p.tickLower);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, p.sqrtPriceX96, supply);
            while (p.liquidity != 0 && SqrtPriceMath.getAmount1Delta(sqrtLower, p.sqrtPriceX96, p.liquidity, true) > supply)
            {
                p.liquidity -= 1;
            }
        }
        if (p.liquidity == 0) revert PositionTooSmall();
    }

    /**
     * @notice The number of tokens the pool will really take for `p`,
     * rounded up as the PoolManager rounds when charging a minter. Never
     * exceeds the supply handed to `plan`; the difference is dust.
     */
    function tokenAmountFor(bool tokenIsCurrency0, Plan memory p) internal pure returns (uint256) {
        return tokenIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(p.sqrtPriceX96, TickMath.getSqrtPriceAtTick(p.tickUpper), p.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(p.tickLower), p.sqrtPriceX96, p.liquidity, true);
    }

    /**
     * @notice How much token0 and token1 a position of `liquidity` across
     * [tickLower, tickUpper] holds when the price is `sqrtPriceX96`,
     * rounded down.
     */
    function amountsForLiquidity(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    /**
     * @notice Returns sqrt(amount1 / amount0) scaled by 2^96, the
     * sqrtPriceX96 form.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        if (_fitsQ192(amount0, amount1)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(Math.sqrt(ratioX192));
        }

        if (!_fitsQ128(amount0, amount1)) revert UnsupportedPrice();
        uint256 ratioX128 = FullMath.mulDiv(amount1, 1 << 128, amount0);
        uint256 sqrtPriceX64 = Math.sqrt(ratioX128);
        if (sqrtPriceX64 > type(uint128).max) revert UnsupportedPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX64 << 32);
    }

    function _nearestUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 floored = _floorToSpacing(tick, tickSpacing);
        int24 rounded = tick - floored >= tickSpacing / 2 ? floored + tickSpacing : floored;
        int24 lo = _ceilToSpacing(MIN_USABLE_TICK, tickSpacing);
        int24 hi = _floorToSpacing(MAX_USABLE_TICK, tickSpacing);
        if (rounded < lo) return lo;
        if (rounded > hi) return hi;
        return rounded;
    }

    function _floorToSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 q = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) q -= 1;
        return q * tickSpacing;
    }

    function _ceilToSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 q = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) q += 1;
        return q * tickSpacing;
    }

    function _fitsQ192(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint192).max) return true;
        return amount1 < (amount0 << 64);
    }

    function _fitsQ128(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint128).max) return true;
        return amount1 < (amount0 << 128);
    }
}
