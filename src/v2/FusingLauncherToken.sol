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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev The single entry point the token uses to notify its holder rewards distributor.
interface IFusingDistributorSink {
    function onTransfer(address from, address to) external;
}

/// @dev The only factory view the token consults at launch: the whitelist staged for the launching wallet.
interface IFactoryWhitelist {
    function whitelistOf(address launcher) external view returns (address[] memory);
}

/**
 * @title FusingLauncherToken
 * @notice The fixed-supply ERC-20 that FusingLaunchFactory creates for each launch.
 * Every token in existence is minted inside the launch transaction and, before
 * that transaction ends, sits in the launch's Uniswap V4 pool as a single
 * position that can never be withdrawn. From then on anybody, the creator
 * included, buys from the pool like everyone else; the only thing that limits
 * a large buy is the price impact it causes.
 * `deployer` is stored as immutable reference data so front ends can attribute
 * the launch; it grants no control over the token whatsoever.
 * `ERC20Burnable` lets a holder destroy their own balance if they choose to;
 * fusi.ng never burns tokens on anyone's behalf.
 */
contract FusingLauncherToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();
    /// @dev Raised when tokens would move to an address off the guard list while the guard is still in force.
    error LaunchGuardActive(address to, uint64 endsAt);
    /// @dev The requested guard window is longer than this contract allows.
    error GuardWindowTooLong(uint64 asked, uint64 max);
    /// @dev Only the contract that created this token is allowed to write the guard list.
    error NotCreator();
    /// @dev The guard list has already been written; it is set once and never altered.
    error GuardListAlreadySet();

    /**
     * Upper bound on how long a launch can stay gated. Sixty seconds gives a
     * planned opening buy room to land in the following block, and is far too
     * short to keep a market shut. No owner exists, so nothing can stretch it.
     */
    uint64 public constant MAX_GUARD_SECONDS = 60;


    address public immutable deployer;
    address public immutable launchFactory;
    /// @dev The address that executed the CREATE2 for this token, namely the launch deployer contract.
    address public immutable creator;

    /**
     * Unix timestamp at which the launch guard lifts. Zero means no guard was
     * ever set and transfers have been unrestricted from the first block.
     *
     * Until that moment, a transfer succeeds only if the RECIPIENT is on
     * `guardAllowed`. Nothing else is restricted: the rule is one-directional,
     * cannot be lengthened, answers to no owner, and once the timestamp is
     * behind us the token behaves as a plain ERC-20 for good.
     *
     * The reason it exists: a launch transaction sits in the public mempool
     * before its pool is tradeable, so without a guard the first block goes to
     * whoever runs the fastest bot instead of to the person who launched.
     * Everything about the guard is on-chain: who was allowed and for how long.
     */
    uint64 public immutable guardEndsAt;

    /// @notice Recipients that transfers may reach while the guard is in force.
    mapping(address account => bool allowed) public guardAllowed;

    /// @dev Flips to true on the single write, so the list can never be extended later.
    bool public guardListSet;

    // ------------------------------------------------------- V2 launch terms

    /// @dev Raised when a transfer would push `to` past the wallet cap during the limits window.
    error MaxWalletExceeded(address to, uint256 wouldHold, uint256 max);
    /// @dev Raised when a single transfer exceeds the per-transaction cap during the limits window.
    error MaxTxExceeded(uint256 amount, uint256 max);
    /// @dev Limits have already been written; they are set once and never revisited.
    error LimitsAlreadySet();
    /// @dev The requested limits window is longer than this contract allows.
    error LimitsWindowTooLong(uint64 asked, uint64 max);

    /**
     * Upper bound on the limits window: 20 minutes. Wallet and transaction
     * caps exist to steady the first minutes of trading, not to be a lasting
     * property of the token, and with no owner nobody can prolong them.
     */
    uint64 public constant MAX_LIMITS_SECONDS = 21 minutes; // 20 minutes of caps plus a launch window of up to a minute

    /// @notice Maximum balance any wallet may reach during the limits window. Zero disables the cap.
    uint256 public maxWallet;
    /// @notice Maximum size of one transfer during the limits window. Zero disables the cap.
    uint256 public maxTx;
    /// @notice Unix timestamp at which the caps stop applying. Zero means they were never enabled.
    uint64 public limitsEndAt;
    /// @dev Set on the single initLimits call.
    bool public limitsSet;
    /// @notice Accounts the caps ignore: the pool, the position locker and the routers.
    mapping(address account => bool) public limitExempt;
    /// @notice The creator's whitelist: spared the caps for WHITELIST_BLOCKS blocks from launch, long enough for a person to land; capped like everyone after that.
    mapping(address account => bool) public launchWhitelisted;
    /// @notice The block the caps were written in, which is the launch block.
    uint64 public launchBlock;
    /// @notice How many blocks from launch the whitelist is spared the caps: the launch window, about a minute.
    uint64 public constant WHITELIST_BLOCKS = 5;

    /// @notice Holder rewards distributor notified on each transfer. Zero means the launch has none.
    address public distributor;
    /// @dev Set on the single initDistributor call.
    bool public distributorSet;



    string public logo;
    string public description;

    Socials private _socials;

    /**
     * @notice Deploys a launch token and mints the full supply straight to
     * `supplyRecipient`, the factory helper that will open the pool position.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address deployer_,
        address launchFactory_,
        address supplyRecipient_,
        uint256 supply_,
        uint64 guardSeconds_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || supplyRecipient_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }
        if (guardSeconds_ > MAX_GUARD_SECONDS) revert GuardWindowTooLong(guardSeconds_, MAX_GUARD_SECONDS);
        creator = msg.sender;
        if (guardSeconds_ > 0) {
            guardEndsAt = uint64(block.timestamp) + guardSeconds_;
            // The supply recipient has to be able to receive the token, or the
            // launch fails: the whole supply is minted below and moved into the
            // pool position before this transaction ends.
            guardAllowed[supplyRecipient_] = true;
        }

        deployer = deployer_;
        // Taken as an argument instead of msg.sender on purpose. FusingLaunchFactory
        // creates this token through FusingLaunchDeployer so the factory itself
        // stays under the EIP-170 bytecode limit, which means msg.sender during
        // construction is that helper rather than the factory.
        launchFactory = launchFactory_;
        logo = logo_;
        description = description_;
        _socials = socials_;

        _mint(supplyRecipient_, supply_);
    }


    /**
     * @notice Records which accounts may receive the token while the guard is
     * in force. One call only, made by the contract that created this token,
     * inside the launch transaction.
     *
     * It is a separate call rather than a constructor argument so the CREATE2
     * address stays independent of the list: a vanity address can be mined
     * before the wallets are picked, and nobody can infer the list from it.
     */
    function initGuardList(address[] calldata list) external {
        if (msg.sender != creator) revert NotCreator();
        if (guardListSet) revert GuardListAlreadySet();
        guardListSet = true;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] != address(0)) guardAllowed[list[i]] = true;
        }
    }

    /// @notice True while transfers are still restricted to the guard list.
    function guardActive() external view returns (bool) {
        return guardEndsAt != 0 && block.timestamp < guardEndsAt;
    }

    /**
     * @notice Writes the wallet and transaction caps. One call only, made by
     * the contract that created this token, inside the launch transaction.
     * A zero cap means that cap is off; a zero `limitsSeconds` means the caps
     * never activate at all.
     *
     * Kept out of the constructor for the same reason as the guard list: the
     * CREATE2 address is mined before the creator has settled on terms, and
     * must not depend on them.
     */
    function initLimits(uint256 maxWallet_, uint256 maxTx_, uint64 limitsSeconds, address[] calldata exempt)
        external
    {
        if (msg.sender != creator) revert NotCreator();
        if (limitsSet) revert LimitsAlreadySet();
        if (limitsSeconds > MAX_LIMITS_SECONDS) revert LimitsWindowTooLong(limitsSeconds, MAX_LIMITS_SECONDS);
        limitsSet = true;
        if (limitsSeconds == 0 || (maxWallet_ == 0 && maxTx_ == 0)) return;
        maxWallet = maxWallet_;
        maxTx = maxTx_;
        limitsEndAt = uint64(block.timestamp) + limitsSeconds;
        launchBlock = uint64(block.number);
        for (uint256 i = 0; i < exempt.length; i++) {
            if (exempt[i] != address(0)) limitExempt[exempt[i]] = true;
        }
        // Caps are aimed at outsiders, not at the creator. The creator's
        // whitelist is spared for the first WHITELIST_BLOCKS blocks, long
        // enough for a person to get a transaction in; after that every one
        // of them is capped like any other wallet. The list is read from the factory now, while the
        // staged terms still exist, which spares the deployer contract bytecode.
        limitExempt[deployer] = true;
        if (launchFactory.code.length > 0) {
            address[] memory wl = IFactoryWhitelist(launchFactory).whitelistOf(deployer);
            for (uint256 i = 0; i < wl.length; i++) {
                launchWhitelisted[wl[i]] = true;
            }
        }
    }

    /**
     * @notice Points the token at its holder rewards distributor. One call
     * only, made by the contract that created this token. Passing zero means
     * the launch has no distributor.
     */
    function initDistributor(address distributor_) external {
        if (msg.sender != creator) revert NotCreator();
        if (distributorSet) revert LimitsAlreadySet();
        distributorSet = true;
        distributor = distributor_;
    }

    /// @dev Only the wallet that launched the token may edit its details.
    error NotTokenDeployer();

    event DetailsUpdated(string logo, string description);

    /**
     * @notice Lets the launching wallet update the logo, description and
     * social links after launch. Name, symbol and supply never change; these
     * three are presentation, and a project that moves its site or gets a
     * new logo should not have to live with the launch-day strings forever.
     */
    function updateDetails(string calldata logo_, string calldata description_, Socials calldata socials_) external {
        if (msg.sender != deployer) revert NotTokenDeployer();
        logo = logo_;
        description = description_;
        _socials = socials_;
        emit DetailsUpdated(logo_, description_);
    }

    /// @notice True while the wallet and transaction caps are in effect.
    function limitsActive() public view returns (bool) {
        return limitsEndAt != 0 && block.timestamp < limitsEndAt;
    }

    /**
     * @dev The guard: the one behaviour this override layers on a plain ERC-20.
     *
     * The check is on the recipient, not the sender. The point is to stop an
     * outsider from holding the token in the first block; if senders were
     * checked instead, the pool would need to be on the list, and a listed
     * pool could then deliver tokens to anyone.
     *
     * Mints always pass, otherwise the supply could never reach the position.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (guardEndsAt != 0 && block.timestamp < guardEndsAt && from != address(0) && !guardAllowed[to]) {
            revert LaunchGuardActive(to, guardEndsAt);
        }
        // V2 caps. Mints and burns are exempt, as is the plumbing: the pool
        // must be able to hold the entire supply and the routers must be able
        // to push any size through it. Only ordinary wallets are capped, and
        // only until `limitsEndAt`; after that this block never runs again.
        if (limitsEndAt != 0 && block.timestamp < limitsEndAt && from != address(0) && to != address(0)) {
            // The per-transaction cap applies as soon as an ordinary wallet is
            // on either end: a buy (pool to wallet), a sell (wallet to pool or
            // router) or a wallet-to-wallet transfer. Moves between two exempt
            // accounts, like the supply entering the position, are uncapped.
            bool window = block.number < uint256(launchBlock) + WHITELIST_BLOCKS;
            bool fromExempt = limitExempt[from] || (window && launchWhitelisted[from]);
            bool toExempt = limitExempt[to] || (window && launchWhitelisted[to]);
            if (!(fromExempt && toExempt)) {
                if (maxTx != 0 && value > maxTx) revert MaxTxExceeded(value, maxTx);
            }
            if (!toExempt && maxWallet != 0) {
                uint256 wouldHold = balanceOf(to) + value;
                if (wouldHold > maxWallet) revert MaxWalletExceeded(to, wouldHold, maxWallet);
            }
        }
        super._update(from, to, value);
        // Holder rewards: once balances settle, the distributor re-reads both
        // accounts. It is fusi.ng code deployed in the same launch transaction,
        // never user-supplied, so a direct call here is safe.
        if (distributor != address(0)) IFusingDistributorSink(distributor).onTransfer(from, to);
    }

    /**
     * @notice The five social links recorded for this launch.
     */
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /**
     * @notice Deployer address and launch metadata in the same tuple shape V1
     * exposed, so existing readers keep working.
     */
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }

    /**
     * @notice ERC-7572 contract metadata, built at call time from the fields
     * fixed at launch and returned as an inline JSON data URI. Trading
     * terminals and explorers that have never heard of fusi.ng pull the
     * token's image and links from this document, so it uses the keys they
     * search for: `image`, `description`, `external_url`, plus each social
     * under its own name, and the same set again under `extensions` for
     * readers that look there. Because no launch field can ever change, the
     * URI is constant and `ContractURIUpdated` is never emitted.
     */
    function contractURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice The `contractURI` document again, exposed under the name a few
     * readers query first, since some token standards publish their metadata
     * as `tokenURI`.
     */
    function tokenURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice There is no admin here: nobody owns, mints or pauses this
     * token. The getter is provided so that scanners probing for a renounced
     * owner see the zero address and report it as such.
     */
    function owner() external pure returns (address) {
        return address(0);
    }

    function _metadata() private view returns (string memory) {
        string memory links = _links();
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"',
            _jsonEscape(name()),
            '","symbol":"',
            _jsonEscape(symbol()),
            '","description":"',
            _jsonEscape(description),
            '","image":"',
            _jsonEscape(logo),
            '"',
            _field("external_url", _socials.website),
            _field("external_link", _socials.website),
            links,
            ',"extensions":{',
            bytes(links).length == 0 ? "" : _stripLeadingComma(links),
            "}}"
        );
    }

    function _links() private view returns (string memory) {
        return string.concat(
            _field("website", _socials.website),
            _field("twitter", _socials.twitter),
            _field("telegram", _socials.telegram),
            _field("discord", _socials.discord),
            _field("farcaster", _socials.farcaster)
        );
    }

    /// @dev Renders `,"key":"value"`; yields an empty string when the value is blank.
    function _field(string memory key, string memory value) private pure returns (string memory) {
        if (bytes(value).length == 0) return "";
        return string.concat(',"', key, '":"', _jsonEscape(value), '"');
    }

    function _stripLeadingComma(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; ++i) {
            out[i - 1] = b[i];
        }
        return string(out);
    }

    /**
     * @dev Makes `s` safe inside a JSON string literal by escaping quotes,
     * backslashes and control characters. The deployer caps metadata length,
     * so walking the bytes one at a time is affordable even for a long
     * description.
     */
    function _jsonEscape(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\" || c == "\n" || c == "\r" || c == "\t") extra += 1;
            else if (uint8(c) < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (c == "\n") {
                out[j++] = "\\";
                out[j++] = "n";
            } else if (c == "\r") {
                out[j++] = "\\";
                out[j++] = "r";
            } else if (c == "\t") {
                out[j++] = "\\";
                out[j++] = "t";
            } else if (uint8(c) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }
}
