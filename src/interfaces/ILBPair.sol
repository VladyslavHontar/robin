// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPairTypes} from "./ILBPairTypes.sol";
import {ILBPairErrors} from "./ILBPairErrors.sol";
import {ILBPairEvents} from "./ILBPairEvents.sol";

/**
 * @title ILBPair
 * @notice Interface for the Liquidity Book Pair contract
 * @dev Main interface that combines types, errors, and events
 */
interface ILBPair is ILBPairTypes, ILBPairErrors, ILBPairEvents {
    // =============================================================
    //                          VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get the token X address
     * @return Token X address
     */
    function tokenX() external view returns (address);

    /**
     * @notice Get the token Y address
     * @return Token Y address
     */
    function tokenY() external view returns (address);

    /**
     * @notice Get the bin step (price increment)
     * @return Bin step in basis points
     */
    function binStep() external view returns (uint16);

    /**
     * @notice Get the current active bin ID
     * @return Active bin ID
     */
    function activeId() external view returns (uint24);

    /**
     * @notice Get the compliance module address
     * @return Compliance module address (address(0) if disabled)
     */
    function compliance() external view returns (address);

    /**
     * @notice Get the oracle module address
     * @return Oracle module address (address(0) if disabled)
     */
    function oracle() external view returns (address);

    /**
     * @notice Get reserves for a specific bin
     * @param binId The bin ID to query
     * @return reserveX Token X reserves
     * @return reserveY Token Y reserves
     */
    function getBinReserves(uint24 binId) external view returns (uint128 reserveX, uint128 reserveY);

    /**
     * @notice Get the next non-empty bin
     * @param binId Starting bin ID
     * @param swapForY Direction of search
     * @return nextBinId The next non-empty bin ID
     */
    function getNextNonEmptyBin(uint24 binId, bool swapForY) external view returns (uint24 nextBinId);

    /**
     * @notice Get fee parameters
     * @return feeParams Current fee parameters
     */
    function getFeeParameters() external view returns (FeeParameters memory feeParams);

    /**
     * @notice Get total liquidity shares for a bin
     * @param binId The bin ID to query
     * @return Total shares in the bin
     */
    function getTotalShares(uint24 binId) external view returns (uint256);

    /**
     * @notice Get user's share balance for a bin
     * @param account User address
     * @param binId Bin ID
     * @return User's share balance
     */
    function balanceOf(address account, uint24 binId) external view returns (uint256);

    /**
     * @notice Calculate swap output amount (view function for quotes)
     * @param swapForY Direction of swap
     * @param amountIn Input amount
     * @return amountOut Output amount
     * @return fees Total fees
     */
    function getSwapOut(
        bool swapForY,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 fees);

    // =============================================================
    //                       SWAP FUNCTIONS
    // =============================================================

    /**
     * @notice Execute a swap
     * @param params Swap parameters
     * @return result Swap result with output amount and fees
     */
    function swap(SwapParameters calldata params) external returns (SwapResult memory result);

    // =============================================================
    //                   LIQUIDITY FUNCTIONS
    // =============================================================

    /**
     * @notice Add liquidity to bins
     * @param params Liquidity parameters
     * @return shares Array of share amounts minted for each bin
     */
    function mint(LiquidityParameters calldata params) external returns (uint256[] memory shares);

    /**
     * @notice Remove liquidity from bins
     * @param params Remove liquidity parameters
     * @return amountX Amount of token X withdrawn
     * @return amountY Amount of token Y withdrawn
     */
    function burn(
        RemoveLiquidityParameters calldata params
    ) external returns (uint256 amountX, uint256 amountY);

    /**
     * @notice Collect accumulated fees for positions
     * @param binIds Array of bin IDs to collect fees from
     * @param account Account to collect fees for
     * @return amountX Amount of token X fees collected
     * @return amountY Amount of token Y fees collected
     */
    function collectFees(
        uint24[] calldata binIds,
        address account
    ) external returns (uint256 amountX, uint256 amountY);

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set fee parameters (only factory)
     * @param feeParams New fee parameters
     */
    function setFeeParameters(FeeParameters calldata feeParams) external;

    /**
     * @notice Collect protocol fees (only factory)
     * @return amountX Amount of token X protocol fees
     * @return amountY Amount of token Y protocol fees
     */
    function collectProtocolFees() external returns (uint256 amountX, uint256 amountY);
}
