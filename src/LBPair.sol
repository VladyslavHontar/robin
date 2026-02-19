// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPair} from "./interfaces/ILBPair.sol";
import {IOracleModule} from "./interfaces/IOracleModule.sol";
import {BinMath} from "./libraries/BinMath.sol";
import {BitMath} from "./libraries/BitMath.sol";
import {SwapHelper} from "./libraries/SwapHelper.sol";
import {FeeHelper} from "./libraries/FeeHelper.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title LBPair
 * @notice Core Liquidity Book Pair contract for DLMM
 * @dev Proxy-compatible implementation using OpenZeppelin Initializable.
 *
 * Architecture:
 * - Deployed once as an implementation contract behind a BeaconProxy.
 * - Each pair is a BeaconProxy that delegates all calls here.
 * - Upgrading the Beacon implementation upgrades ALL pairs simultaneously
 *   (equivalent to Solana program redeployment — state stays in proxies).
 * - Bins store reserves in packed format (112+112+32 bits)
 * - Bitmap index enables O(1) bin lookup instead of O(n) iteration
 * - Fees auto-compound into reserves (Trader Joe V2.1 style)
 */
contract LBPair is ILBPair, Initializable {
    using BinMath for uint24;
    using BitMath for uint256;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    /// @notice Maximum number of bins that can be modified in single operation
    uint256 private constant MAX_BINS_PER_OPERATION = 50;

    /// @notice Maximum price move allowed in single swap (circuit breaker)
    uint24 private constant MAX_PRICE_MOVE_BINS = 200; // 20% at 10bp step

    /// @notice Precision for fee growth per share calculations
    uint256 private constant FEE_PRECISION = 1e18;

    /// @notice Reentrancy guard value
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Token X address
    address public override tokenX;

    /// @notice Token Y address
    address public override tokenY;

    /// @notice Bin step in basis points
    uint16 public override binStep;

    /// @notice Factory address (for access control)
    address public factory;

    /// @notice Current active bin ID
    uint24 public override activeId;

    /// @notice Fee parameters
    FeeParameters public feeParameters;

    /// @notice Protocol fees accumulated
    uint128 public protocolFeesX;
    uint128 public protocolFeesY;

    /// @notice Reentrancy guard
    uint256 private _status;

    /// @notice Oracle module (address(0) = no oracle deviation fee)
    address public oracle;

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

    /// @notice Per-LP fee debt: account => binId => packed(debtX: uint128, debtY: uint128)
    /// @dev Pending fees = (shares * feeGrowth / FEE_PRECISION) - debt
    mapping(address => mapping(uint24 => uint256)) private _feeDebts;

    /// @notice Storage gap for future upgrades (beacon proxy pattern)
    uint256[49] private __gap;

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
    //                        CONSTRUCTOR / INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the implementation contract so it cannot be initialized directly.
        // Each BeaconProxy calls initialize() instead.
        _disableInitializers();
    }

    /**
     * @notice Initialize the pair (called by BeaconProxy on deployment)
     * @param _tokenX Token X address
     * @param _tokenY Token Y address
     * @param _binStep Bin step in basis points
     * @param _activeId Initial active bin ID
     * @param _factory Factory address (set by factory, not msg.sender, since proxy forwards the call)
     */
    function initialize(
        address _tokenX,
        address _tokenY,
        uint16 _binStep,
        uint24 _activeId,
        address _factory
    ) external initializer {
        if (_tokenX == address(0) || _tokenY == address(0)) revert LBPair__ZeroAddress();
        if (_factory == address(0)) revert LBPair__ZeroAddress();
        if (_binStep == 0 || _binStep > BinMath.MAX_BIN_STEP) {
            revert LBPair__InvalidBinStep(_binStep);
        }

        tokenX = _tokenX;
        tokenY = _tokenY;
        binStep = _binStep;
        activeId = _activeId;
        factory = _factory;
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

        // Query oracle deviation fee for accurate quotes
        uint256 oracleDeviationFeeBps;
        if (oracle != address(0)) {
            oracleDeviationFeeBps = IOracleModule(oracle).getDeviationFee(address(this), startBinId);
        }

        // Simulate swap across bins (fee-on-input, constant sum)
        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);
            uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

            // Skip bins with no output reserves (find next bin that has liquidity)
            if (reserveOut == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId, oracleDeviationFeeBps);

            // Max total input (including fee) this bin can accept
            uint256 maxTotalInput = (reserveOut * FeeHelper.BASIS_POINT_MAX) / (FeeHelper.BASIS_POINT_MAX - feeBps);
            uint256 totalConsumed = amountInRemaining < maxTotalInput ? amountInRemaining : maxTotalInput;

            (uint256 binFee, uint256 effectiveInput) = FeeHelper.calculateFee(totalConsumed, feeBps);

            amountOut += effectiveInput; // constant sum: output = post-fee input
            fees += binFee;
            amountInRemaining -= totalConsumed;

            if (effectiveInput >= reserveOut) {
                binsCrossed++;
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                currentBinId = nextBin;
            } else {
                break;
            }
        }
    }

    /**
     * @notice Get unclaimed fees for an account across specified bins
     * @param account User address
     * @param binIds Array of bin IDs to check
     * @return amountX Total unclaimed token X fees
     * @return amountY Total unclaimed token Y fees
     */
    function getUnclaimedFees(
        address account,
        uint24[] calldata binIds
    ) external view returns (uint256 amountX, uint256 amountY) {
        for (uint256 i = 0; i < binIds.length; i++) {
            uint24 binId = binIds[i];
            uint256 shares = _balances[account][binId];
            if (shares == 0) continue;

            BinState memory bin = _getBinState(binId);
            if (bin.liquidityIndex == 0) continue;

            LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];
            (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[account][binId]);

            (uint256 pendingX, uint256 pendingY) = _calculatePendingFees(
                shares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
            );

            amountX += pendingX;
            amountY += pendingY;
        }
    }

    // =============================================================
    //                       SWAP FUNCTIONS
    // =============================================================

    /**
     * @notice Execute a swap
     * @dev Fee-on-input: fee is taken from the input amount. LP fees tracked via
     *      feeGrowthPerShare accumulator. Protocol share is tracked separately.
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

        // Query oracle deviation fee once before the loop (0 if no oracle)
        uint256 oracleDeviationFeeBps;
        if (oracle != address(0)) {
            oracleDeviationFeeBps = IOracleModule(oracle).getDeviationFee(address(this), startBinId);
        }

        // Execute swap across bins (fee-on-input, constant sum)
        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);

            // Get output reserve for this bin
            uint256 reserveOut = params.swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

            // Skip bins with no output reserves (find next bin that has liquidity)
            if (reserveOut == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            // Calculate fee for this bin (includes oracle deviation)
            uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId, oracleDeviationFeeBps);

            // Max total input (including fee) this bin can accept:
            // effectiveInput = totalInput * (1 - feeBps/10000) <= reserveOut
            // => totalInput <= reserveOut * 10000 / (10000 - feeBps)
            uint256 maxTotalInput = (reserveOut * FeeHelper.BASIS_POINT_MAX) / (FeeHelper.BASIS_POINT_MAX - feeBps);
            uint256 totalConsumed = amountInRemaining < maxTotalInput ? amountInRemaining : maxTotalInput;

            // Split consumed amount into fee and effective swap input
            (uint256 binFee, uint256 effectiveInput) = FeeHelper.calculateFee(totalConsumed, feeBps);

            // Constant sum: output = effectiveInput (1:1 within a bin)
            uint256 binAmountOut = effectiveInput;

            // Split fee between LP (auto-compound) and protocol
            (uint256 lpFee, uint256 protocolFee) = FeeHelper.splitFee(binFee, feeParameters.protocolShare);

            // Update totals
            totalAmountOut += binAmountOut;
            totalFees += binFee;
            amountInRemaining -= totalConsumed;

            // Update bin reserves (principal only, fees tracked separately)
            if (params.swapForY) {
                bin.reserveX += uint112(effectiveInput);
                bin.reserveY -= uint112(binAmountOut);
            } else {
                bin.reserveY += uint112(effectiveInput);
                bin.reserveX -= uint112(binAmountOut);
            }
            _setBinState(currentBinId, bin);

            // Accumulate LP fee into feeGrowthPerShare (fee tokens stay in contract)
            if (lpFee > 0 && bin.liquidityIndex != 0) {
                LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];
                if (liquidity.totalShares > 0) {
                    if (params.swapForY) {
                        liquidity.feeGrowthX = FeeHelper.accumulateFees(
                            liquidity.feeGrowthX, lpFee, liquidity.totalShares
                        );
                    } else {
                        liquidity.feeGrowthY = FeeHelper.accumulateFees(
                            liquidity.feeGrowthY, lpFee, liquidity.totalShares
                        );
                    }
                }
            }

            // Track protocol fees (denominated in input token)
            if (params.swapForY) {
                protocolFeesX += uint128(protocolFee);
            } else {
                protocolFeesY += uint128(protocolFee);
            }

            // Check if bin's output is fully consumed
            if (binAmountOut >= reserveOut) {
                binsCrossed++;
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break; // No more bins
                currentBinId = nextBin;
            } else {
                break; // Swap complete within this bin
            }
        }

        // Only pull the actually consumed input (return unconsumed to user)
        uint256 actualAmountIn = params.amountIn - amountInRemaining;

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

        // Execute token transfers (only pull consumed amount)
        if (params.swapForY) {
            _transferFrom(tokenX, msg.sender, address(this), actualAmountIn);
            _transfer(tokenY, params.to, totalAmountOut);
        } else {
            _transferFrom(tokenY, msg.sender, address(this), actualAmountIn);
            _transfer(tokenX, params.to, totalAmountOut);
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
            actualAmountIn,
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

        // Transfer tokens from user to pair
        if (totalAmountX > 0) {
            _transferFrom(tokenX, msg.sender, address(this), totalAmountX);
        }
        if (totalAmountY > 0) {
            _transferFrom(tokenY, msg.sender, address(this), totalAmountY);
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

        // Transfer tokens to user
        if (amountX > 0) {
            _transfer(tokenX, params.to, amountX);
        }
        if (amountY > 0) {
            _transfer(tokenY, params.to, amountY);
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
    ) external override nonReentrant returns (uint256 amountX, uint256 amountY) {
        if (msg.sender != account) revert LBPair__Unauthorized(msg.sender);

        for (uint256 i = 0; i < binIds.length; i++) {
            (uint256 pendingX, uint256 pendingY) = _collectFeesForBin(account, binIds[i]);
            amountX += pendingX;
            amountY += pendingY;
        }

        if (amountX > 0) _transfer(tokenX, account, amountX);
        if (amountY > 0) _transfer(tokenY, account, amountY);

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
     * @notice Set oracle module (only factory)
     * @param _oracle Oracle module address (address(0) to disable)
     */
    function setOracle(address _oracle) external onlyFactory {
        oracle = _oracle;
    }

    /**
     * @notice Collect protocol fees (only factory)
     * @dev Transfers accumulated protocol fees to the factory's fee recipient.
     *      Called via LBFactory.collectProtocolFees() which enforces recipient access.
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

        // Transfer fees to the caller (factory, which forwards to fee recipient)
        if (amountX > 0) {
            _transfer(tokenX, msg.sender, amountX);
        }
        if (amountY > 0) {
            _transfer(tokenY, msg.sender, amountY);
        }

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

        // Load L2 bitmap for current bucket
        uint256 l2Bitmap = _binBitmapL2[l1Index];

        if (swapForY) {
            // Search left (lower bins) — lower bins have more tokenY
            (uint8 bit, bool found) = l2Bitmap.closestBitLeft(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }

            // Cross L2 boundary: search L1 for previous non-empty L2 bucket
            uint16 l1Group = l1Index >> 8;
            uint8 l1Offset = uint8(l1Index);
            uint256 l1Bitmap = _binBitmapL1[l1Group];

            // Search for previous L1 bit (lower L2 bucket) within current group
            (uint8 l1Bit, bool l1Found) = l1Bitmap.closestBitLeft(l1Offset, false);
            if (l1Found) {
                uint16 newL1Index = (l1Group << 8) | uint16(l1Bit);
                uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                uint8 msb = uint8(BitMath.mostSignificantBit(newL2Bitmap));
                return (uint24(newL1Index) << 8) | uint24(msb);
            }

            // Cross L1 group boundary: search lower L1 groups
            for (uint16 g = l1Group; g > 0;) {
                g--;
                uint256 adjL1 = _binBitmapL1[g];
                if (adjL1 != 0) {
                    uint8 topL1 = uint8(BitMath.mostSignificantBit(adjL1));
                    uint16 newL1Index = (g << 8) | uint16(topL1);
                    uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                    uint8 msb = uint8(BitMath.mostSignificantBit(newL2Bitmap));
                    return (uint24(newL1Index) << 8) | uint24(msb);
                }
            }
        } else {
            // Search right (higher bins) — higher bins have more tokenX
            (uint8 bit, bool found) = l2Bitmap.closestBitRight(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }

            // Cross L2 boundary: search L1 for next non-empty L2 bucket
            uint16 l1Group = l1Index >> 8;
            uint8 l1Offset = uint8(l1Index);
            uint256 l1Bitmap = _binBitmapL1[l1Group];

            // Search for next L1 bit (higher L2 bucket) within current group
            (uint8 l1Bit, bool l1Found) = l1Bitmap.closestBitRight(l1Offset, false);
            if (l1Found) {
                uint16 newL1Index = (l1Group << 8) | uint16(l1Bit);
                uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                uint8 lsb = uint8(BitMath.leastSignificantBit(newL2Bitmap));
                return (uint24(newL1Index) << 8) | uint24(lsb);
            }

            // Cross L1 group boundary: search higher L1 groups
            for (uint16 g = l1Group + 1; g < 256; g++) {
                uint256 adjL1 = _binBitmapL1[g];
                if (adjL1 != 0) {
                    uint8 botL1 = uint8(BitMath.leastSignificantBit(adjL1));
                    uint16 newL1Index = (g << 8) | uint16(botL1);
                    uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                    uint8 lsb = uint8(BitMath.leastSignificantBit(newL2Bitmap));
                    return (uint24(newL1Index) << 8) | uint24(lsb);
                }
            }
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
            // First liquidity
            if (amountX > 0 && amountY > 0) {
                // Both tokens: shares = sqrt(amountX * amountY)
                shares = _sqrt(amountX * amountY);
            } else {
                // Single-sided: shares = amount of token being deposited
                shares = amountX > 0 ? amountX : amountY;
            }
        } else {
            // Proportional to existing liquidity
            if (bin.reserveX > 0 && amountX > 0) {
                uint256 shareX = (amountX * liquidity.totalShares) / uint256(bin.reserveX);
                shares = shareX;
            }
            if (bin.reserveY > 0 && amountY > 0) {
                uint256 shareY = (amountY * liquidity.totalShares) / uint256(bin.reserveY);
                shares = shares == 0 ? shareY : (shares < shareY ? shares : shareY);
            }
        }

        // Collect pending fees if user has existing position in this bin
        uint256 existingShares = _balances[to][binId];
        if (existingShares > 0) {
            (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[to][binId]);
            (uint256 pendingFeesX, uint256 pendingFeesY) = _calculatePendingFees(
                existingShares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
            );
            if (pendingFeesX > 0) _transfer(tokenX, to, pendingFeesX);
            if (pendingFeesY > 0) _transfer(tokenY, to, pendingFeesY);
            if (pendingFeesX > 0 || pendingFeesY > 0) {
                emit FeesCollected(to, to, pendingFeesX, pendingFeesY);
            }
        }

        // Update bin reserves
        bin.reserveX += uint112(amountX);
        bin.reserveY += uint112(amountY);
        _setBinState(binId, bin);

        // Update liquidity data
        liquidity.totalShares += uint128(shares);

        // Update user balance
        _balances[to][binId] += shares;

        // Snapshot fee debt at current feeGrowth for new total shares
        _updateFeeDebt(to, binId, _balances[to][binId], liquidity.feeGrowthX, liquidity.feeGrowthY);
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

        // Auto-collect pending fees before burning
        {
            (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[from][binId]);
            uint256 currentShares = _balances[from][binId];
            (uint256 pendingFeesX, uint256 pendingFeesY) = _calculatePendingFees(
                currentShares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
            );
            if (pendingFeesX > 0) _transfer(tokenX, from, pendingFeesX);
            if (pendingFeesY > 0) _transfer(tokenY, from, pendingFeesY);
            if (pendingFeesX > 0 || pendingFeesY > 0) {
                emit FeesCollected(from, from, pendingFeesX, pendingFeesY);
            }
        }

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

        // Update fee debt for remaining shares (or clear if fully exited)
        uint256 remainingShares = _balances[from][binId];
        if (remainingShares > 0) {
            _updateFeeDebt(from, binId, remainingShares, liquidity.feeGrowthX, liquidity.feeGrowthY);
        } else {
            _feeDebts[from][binId] = 0;
        }

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

    // =============================================================
    //                   FEE DEBT HELPERS
    // =============================================================

    /// @notice Pack two uint128 fee debts into a single uint256
    function _packFeeDebts(uint128 debtX, uint128 debtY) internal pure returns (uint256) {
        return uint256(debtX) | (uint256(debtY) << 128);
    }

    /// @notice Unpack a uint256 into two uint128 fee debts
    function _unpackFeeDebts(uint256 packed) internal pure returns (uint128 debtX, uint128 debtY) {
        debtX = uint128(packed);
        debtY = uint128(packed >> 128);
    }

    /// @notice Calculate pending unclaimed fees for a position
    function _calculatePendingFees(
        uint256 shares,
        uint128 feeGrowthX,
        uint128 feeGrowthY,
        uint128 debtX,
        uint128 debtY
    ) internal pure returns (uint256 pendingX, uint256 pendingY) {
        if (shares == 0) return (0, 0);
        pendingX = (shares * uint256(feeGrowthX)) / FEE_PRECISION - uint256(debtX);
        pendingY = (shares * uint256(feeGrowthY)) / FEE_PRECISION - uint256(debtY);
    }

    /// @notice Update fee debt snapshot for a user after shares change
    function _updateFeeDebt(
        address account,
        uint24 binId,
        uint256 newShares,
        uint128 feeGrowthX,
        uint128 feeGrowthY
    ) internal {
        uint128 newDebtX = uint128((newShares * uint256(feeGrowthX)) / FEE_PRECISION);
        uint128 newDebtY = uint128((newShares * uint256(feeGrowthY)) / FEE_PRECISION);
        _feeDebts[account][binId] = _packFeeDebts(newDebtX, newDebtY);
    }

    /// @notice Collect pending fees for a single bin (updates debt, no transfers)
    function _collectFeesForBin(
        address account,
        uint24 binId
    ) internal returns (uint256 pendingX, uint256 pendingY) {
        uint256 shares = _balances[account][binId];
        if (shares == 0) return (0, 0);

        BinState memory bin = _getBinState(binId);
        if (bin.liquidityIndex == 0) return (0, 0);

        LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];
        (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[account][binId]);

        (pendingX, pendingY) = _calculatePendingFees(
            shares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
        );

        if (pendingX > 0 || pendingY > 0) {
            _updateFeeDebt(account, binId, shares, liquidity.feeGrowthX, liquidity.feeGrowthY);
        }
    }

    /**
     * @notice Safe token transfer
     * @param token Token address
     * @param to Recipient
     * @param amount Amount to transfer
     */
    function _transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBPair: TRANSFER_FAILED"
        );
    }

    /**
     * @notice Safe token transferFrom
     * @param token Token address
     * @param from Sender
     * @param to Recipient
     * @param amount Amount to transfer
     */
    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBPair: TRANSFER_FROM_FAILED"
        );
    }
}
