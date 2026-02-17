// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IIdentity} from "./interfaces/IIdentity.sol";
import {ClaimIssuer} from "./ClaimIssuer.sol";

/**
 * @title IdentityRegistry
 * @notice Central registry mapping wallet addresses to Identity contracts
 * @dev Part of ERC-3643 / T-REX compliance stack.
 *
 * The registry:
 * - Maps wallets to their Identity contracts
 * - Tracks investor country codes (ISO 3166-1)
 * - Manages trusted claim issuers per claim topic
 * - Provides isVerified() as the single entry point for compliance checks
 *
 * Verification logic:
 *   isVerified(wallet) = wallet has Identity
 *                        AND Identity has KYC claim (topic 1)
 *                        AND KYC claim is from a trusted issuer
 *                        AND claim is not revoked
 */
contract IdentityRegistry is IIdentityRegistry {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error IdentityRegistry__Unauthorized();
    error IdentityRegistry__IdentityAlreadyExists(address wallet);
    error IdentityRegistry__IdentityNotFound(address wallet);
    error IdentityRegistry__InvalidAddress();
    error IdentityRegistry__IssuerAlreadyTrusted(address issuer);
    error IdentityRegistry__IssuerNotTrusted(address issuer);

    // =============================================================
    //                          EVENTS
    // =============================================================

    event TrustedIssuerAdded(address indexed issuer, uint256[] claimTopics);
    event TrustedIssuerRemoved(address indexed issuer);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Registry owner
    address public owner;

    /// @notice Wallet => Identity contract address
    mapping(address => address) private _identities;

    /// @notice Wallet => ISO 3166-1 country code
    mapping(address => uint16) private _countries;

    /// @notice Agents who can manage identities
    mapping(address => bool) private _agents;

    /// @notice Trusted claim issuers
    mapping(address => bool) private _trustedIssuers;

    /// @notice Trusted issuer => authorized claim topics
    mapping(address => mapping(uint256 => bool)) private _issuerTopics;

    /// @notice List of trusted issuers (for enumeration)
    address[] private _trustedIssuerList;

    /// @notice Required claim topic for verification (default: 1 = KYC)
    uint256 public requiredClaimTopic = 1;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _owner) {
        if (_owner == address(0)) revert IdentityRegistry__InvalidAddress();
        owner = _owner;
        _agents[_owner] = true;
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @inheritdoc IIdentityRegistry
    function isVerified(address wallet) external view override returns (bool) {
        address identityAddr = _identities[wallet];
        if (identityAddr == address(0)) return false;

        // Check if identity has a valid KYC claim from a trusted issuer
        return _hasValidClaim(identityAddr, requiredClaimTopic);
    }

    /// @inheritdoc IIdentityRegistry
    function identity(address wallet) external view override returns (address) {
        return _identities[wallet];
    }

    /// @inheritdoc IIdentityRegistry
    function investorCountry(address wallet) external view override returns (uint16) {
        return _countries[wallet];
    }

    /// @inheritdoc IIdentityRegistry
    function isAgent(address account) external view override returns (bool) {
        return _agents[account];
    }

    /**
     * @notice Check if an address is a trusted claim issuer
     * @param issuer Address to check
     * @return True if trusted
     */
    function isTrustedIssuer(address issuer) external view returns (bool) {
        return _trustedIssuers[issuer];
    }

    /**
     * @notice Get all trusted issuers
     * @return Array of trusted issuer addresses
     */
    function getTrustedIssuers() external view returns (address[] memory) {
        return _trustedIssuerList;
    }

    // =============================================================
    //                  IDENTITY MANAGEMENT (Agents)
    // =============================================================

    /// @inheritdoc IIdentityRegistry
    function registerIdentity(
        address wallet,
        address identityAddress,
        uint16 country
    ) external override onlyAgent {
        if (wallet == address(0) || identityAddress == address(0)) {
            revert IdentityRegistry__InvalidAddress();
        }
        if (_identities[wallet] != address(0)) {
            revert IdentityRegistry__IdentityAlreadyExists(wallet);
        }

        _identities[wallet] = identityAddress;
        _countries[wallet] = country;

        emit IdentityRegistered(wallet, identityAddress, country);
    }

    /// @inheritdoc IIdentityRegistry
    function updateIdentity(
        address wallet,
        address identityAddress
    ) external override onlyAgent {
        if (_identities[wallet] == address(0)) {
            revert IdentityRegistry__IdentityNotFound(wallet);
        }
        if (identityAddress == address(0)) {
            revert IdentityRegistry__InvalidAddress();
        }

        address oldIdentity = _identities[wallet];
        _identities[wallet] = identityAddress;

        emit IdentityUpdated(wallet, oldIdentity, identityAddress);
    }

    /// @inheritdoc IIdentityRegistry
    function updateCountry(address wallet, uint16 country) external override onlyAgent {
        if (_identities[wallet] == address(0)) {
            revert IdentityRegistry__IdentityNotFound(wallet);
        }

        _countries[wallet] = country;

        emit CountryUpdated(wallet, country);
    }

    /// @inheritdoc IIdentityRegistry
    function deleteIdentity(address wallet) external override onlyAgent {
        if (_identities[wallet] == address(0)) {
            revert IdentityRegistry__IdentityNotFound(wallet);
        }

        address identityAddr = _identities[wallet];
        delete _identities[wallet];
        delete _countries[wallet];

        emit IdentityRemoved(wallet, identityAddr);
    }

    // =============================================================
    //                  ADMIN FUNCTIONS (Owner)
    // =============================================================

    /**
     * @notice Add a trusted claim issuer
     * @param issuer ClaimIssuer contract address
     * @param claimTopics Topics this issuer is trusted for
     */
    function addTrustedIssuer(
        address issuer,
        uint256[] calldata claimTopics
    ) external onlyOwner {
        if (issuer == address(0)) revert IdentityRegistry__InvalidAddress();
        if (_trustedIssuers[issuer]) revert IdentityRegistry__IssuerAlreadyTrusted(issuer);

        _trustedIssuers[issuer] = true;
        _trustedIssuerList.push(issuer);

        for (uint256 i = 0; i < claimTopics.length; i++) {
            _issuerTopics[issuer][claimTopics[i]] = true;
        }

        emit TrustedIssuerAdded(issuer, claimTopics);
    }

    /**
     * @notice Remove a trusted claim issuer
     * @param issuer ClaimIssuer contract address
     */
    function removeTrustedIssuer(address issuer) external onlyOwner {
        if (!_trustedIssuers[issuer]) revert IdentityRegistry__IssuerNotTrusted(issuer);

        _trustedIssuers[issuer] = false;

        // Remove from list
        for (uint256 i = 0; i < _trustedIssuerList.length; i++) {
            if (_trustedIssuerList[i] == issuer) {
                _trustedIssuerList[i] = _trustedIssuerList[_trustedIssuerList.length - 1];
                _trustedIssuerList.pop();
                break;
            }
        }

        emit TrustedIssuerRemoved(issuer);
    }

    /**
     * @notice Add an agent
     * @param agent Agent address
     */
    function addAgent(address agent) external onlyOwner {
        if (agent == address(0)) revert IdentityRegistry__InvalidAddress();
        _agents[agent] = true;
        emit AgentAdded(agent);
    }

    /**
     * @notice Remove an agent
     * @param agent Agent address
     */
    function removeAgent(address agent) external onlyOwner {
        _agents[agent] = false;
        emit AgentRemoved(agent);
    }

    /**
     * @notice Set the required claim topic for verification
     * @param topic Claim topic number (1=KYC, 2=AML, etc.)
     */
    function setRequiredClaimTopic(uint256 topic) external onlyOwner {
        requiredClaimTopic = topic;
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert IdentityRegistry__InvalidAddress();
        owner = newOwner;
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Check if an identity has a valid claim for a given topic
     * @param identityAddr Identity contract address
     * @param topic Claim topic to check
     * @return True if a valid, non-revoked claim exists from a trusted issuer
     */
    function _hasValidClaim(
        address identityAddr,
        uint256 topic
    ) internal view returns (bool) {
        // Get all claim IDs for this topic
        try IIdentity(identityAddr).getClaimIdsByTopic(topic) returns (
            bytes32[] memory claimIds
        ) {
            for (uint256 i = 0; i < claimIds.length; i++) {
                // Get the claim details
                try IIdentity(identityAddr).getClaim(claimIds[i]) returns (
                    uint256, // claimTopic
                    uint256, // scheme
                    address issuer,
                    bytes memory, // signature
                    bytes memory, // data
                    string memory // uri
                ) {
                    // Check if issuer is trusted for this topic
                    if (_trustedIssuers[issuer] && _issuerTopics[issuer][topic]) {
                        // Check if claim is not revoked
                        try ClaimIssuer(issuer).isClaimValid(identityAddr, claimIds[i]) returns (
                            bool valid
                        ) {
                            if (valid) return true;
                        } catch {
                            continue;
                        }
                    }
                } catch {
                    continue;
                }
            }
        } catch {
            return false;
        }

        return false;
    }

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert IdentityRegistry__Unauthorized();
        _;
    }

    modifier onlyAgent() {
        if (!_agents[msg.sender]) revert IdentityRegistry__Unauthorized();
        _;
    }
}
