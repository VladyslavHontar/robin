// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IIdentity} from "./interfaces/IIdentity.sol";

/**
 * @title Identity
 * @notice OnchainID identity contract (ERC-735 Claims)
 * @dev Each wallet gets one Identity contract that stores verifiable claims.
 *      Claims are added by trusted Claim Issuers (e.g., KYC providers).
 *
 * Claim Topics:
 *   1 = KYC (Know Your Customer)
 *   2 = AML (Anti-Money Laundering)
 *   3 = Accredited Investor
 *   4 = Qualified Purchaser
 */
contract Identity is IIdentity {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error Identity__Unauthorized();
    error Identity__ClaimNotFound(bytes32 claimId);
    error Identity__ClaimAlreadyExists(bytes32 claimId);

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ClaimAdded(bytes32 indexed claimId, uint256 indexed topic, address indexed issuer);
    event ClaimRemoved(bytes32 indexed claimId, uint256 indexed topic, address indexed issuer);

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Owner of this identity (the wallet this identity represents)
    address public owner;

    /// @notice Claim storage: claimId => Claim data
    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes signature;
        bytes data;
        string uri;
    }

    mapping(bytes32 => Claim) private _claims;

    /// @notice Topic to claim IDs mapping
    mapping(uint256 => bytes32[]) private _claimsByTopic;

    /// @notice Track which claim IDs exist (for deletion)
    mapping(bytes32 => bool) private _claimExists;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _owner) {
        if (_owner == address(0)) revert Identity__Unauthorized();
        owner = _owner;
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @inheritdoc IIdentity
    function getClaimIdsByTopic(
        uint256 topic
    ) external view override returns (bytes32[] memory claimIds) {
        return _claimsByTopic[topic];
    }

    /// @inheritdoc IIdentity
    function getClaim(
        bytes32 claimId
    )
        external
        view
        override
        returns (
            uint256 topic,
            uint256 scheme,
            address issuer,
            bytes memory signature,
            bytes memory data,
            string memory uri
        )
    {
        if (!_claimExists[claimId]) revert Identity__ClaimNotFound(claimId);

        Claim storage claim = _claims[claimId];
        return (
            claim.topic,
            claim.scheme,
            claim.issuer,
            claim.signature,
            claim.data,
            claim.uri
        );
    }

    // =============================================================
    //                    CLAIM MANAGEMENT
    // =============================================================

    /// @inheritdoc IIdentity
    function addClaim(
        uint256 topic,
        uint256 scheme,
        address issuer,
        bytes calldata signature,
        bytes calldata data,
        string calldata uri
    ) external override returns (bytes32 claimId) {
        // Only the identity owner or the claim issuer can add claims
        if (msg.sender != owner && msg.sender != issuer) {
            revert Identity__Unauthorized();
        }

        claimId = keccak256(abi.encodePacked(issuer, topic));

        // If claim already exists, update it (overwrite)
        if (_claimExists[claimId]) {
            _claims[claimId] = Claim({
                topic: topic,
                scheme: scheme,
                issuer: issuer,
                signature: signature,
                data: data,
                uri: uri
            });
        } else {
            _claims[claimId] = Claim({
                topic: topic,
                scheme: scheme,
                issuer: issuer,
                signature: signature,
                data: data,
                uri: uri
            });
            _claimsByTopic[topic].push(claimId);
            _claimExists[claimId] = true;
        }

        emit ClaimAdded(claimId, topic, issuer);
    }

    /// @inheritdoc IIdentity
    function removeClaim(bytes32 claimId) external override returns (bool success) {
        if (!_claimExists[claimId]) revert Identity__ClaimNotFound(claimId);

        Claim storage claim = _claims[claimId];

        // Only owner or the original issuer can remove
        if (msg.sender != owner && msg.sender != claim.issuer) {
            revert Identity__Unauthorized();
        }

        uint256 topic = claim.topic;

        // Remove from topic array
        bytes32[] storage topicClaims = _claimsByTopic[topic];
        for (uint256 i = 0; i < topicClaims.length; i++) {
            if (topicClaims[i] == claimId) {
                topicClaims[i] = topicClaims[topicClaims.length - 1];
                topicClaims.pop();
                break;
            }
        }

        emit ClaimRemoved(claimId, topic, claim.issuer);

        delete _claims[claimId];
        _claimExists[claimId] = false;

        return true;
    }
}
