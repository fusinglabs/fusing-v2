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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FusingHolderDistributor
 * @notice Shares a launch's fee income among its holders in proportion to
 * their balances, for everyone holding at least `minHolding`. Each launch
 * gets its own instance.
 *
 * The mechanism. The launch token reports each transfer here through
 * `onTransfer`, and the distributor tracks an "eligible balance" for every
 * holder: the real balance when it meets the minimum, zero when it does not,
 * and permanently zero for infrastructure accounts (the pool manager, the
 * locker, the dead address and similar), which would otherwise dwarf every
 * real holder. Fees come in via `deposit` / `depositToken` from the fee
 * escrow, and every deposit bumps a per-share accumulator. A holder can
 * claim the accumulator multiplied by their eligible balance, minus what
 * they have taken already, adjusted by the standard per-holder correction so
 * that a purchase made after a deposit earns nothing from it.
 *
 * There is no pause, no drain and no way to redirect funds: the excluded set
 * and the minimum are locked at launch, anyone may deposit, and a claim only
 * ever pays the claimant. A deposit arriving when no holder is eligible is
 * parked in `pending` and folded into the next deposit.
 */
contract FusingHolderDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotToken();
    error NotInitialiser();
    error AlreadyInitialised();
    error ZeroAddress();
    error TransferFailed();
    error NativeValueRequired();

    event Deposited(address indexed asset, uint256 amount, uint256 totalShares);
    event Claimed(address indexed holder, address indexed asset, uint256 amount);
    event Initialised(address indexed token, uint256 minHolding, address[] excluded);

    /// @dev Fixed-point scale used by the per-share accumulator.
    uint256 private constant MAGNITUDE = 2 ** 128;
    address private constant NATIVE = address(0);

    /// @notice The launch token whose holders receive payouts from here.
    address public token;
    /// @notice Minimum balance a holder needs before they earn anything.
    uint256 public minHolding;
    /// @notice The account allowed to call initialise: the launch deployer, during the launch transaction.
    address public immutable initialiser;

    /// @notice Accounts with no claim on rewards: the pool, the locker, the dead address and similar.
    mapping(address account => bool) public excluded;
    /// @notice Each holder's eligible balance, the figure rewards are computed on.
    mapping(address holder => uint256) public shares;
    /// @notice Total of all eligible balances.
    uint256 public totalShares;

    /// @dev Every asset deposited so far, with native ETH listed as address(0).
    address[] private _assets;
    mapping(address asset => bool) private _seen;
    mapping(address asset => uint256) private _perShare;
    mapping(address asset => mapping(address holder => int256)) private _corrections;
    mapping(address asset => mapping(address holder => uint256)) private _claimed;
    /// @notice Amounts that arrived while no holder was eligible, held until the next deposit.
    mapping(address asset => uint256) public pending;

    constructor(address initialiser_) {
        if (initialiser_ == address(0)) revert ZeroAddress();
        initialiser = initialiser_;
    }

    /**
     * @notice Ties the distributor to its launch token. One call only, made by
     * the launch deployer as soon as the token is created and before a single
     * transfer has happened.
     */
    function initialise(address token_, uint256 minHolding_, address[] calldata excluded_) external {
        if (msg.sender != initialiser) revert NotInitialiser();
        if (token != address(0)) revert AlreadyInitialised();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;
        minHolding = minHolding_;
        excluded[address(0)] = true;
        excluded[address(this)] = true;
        for (uint256 i = 0; i < excluded_.length; i++) {
            if (excluded_[i] != address(0)) excluded[excluded_[i]] = true;
        }
        emit Initialised(token_, minHolding_, excluded_);
    }

    // ---------------------------------------------------------------------
    // Token callback
    // ---------------------------------------------------------------------

    /**
     * @notice Invoked by the token once each transfer has settled. Sender and
     * recipient are both re-checked against the minimum, so falling under it
     * ends a holder's accrual immediately and clearing it begins accrual
     * immediately.
     */
    function onTransfer(address from, address to) external {
        if (msg.sender != token) revert NotToken();
        if (from != address(0)) _sync(from);
        if (to != address(0) && to != from) _sync(to);
    }

    function _sync(address holder) private {
        uint256 next;
        if (!excluded[holder]) {
            uint256 bal = IERC20(token).balanceOf(holder);
            next = bal >= minHolding ? bal : 0;
        }
        uint256 prev = shares[holder];
        if (next == prev) return;
        // The share count is changing; adjust each asset's correction so this holder's earned total is unaffected.
        uint256 n = _assets.length;
        for (uint256 i = 0; i < n; i++) {
            address asset = _assets[i];
            if (next > prev) {
                _corrections[asset][holder] -= int256(_perShare[asset] * (next - prev));
            } else {
                _corrections[asset][holder] += int256(_perShare[asset] * (prev - next));
            }
        }
        shares[holder] = next;
        totalShares = totalShares - prev + next;
    }

    // ---------------------------------------------------------------------
    // Fee deposits
    // ---------------------------------------------------------------------

    /// @notice Adds the ETH sent with the call to the holders' pool.
    function deposit() external payable {
        if (msg.value == 0) revert NativeValueRequired();
        _deposit(NATIVE, msg.value);
    }

    /// @notice Draws `amount` of `asset` from the caller and deposits whatever actually landed.
    function depositToken(address asset, uint256 amount) external {
        if (asset == address(0)) revert ZeroAddress();
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(asset, IERC20(asset).balanceOf(address(this)) - before);
    }

    function _deposit(address asset, uint256 amount) private {
        if (!_seen[asset]) {
            _seen[asset] = true;
            _assets.push(asset);
        }
        uint256 total = amount + pending[asset];
        if (totalShares == 0) {
            pending[asset] = total;
            return;
        }
        pending[asset] = 0;
        _perShare[asset] += total * MAGNITUDE / totalShares;
        emit Deposited(asset, total, totalShares);
    }

    // ---------------------------------------------------------------------
    // Holder claims
    // ---------------------------------------------------------------------

    /// @notice The amount of `asset` (native under address(0)) that `holder` could withdraw at this moment.
    function claimable(address holder, address asset) public view returns (uint256) {
        int256 accumulated = int256(_perShare[asset] * shares[holder]) + _corrections[asset][holder];
        uint256 earned = accumulated <= 0 ? 0 : uint256(accumulated) / MAGNITUDE;
        return earned - _claimed[asset][holder];
    }

    /// @notice Sends the caller their full claimable balance of `asset`.
    function claim(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimable(msg.sender, asset);
        if (amount == 0) return 0;
        _claimed[asset][msg.sender] += amount;
        if (asset == NATIVE) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
        emit Claimed(msg.sender, asset, amount);
    }

    /// @notice The complete list of assets ever deposited into this distributor.
    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @notice Cumulative `asset` handed to holders per unit of share, scaled up by 2^128.
    function perShare(address asset) external view returns (uint256) {
        return _perShare[asset];
    }
}
