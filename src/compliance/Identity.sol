// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IIdentity} from "./interfaces/IIdentity.sol";

contract Identity is IIdentity {

    error Identity__Unauthorized();
    error Identity__ClaimNotFound(bytes32 claimId);
    error Identity__ClaimAlreadyExists(bytes32 claimId);

    event ClaimAdded(bytes32 indexed claimId, uint256 indexed topic, address indexed issuer);
    event ClaimRemoved(bytes32 indexed claimId, uint256 indexed topic, address indexed issuer);

    address public owner;

    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes signature;
        bytes data;
        string uri;
    }

    mapping(bytes32 => Claim) private _claims;

    mapping(uint256 => bytes32[]) private _claimsByTopic;

    mapping(bytes32 => bool) private _claimExists;

    constructor(address _owner) {
        if (_owner == address(0)) revert Identity__Unauthorized();
        owner = _owner;
    }

    function getClaimIdsByTopic(
        uint256 topic
    ) external view override returns (bytes32[] memory claimIds) {
        return _claimsByTopic[topic];
    }

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

    function addClaim(
        uint256 topic,
        uint256 scheme,
        address issuer,
        bytes calldata signature,
        bytes calldata data,
        string calldata uri
    ) external override returns (bytes32 claimId) {
        if (msg.sender != owner) {
            revert Identity__Unauthorized();
        }

        claimId = keccak256(abi.encodePacked(issuer, topic));

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

    function removeClaim(bytes32 claimId) external override returns (bool success) {
        if (!_claimExists[claimId]) revert Identity__ClaimNotFound(claimId);

        Claim storage claim = _claims[claimId];

        if (msg.sender != owner && msg.sender != claim.issuer) {
            revert Identity__Unauthorized();
        }

        uint256 topic = claim.topic;

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
