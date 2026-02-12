// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILBPairEvents
 * @notice Events emitted by LBPair contract
 * @dev Separate interface for events to keep code organized
 */
interface ILBPairEvents {
    /**
     * @notice Emitted when a swap is executed
     * @param sender Address initiating the swap
     * @param recipient Address receiving the output tokens
     * @param swapForY True if swapping X for Y, false otherwise
     * @param amountIn Amount of input tokens
     * @param amountOut Amount of output tokens
     * @param fees Total fees collected
     * @param activeBinId Active bin ID after swap
     */
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool swapForY,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fees,
        uint24 activeBinId
    );

    /**
     * @notice Emitted when liquidity is added to bins
     * @param sender Address adding liquidity
     * @param recipient Address receiving LP shares
     * @param binIds Array of bin IDs liquidity was added to
     * @param amounts Array of share amounts minted
     * @param totalAmountX Total amount of token X added
     * @param totalAmountY Total amount of token Y added
     */
    event LiquidityAdded(
        address indexed sender,
        address indexed recipient,
        uint24[] binIds,
        uint256[] amounts,
        uint256 totalAmountX,
        uint256 totalAmountY
    );

    /**
     * @notice Emitted when liquidity is removed from bins
     * @param sender Address removing liquidity
     * @param recipient Address receiving tokens
     * @param binIds Array of bin IDs liquidity was removed from
     * @param amounts Array of share amounts burned
     * @param totalAmountX Total amount of token X withdrawn
     * @param totalAmountY Total amount of token Y withdrawn
     */
    event LiquidityRemoved(
        address indexed sender,
        address indexed recipient,
        uint24[] binIds,
        uint256[] amounts,
        uint256 totalAmountX,
        uint256 totalAmountY
    );

    /**
     * @notice Emitted when fees are collected
     * @param sender Address collecting fees
     * @param recipient Address receiving fees
     * @param amountX Amount of token X fees collected
     * @param amountY Amount of token Y fees collected
     */
    event FeesCollected(
        address indexed sender,
        address indexed recipient,
        uint256 amountX,
        uint256 amountY
    );

    /**
     * @notice Emitted when active bin changes
     * @param oldActiveBinId Previous active bin ID
     * @param newActiveBinId New active bin ID
     */
    event ActiveBinChanged(uint24 oldActiveBinId, uint24 newActiveBinId);

    /**
     * @notice Emitted when fee parameters are updated
     * @param baseFee New base fee
     * @param maxVolatilityFee New max volatility fee
     */
    event FeeParametersSet(uint16 baseFee, uint16 maxVolatilityFee);

    /**
     * @notice Emitted when protocol fees are collected
     * @param amountX Amount of token X protocol fees
     * @param amountY Amount of token Y protocol fees
     */
    event ProtocolFeesCollected(uint256 amountX, uint256 amountY);

    /**
     * @notice Emitted when bin is initialized (first liquidity added)
     * @param binId The initialized bin ID
     */
    event BinInitialized(uint24 binId);

    /**
     * @notice Emitted when bin becomes empty (all liquidity removed)
     * @param binId The emptied bin ID
     */
    event BinEmptied(uint24 binId);
}
