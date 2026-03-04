// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IIdentity
 * @notice Interface for OnchainID Identity contracts (ERC-735/ERC-734)
 * @dev Based on T-REX/ERC-3643 standard for tokenized securities
 */
interface IIdentity {
    /**
     * @notice Get claim IDs by topic
     * @param topic The claim topic to query
     * @return claimIds Array of claim IDs with this topic
     */
    function getClaimIdsByTopic(uint256 topic) external view returns (bytes32[] memory claimIds);

    /**
     * @notice Get claim by ID
     * @param claimId The claim ID
     * @return topic Claim topic
     * @return scheme Signature scheme used
     * @return issuer Claim issuer address
     * @return signature Claim signature
     * @return data Claim data
     * @return uri Optional URI for additional data
     */
    function getClaim(bytes32 claimId)
        external
        view
        returns (
            uint256 topic,
            uint256 scheme,
            address issuer,
            bytes memory signature,
            bytes memory data,
            string memory uri
        );

    /**
     * @notice Add a new claim
     * @param topic Claim topic
     * @param scheme Signature scheme (1 = ECDSA)
     * @param issuer Claim issuer address
     * @param signature Claim signature
     * @param data Claim data
     * @param uri Optional URI
     * @return claimId The ID of the added claim
     */
    function addClaim(
        uint256 topic,
        uint256 scheme,
        address issuer,
        bytes calldata signature,
        bytes calldata data,
        string calldata uri
    ) external returns (bytes32 claimId);

    /**
     * @notice Remove a claim
     * @param claimId The claim ID to remove
     * @return success Whether removal was successful
     */
    function removeClaim(bytes32 claimId) external returns (bool success);
}
