// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IIdentity} from "./interfaces/IIdentity.sol";

contract ClaimIssuer {

    error ClaimIssuer__Unauthorized();
    error ClaimIssuer__ClaimAlreadyRevoked(bytes32 claimId);
    error ClaimIssuer__InvalidSignature();
    error ClaimIssuer__UnsupportedScheme(uint256 scheme);

    event ClaimRevoked(bytes32 indexed claimId);
    event ClaimUnrevoked(bytes32 indexed claimId);
    event SigningKeyAdded(address indexed key);
    event SigningKeyRemoved(address indexed key);

    address public owner;

    address public pendingOwner;

    mapping(bytes32 => bool) public revokedClaims;

    mapping(address => bool) public signingKeys;

    constructor(address _owner) {
        if (_owner == address(0)) revert ClaimIssuer__Unauthorized();
        owner = _owner;
        signingKeys[_owner] = true;
    }

    function isClaimValid(
        address identityAddr,
        bytes32 claimId
    ) external view returns (bool valid) {
        if (revokedClaims[claimId]) return false;

        try IIdentity(identityAddr).getClaim(claimId) returns (
            uint256,
            uint256 scheme,
            address issuer,
            bytes memory signature,
            bytes memory data,
            string memory
        ) {
            if (issuer != address(this)) return false;

            // Only ECDSA (scheme 1) is supported
            if (scheme != 1) return false;
            if (signature.length != 65) return false;

            bytes32 dataHash = keccak256(abi.encodePacked(identityAddr, claimId, data));
            bytes32 ethSignedHash = _toEthSignedMessageHash(dataHash);

            address signer = _recoverSigner(ethSignedHash, signature);
            if (signer == address(0)) return false;
            return signingKeys[signer];
        } catch {
            return false;
        }
    }

    function revokeClaim(bytes32 claimId) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        if (revokedClaims[claimId]) revert ClaimIssuer__ClaimAlreadyRevoked(claimId);

        revokedClaims[claimId] = true;
        emit ClaimRevoked(claimId);
    }

    function unrevokeClaim(bytes32 claimId) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();

        revokedClaims[claimId] = false;
        emit ClaimUnrevoked(claimId);
    }

    function addSigningKey(address key) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        signingKeys[key] = true;
        emit SigningKeyAdded(key);
    }

    function removeSigningKey(address key) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        signingKeys[key] = false;
        emit SigningKeyRemoved(key);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        if (newOwner == address(0)) revert ClaimIssuer__Unauthorized();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert ClaimIssuer__Unauthorized();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _recoverSigner(
        bytes32 hash,
        bytes memory signature
    ) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        if (v < 27) v += 27;

        // Reject v outside {27, 28}
        if (v != 27 && v != 28) return address(0);

        // Reject s in upper half to prevent signature malleability
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }

        return ecrecover(hash, v, r, s);
    }
}
