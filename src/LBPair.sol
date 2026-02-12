// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPair} from "./interfaces/ILBPair.sol";
import {BinMath} from "./libraries/BinMath.sol";
import {BitMath} from "./libraries/BitMath.sol";
import {SwapHelper} from "./libraries/SwapHelper.sol";
import {FeeHelper} from "./libraries/FeeHelper.sol";

/**
 * @title LBPair
 * @notice Core Liquidity Book Pair contract for DLMM
 * @dev Implements concentrated liquidity with discrete bins
 *
 * Architecture:
 * - Bins store reserves in packed format (112+112+32 bits)
 * - Bitmap index enables O(1) bin lookup instead of O(n) iteration
 * - Fees auto-compound into reserves (Trader Joe V2.1 style)
 * - ERC-1155 positions for fungibility within bins
 */
contract LBPair is ILBPair {
    using BinMath for uint24;
    using BitMath for uint256;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    /// @notice Maximum number of bins that can be modified in single operation
    uint256 private constant MAX_BINS_PER_OPERATION = 50;

    /// @notice Maximum price move allowed in single swap (circuit breaker)
    uint24 private constant MAX_PRICE_MOVE_BINS = 200; // 20% at 10bp step

    /// @notice Reentrancy guard value
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Token X address
    address public immutable override tokenX;

    /// @notice Token Y address
    address public immutable override tokenY;

    /// @notice Bin step in basis points
    uint16 public immutable override binStep;

    /// @notice Factory address (for access control)
    address public immutable factory;

    /// @notice Current active bin ID
    uint24 public override activeId;

    /// @notice Fee parameters
    FeeParameters public feeParameters;

    /// @notice Protocol fees accumulated
    uint128 public protocolFeesX;
    uint128 public protocolFeesY;

    /// @notice Reentrancy guard
    uint256 private _status;

    /// @notice Bin storage: binId => packed BinState (256 bits)
    /// Bits 0-111:   reserveX (uint112)
    /// Bits 112-223: reserveY (uint112)
    /// Bits 224-255: liquidityIndex (uint32)
    mapping(uint24 => uint256) private _bins;

    /// @notice Level 1 bitmap: covers 256 bins per bit (65,536 bins total)
    mapping(uint16 => uint256) private _binBitmapL1;

    /// @notice Level 2 bitmap: covers individual bins
    mapping(uint16 => uint256) private _binBitmapL2;

    /// @notice Liquidity data: liquidityIndex => LiquidityData
    mapping(uint32 => LiquidityData) private _liquidityData;

    /// @notice User positions: account => binId => shares
    mapping(address => mapping(uint24 => uint256)) private _balances;

    /// @notice Next liquidity index to use
    uint32 private _nextLiquidityIndex;

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    /// @notice Prevents reentrancy
    modifier nonReentrant() {
        if (_status == ENTERED) revert LBPair__Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    /// @notice Only allows factory to call
    modifier onlyFactory() {
        if (msg.sender != factory) revert LBPair__Unauthorized(msg.sender);
        _;
    }

    /// @notice Validates deadline
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert LBPair__DeadlineExceeded(deadline, block.timestamp);
        }
        _;
    }

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @notice Initialize the pair
     * @param _tokenX Token X address
     * @param _tokenY Token Y address
     * @param _binStep Bin step in basis points
     * @param _activeId Initial active bin ID
     */
    constructor(address _tokenX, address _tokenY, uint16 _binStep, uint24 _activeId) {
        if (_tokenX == address(0) || _tokenY == address(0)) revert LBPair__ZeroAddress();
        if (_binStep == 0 || _binStep > BinMath.MAX_BIN_STEP) {
            revert LBPair__InvalidBinStep(_binStep);
        }

        tokenX = _tokenX;
        tokenY = _tokenY;
        binStep = _binStep;
        activeId = _activeId;
        factory = msg.sender;
        _status = NOT_ENTERED;

        // Initialize with default stock fee parameters
        feeParameters = FeeHelper.getDefaultStockFeeParameters();
        feeParameters.volatilityReference = _activeId;

        _nextLiquidityIndex = 1; // Start at 1 (0 means uninitialized)
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get reserves for a specific bin
     * @param binId The bin ID to query
     * @return reserveX Token X reserves
     * @return reserveY Token Y reserves
     */
    function getBinReserves(
        uint24 binId
    ) external view override returns (uint128 reserveX, uint128 reserveY) {
        BinState memory bin = _getBinState(binId);
        return (uint128(bin.reserveX), uint128(bin.reserveY));
    }

    /**
     * @notice Get the next non-empty bin
     * @param binId Starting bin ID
     * @param swapForY Direction of search
     * @return nextBinId The next non-empty bin ID
     */
    function getNextNonEmptyBin(
        uint24 binId,
        bool swapForY
    ) public view override returns (uint24 nextBinId) {
        return _getNextNonEmptyBin(binId, swapForY);
    }

    /**
     * @notice Get fee parameters
     * @return Current fee parameters
     */
    function getFeeParameters() external view override returns (FeeParameters memory) {
        return feeParameters;
    }

    /**
     * @notice Get total liquidity shares for a bin
     * @param binId The bin ID to query
     * @return Total shares in the bin
     */
    function getTotalShares(uint24 binId) external view override returns (uint256) {
        BinState memory bin = _getBinState(binId);
        if (bin.liquidityIndex == 0) return 0;
        return _liquidityData[bin.liquidityIndex].totalShares;
    }

    /**
     * @notice Get user's share balance for a bin
     * @param account User address
     * @param binId Bin ID
     * @return User's share balance
     */
    function balanceOf(
        address account,
        uint24 binId
    ) external view override returns (uint256) {
        return _balances[account][binId];
    }

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
    ) external view override returns (uint256 amountOut, uint256 fees) {
        uint24 startBinId = activeId;
        uint256 amountInRemaining = amountIn;
        uint24 currentBinId = startBinId;
        uint24 binsCrossed;

        // Simulate swap across bins
        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);

            (uint256 binAmountOut, uint256 binAmountIn) = SwapHelper.getAmountOutSingleBin(
                bin,
                amountInRemaining,
                swapForY
            );

            amountOut += binAmountOut;
            amountInRemaining -= binAmountIn;

            if (SwapHelper.isBinDepleted(bin, binAmountIn, swapForY)) {
                binsCrossed++;
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                currentBinId = nextBin;
            } else {
                break;
            }
        }

        // Calculate total fees
        uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId);
        (fees, ) = FeeHelper.calculateFee(amountIn - amountInRemaining, feeBps);
    }

    // =============================================================
    //                       SWAP FUNCTIONS
    // =============================================================

    /**
     * @notice Execute a swap
     * @param params Swap parameters
     * @return result Swap result with output amount and fees
     */
    function swap(
        SwapParameters calldata params
    ) external override nonReentrant ensure(params.deadline) returns (SwapResult memory result) {
        if (params.amountIn == 0) revert LBPair__ZeroAmount();
        if (params.to == address(0)) revert LBPair__ZeroAddress();

        uint24 startBinId = activeId;
        uint256 amountInRemaining = params.amountIn;
        uint256 totalAmountOut;
        uint256 totalFees;
        uint24 currentBinId = startBinId;
        uint24 binsCrossed;

        // Execute swap across bins
        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);

            // Calculate swap for this bin
            (uint256 binAmountOut, uint256 binAmountIn) = SwapHelper.getAmountOutSingleBin(
                bin,
                amountInRemaining,
                params.swapForY
            );

            // Calculate fees for this bin
            uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId);
            (uint256 binFee, uint256 amountAfterFee) = FeeHelper.calculateFee(
                binAmountIn,
                feeBps
            );

            // Update amounts
            totalAmountOut += binAmountOut;
            totalFees += binFee;
            amountInRemaining -= binAmountIn;

            // Update bin reserves (with fees auto-compounded)
            SwapHelper.updateBinReserves(bin, binAmountIn, binAmountOut, params.swapForY);
            _setBinState(currentBinId, bin);

            // Check if bin depleted
            if (SwapHelper.isBinDepleted(bin, binAmountIn, params.swapForY)) {
                binsCrossed++;

                // Move to next bin
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break; // No more bins
                currentBinId = nextBin;
            } else {
                break; // Swap complete within this bin
            }
        }

        // Validate slippage
        if (totalAmountOut < params.minAmountOut) {
            revert LBPair__SlippageExceeded(totalAmountOut, params.minAmountOut);
        }

        // Validate price move (circuit breaker)
        if (binsCrossed > MAX_PRICE_MOVE_BINS) {
            revert LBPair__ExcessivePriceMove(startBinId, currentBinId, MAX_PRICE_MOVE_BINS);
        }

        // Update active bin
        if (currentBinId != activeId) {
            emit ActiveBinChanged(activeId, currentBinId);
            activeId = currentBinId;
        }

        // Prepare result
        result = SwapResult({
            amountOut: totalAmountOut,
            fees: totalFees,
            newActiveBinId: currentBinId
        });

        emit Swap(
            msg.sender,
            params.to,
            params.swapForY,
            params.amountIn,
            totalAmountOut,
            totalFees,
            currentBinId
        );
    }

    // =============================================================
    //                   LIQUIDITY FUNCTIONS
    // =============================================================

    /**
     * @notice Add liquidity to bins
     * @param params Liquidity parameters
     * @return shares Array of share amounts minted for each bin
     */
    function mint(
        LiquidityParameters calldata params
    ) external override nonReentrant ensure(params.deadline) returns (uint256[] memory shares) {
        if (params.binIds.length == 0) revert LBPair__InvalidLiquidityDistribution();
        if (params.binIds.length > MAX_BINS_PER_OPERATION) {
            revert LBPair__TooManyBins(params.binIds.length, MAX_BINS_PER_OPERATION);
        }
        if (params.to == address(0)) revert LBPair__ZeroAddress();

        // Validate active bin is within slippage tolerance
        uint24 activeIdDesired = params.activeIdDesired;
        uint24 idSlippage = params.idSlippage;
        if (
            activeId < activeIdDesired - idSlippage || activeId > activeIdDesired + idSlippage
        ) {
            revert LBPair__InvalidActiveId(activeId);
        }

        shares = new uint256[](params.binIds.length);
        uint256 totalAmountX;
        uint256 totalAmountY;

        // Add liquidity to each bin
        for (uint256 i = 0; i < params.binIds.length; i++) {
            uint24 binId = params.binIds[i];

            // Calculate amounts for this bin based on distribution
            uint256 amountX = (params.amountX * params.distributionX[i]) / 1e18;
            uint256 amountY = (params.amountY * params.distributionY[i]) / 1e18;

            if (amountX == 0 && amountY == 0) continue;

            // Add liquidity to bin
            shares[i] = _addLiquidityToBin(binId, amountX, amountY, params.to);

            totalAmountX += amountX;
            totalAmountY += amountY;
        }

        emit LiquidityAdded(
            msg.sender,
            params.to,
            params.binIds,
            shares,
            totalAmountX,
            totalAmountY
        );
    }

    /**
     * @notice Remove liquidity from bins
     * @param params Remove liquidity parameters
     * @return amountX Amount of token X withdrawn
     * @return amountY Amount of token Y withdrawn
     */
    function burn(
        RemoveLiquidityParameters calldata params
    )
        external
        override
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amountX, uint256 amountY)
    {
        if (params.binIds.length == 0) revert LBPair__InvalidLiquidityDistribution();
        if (params.to == address(0)) revert LBPair__ZeroAddress();

        // Remove liquidity from each bin
        for (uint256 i = 0; i < params.binIds.length; i++) {
            uint24 binId = params.binIds[i];
            uint256 shares = params.shares[i];

            if (shares == 0) continue;

            (uint256 removedX, uint256 removedY) = _removeLiquidityFromBin(
                binId,
                shares,
                msg.sender
            );

            amountX += removedX;
            amountY += removedY;
        }

        // Validate slippage
        if (amountX < params.minAmountX || amountY < params.minAmountY) {
            revert LBPair__SlippageExceeded(amountX < amountY ? amountX : amountY, 0);
        }

        emit LiquidityRemoved(
            msg.sender,
            params.to,
            params.binIds,
            params.shares,
            amountX,
            amountY
        );
    }

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
    ) external override returns (uint256 amountX, uint256 amountY) {
        // Fee collection logic (simplified for now - fees auto-compound)
        // In future: track fee growth per share and calculate accrued fees
        emit FeesCollected(msg.sender, account, amountX, amountY);
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set fee parameters (only factory)
     * @param _feeParams New fee parameters
     */
    function setFeeParameters(
        FeeParameters calldata _feeParams
    ) external override onlyFactory {
        FeeHelper.validateFeeParameters(_feeParams);
        feeParameters = _feeParams;
        emit FeeParametersSet(_feeParams.baseFee, _feeParams.maxVolatilityFee);
    }

    /**
     * @notice Collect protocol fees (only factory)
     * @return amountX Amount of token X protocol fees
     * @return amountY Amount of token Y protocol fees
     */
    function collectProtocolFees()
        external
        override
        onlyFactory
        returns (uint256 amountX, uint256 amountY)
    {
        amountX = protocolFeesX;
        amountY = protocolFeesY;

        protocolFeesX = 0;
        protocolFeesY = 0;

        emit ProtocolFeesCollected(amountX, amountY);
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Get bin state from packed storage
     * @param binId Bin ID
     * @return bin Unpacked bin state
     */
    function _getBinState(uint24 binId) internal view returns (BinState memory bin) {
        uint256 packed = _bins[binId];
        bin.reserveX = uint112(packed);
        bin.reserveY = uint112(packed >> 112);
        bin.liquidityIndex = uint32(packed >> 224);
    }

    /**
     * @notice Set bin state to packed storage
     * @param binId Bin ID
     * @param bin Bin state to pack
     */
    function _setBinState(uint24 binId, BinState memory bin) internal {
        _bins[binId] =
            uint256(bin.reserveX) |
            (uint256(bin.reserveY) << 112) |
            (uint256(bin.liquidityIndex) << 224);
    }

    /**
     * @notice Find next non-empty bin using bitmap
     * @param binId Starting bin ID
     * @param swapForY Search direction
     * @return Next non-empty bin ID
     */
    function _getNextNonEmptyBin(uint24 binId, bool swapForY) internal view returns (uint24) {
        uint16 l1Index = uint16(binId >> 8);
        uint8 l2Offset = uint8(binId);

        // Load L2 bitmap
        uint256 l2Bitmap = _binBitmapL2[l1Index];

        if (swapForY) {
            // Search right (higher bins)
            (uint8 bit, bool found) = l2Bitmap.closestBitRight(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }
            // TODO: Search L1 for next non-empty L2 bucket
        } else {
            // Search left (lower bins)
            (uint8 bit, bool found) = l2Bitmap.closestBitLeft(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }
            // TODO: Search L1 for previous non-empty L2 bucket
        }

        return binId; // No other bins found
    }

    /**
     * @notice Add liquidity to a single bin
     * @param binId Bin ID
     * @param amountX Amount of token X
     * @param amountY Amount of token Y
     * @param to Recipient address
     * @return shares Shares minted
     */
    function _addLiquidityToBin(
        uint24 binId,
        uint256 amountX,
        uint256 amountY,
        address to
    ) internal returns (uint256 shares) {
        BinState memory bin = _getBinState(binId);

        // Initialize bin if needed
        if (bin.liquidityIndex == 0) {
            bin.liquidityIndex = _nextLiquidityIndex++;
            _setBitmapBit(binId, true);
            emit BinInitialized(binId);
        }

        // Calculate shares (simple proportional for now)
        LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];

        if (liquidity.totalShares == 0) {
            // First liquidity: shares = sqrt(amountX * amountY)
            shares = _sqrt(amountX * amountY);
        } else {
            // Proportional to existing liquidity
            uint256 shareX = (amountX * liquidity.totalShares) / uint256(bin.reserveX);
            uint256 shareY = (amountY * liquidity.totalShares) / uint256(bin.reserveY);
            shares = shareX < shareY ? shareX : shareY;
        }

        // Update bin reserves
        bin.reserveX += uint112(amountX);
        bin.reserveY += uint112(amountY);
        _setBinState(binId, bin);

        // Update liquidity data
        liquidity.totalShares += uint128(shares);

        // Update user balance
        _balances[to][binId] += shares;
    }

    /**
     * @notice Remove liquidity from a single bin
     * @param binId Bin ID
     * @param shares Shares to burn
     * @param from User address
     * @return amountX Amount of token X withdrawn
     * @return amountY Amount of token Y withdrawn
     */
    function _removeLiquidityFromBin(
        uint24 binId,
        uint256 shares,
        address from
    ) internal returns (uint256 amountX, uint256 amountY) {
        // Check user balance
        if (_balances[from][binId] < shares) {
            revert LBPair__InsufficientShares(shares, _balances[from][binId]);
        }

        BinState memory bin = _getBinState(binId);
        LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];

        // Calculate amounts proportional to shares
        amountX = (shares * uint256(bin.reserveX)) / liquidity.totalShares;
        amountY = (shares * uint256(bin.reserveY)) / liquidity.totalShares;

        // Update bin reserves
        bin.reserveX -= uint112(amountX);
        bin.reserveY -= uint112(amountY);

        // Update liquidity data
        liquidity.totalShares -= uint128(shares);

        // Update user balance
        _balances[from][binId] -= shares;

        // If bin empty, clear bitmap
        if (liquidity.totalShares == 0) {
            _setBitmapBit(binId, false);
            emit BinEmptied(binId);
        }

        _setBinState(binId, bin);
    }

    /**
     * @notice Set or clear bitmap bit for a bin
     * @param binId Bin ID
     * @param set True to set, false to clear
     */
    function _setBitmapBit(uint24 binId, bool set) internal {
        uint16 l1Index = uint16(binId >> 8);
        uint8 l2Offset = uint8(binId);

        if (set) {
            _binBitmapL2[l1Index] = _binBitmapL2[l1Index].setBit(l2Offset);
            _binBitmapL1[l1Index >> 8] = _binBitmapL1[l1Index >> 8].setBit(uint8(l1Index));
        } else {
            _binBitmapL2[l1Index] = _binBitmapL2[l1Index].clearBit(l2Offset);
            // Only clear L1 if entire L2 is empty
            if (_binBitmapL2[l1Index] == 0) {
                _binBitmapL1[l1Index >> 8] = _binBitmapL1[l1Index >> 8].clearBit(
                    uint8(l1Index)
                );
            }
        }
    }

    /**
     * @notice Calculate square root (Babylonian method)
     * @param x Input value
     * @return y Square root
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
