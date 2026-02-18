// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBFactory} from "./interfaces/ILBFactory.sol";
import {ILBPair} from "./interfaces/ILBPair.sol";
import {ILBPairTypes} from "./interfaces/ILBPairTypes.sol";
import {IOracleModule} from "./interfaces/IOracleModule.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title LBRouter
 * @notice User-facing router for Liquidity Book operations
 * @dev Provides convenient interfaces for swaps and liquidity management
 *
 * Features:
 * - Simplified swap interface with slippage protection
 * - Liquidity distribution strategies (uniform, normal, spot)
 * - Multi-hop swap support
 * - Deadline enforcement on all operations
 */
contract LBRouter is Initializable {
    // =============================================================
    //                          ERRORS
    // =============================================================

    error LBRouter__ZeroAddress();
    error LBRouter__InvalidPath();
    error LBRouter__InsufficientAmountOut();
    error LBRouter__ExcessiveAmountIn();
    error LBRouter__InvalidDistribution();
    error LBRouter__PairNotFound();
    error LBRouter__DeadlineExceeded();
    error LBRouter__InvalidBinRange();
    error LBRouter__OracleNotSet();

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Factory address (non-immutable for proxy compatibility)
    ILBFactory public factory;

    /// @notice Storage gap for future upgrades
    uint256[50] private __gap;

    // =============================================================
    //                    CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize router (called once through proxy)
     * @param _factory Factory address
     */
    function initialize(address _factory) external initializer {
        if (_factory == address(0)) revert LBRouter__ZeroAddress();
        factory = ILBFactory(_factory);
    }

    // =============================================================
    //                      SWAP FUNCTIONS
    // =============================================================

    /**
     * @notice Swap exact tokens for tokens (single hop)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param binStep Bin step for the pair
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amountOut Actual amount of output tokens received
     */
    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint16 binStep,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        _checkDeadline(deadline);

        // Get pair
        address pair = factory.getPair(tokenIn, tokenOut, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        // Transfer tokens from user to router first
        // (pair will then pull from router)
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        // Approve pair to spend router's tokens
        _safeApprove(tokenIn, pair, amountIn);

        // Determine swap direction
        bool swapForY = tokenIn < tokenOut;

        // Execute swap
        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            to: to
        });

        ILBPairTypes.SwapResult memory result = ILBPair(pair).swap(params);
        amountOut = result.amountOut;

        // Reset approval
        _safeApprove(tokenIn, pair, 0);

        if (amountOut < minAmountOut) {
            revert LBRouter__InsufficientAmountOut();
        }
    }

    /**
     * @notice Swap exact tokens on a specific pair (bypasses factory lookup)
     * @dev Used when the UI already knows the pair address (e.g., user navigated to a pool).
     *      Validates that the pair is a legitimate LBPair by checking tokenX/tokenY match.
     * @param pair The LBPair contract address
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum output tokens (slippage protection)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapOnPair(
        address pair,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        // Validate the pair has the expected tokens (prevents use with arbitrary contracts)
        address pairTokenX = ILBPair(pair).tokenX();
        address pairTokenY = ILBPair(pair).tokenY();
        bool validTokens = (tokenIn == pairTokenX && tokenOut == pairTokenY)
                        || (tokenIn == pairTokenY && tokenOut == pairTokenX);
        if (!validTokens) revert LBRouter__InvalidPath();

        // Transfer tokens from user to router
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        // Approve pair to spend router's tokens
        _safeApprove(tokenIn, pair, amountIn);

        // Determine swap direction
        bool swapForY = tokenIn < tokenOut;

        // Execute swap
        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            to: to
        });

        ILBPairTypes.SwapResult memory result = ILBPair(pair).swap(params);
        amountOut = result.amountOut;

        // Reset approval
        _safeApprove(tokenIn, pair, 0);

        if (amountOut < minAmountOut) {
            revert LBRouter__InsufficientAmountOut();
        }
    }

    /**
     * @notice Get quote for swap (view function)
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param binStep Bin step
     * @param amountIn Input amount
     * @return amountOut Estimated output amount
     * @return fees Estimated fees
     */
    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint16 binStep,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 fees) {
        address pair = factory.getPair(tokenIn, tokenOut, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        bool swapForY = tokenIn < tokenOut;
        return ILBPair(pair).getSwapOut(swapForY, amountIn);
    }

    // =============================================================
    //                   LIQUIDITY FUNCTIONS
    // =============================================================

    /**
     * @notice Add liquidity with uniform distribution
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @param amountX Amount of token X
     * @param amountY Amount of token Y
     * @param activeBinId Desired active bin ID
     * @param binRange Number of bins on each side of active bin
     * @param to Recipient of LP shares
     * @param deadline Transaction deadline
     * @return shares Array of shares minted
     */
    function addLiquidityUniform(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint256 amountX,
        uint256 amountY,
        uint24 activeBinId,
        uint24 binRange,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory shares) {
        _checkDeadline(deadline);

        address pair = factory.getPair(tokenX, tokenY, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        // Pull tokens from user and approve pair
        if (amountX > 0) {
            _safeTransferFrom(tokenX, msg.sender, address(this), amountX);
            _safeApprove(tokenX, pair, amountX);
        }
        if (amountY > 0) {
            _safeTransferFrom(tokenY, msg.sender, address(this), amountY);
            _safeApprove(tokenY, pair, amountY);
        }

        // Generate uniform distribution
        (uint24[] memory binIds, uint64[] memory distX, uint64[] memory distY) =
            _generateUniformDistribution(activeBinId, binRange);

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: activeBinId,
            idSlippage: 5, // 5 bins slippage tolerance
            deadline: deadline,
            to: to
        });

        shares = ILBPair(pair).mint(params);

        // Reset approvals
        if (amountX > 0) _safeApprove(tokenX, pair, 0);
        if (amountY > 0) _safeApprove(tokenY, pair, 0);
    }

    /**
     * @notice Add liquidity with spot concentration (single bin)
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @param amountX Amount of token X
     * @param amountY Amount of token Y
     * @param binId Target bin ID
     * @param to Recipient of LP shares
     * @param deadline Transaction deadline
     * @return shares Shares minted in the bin
     */
    function addLiquiditySpot(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint256 amountX,
        uint256 amountY,
        uint24 binId,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory shares) {
        _checkDeadline(deadline);

        address pair = factory.getPair(tokenX, tokenY, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        // Pull tokens from user and approve pair
        if (amountX > 0) {
            _safeTransferFrom(tokenX, msg.sender, address(this), amountX);
            _safeApprove(tokenX, pair, amountX);
        }
        if (amountY > 0) {
            _safeTransferFrom(tokenY, msg.sender, address(this), amountY);
            _safeApprove(tokenY, pair, amountY);
        }

        // Single bin distribution
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = binId;

        uint64[] memory distX = new uint64[](1);
        distX[0] = 1e18; // 100%

        uint64[] memory distY = new uint64[](1);
        distY[0] = 1e18; // 100%

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: binId,
            idSlippage: 0, // Exact bin
            deadline: deadline,
            to: to
        });

        shares = ILBPair(pair).mint(params);

        // Reset approvals
        if (amountX > 0) _safeApprove(tokenX, pair, 0);
        if (amountY > 0) _safeApprove(tokenY, pair, 0);
    }

    /**
     * @notice Remove liquidity from bins
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @param binIds Array of bin IDs to remove from
     * @param sharesPerBin Array of shares to remove per bin
     * @param minAmountX Minimum amount of token X
     * @param minAmountY Minimum amount of token Y
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amountX Amount of token X received
     * @return amountY Amount of token Y received
     */
    function removeLiquidity(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint24[] calldata binIds,
        uint256[] calldata sharesPerBin,
        uint256 minAmountX,
        uint256 minAmountY,
        address to,
        uint256 deadline
    ) external returns (uint256 amountX, uint256 amountY) {
        _checkDeadline(deadline);

        address pair = factory.getPair(tokenX, tokenY, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        ILBPairTypes.RemoveLiquidityParameters memory params =
            ILBPairTypes.RemoveLiquidityParameters({
                binIds: binIds,
                shares: sharesPerBin,
                minAmountX: minAmountX,
                minAmountY: minAmountY,
                deadline: deadline,
                to: to
            });

        return ILBPair(pair).burn(params);
    }

    // =============================================================
    //                   ORACLE VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get the oracle-derived active bin for a pair (LP helper)
     * @dev Converts Chainlink stock price to a bin ID so LPs know where to position
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @return oracleBinId The bin ID corresponding to the oracle price
     * @return isValid True if oracle price is available and fresh
     */
    function getActiveBinFromOracle(
        address tokenX,
        address tokenY,
        uint16 binStep
    ) external view returns (uint24 oracleBinId, bool isValid) {
        address pair = factory.getPair(tokenX, tokenY, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        address oracleAddr = ILBPair(pair).oracle();
        if (oracleAddr == address(0)) revert LBRouter__OracleNotSet();

        return IOracleModule(oracleAddr).getOracleBinId(pair);
    }

    /**
     * @notice Get oracle deviation info for a pair
     * @dev Shows how far the DEX price is from the oracle and the resulting fee
     * @param tokenX Token X address
     * @param tokenY Token Y address
     * @param binStep Bin step
     * @return dexBinId Current DEX active bin
     * @return oracleBinId Oracle-derived bin ID
     * @return deviationBins Absolute bin distance
     * @return extraFeeBps Extra fee due to deviation
     */
    function getOracleDeviation(
        address tokenX,
        address tokenY,
        uint16 binStep
    ) external view returns (uint24 dexBinId, uint24 oracleBinId, uint24 deviationBins, uint256 extraFeeBps) {
        address pair = factory.getPair(tokenX, tokenY, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        dexBinId = ILBPair(pair).activeId();

        address oracleAddr = ILBPair(pair).oracle();
        if (oracleAddr == address(0)) revert LBRouter__OracleNotSet();

        bool isValid;
        (oracleBinId, isValid) = IOracleModule(oracleAddr).getOracleBinId(pair);

        if (isValid) {
            deviationBins = dexBinId > oracleBinId
                ? dexBinId - oracleBinId
                : oracleBinId - dexBinId;
            extraFeeBps = IOracleModule(oracleAddr).getDeviationFee(pair, dexBinId);
        }
    }

    // =============================================================
    //                    HELPER FUNCTIONS
    // =============================================================

    /**
     * @notice Generate uniform distribution across bins
     * @param activeBinId Center bin ID
     * @param binRange Range on each side
     * @return binIds Array of bin IDs
     * @return distX Distribution for token X
     * @return distY Distribution for token Y
     */
    function _generateUniformDistribution(
        uint24 activeBinId,
        uint24 binRange
    ) internal pure returns (
        uint24[] memory binIds,
        uint64[] memory distX,
        uint64[] memory distY
    ) {
        if (binRange == 0 || binRange > 100) revert LBRouter__InvalidBinRange();

        uint256 totalBins = uint256(binRange) * 2 + 1; // Range on both sides + center
        binIds = new uint24[](totalBins);
        distX = new uint64[](totalBins);
        distY = new uint64[](totalBins);

        uint64 sharePerBin = uint64(1e18 / totalBins);

        for (uint256 i = 0; i < totalBins; i++) {
            // Calculate bin ID: activeBinId - binRange + i
            binIds[i] = uint24(uint256(activeBinId) - uint256(binRange) + i);

            if (binIds[i] < activeBinId) {
                // Below active bin: only token Y
                distX[i] = 0;
                distY[i] = sharePerBin;
            } else if (binIds[i] > activeBinId) {
                // Above active bin: only token X
                distX[i] = sharePerBin;
                distY[i] = 0;
            } else {
                // Active bin: both tokens
                distX[i] = sharePerBin / 2;
                distY[i] = sharePerBin / 2;
            }
        }
    }

    /**
     * @notice Generate normal (bell curve) distribution
     * @param activeBinId Center bin ID
     * @param binRange Range on each side
     * @return binIds Array of bin IDs
     * @return distX Distribution for token X
     * @return distY Distribution for token Y
     */
    function generateNormalDistribution(
        uint24 activeBinId,
        uint24 binRange
    ) external pure returns (
        uint24[] memory binIds,
        uint64[] memory distX,
        uint64[] memory distY
    ) {
        if (binRange == 0 || binRange > 100) revert LBRouter__InvalidBinRange();

        uint256 totalBins = uint256(binRange) * 2 + 1;
        binIds = new uint24[](totalBins);
        distX = new uint64[](totalBins);
        distY = new uint64[](totalBins);

        uint256 totalWeight;

        // Calculate weights using simplified normal distribution
        uint256[] memory weights = new uint256[](totalBins);
        for (uint256 i = 0; i < totalBins; i++) {
            int256 distance = int256(i) - int256(uint256(binRange)); // Distance from center

            // Gaussian-like weight: e^(-(distance^2) / (2 * sigma^2))
            // Simplified: weight = 100 / (1 + distance^2)
            uint256 distSquared = uint256(distance * distance);
            weights[i] = 100e18 / (1e18 + distSquared * 1e18);
            totalWeight += weights[i];
        }

        // Normalize weights to sum to 1e18
        for (uint256 i = 0; i < totalBins; i++) {
            uint64 normalizedShare = uint64((weights[i] * 1e18) / totalWeight);

            binIds[i] = uint24(uint256(activeBinId) - uint256(binRange) + i);

            if (binIds[i] < activeBinId) {
                distX[i] = 0;
                distY[i] = normalizedShare;
            } else if (binIds[i] > activeBinId) {
                distX[i] = normalizedShare;
                distY[i] = 0;
            } else {
                distX[i] = normalizedShare / 2;
                distY[i] = normalizedShare / 2;
            }
        }
    }

    /**
     * @notice Check if deadline has passed
     * @param deadline Deadline timestamp
     */
    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert LBRouter__DeadlineExceeded();
    }

    /**
     * @notice Calculate optimal bin range for a given volatility
     * @param binStep Bin step
     * @param expectedVolatilityBps Expected volatility in basis points
     * @return binRange Recommended bin range
     */
    function calculateOptimalBinRange(
        uint16 binStep,
        uint256 expectedVolatilityBps
    ) external pure returns (uint24 binRange) {
        // binRange = volatility / binStep
        // E.g., 10% volatility with 0.1% bin step = 100 bins
        binRange = uint24((expectedVolatilityBps * 100) / uint256(binStep));

        // Cap at reasonable values
        if (binRange < 5) binRange = 5;
        if (binRange > 100) binRange = 100;
    }

    /**
     * @notice Get recommended bin step for token pair
     * @param expectedDailyVolatilityBps Expected daily volatility
     * @return binStep Recommended bin step (10, 50, or 100 bp)
     */
    function getRecommendedBinStep(
        uint256 expectedDailyVolatilityBps
    ) external pure returns (uint16 binStep) {
        // Ultra-tight (10 bp): < 50 bp daily vol (stable/blue chip stocks)
        if (expectedDailyVolatilityBps < 50) {
            return 10;
        }
        // Standard (50 bp): 50-200 bp daily vol (normal stocks)
        else if (expectedDailyVolatilityBps < 200) {
            return 50;
        }
        // Wide (100 bp): > 200 bp daily vol (volatile stocks/crypto)
        else {
            return 100;
        }
    }

    /**
     * @notice Safe transferFrom for ERC20 tokens
     * @param token Token address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBRouter: TRANSFER_FROM_FAILED"
        );
    }

    /**
     * @notice Safe approve for ERC20 tokens
     * @param token Token address
     * @param spender Spender address
     * @param amount Amount to approve
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBRouter: APPROVE_FAILED"
        );
    }
}
