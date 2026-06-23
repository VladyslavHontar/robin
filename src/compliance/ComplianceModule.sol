// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

contract ComplianceModule is IComplianceModule {

    error ComplianceModule__Unauthorized();
    error ComplianceModule__InvalidAddress();
    error ComplianceModule__NotVerified(address account);
    error ComplianceModule__CountryBlocked(address account, uint16 country);
    error ComplianceModule__TransferLimitExceeded(address account, uint256 amount, uint256 remaining);
    error ComplianceModule__ArrayLengthMismatch();

    address public owner;

    IIdentityRegistry public identityRegistry;

    mapping(address => mapping(uint16 => bool)) private _countryAllowed;

    mapping(address => bool) public countryRestrictionsEnabled;

    struct TransferLimit {
        uint256 dailyLimit;
        uint256 monthlyLimit;
    }
    mapping(address => TransferLimit) private _transferLimits;

    mapping(address => mapping(address => mapping(uint256 => uint256))) private _dailyTransfers;

    mapping(address => mapping(address => mapping(uint256 => uint256))) private _monthlyTransfers;

    mapping(address => bool) public whitelisted;

    mapping(address => bool) public authorizedTokens;

    address public pendingOwner;

    constructor(address _owner, address _identityRegistry) {
        if (_owner == address(0) || _identityRegistry == address(0)) {
            revert ComplianceModule__InvalidAddress();
        }
        owner = _owner;
        identityRegistry = IIdentityRegistry(_identityRegistry);
    }

    function isVerified(address account) external view override returns (bool) {
        if (whitelisted[account]) return true;
        return identityRegistry.isVerified(account);
    }

    function canTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) external view override returns (bool) {
        bool fromWhitelisted = whitelisted[from] || from == address(0);
        bool toWhitelisted = whitelisted[to] || to == address(0);

        if (!fromWhitelisted && !identityRegistry.isVerified(from)) {
            return false;
        }
        if (!toWhitelisted && !identityRegistry.isVerified(to)) {
            return false;
        }

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

        // Recipient-side limits: enforce per-investor caps on the buyer/receiver for real
        // transfers (from != 0). Mints (from == 0) are issuance and exempt from limits.
        if (!toWhitelisted && from != address(0) && amount > 0) {
            TransferLimit storage limits = _transferLimits[token];

            if (limits.dailyLimit > 0) {
                uint256 today = block.timestamp / 1 days;
                uint256 dailyUsed = _dailyTransfers[token][to][today];
                if (dailyUsed + amount > limits.dailyLimit) {
                    return false;
                }
            }

            if (limits.monthlyLimit > 0) {
                uint256 thisMonth = block.timestamp / 30 days;
                uint256 monthlyUsed = _monthlyTransfers[token][to][thisMonth];
                if (monthlyUsed + amount > limits.monthlyLimit) {
                    return false;
                }
            }
        }

        return true;
    }

    function isCountryAllowed(
        address token,
        uint16 country
    ) external view override returns (bool) {
        if (!countryRestrictionsEnabled[token]) return true;
        return _countryAllowed[token][country];
    }

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

    function recordTransfer(address token, address from, address to, uint256 amount) external {
        if (!authorizedTokens[msg.sender]) revert ComplianceModule__Unauthorized();

        uint256 today = block.timestamp / 1 days;
        uint256 thisMonth = block.timestamp / 30 days;

        // Track sent volume for the sender and received volume for the recipient so that
        // both directions count against per-investor limits (whitelisted/zero are exempt).
        if (from != address(0) && !whitelisted[from]) {
            _dailyTransfers[token][from][today] += amount;
            _monthlyTransfers[token][from][thisMonth] += amount;
        }
        if (to != address(0) && !whitelisted[to]) {
            _dailyTransfers[token][to][today] += amount;
            _monthlyTransfers[token][to][thisMonth] += amount;
        }
    }

    function setCountryAllowed(
        address token,
        uint16 country,
        bool allowed
    ) external override onlyOwner {
        _countryAllowed[token][country] = allowed;
        emit CountryAllowed(token, country, allowed);
    }

    function setCountryRestrictionsEnabled(
        address token,
        bool enabled
    ) external onlyOwner {
        countryRestrictionsEnabled[token] = enabled;
    }

    function batchSetCountryAllowed(
        address token,
        uint16[] calldata countries,
        bool[] calldata allowed
    ) external onlyOwner {
        if (countries.length != allowed.length) revert ComplianceModule__ArrayLengthMismatch();
        for (uint256 i = 0; i < countries.length; i++) {
            _countryAllowed[token][countries[i]] = allowed[i];
            emit CountryAllowed(token, countries[i], allowed[i]);
        }
    }

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

    function setWhitelisted(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
    }

    function setAuthorizedToken(address token, bool status) external onlyOwner {
        authorizedTokens[token] = status;
    }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert ComplianceModule__InvalidAddress();
        identityRegistry = IIdentityRegistry(_identityRegistry);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ComplianceModule__InvalidAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert ComplianceModule__Unauthorized();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ComplianceModule__Unauthorized();
        _;
    }
}
