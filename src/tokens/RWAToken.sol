// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IComplianceModule} from "../compliance/interfaces/IComplianceModule.sol";

/**
 * @title RWAToken
 * @notice ERC-3643 compatible token for tokenized Real World Assets (stocks).
 *
 * Design philosophy:
 * - Fully ERC-20 compatible interface — any DEX or protocol works with it as-is.
 * - Compliance is enforced internally inside `_update()` (the transfer hook).
 * - The DEX (LBPair) calls `transferFrom()` — it never knows or cares about compliance.
 * - If complianceModule is address(0), the token behaves exactly like plain ERC-20.
 *
 * ERC-3643 features implemented:
 * - Compliance hook on every transfer (mint/burn exempt)
 * - forcedTransfer() for regulatory recovery (owner only)
 * - freeze() / unfreeze() per-account (owner only)
 *
 * Compliance stack (ERC-3643 spec):
 *   RWAToken._update()
 *     → ComplianceModule.canTransfer()
 *       → IdentityRegistry.isVerified()
 *         → Identity.getClaim()
 *           → ClaimIssuer.isClaimValid()
 */
contract RWAToken {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error RWAToken__ZeroAddress();
    error RWAToken__Unauthorized();
    error RWAToken__InsufficientBalance(address account, uint256 balance, uint256 needed);
    error RWAToken__InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error RWAToken__NotCompliant(address from, address to);
    error RWAToken__AccountFrozen(address account);

    // =============================================================
    //                          EVENTS
    // =============================================================

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ComplianceModuleSet(address indexed compliance);
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);

    // =============================================================
    //                          STORAGE
    // =============================================================

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    address public owner;

    /// @notice ERC-3643 compliance module. address(0) = no restrictions.
    address public complianceModule;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    /// @notice Frozen accounts cannot send or receive tokens.
    mapping(address => bool) public frozen;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _owner) {
        if (_owner == address(0)) revert RWAToken__ZeroAddress();
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        owner = _owner;
    }

    // =============================================================
    //                       MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert RWAToken__Unauthorized();
        _;
    }

    // =============================================================
    //                   ERC-20 VIEW FUNCTIONS
    // =============================================================

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address _owner, address spender) external view returns (uint256) {
        return _allowances[_owner][spender];
    }

    // =============================================================
    //                   ERC-20 STATE FUNCTIONS
    // =============================================================

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert RWAToken__InsufficientAllowance(msg.sender, currentAllowance, amount);
            }
            unchecked {
                _allowances[from][msg.sender] = currentAllowance - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // =============================================================
    //                    ERC-3643 ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set the compliance module.
     * @param _complianceModule ComplianceModule address. Pass address(0) to remove restrictions.
     */
    function setComplianceModule(address _complianceModule) external onlyOwner {
        complianceModule = _complianceModule;
        emit ComplianceModuleSet(_complianceModule);
    }

    /**
     * @notice Freeze an account. Frozen accounts cannot transfer or receive tokens.
     * @param account Address to freeze.
     */
    function freeze(address account) external onlyOwner {
        frozen[account] = true;
        emit AccountFrozen(account);
    }

    /**
     * @notice Unfreeze an account.
     * @param account Address to unfreeze.
     */
    function unfreeze(address account) external onlyOwner {
        frozen[account] = false;
        emit AccountUnfrozen(account);
    }

    /**
     * @notice Regulatory forced transfer — bypasses compliance and freeze checks.
     * @dev For use by regulators/owner to recover assets in compliance scenarios.
     * @param from Source address.
     * @param to Destination address.
     * @param amount Amount to transfer.
     */
    function forcedTransfer(address from, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert RWAToken__ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert RWAToken__InsufficientBalance(from, bal, amount);
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
        emit ForcedTransfer(from, to, amount);
    }

    /**
     * @notice Transfer ownership.
     * @param newOwner New owner address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert RWAToken__ZeroAddress();
        owner = newOwner;
    }

    // =============================================================
    //                     MINT / BURN (owner only)
    // =============================================================

    /**
     * @notice Mint tokens. Bypasses compliance — issuer is always verified.
     * @param to Recipient.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert RWAToken__ZeroAddress();
        _totalSupply += amount;
        unchecked { _balances[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn tokens from an account.
     * @param from Account to burn from.
     * @param amount Amount to burn.
     */
    function burn(address from, uint256 amount) external onlyOwner {
        uint256 bal = _balances[from];
        if (bal < amount) revert RWAToken__InsufficientBalance(from, bal, amount);
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // =============================================================
    //                       INTERNAL LOGIC
    // =============================================================

    /**
     * @dev ERC-3643 compliance hook. Called on every transfer (not mint/burn).
     *
     * Checks in order:
     * 1. Neither account is frozen.
     * 2. ComplianceModule.canTransfer() — identity verification, country rules,
     *    transfer limits, etc. — only if complianceModule is set.
     */
    function _update(address from, address to, uint256 amount) internal {
        // Skip compliance on mint (from == address(0)) and burn (to == address(0))
        bool isTransfer = from != address(0) && to != address(0);

        if (isTransfer) {
            if (frozen[from]) revert RWAToken__AccountFrozen(from);
            if (frozen[to]) revert RWAToken__AccountFrozen(to);

            if (complianceModule != address(0)) {
                // Compliance is checked for EOA participants only.
                // Contract addresses (DEX pairs, vaults, bridges) are infrastructure and bypass the check.
                //
                // EOA sender must be verified — you can't initiate a transfer without KYC.
                if (from.code.length == 0 && !IComplianceModule(complianceModule).isVerified(from)) {
                    revert RWAToken__NotCompliant(from, to);
                }
                // EOA recipient must be verified — you can't receive a regulated token without KYC.
                // This prevents unverified users from acquiring the token via swaps where the
                // contract (DEX pair) is the sender.
                if (to.code.length == 0 && !IComplianceModule(complianceModule).isVerified(to)) {
                    revert RWAToken__NotCompliant(from, to);
                }
            }
        }

        if (from == address(0)) {
            _totalSupply += amount;
        } else {
            uint256 bal = _balances[from];
            if (bal < amount) revert RWAToken__InsufficientBalance(from, bal, amount);
            unchecked { _balances[from] = bal - amount; }
        }

        if (to == address(0)) {
            unchecked { _totalSupply -= amount; }
        } else {
            unchecked { _balances[to] += amount; }
        }

        emit Transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert RWAToken__ZeroAddress();
        _update(from, to, amount);
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        if (_owner == address(0) || spender == address(0)) revert RWAToken__ZeroAddress();
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }
}
