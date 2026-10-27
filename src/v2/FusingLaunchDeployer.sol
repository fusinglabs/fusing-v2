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

import {FusingLauncherToken} from "./FusingLauncherToken.sol";
import {FusingHolderDistributor} from "./FusingHolderDistributor.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";

/**
 * @notice Everything FusingLaunchFactory passes to the deployer to bring
 * up a single launch token.
 */
struct LaunchDeployment {
    address originalDeployer;
    address supplyRecipient;
    uint256 supply;
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    FusingLauncherToken.Socials socials;
}

/**
 * @title FusingLaunchDeployer
 * @notice Creates the launch token for a fusi.ng launch when the factory
 * asks. It is a separate contract for one reason: keeping the factory's
 * deployed bytecode under EIP-170's 24576-byte cap. Embedding the token's
 * creation code with `new` is the largest single item in the factory's
 * size. The token still stores the true factory address, never this one.
 */
/**
 * @dev What this contract reads back from the factory: the guard a
 * launcher staged for their next launch.
 *
 * It is read here instead of passed through the launch call because adding
 * it there pushed the factory over the compiler's stack limit. Reading it
 * keeps the launch path byte for byte what it was.
 */
interface IGuardConfig {
    function guardSecondsOf(address launcher) external view returns (uint64);
    function guardListOf(address launcher) external view returns (address[] memory);
    // V2 additions: the launcher's staged terms, and the plumbing the token caps must skip.
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory);
    function limitExemptions() external view returns (address[] memory);
}

contract FusingLaunchDeployer {
    // The token stores this metadata and serves it back through view
    // functions with unbounded return sizes, so an oversized write here
    // would make the token permanently unreadable: `socials()` hands back
    // all five strings together and could exhaust gas or time out an RPC
    // node. The strings are immutable once written, so bounding the write
    // is the only place a limit can live.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /// @dev The holder distributor every launch that opts in gets a clone of. Its initialiser is this deployer.
    address public distributorImplementation;

    error DistributorNotWired();
    error DistributorAlreadyWired();
    error NotFactoryOwner();

    /**
     * @notice Wires the distributor implementation, once, by the factory
     * owner. Set after construction because the implementation's constructor
     * needs this deployer's address and this deployer needs the
     * implementation's: one of the two has to come second.
     */
    function setDistributorImplementation(address implementation) external {
        // The account that deployed this contract, or the factory's owner: the
        // deploy script is both, a test stack is only the first.
        if (msg.sender != installer && msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        if (distributorImplementation != address(0)) revert DistributorAlreadyWired();
        if (implementation == address(0)) revert DistributorNotWired();
        distributorImplementation = implementation;
    }

    /// @dev The account that deployed this contract, allowed to wire the distributor implementation once.
    address public immutable installer;

    constructor(address factory_) {
        installer = msg.sender;
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Creates a new launch token and hands back its address.
     */
    function deployToken(LaunchDeployment calldata params) external onlyFactory returns (address token) {
        _requireMetadataWithinLimits(params);

        // CREATE2 with the salt scoped to the initiating account: a caller's
        // salt needs to be unique only across their own launches, and the
        // address can be predicted (or vanity-mined) before sending. Reusing
        // a salt with identical inputs reverts on the address collision.
        bytes32 tokenSalt = keccak256(abi.encode(params.originalDeployer, params.salt));
        token = address(
            new FusingLauncherToken{salt: tokenSalt}(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                factory,
                params.supplyRecipient,
                params.supply,
                IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
            )
        );

        // Register the allowed receivers while the token will still take the list.
        address[] memory list = IGuardConfig(factory).guardListOf(params.originalDeployer);
        if (list.length > 0 && IGuardConfig(factory).guardSecondsOf(params.originalDeployer) > 0) {
            FusingLauncherToken(token).initGuardList(list);
        }

        _applyTerms(token, params.originalDeployer, params.supplyRecipient);
    }

    /// @notice The holder rewards distributor deployed for `token`, or zero if it has none.
    mapping(address token => address) public distributorOf;

    /**
     * @dev V2 token-side terms. Limits are initialised on every launch (so
     * the write-once slot is used up inside the launch transaction and can
     * never be set afterwards), and if the plan names a HOLDERS payee the
     * distributor is created here and bound to the token before any
     * transfer has taken place.
     */
    function _applyTerms(address token, address launcher, address supplyRecipient) private {
        FusingTerms.LaunchTerms memory terms = IGuardConfig(factory).termsOf(launcher);
        // Turn the creator's caps, given as shares of supply, into amounts; the factory has already range-checked them.
        uint256 supply = FusingLauncherToken(token).totalSupply();
        uint256 maxWallet = supply * terms.maxWalletBps / 10_000;
        uint256 maxTx = supply * terms.maxTxBps / 10_000;
        uint64 limitsSeconds = (maxWallet != 0 || maxTx != 0) ? uint64(terms.limitsSeconds) : 0;
        // The caps are meant for the open market: on a whitelisted launch they start counting when the window ends.
        if (limitsSeconds != 0) limitsSeconds += IGuardConfig(factory).guardSecondsOf(launcher);
        address[] memory plumbing = IGuardConfig(factory).limitExemptions();
        // The plumbing, the supply recipient and the burn address are not
        // wallets the caps are aimed at, and none of them should collect
        // holder rewards.
        address[] memory exempt = new address[](plumbing.length + 2);
        for (uint256 i = 0; i < plumbing.length; i++) {
            exempt[i] = plumbing[i];
        }
        exempt[plumbing.length] = supplyRecipient;
        exempt[plumbing.length + 1] = 0x000000000000000000000000000000000000dEaD;
        FusingLauncherToken(token).initLimits(maxWallet, maxTx, limitsSeconds, exempt);

        bool holders;
        for (uint256 i = 0; i < terms.payees.length; i++) {
            if (terms.payees[i].kind == FusingTerms.PayeeKind.HOLDERS) holders = true;
        }
        if (holders) {
            // A minimal proxy of one implementation rather than a fresh
            // contract: embedding the distributor's creation code here pushed
            // this deployer past the bytecode limit once the token grew.
            if (distributorImplementation == address(0)) revert DistributorNotWired();
            FusingHolderDistributor d = FusingHolderDistributor(_clone(distributorImplementation));
            d.initialise(token, terms.minHolding, exempt);
            FusingLauncherToken(token).initDistributor(address(d));
            distributorOf[token] = address(d);
        } else {
            FusingLauncherToken(token).initDistributor(address(0));
        }
    }

    /// @dev An EIP-1167 minimal proxy of `implementation`: 45 bytes of runtime that delegate every call to it.
    function _clone(address implementation) private returns (address instance) {
        bytes20 target = bytes20(implementation);
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), target)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert DistributorNotWired();
    }

    /**
     * @notice The address `deployToken` will produce for these inputs, so a
     * token's address is known before its launch transaction is sent.
     */
    function predictTokenAddress(LaunchDeployment calldata params) external view returns (address) {
        bytes32 tokenSalt = keccak256(abi.encode(params.originalDeployer, params.salt));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), tokenSalt, _initCodeHash(params)))))
        );
    }

    /**
     * @dev Separated out and given a memory argument because ABI-encoding
     * eleven constructor arguments directly from calldata exhausts the Yul
     * optimizer's stack. The copy to memory costs a little gas on a view
     * call and keeps the encoding in a single place, which is what counts:
     * this hash and the one CREATE2 computes in `deployToken` must match
     * exactly, or a mined address ends up somewhere else.
     */
    function _initCodeHash(LaunchDeployment memory params) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(FusingLauncherToken).creationCode,
                abi.encode(
                    params.name,
                    params.symbol,
                    params.logo,
                    params.description,
                    params.socials,
                    params.originalDeployer,
                    factory,
                    params.supplyRecipient,
                    params.supply,
                    IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
                )
            )
        );
    }

    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
