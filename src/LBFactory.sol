// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBFactory} from "./interfaces/ILBFactory.sol";
import {ILBPairTypes} from "./interfaces/ILBPairTypes.sol";
import {ILBPair} from "./interfaces/ILBPair.sol";
import {LBPair} from "./LBPair.sol";
import {IComplianceModule} from "./compliance/interfaces/IComplianceModule.sol";

/**
 * @title LBFactory
 * @notice Factory contract for deploying and managing Liquidity Book Pairs
 * @dev Implements three-tier bin step system optimized for stock trading
 *
 * Supported Bin Steps:
 * - Ultra-Tight: 10 bp (0.1%) - Large-cap stocks
 * - Standard: 50 bp (0.5%) - Mid-cap stocks
 * - Wide: 100 bp (1%) - Small-cap/volatile stocks
 */
contract LBFactory is ILBFactory {
    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Factory owner (can set fees and recipient)
    address public override owner;

    /// @notice Protocol fee recipient
    address public override protocolFeeRecipient;

    /// @notice Array of all created pairs
    address[] public override allPairs;

    /// @notice Supported bin steps
    mapping(uint16 => bool) public override isBinStepSupported;

    /// @notice Get pair by tokens and bin step: tokenA => tokenB => binStep => pair
    mapping(address => mapping(address => mapping(uint16 => address))) private _pairs;

    /// @notice Compliance module address (optional)
    address public complianceModule;

    /// @notice Constant bin steps (immutable after deployment)
    uint16 public constant BIN_STEP_ULTRA_TIGHT = 10; // 0.1%
    uint16 public constant BIN_STEP_STANDARD = 50; // 0.5%
    uint16 public constant BIN_STEP_WIDE = 100; // 1%

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @notice Initialize the factory
     * @param _owner Initial owner address
     * @param _protocolFeeRecipient Initial protocol fee recipient
     */
    constructor(address _owner, address _protocolFeeRecipient) {
        if (_owner == address(0) || _protocolFeeRecipient == address(0)) {
            revert LBFactory__ZeroAddress();
        }

        owner = _owner;
        protocolFeeRecipient = _protocolFeeRecipient;

        // Enable supported bin steps
        isBinStepSupported[BIN_STEP_ULTRA_TIGHT] = true;
        isBinStepSupported[BIN_STEP_STANDARD] = true;
        isBinStepSupported[BIN_STEP_WIDE] = true;
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get the pair for token pair at specific bin step
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @return pair Pair address (address(0) if doesn't exist)
     */
    function getPair(
        address tokenX,
        address tokenY,
        uint16 binStep
    ) external view override returns (address pair) {
        (address token0, address token1) = _sortTokens(tokenX, tokenY);
        return _pairs[token0][token1][binStep];
    }

    /**
     * @notice Get all pairs for a token pair (across all bin steps)
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @return pairs Array of pair addresses
     */
    function getAllPairs(
        address tokenX,
        address tokenY
    ) external view override returns (address[] memory pairs) {
        (address token0, address token1) = _sortTokens(tokenX, tokenY);

        // Count non-zero pairs
        uint256 count;
        if (_pairs[token0][token1][BIN_STEP_ULTRA_TIGHT] != address(0)) count++;
        if (_pairs[token0][token1][BIN_STEP_STANDARD] != address(0)) count++;
        if (_pairs[token0][token1][BIN_STEP_WIDE] != address(0)) count++;

        // Build array
        pairs = new address[](count);
        uint256 index;
        if (_pairs[token0][token1][BIN_STEP_ULTRA_TIGHT] != address(0)) {
            pairs[index++] = _pairs[token0][token1][BIN_STEP_ULTRA_TIGHT];
        }
        if (_pairs[token0][token1][BIN_STEP_STANDARD] != address(0)) {
            pairs[index++] = _pairs[token0][token1][BIN_STEP_STANDARD];
        }
        if (_pairs[token0][token1][BIN_STEP_WIDE] != address(0)) {
            pairs[index++] = _pairs[token0][token1][BIN_STEP_WIDE];
        }
    }

    /**
     * @notice Get total number of pairs created
     * @return Number of pairs
     */
    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    // =============================================================
    //                    PAIR CREATION
    // =============================================================

    /**
     * @notice Create a new LBPair
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step in basis points
     * @param activeId Initial active bin ID
     * @return pair Address of created pair
     */
    function createPair(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint24 activeId
    ) external override returns (address pair) {
        // Validate inputs
        if (tokenX == address(0) || tokenY == address(0)) {
            revert LBFactory__ZeroAddress();
        }
        if (tokenX == tokenY) {
            revert LBFactory__IdenticalTokens();
        }
        if (!isBinStepSupported[binStep]) {
            revert LBFactory__InvalidBinStep(binStep);
        }

        // Sort tokens (token0 < token1)
        (address token0, address token1) = _sortTokens(tokenX, tokenY);

        // Check if pair already exists
        if (_pairs[token0][token1][binStep] != address(0)) {
            revert LBFactory__PairAlreadyExists(token0, token1, binStep);
        }

        // Deploy new pair
        pair = address(new LBPair(token0, token1, binStep, activeId));

        // Set compliance module if configured
        if (complianceModule != address(0)) {
            LBPair(pair).setCompliance(complianceModule);
        }

        // Store pair
        _pairs[token0][token1][binStep] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, binStep, pair, allPairs.length);
    }

    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set fee parameters for a pair (owner only)
     * @param pair Pair address
     * @param feeParams New fee parameters
     */
    function setFeeParameters(
        address pair,
        ILBPairTypes.FeeParameters calldata feeParams
    ) external override onlyOwner {
        if (pair == address(0)) revert LBFactory__ZeroAddress();

        ILBPair(pair).setFeeParameters(feeParams);

        emit FeeParametersSet(
            pair,
            feeParams.baseFee,
            feeParams.protocolShare,
            feeParams.maxVolatilityFee
        );
    }

    /**
     * @notice Set protocol fee recipient (owner only)
     * @param recipient New recipient address
     */
    function setProtocolFeeRecipient(address recipient) external override onlyOwner {
        if (recipient == address(0)) revert LBFactory__ZeroAddress();

        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    /**
     * @notice Transfer ownership (owner only)
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert LBFactory__ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Set the compliance module for all new pairs
     * @param _complianceModule ComplianceModule address (address(0) to disable)
     */
    function setComplianceModule(address _complianceModule) external onlyOwner {
        complianceModule = _complianceModule;
    }

    /**
     * @notice Set compliance module on an existing pair
     * @param pair Pair address
     * @param _complianceModule ComplianceModule address (address(0) to disable)
     */
    function setPairCompliance(
        address pair,
        address _complianceModule
    ) external onlyOwner {
        if (pair == address(0)) revert LBFactory__ZeroAddress();
        LBPair(pair).setCompliance(_complianceModule);
    }

    /**
     * @notice Collect protocol fees from a pair (fee recipient only)
     * @param pair Pair address
     * @return amountX Amount of token X collected
     * @return amountY Amount of token Y collected
     */
    function collectProtocolFees(
        address pair
    ) external override returns (uint256 amountX, uint256 amountY) {
        if (msg.sender != protocolFeeRecipient) {
            revert LBFactory__Unauthorized(msg.sender);
        }
        if (pair == address(0)) revert LBFactory__ZeroAddress();

        return ILBPair(pair).collectProtocolFees();
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Sort two tokens by address
     * @param tokenA First token
     * @param tokenB Second token
     * @return token0 Lower address
     * @return token1 Higher address
     */
    function _sortTokens(
        address tokenA,
        address tokenB
    ) private pure returns (address token0, address token1) {
        if (tokenA < tokenB) {
            (token0, token1) = (tokenA, tokenB);
        } else {
            (token0, token1) = (tokenB, tokenA);
        }
    }

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    /// @notice Only allows owner to call
    modifier onlyOwner() {
        if (msg.sender != owner) revert LBFactory__Unauthorized(msg.sender);
        _;
    }
}
