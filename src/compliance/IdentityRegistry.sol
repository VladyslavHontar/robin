// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IIdentity} from "./interfaces/IIdentity.sol";
import {ClaimIssuer} from "./ClaimIssuer.sol";

contract IdentityRegistry is IIdentityRegistry {

    error IdentityRegistry__Unauthorized();
    error IdentityRegistry__IdentityAlreadyExists(address wallet);
    error IdentityRegistry__IdentityNotFound(address wallet);
    error IdentityRegistry__InvalidAddress();
    error IdentityRegistry__IssuerAlreadyTrusted(address issuer);
    error IdentityRegistry__IssuerNotTrusted(address issuer);

    event TrustedIssuerAdded(address indexed issuer, uint256[] claimTopics);
    event TrustedIssuerRemoved(address indexed issuer);
    event AgentAdded(address indexed agent);
    event AgentRemoved(address indexed agent);

    address public owner;

    mapping(address => address) private _identities;

    mapping(address => uint16) private _countries;

    mapping(address => bool) private _agents;

    mapping(address => bool) private _trustedIssuers;

    mapping(address => mapping(uint256 => bool)) private _issuerTopics;

    address[] private _trustedIssuerList;

    uint256 public requiredClaimTopic = 1;

    address public pendingOwner;

    constructor(address _owner) {
        if (_owner == address(0)) revert IdentityRegistry__InvalidAddress();
        owner = _owner;
        _agents[_owner] = true;
    }

    function isVerified(address wallet) external view override returns (bool) {
        address identityAddr = _identities[wallet];
        if (identityAddr == address(0)) return false;

        return _hasValidClaim(identityAddr, requiredClaimTopic);
    }

    function identity(address wallet) external view override returns (address) {
        return _identities[wallet];
    }

    function investorCountry(address wallet) external view override returns (uint16) {
        return _countries[wallet];
    }

    function isAgent(address account) external view override returns (bool) {
        return _agents[account];
    }

    function isTrustedIssuer(address issuer) external view returns (bool) {
        return _trustedIssuers[issuer];
    }

    function getTrustedIssuers() external view returns (address[] memory) {
        return _trustedIssuerList;
    }

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

    function updateCountry(address wallet, uint16 country) external override onlyAgent {
        if (_identities[wallet] == address(0)) {
            revert IdentityRegistry__IdentityNotFound(wallet);
        }

        _countries[wallet] = country;

        emit CountryUpdated(wallet, country);
    }

    function deleteIdentity(address wallet) external override onlyAgent {
        if (_identities[wallet] == address(0)) {
            revert IdentityRegistry__IdentityNotFound(wallet);
        }

        address identityAddr = _identities[wallet];
        delete _identities[wallet];
        delete _countries[wallet];

        emit IdentityRemoved(wallet, identityAddr);
    }

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

    function removeTrustedIssuer(address issuer) external onlyOwner {
        if (!_trustedIssuers[issuer]) revert IdentityRegistry__IssuerNotTrusted(issuer);

        _trustedIssuers[issuer] = false;

        for (uint256 i = 0; i < _trustedIssuerList.length; i++) {
            if (_trustedIssuerList[i] == issuer) {
                _trustedIssuerList[i] = _trustedIssuerList[_trustedIssuerList.length - 1];
                _trustedIssuerList.pop();
                break;
            }
        }

        emit TrustedIssuerRemoved(issuer);
    }

    function addAgent(address agent) external onlyOwner {
        if (agent == address(0)) revert IdentityRegistry__InvalidAddress();
        _agents[agent] = true;
        emit AgentAdded(agent);
    }

    function removeAgent(address agent) external onlyOwner {
        _agents[agent] = false;
        emit AgentRemoved(agent);
    }

    function setRequiredClaimTopic(uint256 topic) external onlyOwner {
        requiredClaimTopic = topic;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert IdentityRegistry__InvalidAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert IdentityRegistry__Unauthorized();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function _hasValidClaim(
        address identityAddr,
        uint256 topic
    ) internal view returns (bool) {
        try IIdentity(identityAddr).getClaimIdsByTopic(topic) returns (
            bytes32[] memory claimIds
        ) {
            for (uint256 i = 0; i < claimIds.length; i++) {
                try IIdentity(identityAddr).getClaim(claimIds[i]) returns (
                    uint256,
                    uint256,
                    address issuer,
                    bytes memory,
                    bytes memory,
                    string memory
                ) {
                    if (_trustedIssuers[issuer] && _issuerTopics[issuer][topic]) {
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

    modifier onlyOwner() {
        if (msg.sender != owner) revert IdentityRegistry__Unauthorized();
        _;
    }

    modifier onlyAgent() {
        if (!_agents[msg.sender]) revert IdentityRegistry__Unauthorized();
        _;
    }
}
