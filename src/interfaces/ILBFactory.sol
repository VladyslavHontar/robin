// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPairTypes} from "./ILBPairTypes.sol";

/**
 * @title ILBFactory
 * @notice Interface for the Liquidity Book Factory
 * @dev Factory for deploying and managing LBPair contracts
 */
interface ILBFactory {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error LBFactory__ZeroAddress();
    error LBFactory__PairAlreadyExists(address tokenX, address tokenY, uint16 binStep);
    error LBFactory__InvalidBinStep(uint16 binStep);
    error LBFactory__Unauthorized(address caller);
    error LBFactory__IdenticalTokens();
    error LBFactory__InvalidTokenOrder();
    error LBFactory__NotERC20(address token);

    // =============================================================
    //                          EVENTS
    // =============================================================

    event PairCreated(
        address indexed tokenX,
        address indexed tokenY,
        uint16 indexed binStep,
        address pair,
        uint256 pairCount
    );

    event FeeParametersSet(
        address indexed pair,
        uint16 baseFee,
        uint16 protocolShare,
        uint16 maxVolatilityFee
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event ProtocolFeeRecipientSet(address indexed recipient);

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
    ) external view returns (address pair);

    /**
     * @notice Get all pairs for a token pair (across all bin steps)
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @return pairs Array of pair addresses
     */
    function getAllPairs(
        address tokenX,
        address tokenY
    ) external view returns (address[] memory pairs);

    /**
     * @notice Get total number of pairs created
     * @return Number of pairs
     */
    function allPairsLength() external view returns (uint256);

    /**
     * @notice Compute the deterministic address of a pair without any chain query.
     * @dev Uses CREATE2: address = keccak256(0xff ++ factory ++ salt ++ initCodeHash)
     *      salt = keccak256(token0, token1, binStep) where token0 < token1.
     *      Works even before the pair is deployed — equivalent to Solana PDA derivation.
     * @param tokenA One token of the pair (order doesn't matter)
     * @param tokenB Other token of the pair
     * @param binStep Bin step in basis points
     * @return pair Deterministic pair address
     */
    function computePairAddress(
        address tokenA,
        address tokenB,
        uint16 binStep
    ) external view returns (address pair);

    /**
     * @notice Get pair at index
     * @param index Index in allPairs array
     * @return pair Pair address
     */
    function allPairs(uint256 index) external view returns (address pair);

    /**
     * @notice Check if bin step is supported
     * @param binStep Bin step to check
     * @return Whether bin step is supported
     */
    function isBinStepSupported(uint16 binStep) external view returns (bool);

    /**
     * @notice Get factory owner
     * @return Owner address
     */
    function owner() external view returns (address);

    /**
     * @notice Get protocol fee recipient
     * @return Recipient address
     */
    function protocolFeeRecipient() external view returns (address);

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
    ) external returns (address pair);

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
    ) external;

    /**
     * @notice Set protocol fee recipient (owner only)
     * @param recipient New recipient address
     */
    function setProtocolFeeRecipient(address recipient) external;

    /**
     * @notice Transfer ownership (owner only)
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external;

    /**
     * @notice Collect protocol fees from a pair (fee recipient only)
     * @param pair Pair address
     * @return amountX Amount of token X collected
     * @return amountY Amount of token Y collected
     */
    function collectProtocolFees(
        address pair
    ) external returns (uint256 amountX, uint256 amountY);
}
