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

import {FusingLaunchLocker} from "./FusingLaunchLocker.sol";
import {FusingPositionMath} from "./libraries/FusingPositionMath.sol";

/**
 * @title FusingPositionMinter
 * @notice Plans and mints the one locked position that makes up a fusi.ng
 * launch's entire market, acting for FusingLaunchFactory. It is a separate
 * contract solely to keep the factory under EIP-170's size limit: the tick
 * math, the Permit2 approvals and the PositionManager action encoding add
 * up.
 *
 * The launch token mints its full supply directly to this contract, the
 * factory calls `mintLaunchPosition` within the same transaction, and the
 * PositionManager draws the supply from here into the pool. Nothing stays
 * here across transactions: any remainder the pool's rounding leaves is
 * sent to the locker, so supply that missed the pool never enters
 * circulation.
 */
contract FusingPositionMinter {
    using SafeERC20 for IERC20;

    uint256 private constant MINT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error ZeroAddress();
    error SupplyNotReceived(uint256 expected, uint256 held);

    event LaunchDustLocked(address indexed launchToken, uint256 amount);

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    FusingLaunchLocker public immutable locker;
    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        FusingLaunchLocker locker_,
        address factory_
    ) {
        if (address(positionManager_) == address(0) || address(permit2_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        factory = factory_;
    }

    /**
     * @notice The opening price, tick range and liquidity a launch on these
     * terms receives. Pure arithmetic, exposed so the factory and anyone
     * previewing a launch get it from a single source.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        external
        pure
        returns (FusingPositionMath.Plan memory)
    {
        return FusingPositionMath.plan(tokenIsCurrency0, supply, phantomQuote, tickSpacing);
    }

    /**
     * @notice Mints the launch position, owned by the locker, out of the
     * supply this contract holds. The pool must already be initialised at
     * `p.sqrtPriceX96`; that makes the position one-sided, so no quote is
     * required.
     * @return positionId The PositionManager token id of the minted position.
     * @return tokenAmount The amount of supply that actually went into the pool.
     */
    function mintLaunchPosition(
        address launchToken,
        PoolKey calldata key,
        FusingPositionMath.Plan calldata p,
        uint256 supply
    ) external onlyFactory returns (uint256 positionId, uint256 tokenAmount) {
        uint256 held = IERC20(launchToken).balanceOf(address(this));
        if (held < supply) revert SupplyNotReceived(supply, held);

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == launchToken;
        _approvePermit2(launchToken, supply);

        positionId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            // At the boundary price the quote leg has to be exactly zero. If
            // the pool asks for any quote, it was not initialised where the
            // plan says.
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(supply) : uint128(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(0) : uint128(supply),
            address(locker),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + MINT_DEADLINE_WINDOW);

        uint256 left = IERC20(launchToken).balanceOf(address(this));
        tokenAmount = held - left;
        if (left != 0) {
            // The locker cannot send tokens anywhere, so a plain transfer to
            // it is every bit as locked as the position.
            IERC20(launchToken).safeTransfer(address(locker), left);
            emit LaunchDustLocked(launchToken, left);
        }
    }

    function _approvePermit2(address token, uint256 amount) private {
        IERC20(token).forceApprove(address(permit2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp + MINT_DEADLINE_WINDOW));
    }
}
