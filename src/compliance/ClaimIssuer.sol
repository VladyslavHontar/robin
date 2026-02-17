// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IIdentity} from "./interfaces/IIdentity.sol";

/**
 * @title ClaimIssuer
 * @notice Trusted entity that issues and validates identity claims
 * @dev KYC providers deploy this contract. They sign claims off-chain,
 *      then add them to user Identity contracts. The ClaimIssuer can
 *      also revoke claims when KYC expires or is invalidated.
 *
 * Verification flow:
 * 1. KYC provider verifies user off-chain
 * 2. Provider signs claim data with their key
 * 3. Claim is added to user's Identity contract
 * 4. IdentityRegistry checks claim validity via this contract
 */
contract ClaimIssuer {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error ClaimIssuer__Unauthorized();
    error ClaimIssuer__ClaimAlreadyRevoked(bytes32 claimId);
    error ClaimIssuer__InvalidSignature();

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ClaimRevoked(bytes32 indexed claimId);
    event ClaimUnrevoked(bytes32 indexed claimId);
    event SigningKeyAdded(address indexed key);
    event SigningKeyRemoved(address indexed key);

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Owner of this claim issuer (KYC provider)
    address public owner;

    /// @notice Revoked claims: claimId => revoked
    mapping(bytes32 => bool) public revokedClaims;

    /// @notice Authorized signing keys (can sign claims on behalf of issuer)
    mapping(address => bool) public signingKeys;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _owner) {
        if (_owner == address(0)) revert ClaimIssuer__Unauthorized();
        owner = _owner;
        signingKeys[_owner] = true;
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Check if a claim on an Identity contract is valid
     * @param identityAddr The Identity contract address
     * @param claimId The claim ID to validate
     * @return valid True if claim exists, is from this issuer, has valid signature, and not revoked
     */
    function isClaimValid(
        address identityAddr,
        bytes32 claimId
    ) external view returns (bool valid) {
        // Check if revoked first (cheapest check)
        if (revokedClaims[claimId]) return false;

        // Get claim from identity
        try IIdentity(identityAddr).getClaim(claimId) returns (
            uint256, // topic
            uint256 scheme,
            address issuer,
            bytes memory signature,
            bytes memory data,
            string memory // uri
        ) {
            // Must be issued by this contract
            if (issuer != address(this)) return false;

            // Validate signature (scheme 1 = ECDSA)
            if (scheme == 1 && signature.length == 65) {
                // Reconstruct the signed message
                bytes32 dataHash = keccak256(abi.encodePacked(identityAddr, claimId, data));
                bytes32 ethSignedHash = _toEthSignedMessageHash(dataHash);

                address signer = _recoverSigner(ethSignedHash, signature);
                return signingKeys[signer];
            }

            // Scheme 0 = no signature verification (trust-based)
            if (scheme == 0) return true;

            return false;
        } catch {
            return false;
        }
    }

    // =============================================================
    //                    CLAIM MANAGEMENT
    // =============================================================

    /**
     * @notice Revoke a claim (makes it invalid)
     * @param claimId The claim ID to revoke
     */
    function revokeClaim(bytes32 claimId) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        if (revokedClaims[claimId]) revert ClaimIssuer__ClaimAlreadyRevoked(claimId);

        revokedClaims[claimId] = true;
        emit ClaimRevoked(claimId);
    }

    /**
     * @notice Un-revoke a claim (re-enable it)
     * @param claimId The claim ID to un-revoke
     */
    function unrevokeClaim(bytes32 claimId) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();

        revokedClaims[claimId] = false;
        emit ClaimUnrevoked(claimId);
    }

    // =============================================================
    //                    KEY MANAGEMENT
    // =============================================================

    /**
     * @notice Add a signing key
     * @param key Address authorized to sign claims
     */
    function addSigningKey(address key) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        signingKeys[key] = true;
        emit SigningKeyAdded(key);
    }

    /**
     * @notice Remove a signing key
     * @param key Address to deauthorize
     */
    function removeSigningKey(address key) external {
        if (msg.sender != owner) revert ClaimIssuer__Unauthorized();
        signingKeys[key] = false;
        emit SigningKeyRemoved(key);
    }

    // =============================================================
    //                    INTERNAL HELPERS
    // =============================================================

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

        return ecrecover(hash, v, r, s);
    }
}
