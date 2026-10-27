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

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFusingFeeEscrow} from "./interfaces/ILaunchpadV2.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";

interface IFusingHolderDistributor {
    function deposit() external payable;
    function depositToken(address token, uint256 amount) external;
}

/**
 * @title FusingFeeEscrow
 * @notice The ledger of claimable balances that every launch's fees flow
 * into. In V2 it is also where a launch's payout plan gets applied.
 *
 * In V1 the whole creator share went to a single address. V2 lets a launch
 * declare up to five payees, each with a basis-point share, drawn from three
 * kinds:
 *
 *   WALLET   a plain address, credited to its claimable balance just as V1 did.
 *   HANDLE   an X account, keyed by the keccak of the lower-cased handle. The
 *            share accrues to the handle, and whoever proves control of the
 *            account collects it: after a login with X, the fusi.ng attester
 *            signs (handle, wallet, deadline), and `claimHandle` moves the
 *            balance into that wallet's own ledger.
 *   HOLDERS  the launch's holder distributor; the share is passed through to
 *            it and shared out pro rata (see FusingHolderDistributor).
 *
 * A launch without a plan sends its entire creator share to the default
 * recipient the locker supplies, which is precisely V1 behaviour. The factory
 * writes the plan once, in the launch transaction, and it is frozen from then
 * on: the split shown on the launch page at birth is the split enforced for
 * the life of the token.
 *
 * Crediting needs no permission. Native credits bring their own ETH and token
 * credits are pulled from the caller, so a stranger crediting the escrow can
 * only lose value, never take it. Token credits book the balance change that
 * actually landed.
 */
contract FusingFeeEscrow is IFusingFeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;


    error ZeroAddress();
    error NativeValueRequired();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();
    error NotFactory();
    error PlanAlreadySet(address launchToken);
    error TooManyPayees(uint256 count, uint256 max);
    error SharesMustSumToTotal(uint256 sum);
    error EmptyPayee();
    error AttestationExpired(uint256 deadline);
    error BadAttestation();
    error NoAttester();

    event Credited(address indexed recipient, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, uint256 amount);
    event CreditedHandle(bytes32 indexed handle, address indexed token, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);
    event HandleClaimed(bytes32 indexed handle, address indexed to, address indexed token, uint256 amount);
    event PlanSet(address indexed launchToken, FusingTerms.Payee[] payees);
    event AttesterSet(address indexed attester);

    /// @notice Five wallet or handle payees at most, plus the two vaults, gives seven.
    uint256 public constant MAX_PAYEES = 7;
    uint256 private constant BPS = 10_000;
    /// @dev The token ledgers file native ETH under the zero address.
    address private constant NATIVE = address(0);

    /// @notice The launch factory, sole author of payout plans. The owner sets it exactly once.
    address public factory;
    /// @notice The fusi.ng owner: the account that appoints the factory and the attester.
    address public immutable owner;
    /// @notice The key that signs proofs of X handle ownership. The owner can replace it.
    address public attester;

    mapping(address recipient => uint256 amount) private _nativeBalances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;
    /// @dev Per-handle balances, one entry per asset, with native ETH under address(0).
    mapping(bytes32 handle => mapping(address asset => uint256 amount)) private _handleBalances;
    mapping(address launchToken => FusingTerms.Payee[]) private _plans;

    error NotOwner();
    error FactoryAlreadySet();

    event FactorySet(address indexed factory);

    /// @dev Whoever deploys the escrow owns it; the escrow has to exist before the factory that depends on it.
    constructor() {
        owner = msg.sender;
    }

    /// @notice Appoints the factory. Owner only, one time; the factory constructor takes this address, so the escrow comes first.
    function setFactory(address factory_) external {
        if (msg.sender != owner) revert NotOwner();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    // ---------------------------------------------------------------------
    // Payout plans
    // ---------------------------------------------------------------------

    /**
     * @notice Stores the payout plan for `launchToken`. Factory only, one
     * time. Shares have to add up to exactly 10,000 bps. Passing an empty
     * list leaves the launch without a plan, so the default recipient takes
     * the full share.
     */
    function setPlan(address launchToken, FusingTerms.Payee[] calldata payees) external {
        if (msg.sender != factory) revert NotFactory();
        if (_plans[launchToken].length != 0) revert PlanAlreadySet(launchToken);
        if (payees.length == 0) return;
        if (payees.length > MAX_PAYEES) revert TooManyPayees(payees.length, MAX_PAYEES);
        uint256 sum;
        for (uint256 i = 0; i < payees.length; i++) {
            FusingTerms.Payee calldata p = payees[i];
            if (p.bps == 0) revert EmptyPayee();
            if (p.kind == FusingTerms.PayeeKind.HANDLE) {
                if (p.handle == bytes32(0)) revert EmptyPayee();
            } else if (p.account == address(0)) {
                revert ZeroAddress();
            }
            sum += p.bps;
            _plans[launchToken].push(p);
        }
        if (sum != BPS) revert SharesMustSumToTotal(sum);
        emit PlanSet(launchToken, payees);
    }

    function planOf(address launchToken) external view returns (FusingTerms.Payee[] memory) {
        return _plans[launchToken];
    }

    // ---------------------------------------------------------------------
    // Fee credits
    // ---------------------------------------------------------------------

    /// @notice The V1 call: books the ETH sent with the call to `recipient`.
    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert NativeValueRequired();
        _creditNative(recipient, msg.value);
    }

    /// @notice The V1 call: draws `amount` of `token` from the caller and books whatever actually landed.
    function creditToken(address recipient, address token, uint256 amount) external {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        uint256 received = _pull(token, amount);
        _creditToken(recipient, token, received);
    }

    /**
     * @notice Books the ETH sent with the call as creator fees for
     * `launchToken`, divided according to its plan, or entirely to
     * `fallbackRecipient` if no plan exists.
     */
    function creditFor(address launchToken, address fallbackRecipient) external payable {
        if (fallbackRecipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert NativeValueRequired();
        _apply(launchToken, fallbackRecipient, NATIVE, msg.value);
    }

    /**
     * @notice Draws `amount` of `asset` from the caller and books whatever
     * landed as creator fees for `launchToken`, divided according to its plan.
     */
    function creditTokenFor(address launchToken, address fallbackRecipient, address asset, uint256 amount)
        external
        returns (uint256 received)
    {
        if (fallbackRecipient == address(0) || asset == address(0)) revert ZeroAddress();
        received = _pull(asset, amount);
        _apply(launchToken, fallbackRecipient, asset, received);
    }

    function _apply(address launchToken, address fallbackRecipient, address asset, uint256 amount) private {
        FusingTerms.Payee[] storage plan = _plans[launchToken];
        uint256 n = plan.length;
        if (n == 0) {
            _creditAsset(fallbackRecipient, asset, amount);
            return;
        }
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            FusingTerms.Payee storage p = plan[i];
            // Whatever rounding leaves over goes to the final payee, so every wei is assigned.
            uint256 share = i + 1 == n ? amount - paid : amount * p.bps / BPS;
            paid += share;
            if (share == 0) continue;
            if (p.kind == FusingTerms.PayeeKind.WALLET) {
                _creditAsset(p.account, asset, share);
            } else if (p.kind == FusingTerms.PayeeKind.HANDLE) {
                _handleBalances[p.handle][asset] += share;
                emit CreditedHandle(p.handle, asset, share);
            } else {
                _forwardToHolders(p.account, asset, share);
            }
        }
    }

    /**
     * @dev If the holder distributor rejects the deposit for any reason
     * (paused, gas exhausted, whatever it may be), fee collection must still
     * succeed. The share is therefore booked to the distributor's own
     * claimable balance on failure, from where it can be pushed in later.
     */
    function _forwardToHolders(address distributor, address asset, uint256 amount) private {
        if (asset == NATIVE) {
            try IFusingHolderDistributor(distributor).deposit{value: amount}() {}
            catch {
                _creditNative(distributor, amount);
            }
        } else {
            IERC20(asset).forceApprove(distributor, amount);
            try IFusingHolderDistributor(distributor).depositToken(asset, amount) {}
            catch {
                IERC20(asset).forceApprove(distributor, 0);
                _creditToken(distributor, asset, amount);
            }
        }
    }

    function _creditAsset(address recipient, address asset, uint256 amount) private {
        if (asset == NATIVE) _creditNative(recipient, amount);
        else _creditToken(recipient, asset, amount);
    }

    function _creditNative(address recipient, uint256 amount) private {
        _nativeBalances[recipient] += amount;
        emit Credited(recipient, amount);
    }

    function _creditToken(address recipient, address token, uint256 amount) private {
        _tokenBalances[recipient][token] += amount;
        emit CreditedToken(recipient, token, amount);
    }

    function _pull(address token, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------------
    // X handle claims
    // ---------------------------------------------------------------------

    /// @notice Sets the key whose signatures prove handle ownership. Owner only.
    function setAttester(address attester_) external {
        if (msg.sender != owner) revert NotOwner();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    /**
     * @notice The digest the attester signs to vouch that `wallet` controls
     * `handle` until `deadline`. It folds in the chain id and this contract's
     * address, so the same signature is useless anywhere else.
     */
    function attestationDigest(bytes32 handle, address wallet, uint256 deadline) public view returns (bytes32) {
        return keccak256(abi.encode("fusi.ng handle attestation", block.chainid, address(this), handle, wallet, deadline));
    }

    /**
     * @notice Transfers a handle's balance of `asset` (native under
     * address(0)) into the caller's own claimable ledger, provided the caller
     * presents an unexpired attestation of ownership. From there it is claimed
     * like any other balance.
     */
    function claimHandle(bytes32 handle, address asset, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 amount)
    {
        if (attester == address(0)) revert NoAttester();
        if (block.timestamp > deadline) revert AttestationExpired(deadline);
        bytes32 digest =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", attestationDigest(handle, msg.sender, deadline)));
        if (_recover(digest, signature) != attester) revert BadAttestation();

        amount = _handleBalances[handle][asset];
        if (amount == 0) return 0;
        _handleBalances[handle][asset] = 0;
        _creditAsset(msg.sender, asset, amount);
        emit HandleClaimed(handle, msg.sender, asset, amount);
    }

    /// @dev Bare ecrecover plus the high-s malleability guard; the OpenZeppelin copy we pin does not include ECDSA.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadAttestation();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadAttestation();
        if (v != 27 && v != 28) revert BadAttestation();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadAttestation();
        return signer;
    }

    /// @notice Computes the key a plan stores for a handle: keccak256 of its lower-cased form. Leave the @ off.
    function handleKey(string calldata handle) external pure returns (bytes32) {
        bytes memory b = bytes(handle);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return keccak256(b);
    }

    function handleBalance(bytes32 handle, address asset) external view returns (uint256) {
        return _handleBalances[handle][asset];
    }

    // ---------------------------------------------------------------------
    // Claims (same as V1)
    // ---------------------------------------------------------------------

    function claim() external returns (uint256 amount) {
        return _claimNative(_nativeBalances[msg.sender]);
    }

    function claim(uint256 amount) external returns (uint256) {
        return _claimNative(amount);
    }

    function claimToken(address token) external returns (uint256 amount) {
        return _claimToken(token, _tokenBalances[msg.sender][token]);
    }

    function claimToken(address token, uint256 amount) external returns (uint256) {
        return _claimToken(token, amount);
    }

    function balanceOf(address recipient) external view returns (uint256) {
        return _nativeBalances[recipient];
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokenBalances[recipient][token];
    }

    function _claimNative(uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _nativeBalances[msg.sender];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _nativeBalances[msg.sender] = available - amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
        emit Claimed(msg.sender, amount);
        return amount;
    }

    function _claimToken(address token, uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _tokenBalances[msg.sender][token];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _tokenBalances[msg.sender][token] = available - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ClaimedToken(msg.sender, token, amount);
        return amount;
    }
}
