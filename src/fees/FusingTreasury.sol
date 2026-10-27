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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFusingFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";

/**
 * @title FusingTreasury
 * @notice The landing spot for the protocol's cut of every V2 fee, and the
 * contract that decides how that cut is divided. The factories name it as
 * their protocol fee recipient, so each collection's protocol ETH and each
 * launch fee end up here; from there anyone may call `distribute`, which
 * pays the balance out over the legs the owner has configured: a share to
 * operations, a share to the FUSE buyback wallet (or a burn vault, later
 * on), and so forth, up to five legs adding up to 100%.
 *
 * Those legs are the only thing the owner (the treasury Safe) controls, and
 * it can rewrite them whenever it likes; there is no other lever. ETH leaves
 * only along the legs. Any stray ERC-20 that ends up here can be swept out
 * by the owner, because the protocol is paid in ETH and anything else is a
 * mistake on someone's part.
 *
 * `receive` deliberately does nothing beyond accepting. The converter pays
 * the protocol with a bounded gas stipend and falls back to crediting the
 * escrow when that fails, so a cheap receive is what keeps that fallback
 * from ever firing. If it does fire, `distribute` claims the credit first.
 */
contract FusingTreasury is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Leg {
        address to;
        uint16 bps;
        string label;
    }

    uint256 public constant MAX_LEGS = 5;
    uint256 private constant BPS = 10_000;

    /// @notice The fee escrow, where the converter credits us when a direct pay fails. May be unset.
    IFusingFeeEscrow public immutable escrow;

    Leg[] private _legs;

    event LegsSet(Leg[] legs);
    event Distributed(uint256 total, address[] to, uint256[] amounts);
    event EscrowClaimed(uint256 amount);
    event TokenSwept(address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error LegsInvalid();
    error NothingToDistribute();
    error EthTransferFailed(address to);
    error OwnershipCannotBeRenounced();

    constructor(address owner_, IFusingFeeEscrow escrow_, Leg[] memory legs_) Ownable(owner_) {
        escrow = escrow_;
        _setLegs(legs_);
    }

    /// @dev Takes in the converter's payouts and the launch fees the factories send.
    receive() external payable {}

    function legs() external view returns (Leg[] memory) {
        return _legs;
    }

    /// @notice Overwrites the split. Between one and five legs, no zero address, no zero share, totalling 100%.
    function setLegs(Leg[] calldata legs_) external onlyOwner {
        Leg[] memory copy = new Leg[](legs_.length);
        for (uint256 i = 0; i < legs_.length; i++) {
            copy[i] = legs_[i];
        }
        _setLegs(copy);
    }

    /// @notice Collects whatever ETH the escrow is holding for this treasury. Anyone may call it; `distribute` runs it as well.
    function claimFromEscrow() public returns (uint256 amount) {
        if (address(escrow) == address(0)) return 0;
        if (escrow.balanceOf(address(this)) == 0) return 0;
        amount = escrow.claim();
        emit EscrowClaimed(amount);
    }

    /**
     * @notice Pays out the treasury's full balance across the legs. The
     * final leg absorbs any rounding remainder so no wei is left behind.
     * Anyone may call it: the destinations belong to the owner, not to
     * whoever triggers the payout.
     */
    function distribute() external nonReentrant returns (uint256 total) {
        claimFromEscrow();
        total = address(this).balance;
        if (total == 0) revert NothingToDistribute();

        uint256 n = _legs.length;
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            Leg storage leg = _legs[i];
            uint256 share = i + 1 == n ? total - paid : total * leg.bps / BPS;
            paid += share;
            to[i] = leg.to;
            amounts[i] = share;
            if (share == 0) continue;
            (bool ok,) = payable(leg.to).call{value: share}("");
            if (!ok) revert EthTransferFailed(leg.to);
        }
        emit Distributed(total, to, amounts);
    }

    /// @notice Transfers this treasury's entire balance of `asset` to `to`. ETH is never moved this way.
    function sweepToken(address asset, address to) external onlyOwner {
        if (asset == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(to, amount);
        emit TokenSwept(asset, to, amount);
    }

    /// @notice Disabled for good: an ownerless treasury could never adjust its split again.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _setLegs(Leg[] memory legs_) private {
        if (legs_.length == 0 || legs_.length > MAX_LEGS) revert LegsInvalid();
        delete _legs;
        uint256 sum;
        for (uint256 i = 0; i < legs_.length; i++) {
            if (legs_[i].to == address(0)) revert ZeroAddress();
            if (legs_[i].bps == 0) revert LegsInvalid();
            sum += legs_[i].bps;
            _legs.push(legs_[i]);
        }
        if (sum != BPS) revert LegsInvalid();
        emit LegsSet(legs_);
    }
}
