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

/**
 * @notice The launch terms introduced in V2, used by the factory (stages and
 * validates them), the deployer (applies the token-side ones), the fee hook
 * (the fee schedule), the fee escrow (the payout plan) and the fee converter
 * (the payout mode).
 */
library FusingTerms {
    enum PayeeKind {
        WALLET,
        HANDLE,
        HOLDERS
    }

    /// @notice A single recipient in a launch's creator fee split.
    struct Payee {
        PayeeKind kind;
        /// @dev For WALLET, the recipient address. For HOLDERS, the creator leaves it zero and the factory fills in the distributor.
        address account;
        /// @dev For HANDLE, keccak256 of the X handle in lower case, with the leading @ removed.
        bytes32 handle;
        /// @dev The payee's share in basis points. All shares in a plan add up to 10,000.
        uint16 bps;
    }

    /**
     * @notice The asset the creator's fees are paid in. The protocol's share
     * is converted to ETH no matter which mode the creator picks. All
     * conversions share the same bounds (FusingSwapGuard), and anything that
     * does not fit within them is queued.
     *
     *   ETH              everything is converted along the pricer's route and
     *                    paid as ETH. The default, since its value is zero.
     *   QUOTE            the token side is sold into the pool and everything
     *                    is paid in the pool's quote asset: PEPE for a PEPE
     *                    pair, USDC for a USDC pair, the stock for a stock
     *                    pair. On an ETH-quoted pool this is identical to ETH.
     *   TOKEN_AND_QUOTE  none of the creator's share is sold: the token side
     *                    is handed over as tokens and the quote side as quote,
     *                    just as the LP fees accrued. This is what V1 paid.
     *   TOKEN            the quote side buys the launch token back out of its
     *                    own pool and everything is paid in tokens.
     *
     * Burning and adding liquidity are not modes: they are payees within the
     * creator's split (the burn vault and the liquidity vault), and each
     * accepts whatever asset the mode produces.
     */
    enum PayoutMode {
        ETH,
        QUOTE,
        TOKEN_AND_QUOTE,
        TOKEN
    }

    /**
     * @notice The parameters the anti-sniper switch runs on. The protocol
     * owner sets them once and every launch that enables the switch uses them.
     */
    struct Presets {
        // Flat surcharge in pips applied in the launch block and for sniperBlocks - 1 blocks after it.
        uint24 sniperPremium;
        uint32 sniperBlocks;
    }

    /**
     * @notice The terms a creator stages ahead of their next launch. The zero
     * value of every field means V1 behaviour, so an all-zero struct describes
     * a V1 launch paid in ETH.
     *
     * The limits and the fee schedule are chosen by the creator within bounds
     * the protocol enforces (FusingLaunchFactory): caps from 0.1% to 3% of
     * supply, and an opening fee of at most 20% decaying to the base fee, each
     * lasting no longer than 20 minutes. Once they expire there are no limits
     * and the fee is base plus creator tax.
     */
    struct LaunchTerms {
        // Token caps as basis points of supply. A zero field means no cap of that kind; both zero means limits are off.
        uint16 maxWalletBps;
        uint16 maxTxBps;
        uint32 limitsSeconds;
        // Fee schedule: the pool's total fee at the moment of launch, in pips
        // (1% = 10_000), decaying linearly to the resting fee across decaySeconds. Zero disables it.
        uint24 startFee;
        uint32 decaySeconds;
        // Turns on the anti-sniper window using the protocol's preset figures.
        bool antiSniper;
        PayoutMode payoutMode;
        // As many as 33 wallets exempted from the caps and the launch-block
        // premium: the creator's own circle, allowed in before the bots.
        address[] whitelist;
        // The creator's opening buy: at most 6% of supply held freely, or at
        // most 20% when it goes directly into a lock lasting at least seven
        // days (devLockSeconds), then vesting linearly over devVestSeconds
        // (zero means everything at once).
        uint32 devLockSeconds;
        uint32 devVestSeconds;
        // Holder rewards: the minimum balance that qualifies to earn, relevant when a HOLDERS payee is present. Set by the creator.
        uint256 minHolding;
        // At most five payees. When empty, the creator's entire share goes to the creator fee recipient.
        Payee[] payees;
    }
}
