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
 * @notice Interfaces shared across the fusi.ng contracts: the fee escrow
 * and the launch factory's records. Uniswap V4 core and periphery types are
 * not redeclared here; each contract imports them from the Uniswap packages
 * it needs.
 */

/**
 * @notice The ledger of claimable balances that the locker credits collected
 * fees into. Crediting native ETH needs no permission, since the caller
 * sends the ETH being credited. Crediting tokens pulls them from the caller,
 * so leaving it open is just as safe.
 */
interface IFusingFeeEscrow {
    function credit(address recipient) external payable;
    function creditToken(address recipient, address token, uint256 amount) external;
    /// @dev V2: credits the amount as creator fees for `launchToken`, divided by that launch's payout plan.
    function creditFor(address launchToken, address fallbackRecipient) external payable;
    function creditTokenFor(address launchToken, address fallbackRecipient, address asset, uint256 amount)
        external
        returns (uint256 received);
    function claim() external returns (uint256 amount);
    function claim(uint256 amount) external returns (uint256);
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/**
 * @notice V2: the locker forwards each collection to the converter, which
 * converts it to ETH and pays the launch's recipients. A native quote comes
 * in as msg.value; the launch token and any ERC-20 quote are transferred
 * ahead of the call.
 */
interface IFusingFeeConverter {
    function settle(address token, uint256 tokenAmount, uint256 quoteAmount) external payable;
}

/**
 * @notice The bare ERC-721 receiver signature FusingLaunchLocker implements
 * so it can accept the Uniswap V4 position NFT.
 */
interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/**
 * @notice The record FusingLaunchFactory keeps for each launch, read by the
 * locker, the router and off-chain indexers alike.
 *
 * A launch is a single ordinary Uniswap V4 pool from the moment it opens,
 * its only hook the fee hook that sets each swap's LP fee. The entire supply
 * lives in one position owned by the locker, ranged from the opening price
 * upward, so the pool behaves like a constant-product curve with a phantom
 * quote reserve: opening it costs no quote at all, and the price can never
 * drop below where it opened. The pool's LP fee is the launch's entire
 * trading fee; because the locked position is the only liquidity the launch
 * seeded, that fee accrues to the locker, which divides it between the
 * protocol and the creator.
 */
interface IFusingLaunchFactory {
    struct LaunchedToken {
        address token;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        // The virtual quote reserve the curve started with, denominated in quote units.
        uint256 phantomQuote;
        // LP fee of the pool in hundredths of a basis point (1% = 10_000).
        // Always (baseFeeBps + creatorTaxBps) * 100.
        uint24 poolFee;
        int24 tickSpacing;
        // Range and size of the locked position.
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
        // Fee terms fixed at launch. protocolFeeShareBps divides the base fee
        // between the protocol and the creator; the creator tax goes entirely
        // to the creator.
        uint16 baseFeeBps;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        address protocolFeeRecipient;
        uint64 launchedAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}
