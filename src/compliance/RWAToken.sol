// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IComplianceModule} from "./interfaces/IComplianceModule.sol";

contract RWAToken {

    error RWAToken__ZeroAddress();
    error RWAToken__Unauthorized();
    error RWAToken__InsufficientBalance(address account, uint256 balance, uint256 needed);
    error RWAToken__InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error RWAToken__NotCompliant(address from, address to);
    error RWAToken__AccountFrozen(address account);
    error RWAToken__AccountNotFrozen(address account);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ComplianceModuleSet(address indexed compliance);
    event AccountFrozen(address indexed account);
    event AccountUnfrozen(address indexed account);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    address public owner;

    address public pendingOwner;

    address public complianceModule;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    mapping(address => bool) public frozen;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _owner) {
        if (_owner == address(0)) revert RWAToken__ZeroAddress();
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert RWAToken__Unauthorized();
        _;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address _owner, address spender) external view returns (uint256) {
        return _allowances[_owner][spender];
    }

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

    function setComplianceModule(address _complianceModule) external onlyOwner {
        complianceModule = _complianceModule;
        emit ComplianceModuleSet(_complianceModule);
    }

    function freeze(address account) external onlyOwner {
        frozen[account] = true;
        emit AccountFrozen(account);
    }

    function unfreeze(address account) external onlyOwner {
        frozen[account] = false;
        emit AccountUnfrozen(account);
    }

    function forcedTransfer(address from, address to, uint256 amount) external onlyOwner {
        if (!frozen[from]) revert RWAToken__AccountNotFrozen(from);
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

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert RWAToken__ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert RWAToken__Unauthorized();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert RWAToken__ZeroAddress();
        _update(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _update(from, address(0), amount);
    }

    function _update(address from, address to, uint256 amount) internal {
        bool isMint = from == address(0) && to != address(0);
        bool isTransfer = from != address(0) && to != address(0);

        // Recipient-side compliance applies to transfers AND mints: per ERC-3643 newly issued
        // securities must land on a verified, compliant, non-frozen holder. Burns (to == 0) and
        // owner forcedTransfer (which bypasses _update) are intentionally exempt.
        if (isTransfer || isMint) {
            if (frozen[to]) revert RWAToken__AccountFrozen(to);
            if (isTransfer && frozen[from]) revert RWAToken__AccountFrozen(from);

            if (complianceModule != address(0)) {
                if (!IComplianceModule(complianceModule).canTransfer(address(this), from, to, amount)) {
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

        if (isTransfer && complianceModule != address(0)) {
            IComplianceModule(complianceModule).recordTransfer(address(this), from, to, amount);
        }
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
