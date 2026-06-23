// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IComplianceModule
 * @notice Compliance rules engine for trading restrictions
 * @dev Implements geographic restrictions, transfer limits, trading hours, etc.
 */
interface IComplianceModule {
    // Events
    event ComplianceRuleAdded(address indexed token, string ruleName);
    event ComplianceRuleRemoved(address indexed token, string ruleName);
    event CountryAllowed(address indexed token, uint16 indexed country, bool allowed);
    event TransferLimitSet(address indexed token, uint256 dailyLimit, uint256 monthlyLimit);

    /**
     * @notice Check if an address is KYC verified
     * @param account The address to check
     * @return verified True if account has passed KYC
     */
    function isVerified(address account) external view returns (bool verified);

    /**
     * @notice Check if a transfer is compliant
     * @param token The token address
     * @param from The sender address
     * @param to The recipient address
     * @param amount The transfer amount
     * @return compliant True if transfer passes all compliance checks
     */
    function canTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) external view returns (bool compliant);

    /**
     * @notice Check if a country is allowed to trade a token
     * @param token The token address
     * @param country The ISO 3166-1 country code
     * @return allowed True if country is allowed
     */
    function isCountryAllowed(address token, uint16 country) external view returns (bool allowed);

    /**
     * @notice Set country allowance for a token
     * @param token The token address
     * @param country The country code
     * @param allowed Whether to allow or block
     */
    function setCountryAllowed(address token, uint16 country, bool allowed) external;

    /**
     * @notice Set transfer limits for a token
     * @param token The token address
     * @param dailyLimit Maximum amount per 24 hours (0 = no limit)
     * @param monthlyLimit Maximum amount per 30 days (0 = no limit)
     */
    function setTransferLimits(address token, uint256 dailyLimit, uint256 monthlyLimit) external;

    /**
     * @notice Get transfer limits for an address
     * @param token The token address
     * @param account The address to check
     * @return dailyRemaining Remaining daily transfer limit
     * @return monthlyRemaining Remaining monthly transfer limit
     */
    function getTransferLimits(address token, address account)
        external
        view
        returns (uint256 dailyRemaining, uint256 monthlyRemaining);

    /**
     * @notice Record a completed transfer for limit tracking (both sender and recipient)
     * @param token The token address
     * @param from The sender address
     * @param to The recipient address
     * @param amount The transfer amount
     */
    function recordTransfer(address token, address from, address to, uint256 amount) external;
}
