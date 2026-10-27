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

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {FusingPositionMath} from "../v2/libraries/FusingPositionMath.sol";

/**
 * @title MultiFusePositionMinter
 * @notice Plans and mints the locked positions for a MultiFuse launch on
 * behalf of MultiFuseFactory: a single-sided position in each
 * market, every one seeded with an equal share of the supply. It lives in
 * its own contract so the factory's bytecode stays within the EIP-170 size
 * limit.
 *
 * The launch token mints its entire supply here, the factory calls
 * `mintLaunchPositions` within the same transaction, and the PositionManager
 * draws each share out of this contract into its pool. Any remainder the
 * pools' rounding leaves behind is forwarded to the locker in one transfer
 * after the final mint, so tokens that never made it into a pool can never
 * enter circulation.
 */
contract MultiFusePositionMinter {
    using SafeERC20 for IERC20;

    uint256 private constant MINT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error ZeroAddress();
    error SupplyNotReceived(uint256 expected, uint256 held);
    error LengthMismatch();

    event LaunchDustLocked(address indexed launchToken, uint256 amount);

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable locker;
    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPositionManager positionManager_, IAllowanceTransfer permit2_, address locker_, address factory_) {
        if (address(positionManager_) == address(0) || address(permit2_) == address(0)) revert ZeroAddress();
        if (locker_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        factory = factory_;
    }

    /**
     * @notice The opening price, tick range and liquidity a market receives
     * when `supply` tokens are placed against `phantomQuote`. Pure
     * arithmetic, published here so the factory and anyone previewing a
     * launch get their numbers from a single source.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        external
        pure
        returns (FusingPositionMath.Plan memory)
    {
        return FusingPositionMath.plan(tokenIsCurrency0, supply, phantomQuote, tickSpacing);
    }

    /**
     * @notice Mints a position for every market, owned by the locker, out of
     * the token balance this contract holds. Each pool has to be initialized
     * at its plan's sqrt price beforehand; that is what makes every position
     * one-sided and lets it be minted without any quote asset.
     * @param supplyEach The share of the supply that goes into each market.
     * @return positionIds The PositionManager token ids, in market order.
     * @return tokenAmounts How much supply actually ended up in each pool.
     */
    function mintLaunchPositions(
        address launchToken,
        PoolKey[] calldata keys,
        FusingPositionMath.Plan[] calldata plans,
        uint256 supplyEach
    ) external onlyFactory returns (uint256[] memory positionIds, uint256[] memory tokenAmounts) {
        uint256 n = keys.length;
        if (n == 0 || plans.length != n) revert LengthMismatch();
        uint256 held = IERC20(launchToken).balanceOf(address(this));
        if (held < supplyEach * n) revert SupplyNotReceived(supplyEach * n, held);

        _approvePermit2(launchToken, held);

        positionIds = new uint256[](n);
        tokenAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 before = IERC20(launchToken).balanceOf(address(this));
            positionIds[i] = positionManager.nextTokenId();
            _mint(launchToken, keys[i], plans[i], supplyEach);
            tokenAmounts[i] = before - IERC20(launchToken).balanceOf(address(this));
        }

        uint256 left = IERC20(launchToken).balanceOf(address(this));
        if (left != 0) {
            // The locker cannot send tokens anywhere, so a straight transfer
            // to it locks the remainder just as firmly as the positions.
            IERC20(launchToken).safeTransfer(locker, left);
            emit LaunchDustLocked(launchToken, left);
        }
    }

    function _mint(address launchToken, PoolKey calldata key, FusingPositionMath.Plan calldata p, uint256 supply)
        private
    {
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == launchToken;
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            // At the boundary price the quote side has to work out to
            // exactly zero. If the mint demands any quote at all, the pool
            // was not initialized at the price the plan assumed.
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(supply) : uint128(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(0) : uint128(supply),
            locker,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + MINT_DEADLINE_WINDOW);
    }

    function _approvePermit2(address token, uint256 amount) private {
        IERC20(token).forceApprove(address(permit2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp + MINT_DEADLINE_WINDOW));
    }
}
