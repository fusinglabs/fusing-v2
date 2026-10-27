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

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @notice Guard rails for any swap the protocol pushes into a launch pool
 * on its own account. Fee collection is a public, permissionless call, so
 * without these a stranger could time it to turn our trade into a large,
 * sandwichable market order:
 *
 *   cappedInput  how much of `available` can be sold before the pool's
 *                square-root price shifts by `maxSqrtMoveBps` (roughly
 *                double that in price terms). Anything beyond that waits
 *                for the next call.
 *   floor        the minimum the swap must return: the input net of the
 *                pool fee, valued at the pre-swap price, less `toleranceBps`.
 *
 * The same maths FusingBurnVault uses, kept in one place so the fee
 * converter and the vault can never drift apart.
 */
library FusingSwapGuard {
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    function cappedInput(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint24 fee,
        bool zeroForOne,
        uint256 available,
        uint256 maxSqrtMoveBps
    ) internal pure returns (uint256) {
        uint256 move = (uint256(sqrtPriceX96) * maxSqrtMoveBps) / BASIS_POINTS;
        if (move == 0) return 0;
        uint256 net;
        if (zeroForOne) {
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

    function floor(uint160 sqrtPriceX96, uint24 fee, bool zeroForOne, uint256 amountIn, uint256 toleranceBps)
        internal
        pure
        returns (uint256 minOut, bool ok)
    {
        uint256 net = amountIn - FullMath.mulDivRoundingUp(amountIn, fee, PIPS);
        if (net == 0 || net > type(uint128).max) return (0, false);
        uint256 valued = valueAtSqrtPrice(sqrtPriceX96, uint128(net), zeroForOne);
        if (valued == 0) return (0, false);
        return ((valued * (BASIS_POINTS - toleranceBps)) / BASIS_POINTS, true);
    }

    /// @dev Value of `amount` on the input side expressed in the output side at `sqrtRatioX96`, with no curve impact.
    function valueAtSqrtPrice(uint160 sqrtRatioX96, uint128 amount, bool zeroForOne) internal pure returns (uint256) {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return zeroForOne ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return zeroForOne ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
    }
}
