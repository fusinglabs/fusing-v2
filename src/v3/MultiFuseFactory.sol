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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FusingLauncherToken} from "../v2/FusingLauncherToken.sol";
import {LaunchDeployment, FusingLaunchDeployer} from "../v2/FusingLaunchDeployer.sol";
import {FusingQuotePricer} from "../v2/FusingQuotePricer.sol";
import {FusingPositionMath} from "../v2/libraries/FusingPositionMath.sol";
import {FusingQuoteAssetProbe} from "../v2/libraries/FusingQuoteAssetProbe.sol";
import {IFusingFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";
import {MultiFuseLocker} from "./MultiFuseLocker.sol";
import {MultiFusePositionMinter} from "./MultiFusePositionMinter.sol";
import {IMultiFuseFactory} from "./interfaces/ILaunchpadV3.sol";
import {FusingTerms} from "../v2/libraries/FusingTerms.sol";

/**
 * @title MultiFuseFactory
 * @notice The MultiFuse launch factory. One call deploys the launch token
 * and opens a Uniswap V4 pool for each quote asset the creator picked, up to
 * MAX_MARKETS of them. The pools are deliberately simple: no hook, a static
 * LP fee, and an equal slice of the supply in each, placed as a permanently
 * locked single-sided position that runs from the opening price upward.
 *
 * All markets open at one ETH-denominated price. The quote pricer translates
 * the launch config's phantom reserve into every quote asset, then each pool
 * receives 1/N of the supply against 1/N of that reserve. The curves are
 * therefore scaled copies of each other, and there is no gap to arbitrage
 * when trading begins. From then on arbitrageurs hold the markets together,
 * exactly as they would for the same asset listed on two venues.
 *
 * This contract sits next to FusingLaunchFactory (the single-market factory)
 * and has its own locker and position minter. The fee escrow and the quote
 * pricer are shared between the two.
 */
contract MultiFuseFactory is Ownable2Step, ReentrancyGuard, IMultiFuseFactory {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_BASE_FEE_BPS = 1_000; // hard cap of 10%
    uint256 private constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // hard cap of 10%
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // base plus creator tax, at most 20%
    // Uniswap V4 states its LP fee in hundredths of a basis point.
    uint24 private constant PIPS_PER_BP = 100;
    uint8 private constant MIN_PAIR_TOKEN_DECIMALS = 6;
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    uint256 private constant MAX_SUPPLY = uint256(uint128(type(int128).max));
    int24 private constant MAX_TICK_SPACING = 32767;
    /// @notice Upper bound on the number of pools a single launch can open.
    uint256 public constant MAX_MARKETS = 6;
    uint256 public constant CREATOR_FEE_RECIPIENT_TIMELOCK = 3 days;
    uint256 public constant CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW = 3 days;

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        FusingLauncherToken.Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        // Optional commitment to the terms this launch will be locked to.
        // Leave it zero to skip the check; previewLaunchEconomics returns
        // the value to pass.
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    /**
     * @notice The launch terms expressed against native ETH for the entire
     * supply. `phantomQuote` is denominated in wei, and each market's own
     * reserve is derived from it.
     */
    struct LaunchConfig {
        uint256 supply;
        uint256 phantomQuote;
        int24 tickSpacing;
        bool enabled;
    }

    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint8 decimals;
    }

    struct PendingCreatorFeeRecipient {
        address newRecipient;
        uint256 effectiveAt;
        uint256 expiresAt;
    }

    error InvalidLaunchConfigId();
    error LaunchConfigDisabled();
    error InvalidBasisPoints();
    error CreatorTaxTooHigh();
    error CombinedFeeTooHigh();
    error SupplyTooLow();
    error SupplyTooHigh();
    error InvalidTickSpacing();
    error LaunchFeeNotPaid();
    error NotWhitelisted();
    /// @dev The ERC-20 quote asset has not yet passed the exact-transfer proof.
    error QuoteAssetNotProven(address quoteToken);
    error FeeTransferFailed();
    error ZeroAddress();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error InvalidTokenParams();
    error TokenNotFound();
    error NotLaunchForwarder();
    error NotCreatorFeeRecipient();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 effectiveAt);
    error TimelockExpired(uint256 expiresAt);
    error LaunchDependenciesNotWired();
    error PairTokenValidationFailed();
    error InvalidPhantomQuote();
    error PairTokenEconomicsInvalid();
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error PairTokenDecimalsUnavailable();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    error PoolAlreadyExists();
    /// @dev No quote assets were given, or more than MAX_MARKETS of them.
    error InvalidMarketCount();
    /// @dev A quote asset appears more than once in the list.
    error DuplicatePairToken();
    /// @dev WETH is rejected as a quote; markets in ETH use the native asset.
    error WethNotAllowed();
    error MarketNotFound();

    event TokenLaunched(
        address indexed token, address indexed deployer, uint256 launchConfigId, uint24 poolFee, address[] pairTokens
    );
    /**
     * @notice Emitted once for each market, in market order, next to
     * TokenLaunched. `tokenAmount` is the supply that actually landed in
     * that pool.
     */
    event MarketOpened(
        address indexed token,
        bytes32 indexed poolId,
        uint256 marketIndex,
        address pairToken,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenAmount,
        uint256 phantomQuote
    );
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );
    event CreatorFeeRecipientChangeProposed(
        address indexed token,
        address indexed currentRecipient,
        address indexed proposedRecipient,
        uint256 effectiveAt,
        uint256 expiresAt
    );
    event CreatorFeeRecipientChangeCancelled(address indexed token, address indexed proposedRecipient);
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchFeeUpdated(uint256 launchFee);
    event LaunchEnabledUpdated(bool enabled);
    event WhitelistedLauncherUpdated(address indexed launcher, bool enabled);
    event MaxCreatorTaxUpdated(uint256 bps);
    event BaseFeeUpdated(uint256 bps);
    event ProtocolFeeShareUpdated(uint256 bps);
    event ProtocolFeeRecipientUpdated(address recipient);
    event PositionMinterSet(address minter);
    event LaunchDeployerSet(address deployer);
    event LaunchForwarderSet(address forwarder);
    event PairTokenEconomicsUpdated(address indexed pairToken, uint256 phantomQuote, uint8 decimals);
    event PairTokenEconomicsCleared(address indexed pairToken);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    MultiFuseLocker public immutable locker;
    IFusingFeeEscrow public immutable feeEscrow;
    FusingQuotePricer public immutable quotePricer;
    address public immutable weth;

    MultiFusePositionMinter public positionMinter;
    FusingLaunchDeployer public launchDeployer;
    address public launchForwarder;

    uint256 public baseFeeBps = 110; // 1.1%, the fusi.ng signature rate
    uint256 public protocolFeeShareBps = 3_000; // the V1 default; the V2 deploy sets 4_000, protocol 40% and creator 60%
    address public protocolFeeRecipient;
    uint256 public maxCreatorTaxBps = 1_000; // 10% until the owner changes it

    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address launcher => bool enabled) public whitelistedLaunchers;

    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    mapping(address token => Market[] markets) private _markets;
    mapping(address token => PendingCreatorFeeRecipient) public pendingCreatorFeeRecipient;
    LaunchConfig[] private _launchConfigs;

    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        MultiFuseLocker locker_,
        IFusingFeeEscrow feeEscrow_,
        FusingQuotePricer quotePricer_,
        address weth_,
        address protocolFeeRecipient_,
        uint256 initialLaunchFee
    ) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || address(positionManager_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(quotePricer_) == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (address(positionManager_.poolManager()) != address(poolManager_)) revert LaunchDependenciesNotWired();

        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        feeEscrow = feeEscrow_;
        quotePricer = quotePricer_;
        weth = weth_;
        protocolFeeRecipient = protocolFeeRecipient_;
        launchFee = initialLaunchFee;
    }

    // ---------------------------------------------------------------------
    // Read-only views
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // What the shared token deployer asks its factory for
    // ---------------------------------------------------------------------

    /**
     * @dev MultiFuse launches share FusingLaunchDeployer with the single-pool
     * factory, and that deployer reads the launcher's guard and V2 terms from
     * whichever factory owns it. A MultiFuse launch carries the token-side
     * protections only: wallet and transaction caps for a while, and a
     * whitelist window in which only the list can receive the token. There
     * is no hook on its pools, so no fee schedule, no sniper tax, no payout
     * plan and no dev lock; those fields of the terms stay zero.
     */
    struct LaunchGuard {
        uint16 maxWalletBps;
        uint16 maxTxBps;
        uint32 limitsSeconds;
        address[] whitelist;
    }

    uint16 public constant MIN_LIMIT_BPS = 10;
    uint16 public constant MAX_LIMIT_BPS = 300;
    uint32 public constant MAX_LIMITS_SECONDS = 20 minutes;
    uint256 public constant MAX_WHITELIST = 33;
    /// @notice How long a whitelisted launch stays closed to everyone off the list.
    uint64 public constant WHITELIST_GUARD_SECONDS = 60;

    mapping(address launcher => LaunchGuard) private _guardOf;

    event GuardStaged(address indexed launcher, uint16 maxWalletBps, uint16 maxTxBps, uint32 limitsSeconds, uint256 whitelisted);
    error TermsInvalid();

    /**
     * @notice Records the caps and whitelist for the caller's next MultiFuse
     * launch. The launch consumes them; stage nothing, or all zeros, for an
     * open launch. Anyone may call this; it only shapes launches the caller makes.
     */
    function stageGuard(LaunchGuard calldata g) external {
        _stageGuard(msg.sender, g);
    }

    /// @notice Lets the launch-and-buy router stage the guard for the account it is launching for.
    function stageGuardFor(address launcher, LaunchGuard calldata g) external {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        _stageGuard(launcher, g);
    }

    /// @notice Whatever `launcher` has staged for their upcoming launch.
    function guardOf(address launcher) external view returns (LaunchGuard memory) {
        return _guardOf[launcher];
    }

    function _stageGuard(address launcher, LaunchGuard calldata g) private {
        if (g.maxWalletBps != 0 && (g.maxWalletBps < MIN_LIMIT_BPS || g.maxWalletBps > MAX_LIMIT_BPS)) revert TermsInvalid();
        if (g.maxTxBps != 0 && (g.maxTxBps < MIN_LIMIT_BPS || g.maxTxBps > MAX_LIMIT_BPS)) revert TermsInvalid();
        bool caps = g.maxWalletBps != 0 || g.maxTxBps != 0;
        if (caps && (g.limitsSeconds == 0 || g.limitsSeconds > MAX_LIMITS_SECONDS)) revert TermsInvalid();
        if (g.whitelist.length > MAX_WHITELIST) revert TermsInvalid();
        LaunchGuard storage t = _guardOf[launcher];
        t.maxWalletBps = g.maxWalletBps;
        t.maxTxBps = g.maxTxBps;
        t.limitsSeconds = caps ? g.limitsSeconds : 0;
        delete t.whitelist;
        uint256 listed;
        for (uint256 i = 0; i < g.whitelist.length; i++) {
            if (g.whitelist[i] != address(0)) {
                t.whitelist.push(g.whitelist[i]);
                listed++;
            }
        }
        emit GuardStaged(launcher, g.maxWalletBps, g.maxTxBps, t.limitsSeconds, listed);
    }

    /// @dev A whitelist is a launch window, the same length as on the single-pool factory.
    function guardSecondsOf(address launcher) public view returns (uint64) {
        return _guardOf[launcher].whitelist.length > 0 ? WHITELIST_GUARD_SECONDS : 0;
    }

    /// @dev Who may receive the token during the window: the launch plumbing, the creator and the list.
    function guardListOf(address launcher) external view returns (address[] memory list) {
        address[] storage wl = _guardOf[launcher].whitelist;
        if (wl.length == 0) return list;
        list = new address[](6 + wl.length);
        list[0] = address(poolManager);
        list[1] = address(positionManager);
        list[2] = address(positionMinter);
        list[3] = address(locker);
        list[4] = launchForwarder;
        list[5] = launcher;
        for (uint256 i = 0; i < wl.length; i++) {
            list[6 + i] = wl[i];
        }
    }

    /// @dev The token-side terms only; every hook, payout and lock field stays zero.
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory terms) {
        LaunchGuard storage g = _guardOf[launcher];
        terms.maxWalletBps = g.maxWalletBps;
        terms.maxTxBps = g.maxTxBps;
        terms.limitsSeconds = g.limitsSeconds;
        terms.whitelist = g.whitelist;
    }

    /// @notice The pool plumbing and routers that the token caps must never apply to.
    function limitExemptions() external view returns (address[] memory list) {
        list = new address[](7);
        list[0] = address(poolManager);
        list[1] = address(positionMinter);
        list[2] = address(locker);
        list[3] = launchForwarder;
        list[4] = address(feeEscrow);
        // The supply passes through Uniswap's PositionManager and Permit2 during the launch transaction.
        list[5] = address(positionManager);
        list[6] = address(positionMinter.permit2());
    }

    /// @notice The wallets `launcher` staged to be spared the caps for the first blocks.
    function whitelistOf(address launcher) external view returns (address[] memory) {
        return _guardOf[launcher].whitelist;
    }

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    function getLaunchedToken(address token) external view override returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    function getMarkets(address token) external view override returns (Market[] memory) {
        return _markets[token];
    }

    function getMarket(address token, uint256 index) external view override returns (Market memory) {
        if (index >= _markets[token].length) revert MarketNotFound();
        return _markets[token][index];
    }

    /**
     * @notice Rebuilds the pool key for market `index` of a launched token.
     */
    function poolKeyFor(address token, uint256 index) public view override returns (PoolKey memory) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (index >= _markets[token].length) revert MarketNotFound();
        return _poolKey(token, _markets[token][index].pairToken, launch.poolFee, launch.tickSpacing);
    }

    function poolKeysFor(address token) external view override returns (PoolKey[] memory keys) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        Market[] storage ms = _markets[token];
        keys = new PoolKey[](ms.length);
        for (uint256 i = 0; i < ms.length; i++) {
            keys[i] = _poolKey(token, ms[i].pairToken, launch.poolFee, launch.tickSpacing);
        }
    }

    function poolIdFor(address token, uint256 index) external view returns (PoolId) {
        return poolKeyFor(token, index).toId();
    }

    function canLaunch(address launcher) public view returns (bool) {
        return launchEnabled || whitelistedLaunchers[launcher];
    }

    function poolFeeFor(uint16 creatorTaxBps) public view returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24((baseFeeBps + creatorTaxBps) * PIPS_PER_BP);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    function setLaunchFee(uint256 newLaunchFee) external onlyOwner {
        launchFee = newLaunchFee;
        emit LaunchFeeUpdated(newLaunchFee);
    }

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    function setWhitelistedLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        whitelistedLaunchers[launcher] = enabled;
        emit WhitelistedLauncherUpdated(launcher, enabled);
    }

    function setPairTokenEconomics(address pairToken, uint256 phantomQuote, uint8 expectedDecimals)
        external
        onlyOwner
    {
        if (pairToken == address(0) || phantomQuote == 0) revert PairTokenEconomicsInvalid();
        if (expectedDecimals < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenEconomicsInvalid();
        _requireDecimals(pairToken, expectedDecimals, false);
        pairTokenEconomics[pairToken] = PairTokenEconomics({phantomQuote: phantomQuote, decimals: expectedDecimals});
        emit PairTokenEconomicsUpdated(pairToken, phantomQuote, expectedDecimals);
    }

    function clearPairTokenEconomics(address pairToken) external onlyOwner {
        delete pairTokenEconomics[pairToken];
        emit PairTokenEconomicsCleared(pairToken);
    }

    function setMaxCreatorTaxBps(uint256 bps) external onlyOwner {
        if (bps > MAX_CREATOR_TAX_CEILING_BPS) revert InvalidBasisPoints();
        maxCreatorTaxBps = bps;
        emit MaxCreatorTaxUpdated(bps);
    }

    function setBaseFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_BASE_FEE_BPS) revert InvalidBasisPoints();
        baseFeeBps = bps;
        emit BaseFeeUpdated(bps);
    }

    function setProtocolFeeShareBps(uint256 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBasisPoints();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setPositionMinter(MultiFusePositionMinter minter) external onlyOwner {
        if (address(positionMinter) != address(0)) revert AlreadySet();
        if (address(minter) == address(0)) revert ZeroAddress();
        positionMinter = minter;
        emit PositionMinterSet(address(minter));
    }

    function setLaunchDeployer(FusingLaunchDeployer deployer) external onlyOwner {
        if (address(launchDeployer) != address(0)) revert AlreadySet();
        if (address(deployer) == address(0)) revert ZeroAddress();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ---------------------------------------------------------------------
    // Launching
    // ---------------------------------------------------------------------

    /**
     * @notice Computes the digest a launch of `launchConfigId` on `pairTokens`
     * would lock in if sent now. Pass it as TokenParams.expectedEconomics.
     */
    function previewLaunchEconomics(uint256 launchConfigId, address[] calldata pairTokens)
        external
        view
        returns (bytes32)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        LaunchConfig memory config = _launchConfigs[launchConfigId];
        _validatePairTokens(pairTokens);
        return _economicsDigest(config, _phantoms(config, pairTokens));
    }

    /**
     * @notice The virtual reserve each market would open with if a launch on
     * `pairTokens` were sent now. Figures are per market, in that quote
     * asset's own units, and already scaled to the market's share of the
     * supply.
     */
    function previewQuoteEconomics(uint256 launchConfigId, address[] calldata pairTokens)
        external
        view
        returns (uint256[] memory phantomQuotes)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validatePairTokens(pairTokens);
        phantomQuotes = _phantoms(_launchConfigs[launchConfigId], pairTokens);
        for (uint256 i = 0; i < phantomQuotes.length; i++) {
            phantomQuotes[i] /= pairTokens.length;
        }
    }

    /**
     * @notice Deploys the launch token and opens a pool against every quote
     * asset in the list.
     * @param pairTokens Between 1 and MAX_MARKETS distinct quote assets, with
     * address(0) standing for native ETH. Each gets an equal share of the
     * supply.
     */
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address[] calldata pairTokens)
        external
        payable
        nonReentrant
        returns (address token)
    {
        return _launchToken(params, launchConfigId, pairTokens, msg.sender);
    }

    /**
     * @notice Launch entry point for the trusted launch-and-buy router, which
     * acts on behalf of the user who started the transaction. Only the
     * configured `launchForwarder` is allowed to name `originalDeployer`, so
     * the real creator is recorded without resorting to `tx.origin`.
     */
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        address originalDeployer
    ) external payable nonReentrant returns (address token) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        return _launchToken(params, launchConfigId, pairTokens, originalDeployer);
    }

    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        address originalDeployer
    ) private returns (address token) {
        _requireLaunchDependenciesWired();
        if (!canLaunch(originalDeployer)) revert NotWhitelisted();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();
        if (baseFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) revert CombinedFeeTooHigh();
        _validatePairTokens(pairTokens);

        LaunchConfig memory config = _launchConfigs[launchConfigId];
        if (!config.enabled) revert LaunchConfigDisabled();

        uint256[] memory phantoms = _phantoms(config, pairTokens);
        // Each ERC-20 quote must have passed the exact-transfer proof before
        // a single pool is opened; FusingQuoteAssetProbe explains why. If one
        // quote in the set misbehaved, buys on that market would fail and fee
        // collection for the entire launch would fail along with them.
        for (uint256 i = 0; i < pairTokens.length; i++) {
            if (pairTokens[i] == address(0)) continue;
            if (!quotePricer.exactTransferProven(pairTokens[i])) {
                revert QuoteAssetNotProven(pairTokens[i]);
            }
        }
        bytes32 economics = _economicsDigest(config, phantoms);
        if (params.expectedEconomics != bytes32(0) && params.expectedEconomics != economics) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, economics);
        }

        // Deploy the token before anything else, since the currency ordering
        // of every pool key depends on its address. The full supply is minted
        // to the position minter.
        token = launchDeployer.deployToken(
            LaunchDeployment({
                originalDeployer: originalDeployer,
                supplyRecipient: address(positionMinter),
                supply: config.supply,
                salt: params.salt,
                name: params.name,
                symbol: params.symbol,
                logo: params.logo,
                description: params.description,
                socials: params.socials
            })
        );

        // The token read its caps and whitelist from this factory while it was
        // being deployed; the staged guard goes with the launch that used it.
        delete _guardOf[originalDeployer];

        uint24 poolFee = poolFeeFor(params.creatorTaxBps);
        _launchedTokens[token] = LaunchedToken({
            token: token,
            deployer: originalDeployer,
            creatorFeeRecipient: params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient,
            poolFee: poolFee,
            tickSpacing: config.tickSpacing,
            baseFeeBps: uint16(baseFeeBps),
            creatorTaxBps: params.creatorTaxBps,
            protocolFeeShareBps: uint16(protocolFeeShareBps),
            protocolFeeRecipient: protocolFeeRecipient,
            launchedAt: uint64(block.timestamp),
            marketCount: uint8(pairTokens.length),
            exists: true
        });

        _openMarkets(token, pairTokens, phantoms, config, poolFee);

        // Kept for the very end, once the launch is completely written down:
        // this sends ETH to the protocol recipient, and that recipient could
        // be a contract that re-enters us.
        _payLaunchFee();

        emit TokenLaunched(token, originalDeployer, launchConfigId, poolFee, pairTokens);
    }

    /**
     * @dev Initializes each pool at the price its plan calls for, mints the
     * positions and hands them to the locker. Market i receives supply / N
     * tokens against phantom_i / N of quote, which is what puts every market
     * at the same ETH price.
     */
    function _openMarkets(
        address token,
        address[] calldata pairTokens,
        uint256[] memory phantoms,
        LaunchConfig memory config,
        uint24 poolFee
    ) private {
        uint256 n = pairTokens.length;
        uint256 supplyEach = config.supply / n;
        PoolKey[] memory keys = new PoolKey[](n);
        FusingPositionMath.Plan[] memory plans = new FusingPositionMath.Plan[](n);

        for (uint256 i = 0; i < n; i++) {
            keys[i] = _poolKey(token, pairTokens[i], poolFee, config.tickSpacing);
            // Anyone can initialize a hookless pool for an address that has
            // no code yet. If we launched into a pool someone else had set
            // up, trading would open at their chosen price, so the launch is
            // rejected instead.
            //
            // A mempool watcher can grief this check, and we accept that
            // knowingly; the same check in FusingLaunchFactory carries the
            // full reasoning. Changing the salt yields a new token address
            // and with it a fresh set of pool keys, and sending through a
            // private relay sidesteps the race entirely. Every alternative
            // either breaks the address prediction the interface relies on
            // or bolts a swap path onto this function.
            (uint160 existingPrice,,,) = poolManager.getSlot0(keys[i].toId());
            if (existingPrice != 0) revert PoolAlreadyExists();

            bool tokenIsCurrency0 = Currency.unwrap(keys[i].currency0) == token;
            plans[i] = positionMinter.plan(tokenIsCurrency0, supplyEach, phantoms[i] / n, config.tickSpacing);
            poolManager.initialize(keys[i], plans[i].sqrtPriceX96);
        }

        (uint256[] memory positionIds, uint256[] memory tokenAmounts) =
            positionMinter.mintLaunchPositions(token, keys, plans, supplyEach);
        locker.lockPositions(token, positionIds);

        for (uint256 i = 0; i < n; i++) {
            _markets[token].push(
                Market({
                    pairToken: pairTokens[i],
                    phantomQuote: phantoms[i] / n,
                    tickLower: plans[i].tickLower,
                    tickUpper: plans[i].tickUpper,
                    liquidity: plans[i].liquidity,
                    positionId: positionIds[i]
                })
            );
            emit MarketOpened(
                token,
                PoolId.unwrap(keys[i].toId()),
                i,
                pairTokens[i],
                positionIds[i],
                plans[i].tickLower,
                plans[i].tickUpper,
                plans[i].liquidity,
                tokenAmounts[i],
                phantoms[i] / n
            );
        }
    }

    // ---------------------------------------------------------------------
    // Creator fee recipient management
    // ---------------------------------------------------------------------

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (msg.sender != launch.creatorFeeRecipient) revert NotCreatorFeeRecipient();
        _setCreatorFeeRecipient(token, launch, newRecipient);
    }

    function setCreatorFeeRecipient(address token, address newRecipient) external onlyOwner {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (newRecipient == address(0)) revert ZeroAddress();

        uint256 effectiveAt = block.timestamp + CREATOR_FEE_RECIPIENT_TIMELOCK;
        uint256 expiresAt = effectiveAt + CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW;
        pendingCreatorFeeRecipient[token] =
            PendingCreatorFeeRecipient({newRecipient: newRecipient, effectiveAt: effectiveAt, expiresAt: expiresAt});
        emit CreatorFeeRecipientChangeProposed(token, launch.creatorFeeRecipient, newRecipient, effectiveAt, expiresAt);
    }

    function executeCreatorFeeRecipientChange(address token) external {
        PendingCreatorFeeRecipient memory pending = pendingCreatorFeeRecipient[token];
        if (pending.newRecipient == address(0)) revert NoPendingChange();
        if (block.timestamp < pending.effectiveAt) revert TimelockNotElapsed(pending.effectiveAt);
        if (block.timestamp > pending.expiresAt) revert TimelockExpired(pending.expiresAt);

        LaunchedToken storage launch = _launchedTokens[token];
        delete pendingCreatorFeeRecipient[token];
        _setCreatorFeeRecipient(token, launch, pending.newRecipient);
    }

    function cancelCreatorFeeRecipientChange(address token) external onlyOwner {
        PendingCreatorFeeRecipient memory pending = pendingCreatorFeeRecipient[token];
        if (pending.newRecipient == address(0)) revert NoPendingChange();
        delete pendingCreatorFeeRecipient[token];
        emit CreatorFeeRecipientChangeCancelled(token, pending.newRecipient);
    }

    function _setCreatorFeeRecipient(address token, LaunchedToken storage launch, address newRecipient) private {
        if (newRecipient == address(0)) revert ZeroAddress();
        address previousRecipient = launch.creatorFeeRecipient;
        launch.creatorFeeRecipient = newRecipient;
        emit CreatorFeeRecipientUpdated(token, previousRecipient, newRecipient);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Requires 1 to MAX_MARKETS distinct quote assets and refuses WETH,
    /// because ETH markets use the native asset.
    function _validatePairTokens(address[] calldata pairTokens) private view {
        uint256 n = pairTokens.length;
        if (n == 0 || n > MAX_MARKETS) revert InvalidMarketCount();
        for (uint256 i = 0; i < n; i++) {
            if (pairTokens[i] == weth) revert WethNotAllowed();
            for (uint256 j = i + 1; j < n; j++) {
                if (pairTokens[i] == pairTokens[j]) revert DuplicatePairToken();
            }
        }
    }

    /// @dev The full-supply virtual reserve for each quote asset in the list.
    function _phantoms(LaunchConfig memory config, address[] calldata pairTokens)
        private
        view
        returns (uint256[] memory phantoms)
    {
        phantoms = new uint256[](pairTokens.length);
        for (uint256 i = 0; i < pairTokens.length; i++) {
            phantoms[i] = _quoteEconomics(config, pairTokens[i]);
        }
    }

    /**
     * @dev Works out the full-supply virtual reserve for a single quote
     * asset. Native ETH uses the config value as is, a curated ERC-20 uses
     * the override the owner set for it, and any other ERC-20 is converted
     * by the quote pricer.
     */
    function _quoteEconomics(LaunchConfig memory config, address pairToken) private view returns (uint256) {
        if (pairToken == address(0)) return config.phantomQuote;

        PairTokenEconomics memory curated = pairTokenEconomics[pairToken];
        if (curated.phantomQuote != 0) {
            _requireDecimals(pairToken, curated.decimals, true);
            return curated.phantomQuote;
        }

        if (pairToken.code.length == 0) revert PairTokenValidationFailed();
        if (_readDecimals(pairToken) < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenValidationFailed();
        return quotePricer.quoteEconomics(pairToken, config.phantomQuote);
    }

    function _requireDecimals(address pairToken, uint8 expectedDecimals, bool required) private view {
        if (!required && pairToken.code.length == 0) return;
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
        } catch {
            if (required) revert PairTokenDecimalsUnavailable();
        }
    }

    function _readDecimals(address pairToken) private view returns (uint8) {
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            return actual;
        } catch {
            revert PairTokenDecimalsUnavailable();
        }
    }

    /// @dev Hashes every owner-controlled term that determines what the
    /// creator is signing up for.
    function _economicsDigest(LaunchConfig memory config, uint256[] memory phantoms) private view returns (bytes32) {
        return keccak256(abi.encode(phantoms, config.supply, config.tickSpacing, baseFeeBps, protocolFeeShareBps));
    }

    function _requireLaunchDependenciesWired() private view {
        if (address(positionMinter) == address(0) || address(launchDeployer) == address(0)) {
            revert LaunchDependenciesNotWired();
        }
        if (launchDeployer.factory() != address(this) || positionMinter.factory() != address(this)) {
            revert LaunchDependenciesNotWired();
        }
        if (address(locker.factory()) != address(this)) revert LaunchDependenciesNotWired();
        if (
            address(locker.positionManager()) != address(positionManager)
                || address(locker.feeEscrow()) != address(feeEscrow)
        ) {
            revert LaunchDependenciesNotWired();
        }
        if (
            address(positionMinter.positionManager()) != address(positionManager)
                || positionMinter.locker() != address(locker)
        ) {
            revert LaunchDependenciesNotWired();
        }
    }

    function _poolKey(address token, address pairToken, uint24 fee, int24 tickSpacing)
        private
        pure
        returns (PoolKey memory)
    {
        (Currency currency0, Currency currency1) = pairToken < token
            ? (Currency.wrap(pairToken), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(pairToken));
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _payLaunchFee() private {
        if (launchFee == 0) return;
        (bool sent,) = payable(protocolFeeRecipient).call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();
    }

    function _validateLaunchConfig(LaunchConfig calldata config) private view {
        if (config.supply < MIN_LAUNCH_SUPPLY) revert SupplyTooLow();
        if (config.supply > MAX_SUPPLY) revert SupplyTooHigh();
        if (config.phantomQuote == 0) revert InvalidPhantomQuote();
        if (config.tickSpacing <= 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
        // Try both currency orderings and the smallest possible slice now, so
        // a config the position math cannot place is rejected at setup time
        // rather than failing individual launches later.
        if (address(positionMinter) != address(0)) {
            uint256 slice = config.supply / MAX_MARKETS;
            uint256 phantom = config.phantomQuote / MAX_MARKETS;
            positionMinter.plan(true, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(false, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(true, slice, phantom, config.tickSpacing);
            positionMinter.plan(false, slice, phantom, config.tickSpacing);
        }
    }


}
