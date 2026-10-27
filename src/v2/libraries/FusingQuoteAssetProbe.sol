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

/**
 * @title FusingQuoteAssetProbe
 * @notice Checks that a candidate quote asset transfers exact amounts before
 * any launch is allowed to open a pool against it.
 *
 * The quote pricer is not able to make this call on its own. It measures a
 * hop's depth by reading the balance of whichever side sits NEARER to ETH,
 * so on a direct pool against WETH the only balance it ever inspects is the
 * WETH one; at no point does the route walk exercise the candidate's own
 * transfer logic. A token that skims a cut on every transfer, or one whose
 * balances derive from shares and round down, therefore passes the depth
 * floor just as cleanly as an honest token would.
 *
 * The cost of letting that through: the launch transaction itself goes
 * through, because the opening position holds nothing but the launched
 * token and no quote asset changes hands at creation. The damage only shows
 * up later. A buy paid in the quote asset settles an exact figure into the
 * Uniswap V4 PoolManager, so less arrives than the swap owes and the whole
 * call reverts with CurrencyNotSettled; fee collection likewise moves exact
 * figures into the escrow and reverts with FusingLaunchLocker.InexactTransfer.
 * The launch is left open, its whole supply sits locked in a position, and
 * its market is broken.
 *
 * The probe is a round trip: `amount` is pulled from the payer and then sent
 * straight back, and each leg has to land to the wei. Both directions are
 * tested because a token may tax just one of them, and the same comparison
 * flags share-rounding rebasers, whose transfers land a wei or two short in
 * either direction.
 *
 * It runs once per asset rather than once per launch, via
 * FusingQuotePricer.proveExactTransfers, which is open to any caller and
 * takes its funding from that caller. This preserves a property fusi.ng
 * cares about: a creator launching against an ERC-20 quote still needs to
 * hold nothing but ETH.
 *
 * What it does NOT catch, listed openly, since a check that looks complete
 * but is not does more harm than one that admits its limits:
 *
 * - a token that only taxes transfers above some threshold larger than the
 *   probe;
 * - a token that exempts specific addresses, when the payer and the caller
 *   both happen to be exempt (the usual shape is a taxed token that
 *   whitelists its own pool and router, and the probe does catch that one,
 *   since it moves tokens between two addresses that appear on no such
 *   list);
 * - a token that is upgradeable or carries an owner switch and only turns
 *   its tax on after the launch;
 * - a fee small enough to round down to zero at the probe size;
 * - a rebasing token whose transfers are exact and whose balances only
 *   change on a separate rebase call. Such a token passes here and still
 *   breaks the locker's accounting later on.
 *
 * None of those scenarios involve the honest creator who simply reaches for
 * a popular taxed token, and that is precisely the case this check is here
 * to catch.
 */
library FusingQuoteAssetProbe {
    using SafeERC20 for IERC20;

    /// @dev One leg of the probe landed short (or long) of the amount sent.
    error QuoteAssetInexact(address asset, uint256 sent, uint256 received);
    /// @dev The probe amount came out as zero, which can prove nothing.
    error QuoteAssetProbeTooSmall(address asset);

    /// @dev The probe must be worth at least this fraction of the pricer's
    /// depth floor. At that size a percentage fee cannot round down to zero,
    /// and since the full amount returns to the payer the only real expense
    /// is gas.
    uint256 internal constant PROBE_DIVISOR = 1_000;

    /**
     * @notice Pulls `amount` of `asset` from `payer` into this contract and
     * sends it back, reverting unless both legs land exactly. Nothing stays
     * behind afterwards, and the only allowance needed is `amount` from the
     * payer.
     */
    function requireExactTransfers(address asset, address payer, uint256 amount) internal {
        if (amount == 0) revert QuoteAssetProbeTooSmall(asset);

        IERC20 token = IERC20(asset);
        uint256 payerBefore = token.balanceOf(payer);
        uint256 selfBefore = token.balanceOf(address(this));

        // Leg one: payer to this contract.
        token.safeTransferFrom(payer, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - selfBefore;
        if (received != amount) revert QuoteAssetInexact(asset, amount, received);

        // Leg two: back to the payer, who must finish exactly where they began.
        token.safeTransfer(payer, amount);
        uint256 payerAfter = token.balanceOf(payer);
        if (payerAfter != payerBefore) {
            revert QuoteAssetInexact(asset, amount, amount - (payerBefore - payerAfter));
        }
        // Finally this contract must hold nothing extra. A token that credits
        // the sender instead of the recipient would leave a residue here.
        uint256 selfAfter = token.balanceOf(address(this));
        if (selfAfter != selfBefore) revert QuoteAssetInexact(asset, amount, selfAfter - selfBefore);
    }
}
