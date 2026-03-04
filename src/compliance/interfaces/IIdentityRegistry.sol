// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IIdentityRegistry
 * @notice Registry mapping wallet addresses to their Identity contracts
 * @dev Central registry for KYC/compliance verification
 */
interface IIdentityRegistry {
    // Events
    event IdentityRegistered(address indexed wallet, address indexed identity, uint16 indexed country);
    event IdentityRemoved(address indexed wallet, address indexed identity);
    event IdentityUpdated(address indexed wallet, address indexed oldIdentity, address indexed newIdentity);
    event CountryUpdated(address indexed wallet, uint16 indexed country);

    /**
     * @notice Check if an address has passed verification
     * @param wallet The wallet address to check
     * @return verified True if wallet is verified (has valid claims)
     */
    function isVerified(address wallet) external view returns (bool verified);

    /**
     * @notice Get the Identity contract for a wallet
     * @param wallet The wallet address
     * @return identity The Identity contract address (address(0) if not registered)
     */
    function identity(address wallet) external view returns (address identity);

    /**
     * @notice Get the country code for an investor
     * @param wallet The wallet address
     * @return country The ISO 3166-1 numeric country code
     */
    function investorCountry(address wallet) external view returns (uint16 country);

    /**
     * @notice Register a new identity
     * @param wallet The wallet address
     * @param identityAddress The Identity contract address
     * @param country The ISO 3166-1 numeric country code
     */
    function registerIdentity(address wallet, address identityAddress, uint16 country) external;

    /**
     * @notice Update an existing identity
     * @param wallet The wallet address
     * @param identityAddress The new Identity contract address
     */
    function updateIdentity(address wallet, address identityAddress) external;

    /**
     * @notice Update country for an investor
     * @param wallet The wallet address
     * @param country The new country code
     */
    function updateCountry(address wallet, uint16 country) external;

    /**
     * @notice Remove an identity (revoke KYC)
     * @param wallet The wallet address
     */
    function deleteIdentity(address wallet) external;

    /**
     * @notice Check if an address is an agent (can manage identities)
     * @param account The address to check
     * @return isAgent True if account is an agent
     */
    function isAgent(address account) external view returns (bool isAgent);
}
