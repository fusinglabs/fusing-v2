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

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @notice The records MultiFuseFactory keeps: a single launch with
 * multiple markets. Each market is a plain, hookless Uniswap V4 pool pairing
 * the launch token with one quote asset, seeded with an equal share of the
 * supply in one locked position, and every market opens at the same
 * ETH-denominated price. The locker, the router and off-chain indexers all
 * read from here.
 */
interface IMultiFuseFactory {
    /// @notice A single pool belonging to a launch.
    struct Market {
        address pairToken;
        // The virtual quote reserve this pool's curve started from, in the
        // quote asset's units, sized for this pool's share of the supply.
        uint256 phantomQuote;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
    }

    struct LaunchedToken {
        address token;
        address deployer;
        address creatorFeeRecipient;
        // LP fee of the pools in hundredths of a basis point, identical across all markets.
        uint24 poolFee;
        int24 tickSpacing;
        // Fee terms fixed at launch time and applied uniformly to every market.
        uint16 baseFeeBps;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        address protocolFeeRecipient;
        uint64 launchedAt;
        uint8 marketCount;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function getMarkets(address token) external view returns (Market[] memory);
    function getMarket(address token, uint256 index) external view returns (Market memory);
    function poolKeyFor(address token, uint256 index) external view returns (PoolKey memory);
    function poolKeysFor(address token) external view returns (PoolKey[] memory);
}
