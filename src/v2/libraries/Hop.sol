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
 * @notice A single pool along a route from one asset to another. The quote
 * pricer values an asset by walking a chain of these from that asset to ETH,
 * and the router trades along the very same chain with real funds. Sharing
 * one struct between the two guarantees that any route the pricer accepts
 * is also, hop for hop, a route the router is able to execute.
 * @param key For a Uniswap V4 hop this is the pool key as V4 defines it. For
 *        a Uniswap V3 hop, `currency0` and `currency1` hold the pool's two
 *        tokens sorted by address, `fee` holds the V3 fee tier, and both
 *        `tickSpacing` and `hooks` must be zero; the pool address is then
 *        whatever the V3 factory resolves for that triple.
 * @param v3 True when the hop is a Uniswap V3 pool, false when it is V4.
 */
struct Hop {
    PoolKey key;
    bool v3;
}
