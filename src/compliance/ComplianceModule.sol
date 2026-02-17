// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/**
 * @title ComplianceModule
 * @notice Rules engine for trading compliance on Robin DEX
 * @dev Called by LBPair before every swap/mint/burn to enforce:
 *      1. KYC verification (via IdentityRegistry)
 *      2. Country restrictions (geographic blocking)
 *      3. Transfer limits (daily/monthly caps)
 *
 * The compliance module is the single gateway that LBPair calls.
 * It delegates identity checks to the IdentityRegistry.
 */
contract ComplianceModule is IComplianceModule {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error ComplianceModule__Unauthorized();
    error ComplianceModule__InvalidAddress();
    error ComplianceModule__NotVerified(address account);
    error ComplianceModule__CountryBlocked(address account, uint16 country);
    error ComplianceModule__TransferLimitExceeded(address account, uint256 amount, uint256 remaining);

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Owner (factory or admin)
    address public owner;

    /// @notice Identity registry for KYC checks
    IIdentityRegistry public identityRegistry;

    /// @notice Country restrictions: token => country => allowed
    mapping(address => mapping(uint16 => bool)) private _countryAllowed;

    /// @notice Whether country restrictions are enabled for a token
    mapping(address => bool) public countryRestrictionsEnabled;

    /// @notice Transfer limits per token
    struct TransferLimit {
        uint256 dailyLimit;    // Max per 24h (0 = unlimited)
        uint256 monthlyLimit;  // Max per 30d (0 = unlimited)
    }
    mapping(address => TransferLimit) private _transferLimits;

    /// @notice Transfer tracking: token => account => day => amount
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _dailyTransfers;

    /// @notice Transfer tracking: token => account => month => amount
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _monthlyTransfers;

    /// @notice Whitelisted addresses (exempt from compliance, e.g., pairs, router)
    mapping(address => bool) public whitelisted;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _owner, address _identityRegistry) {
        if (_owner == address(0) || _identityRegistry == address(0)) {
            revert ComplianceModule__InvalidAddress();
        }
        owner = _owner;
        identityRegistry = IIdentityRegistry(_identityRegistry);
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @inheritdoc IComplianceModule
    function isVerified(address account) external view override returns (bool) {
        if (whitelisted[account]) return true;
        return identityRegistry.isVerified(account);
    }

    /// @inheritdoc IComplianceModule
    function canTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) external view override returns (bool) {
        // Whitelisted addresses bypass all checks (pairs, router, etc.)
        bool fromWhitelisted = whitelisted[from] || from == address(0);
        bool toWhitelisted = whitelisted[to] || to == address(0);

        // Check KYC for non-whitelisted addresses
        if (!fromWhitelisted && !identityRegistry.isVerified(from)) {
            return false;
        }
        if (!toWhitelisted && !identityRegistry.isVerified(to)) {
            return false;
        }

        // Check country restrictions
        if (countryRestrictionsEnabled[token]) {
            if (!fromWhitelisted) {
                uint16 fromCountry = identityRegistry.investorCountry(from);
                if (fromCountry != 0 && !_countryAllowed[token][fromCountry]) {
                    return false;
                }
            }
            if (!toWhitelisted) {
                uint16 toCountry = identityRegistry.investorCountry(to);
                if (toCountry != 0 && !_countryAllowed[token][toCountry]) {
                    return false;
                }
            }
        }

        // Check transfer limits for sender
        if (!fromWhitelisted && amount > 0) {
            TransferLimit storage limits = _transferLimits[token];

            if (limits.dailyLimit > 0) {
                uint256 today = block.timestamp / 1 days;
                uint256 dailyUsed = _dailyTransfers[token][from][today];
                if (dailyUsed + amount > limits.dailyLimit) {
                    return false;
                }
            }

            if (limits.monthlyLimit > 0) {
                uint256 thisMonth = block.timestamp / 30 days;
                uint256 monthlyUsed = _monthlyTransfers[token][from][thisMonth];
                if (monthlyUsed + amount > limits.monthlyLimit) {
                    return false;
                }
            }
        }

        return true;
    }

    /// @inheritdoc IComplianceModule
    function isCountryAllowed(
        address token,
        uint16 country
    ) external view override returns (bool) {
        if (!countryRestrictionsEnabled[token]) return true;
        return _countryAllowed[token][country];
    }

    /// @inheritdoc IComplianceModule
    function getTransferLimits(
        address token,
        address account
    ) external view override returns (uint256 dailyRemaining, uint256 monthlyRemaining) {
        TransferLimit storage limits = _transferLimits[token];

        if (limits.dailyLimit == 0) {
            dailyRemaining = type(uint256).max;
        } else {
            uint256 today = block.timestamp / 1 days;
            uint256 used = _dailyTransfers[token][account][today];
            dailyRemaining = limits.dailyLimit > used ? limits.dailyLimit - used : 0;
        }

        if (limits.monthlyLimit == 0) {
            monthlyRemaining = type(uint256).max;
        } else {
            uint256 thisMonth = block.timestamp / 30 days;
            uint256 used = _monthlyTransfers[token][account][thisMonth];
            monthlyRemaining = limits.monthlyLimit > used ? limits.monthlyLimit - used : 0;
        }
    }

    // =============================================================
    //                  TRANSFER RECORDING
    // =============================================================

    /**
     * @notice Record a transfer for limit tracking
     * @dev Called by LBPair after a successful transfer
     * @param token Token address
     * @param from Sender
     * @param amount Amount transferred
     */
    function recordTransfer(address token, address from, uint256 amount) external {
        if (!whitelisted[msg.sender]) revert ComplianceModule__Unauthorized();

        if (whitelisted[from] || from == address(0)) return;

        uint256 today = block.timestamp / 1 days;
        uint256 thisMonth = block.timestamp / 30 days;

        _dailyTransfers[token][from][today] += amount;
        _monthlyTransfers[token][from][thisMonth] += amount;
    }

    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    /// @inheritdoc IComplianceModule
    function setCountryAllowed(
        address token,
        uint16 country,
        bool allowed
    ) external override onlyOwner {
        _countryAllowed[token][country] = allowed;
        emit CountryAllowed(token, country, allowed);
    }

    /**
     * @notice Enable/disable country restrictions for a token
     * @param token Token address
     * @param enabled Whether to enable restrictions
     */
    function setCountryRestrictionsEnabled(
        address token,
        bool enabled
    ) external onlyOwner {
        countryRestrictionsEnabled[token] = enabled;
    }

    /**
     * @notice Batch set country allowances
     * @param token Token address
     * @param countries Array of country codes
     * @param allowed Array of allowed flags
     */
    function batchSetCountryAllowed(
        address token,
        uint16[] calldata countries,
        bool[] calldata allowed
    ) external onlyOwner {
        for (uint256 i = 0; i < countries.length; i++) {
            _countryAllowed[token][countries[i]] = allowed[i];
            emit CountryAllowed(token, countries[i], allowed[i]);
        }
    }

    /// @inheritdoc IComplianceModule
    function setTransferLimits(
        address token,
        uint256 dailyLimit,
        uint256 monthlyLimit
    ) external override onlyOwner {
        _transferLimits[token] = TransferLimit({
            dailyLimit: dailyLimit,
            monthlyLimit: monthlyLimit
        });
        emit TransferLimitSet(token, dailyLimit, monthlyLimit);
    }

    /**
     * @notice Whitelist an address (exempt from compliance)
     * @param account Address to whitelist (e.g., LBPair, Router)
     * @param status True to whitelist, false to remove
     */
    function setWhitelisted(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
    }

    /**
     * @notice Update the identity registry
     * @param _identityRegistry New registry address
     */
    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert ComplianceModule__InvalidAddress();
        identityRegistry = IIdentityRegistry(_identityRegistry);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ComplianceModule__InvalidAddress();
        owner = newOwner;
    }

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert ComplianceModule__Unauthorized();
        _;
    }
}
