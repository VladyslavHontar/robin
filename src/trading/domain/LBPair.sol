// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBPair} from "./ports/ILBPair.sol";
import {IOracleModule} from "./ports/IOracleModule.sol";
import {BinMath} from "./services/BinMath.sol";
import {BitMath} from "./services/BitMath.sol";
import {SwapHelper} from "./services/SwapHelper.sol";
import {FeeHelper} from "./services/FeeHelper.sol";
import {SafeCast} from "./services/SafeCast.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract LBPair is ILBPair, Initializable {
    using BinMath for uint24;
    using BitMath for uint256;

    uint256 private constant MAX_BINS_PER_OPERATION = 50;

    // Circuit breaker: a single swap may move the active bin by at most this many bins.
    // Must stay strictly below SwapHelper.MAX_BINS_PER_SWAP (the loop cap) so the check is live.
    uint24 private constant MAX_PRICE_MOVE_BINS = 50;

    uint256 private constant FEE_PRECISION = 1e18;

    /// @dev Shares permanently locked on the first deposit to each bin to defuse
    ///      first-depositor share-inflation / donation attacks.
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /// @dev Burn address that holds the locked minimum-liquidity shares (unrecoverable).
    address private constant DEAD_ADDRESS = address(0xdEaD);

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    address public override tokenX;

    address public override tokenY;

    uint16 public override binStep;

    address public factory;

    uint24 public override activeId;

    FeeParameters public feeParameters;

    uint256 public protocolFeesX;
    uint256 public protocolFeesY;

    uint256 private _status;

    address public oracle;

    bool public paused;

    mapping(uint24 => uint256) private _bins;

    mapping(uint16 => uint256) private _binBitmapL1;

    mapping(uint16 => uint256) private _binBitmapL2;

    mapping(uint32 => LiquidityData) private _liquidityData;

    mapping(address => mapping(uint24 => uint256)) private _balances;

    uint32 private _nextLiquidityIndex;

    mapping(address => mapping(uint24 => uint256)) private _feeDebts;

    /// @notice Hard-halt threshold: max bins the post-swap price may deviate from the oracle.
    ///         0 disables the check. Configured by the factory.
    uint24 public maxOracleDeviationBins;

    uint256[46] private __gap;

    modifier nonReentrant() {
        if (_status == ENTERED) revert LBPair__Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert LBPair__Unauthorized(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert LBPair__Paused();
        _;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert LBPair__DeadlineExceeded(deadline, block.timestamp);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _tokenX,
        address _tokenY,
        uint16 _binStep,
        uint24 _activeId,
        address _factory
    ) external initializer {
        if (_tokenX == address(0) || _tokenY == address(0)) revert LBPair__ZeroAddress();
        if (_tokenX == _tokenY) revert LBPair__ZeroAddress();
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

        feeParameters = FeeHelper.getDefaultStockFeeParameters();
        feeParameters.volatilityReference = _activeId;

        _nextLiquidityIndex = 1;

        // Default oracle deviation circuit breaker (bins). Operator can retune via the factory.
        maxOracleDeviationBins = 50;
    }

    function getBinReserves(
        uint24 binId
    ) external view override returns (uint128 reserveX, uint128 reserveY) {
        BinState memory bin = _getBinState(binId);
        return (uint128(bin.reserveX), uint128(bin.reserveY));
    }

    function getNextNonEmptyBin(
        uint24 binId,
        bool swapForY
    ) public view override returns (uint24 nextBinId) {
        return _getNextNonEmptyBin(binId, swapForY);
    }

    function getFeeParameters() external view override returns (FeeParameters memory) {
        return feeParameters;
    }

    function getTotalShares(uint24 binId) external view override returns (uint256) {
        BinState memory bin = _getBinState(binId);
        if (bin.liquidityIndex == 0) return 0;
        return _liquidityData[bin.liquidityIndex].totalShares;
    }

    function balanceOf(
        address account,
        uint24 binId
    ) external view override returns (uint256) {
        return _balances[account][binId];
    }

    function getSwapOut(
        bool swapForY,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, uint256 fees) {
        uint24 startBinId = activeId;
        uint256 amountInRemaining = amountIn;
        uint24 currentBinId = startBinId;
        uint24 binsCrossed;

        uint256 oracleDeviationFeeBps;
        if (oracle != address(0)) {
            oracleDeviationFeeBps = IOracleModule(oracle).getDeviationFee(address(this), startBinId);
        }

        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);
            uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

            if (reserveOut == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId, oracleDeviationFeeBps);

            uint256 price = BinMath.getPriceFromId(currentBinId, binStep);

            uint256 maxEffectiveInput = swapForY
                ? BinMath._mulDivDown(reserveOut, BinMath.SCALE, price)
                : BinMath._mulDivDown(reserveOut, price, BinMath.SCALE);

            if (maxEffectiveInput == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            uint256 maxTotalInput =
                (maxEffectiveInput * FeeHelper.BASIS_POINT_MAX) / (FeeHelper.BASIS_POINT_MAX - feeBps);
            uint256 totalConsumed = amountInRemaining < maxTotalInput ? amountInRemaining : maxTotalInput;

            (uint256 binFee, uint256 effectiveInput) = FeeHelper.calculateFee(totalConsumed, feeBps);

            uint256 binAmountOut;
            if (totalConsumed >= maxTotalInput) {
                binAmountOut = reserveOut;
            } else {
                binAmountOut = swapForY
                    ? BinMath._mulDivDown(effectiveInput, price, BinMath.SCALE)
                    : BinMath._mulDivDown(effectiveInput, BinMath.SCALE, price);
                if (binAmountOut > reserveOut) binAmountOut = reserveOut;
            }

            amountOut += binAmountOut;
            fees += binFee;
            amountInRemaining -= totalConsumed;

            if (binAmountOut >= reserveOut) {
                binsCrossed++;
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, swapForY);
                if (nextBin == currentBinId) break;
                currentBinId = nextBin;
            } else {
                break;
            }
        }
    }

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

    function swap(
        SwapParameters calldata params
    ) external override nonReentrant whenNotPaused ensure(params.deadline) returns (SwapResult memory result) {
        if (params.amountIn == 0) revert LBPair__ZeroAmount();
        if (params.to == address(0)) revert LBPair__ZeroAddress();

        uint24 startBinId = activeId;
        uint256 amountInRemaining = params.amountIn;
        uint256 totalAmountOut;
        uint256 totalFees;
        uint24 currentBinId = startBinId;
        uint24 binsCrossed;

        uint256 oracleDeviationFeeBps;
        if (oracle != address(0)) {
            try IOracleModule(oracle).getDeviationFee(address(this), startBinId) returns (uint256 fee) {
                oracleDeviationFeeBps = fee;
            } catch {
                oracleDeviationFeeBps = 0;
            }
        }

        while (amountInRemaining > 0 && binsCrossed < SwapHelper.MAX_BINS_PER_SWAP) {
            BinState memory bin = _getBinState(currentBinId);

            uint256 reserveOut = params.swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

            if (reserveOut == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            uint256 feeBps = FeeHelper.getTotalFee(feeParameters, startBinId, currentBinId, oracleDeviationFeeBps);

            // Price of the current bin, scaled by BinMath.SCALE (units of Y per 1 unit of X).
            uint256 price = BinMath.getPriceFromId(currentBinId, binStep);

            // Effective (post-fee) input that exactly drains `reserveOut` of the output token,
            // converted through the bin price.
            uint256 maxEffectiveInput = params.swapForY
                ? BinMath._mulDivDown(reserveOut, BinMath.SCALE, price)
                : BinMath._mulDivDown(reserveOut, price, BinMath.SCALE);

            // Output reserve is sub-unit relative to the input token at this price; skip the bin
            // instead of giving it away for zero input.
            if (maxEffectiveInput == 0) {
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break;
                binsCrossed++;
                currentBinId = nextBin;
                continue;
            }

            uint256 maxTotalInput =
                (maxEffectiveInput * FeeHelper.BASIS_POINT_MAX) / (FeeHelper.BASIS_POINT_MAX - feeBps);
            uint256 totalConsumed = amountInRemaining < maxTotalInput ? amountInRemaining : maxTotalInput;

            (uint256 binFee, uint256 effectiveInput) = FeeHelper.calculateFee(totalConsumed, feeBps);

            uint256 binAmountOut;
            if (totalConsumed >= maxTotalInput) {
                // Enough input to fully drain this bin; pin output to the reserve to avoid dust.
                binAmountOut = reserveOut;
            } else {
                binAmountOut = params.swapForY
                    ? BinMath._mulDivDown(effectiveInput, price, BinMath.SCALE)
                    : BinMath._mulDivDown(effectiveInput, BinMath.SCALE, price);
                if (binAmountOut > reserveOut) binAmountOut = reserveOut;
            }

            (uint256 lpFee, uint256 protocolFee) = FeeHelper.splitFee(binFee, feeParameters.protocolShare);

            totalAmountOut += binAmountOut;
            totalFees += binFee;
            amountInRemaining -= totalConsumed;

            if (params.swapForY) {
                bin.reserveX += SafeCast.toUint112(effectiveInput);
                bin.reserveY -= SafeCast.toUint112(binAmountOut);
            } else {
                bin.reserveY += SafeCast.toUint112(effectiveInput);
                bin.reserveX -= SafeCast.toUint112(binAmountOut);
            }
            _setBinState(currentBinId, bin);

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

            if (params.swapForY) {
                protocolFeesX += protocolFee;
            } else {
                protocolFeesY += protocolFee;
            }

            if (binAmountOut >= reserveOut) {
                binsCrossed++;
                uint24 nextBin = _getNextNonEmptyBin(currentBinId, params.swapForY);
                if (nextBin == currentBinId) break;
                currentBinId = nextBin;
            } else {
                break;
            }
        }

        uint256 actualAmountIn = params.amountIn - amountInRemaining;

        if (totalAmountOut < params.minAmountOut) {
            revert LBPair__SlippageExceeded(totalAmountOut, params.minAmountOut);
        }

        if (binsCrossed > MAX_PRICE_MOVE_BINS) {
            revert LBPair__ExcessivePriceMove(startBinId, currentBinId, MAX_PRICE_MOVE_BINS);
        }

        // Hard-halt: refuse swaps that push the DEX price too far from the oracle (manipulation /
        // stale-pool protection for RWAs). Disabled when oracle unset or threshold is 0.
        if (oracle != address(0) && maxOracleDeviationBins > 0) {
            try IOracleModule(oracle).getOracleBinId(address(this)) returns (uint24 oracleBinId, bool isValid) {
                if (isValid) {
                    uint24 deviation = currentBinId > oracleBinId
                        ? currentBinId - oracleBinId
                        : oracleBinId - currentBinId;
                    if (deviation > maxOracleDeviationBins) {
                        revert LBPair__OracleDeviationTooHigh(currentBinId, oracleBinId, maxOracleDeviationBins);
                    }
                }
            } catch {}
        }

        if (currentBinId != activeId) {
            emit ActiveBinChanged(activeId, currentBinId);
            activeId = currentBinId;
        }

        if (params.swapForY) {
            _transferFrom(tokenX, msg.sender, address(this), actualAmountIn);
            _transfer(tokenY, params.to, totalAmountOut);
        } else {
            _transferFrom(tokenY, msg.sender, address(this), actualAmountIn);
            _transfer(tokenX, params.to, totalAmountOut);
        }

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

    function mint(
        LiquidityParameters calldata params
    ) external override nonReentrant whenNotPaused ensure(params.deadline) returns (uint256[] memory shares) {
        if (params.binIds.length == 0) revert LBPair__InvalidLiquidityDistribution();
        if (params.binIds.length != params.distributionX.length || params.binIds.length != params.distributionY.length) {
            revert LBPair__InvalidLiquidityDistribution();
        }
        if (params.binIds.length > MAX_BINS_PER_OPERATION) {
            revert LBPair__TooManyBins(params.binIds.length, MAX_BINS_PER_OPERATION);
        }
        if (params.to == address(0)) revert LBPair__ZeroAddress();

        uint256 activeIdDesired = params.activeIdDesired;
        uint256 idSlippage = params.idSlippage;
        uint256 minBinId = activeIdDesired > idSlippage ? activeIdDesired - idSlippage : 0;
        uint256 maxBinId = activeIdDesired + idSlippage;
        if (uint256(activeId) < minBinId || uint256(activeId) > maxBinId) {
            revert LBPair__InvalidActiveId(activeId);
        }

        shares = new uint256[](params.binIds.length);
        uint256 totalAmountX;
        uint256 totalAmountY;
        uint256 totalPendingFeesX;
        uint256 totalPendingFeesY;

        for (uint256 i = 0; i < params.binIds.length; i++) {
            uint24 binId = params.binIds[i];

            uint256 amountX = (params.amountX * params.distributionX[i]) / 1e18;
            uint256 amountY = (params.amountY * params.distributionY[i]) / 1e18;

            if (amountX == 0 && amountY == 0) continue;

            (uint256 mintShares, uint256 pfX, uint256 pfY) = _addLiquidityToBin(binId, amountX, amountY, params.to);
            shares[i] = mintShares;
            totalPendingFeesX += pfX;
            totalPendingFeesY += pfY;

            totalAmountX += amountX;
            totalAmountY += amountY;
        }

        if (totalAmountX > 0) {
            uint256 balBefore = IERC20(tokenX).balanceOf(address(this));
            _transferFrom(tokenX, msg.sender, address(this), totalAmountX);
            if (IERC20(tokenX).balanceOf(address(this)) < balBefore + totalAmountX) {
                revert LBPair__TransferFailed();
            }
        }
        if (totalAmountY > 0) {
            uint256 balBefore = IERC20(tokenY).balanceOf(address(this));
            _transferFrom(tokenY, msg.sender, address(this), totalAmountY);
            if (IERC20(tokenY).balanceOf(address(this)) < balBefore + totalAmountY) {
                revert LBPair__TransferFailed();
            }
        }

        if (totalPendingFeesX > 0) _transfer(tokenX, params.to, totalPendingFeesX);
        if (totalPendingFeesY > 0) _transfer(tokenY, params.to, totalPendingFeesY);
        if (totalPendingFeesX > 0 || totalPendingFeesY > 0) {
            emit FeesCollected(params.to, params.to, totalPendingFeesX, totalPendingFeesY);
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

    function burn(
        RemoveLiquidityParameters calldata params
    )
        external
        override
        nonReentrant
        whenNotPaused
        ensure(params.deadline)
        returns (uint256 amountX, uint256 amountY)
    {
        if (params.binIds.length == 0) revert LBPair__InvalidLiquidityDistribution();
        if (params.to == address(0)) revert LBPair__ZeroAddress();

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

        if (amountX < params.minAmountX || amountY < params.minAmountY) {
            revert LBPair__SlippageExceeded(amountX < amountY ? amountX : amountY, 0);
        }

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

    function setFeeParameters(
        FeeParameters calldata _feeParams
    ) external override onlyFactory {
        FeeHelper.validateFeeParameters(_feeParams);
        feeParameters = _feeParams;
        emit FeeParametersSet(_feeParams.baseFee, _feeParams.maxVolatilityFee);
    }

    function setOracle(address _oracle) external onlyFactory {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    /// @notice Set the oracle deviation circuit breaker (in bins). 0 disables the check.
    function setMaxOracleDeviationBins(uint24 _maxDeviationBins) external onlyFactory {
        maxOracleDeviationBins = _maxDeviationBins;
        emit MaxOracleDeviationBinsSet(_maxDeviationBins);
    }

    function setPaused(bool _paused) external onlyFactory {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    function collectProtocolFees()
        external
        override
        onlyFactory
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        amountX = protocolFeesX;
        amountY = protocolFeesY;

        protocolFeesX = 0;
        protocolFeesY = 0;

        if (amountX > 0) {
            _transfer(tokenX, msg.sender, amountX);
        }
        if (amountY > 0) {
            _transfer(tokenY, msg.sender, amountY);
        }

        emit ProtocolFeesCollected(amountX, amountY);
    }

    function _getBinState(uint24 binId) internal view returns (BinState memory bin) {
        uint256 packed = _bins[binId];
        bin.reserveX = uint112(packed);
        bin.reserveY = uint112(packed >> 112);
        bin.liquidityIndex = uint32(packed >> 224);
    }

    function _setBinState(uint24 binId, BinState memory bin) internal {
        _bins[binId] =
            uint256(bin.reserveX) |
            (uint256(bin.reserveY) << 112) |
            (uint256(bin.liquidityIndex) << 224);
    }

    function _getNextNonEmptyBin(uint24 binId, bool swapForY) internal view returns (uint24) {
        uint16 l1Index = uint16(binId >> 8);
        uint8 l2Offset = uint8(binId);

        uint256 l2Bitmap = _binBitmapL2[l1Index];

        if (swapForY) {
            (uint8 bit, bool found) = l2Bitmap.closestBitLeft(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }

            uint16 l1Group = l1Index >> 8;
            uint8 l1Offset = uint8(l1Index);
            uint256 l1Bitmap = _binBitmapL1[l1Group];

            (uint8 l1Bit, bool l1Found) = l1Bitmap.closestBitLeft(l1Offset, false);
            if (l1Found) {
                uint16 newL1Index = (l1Group << 8) | uint16(l1Bit);
                uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                uint8 msb = uint8(BitMath.mostSignificantBit(newL2Bitmap));
                return (uint24(newL1Index) << 8) | uint24(msb);
            }

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
            (uint8 bit, bool found) = l2Bitmap.closestBitRight(l2Offset, false);
            if (found) {
                return (uint24(l1Index) << 8) | uint24(bit);
            }

            uint16 l1Group = l1Index >> 8;
            uint8 l1Offset = uint8(l1Index);
            uint256 l1Bitmap = _binBitmapL1[l1Group];

            (uint8 l1Bit, bool l1Found) = l1Bitmap.closestBitRight(l1Offset, false);
            if (l1Found) {
                uint16 newL1Index = (l1Group << 8) | uint16(l1Bit);
                uint256 newL2Bitmap = _binBitmapL2[newL1Index];
                uint8 lsb = uint8(BitMath.leastSignificantBit(newL2Bitmap));
                return (uint24(newL1Index) << 8) | uint24(lsb);
            }

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

        return binId;
    }

    function _addLiquidityToBin(
        uint24 binId,
        uint256 amountX,
        uint256 amountY,
        address to
    ) internal returns (uint256 shares, uint256 pendingFeesX, uint256 pendingFeesY) {
        BinState memory bin = _getBinState(binId);

        if (bin.liquidityIndex == 0) {
            bin.liquidityIndex = _nextLiquidityIndex++;
            _setBitmapBit(binId, true);
            emit BinInitialized(binId);
        }

        LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];

        if (liquidity.totalShares == 0) {
            uint256 initialShares = (amountX > 0 && amountY > 0)
                ? _sqrt(amountX * amountY)
                : (amountX > 0 ? amountX : amountY);

            // Permanently lock MINIMUM_LIQUIDITY shares to the burn address on the first deposit
            // so totalShares can never be driven to a tiny value, defusing share-inflation /
            // donation attacks against later depositors.
            if (initialShares <= MINIMUM_LIQUIDITY) {
                revert LBPair__InsufficientLiquidityMinted();
            }
            liquidity.totalShares += SafeCast.toUint128(MINIMUM_LIQUIDITY);
            _balances[DEAD_ADDRESS][binId] += MINIMUM_LIQUIDITY;

            shares = initialShares - MINIMUM_LIQUIDITY;
        } else {
            if (bin.reserveX > 0 && amountX > 0) {
                uint256 shareX = (amountX * liquidity.totalShares) / uint256(bin.reserveX);
                shares = shareX;
            }
            if (bin.reserveY > 0 && amountY > 0) {
                uint256 shareY = (amountY * liquidity.totalShares) / uint256(bin.reserveY);
                shares = shares == 0 ? shareY : (shares < shareY ? shares : shareY);
            }
        }

        if (shares == 0 && (amountX > 0 || amountY > 0)) revert LBPair__ZeroAmount();

        uint256 existingShares = _balances[to][binId];
        if (existingShares > 0) {
            (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[to][binId]);
            (pendingFeesX, pendingFeesY) = _calculatePendingFees(
                existingShares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
            );
        }

        bin.reserveX += SafeCast.toUint112(amountX);
        bin.reserveY += SafeCast.toUint112(amountY);
        _setBinState(binId, bin);

        liquidity.totalShares += SafeCast.toUint128(shares);
        _balances[to][binId] += shares;

        _updateFeeDebt(to, binId, _balances[to][binId], liquidity.feeGrowthX, liquidity.feeGrowthY);

        if (pendingFeesX > 0 || pendingFeesY > 0) {
            emit FeesCollected(to, to, pendingFeesX, pendingFeesY);
        }
    }

    function _removeLiquidityFromBin(
        uint24 binId,
        uint256 shares,
        address from
    ) internal returns (uint256 amountX, uint256 amountY) {
        if (_balances[from][binId] < shares) {
            revert LBPair__InsufficientShares(shares, _balances[from][binId]);
        }

        BinState memory bin = _getBinState(binId);
        LiquidityData storage liquidity = _liquidityData[bin.liquidityIndex];

        uint256 pendingFeesX;
        uint256 pendingFeesY;
        {
            (uint128 debtX, uint128 debtY) = _unpackFeeDebts(_feeDebts[from][binId]);
            uint256 currentShares = _balances[from][binId];
            (pendingFeesX, pendingFeesY) = _calculatePendingFees(
                currentShares, liquidity.feeGrowthX, liquidity.feeGrowthY, debtX, debtY
            );
        }

        amountX = (shares * uint256(bin.reserveX)) / liquidity.totalShares;
        amountY = (shares * uint256(bin.reserveY)) / liquidity.totalShares;

        bin.reserveX -= SafeCast.toUint112(amountX);
        bin.reserveY -= SafeCast.toUint112(amountY);

        liquidity.totalShares -= SafeCast.toUint128(shares);
        _balances[from][binId] -= shares;

        uint256 remainingShares = _balances[from][binId];
        if (remainingShares > 0) {
            _updateFeeDebt(from, binId, remainingShares, liquidity.feeGrowthX, liquidity.feeGrowthY);
        } else {
            _feeDebts[from][binId] = 0;
        }

        if (liquidity.totalShares == 0) {
            _setBitmapBit(binId, false);
            emit BinEmptied(binId);
        }

        _setBinState(binId, bin);

        if (pendingFeesX > 0) _transfer(tokenX, from, pendingFeesX);
        if (pendingFeesY > 0) _transfer(tokenY, from, pendingFeesY);
        if (pendingFeesX > 0 || pendingFeesY > 0) {
            emit FeesCollected(from, from, pendingFeesX, pendingFeesY);
        }
    }

    function _setBitmapBit(uint24 binId, bool set) internal {
        uint16 l1Index = uint16(binId >> 8);
        uint8 l2Offset = uint8(binId);

        if (set) {
            _binBitmapL2[l1Index] = _binBitmapL2[l1Index].setBit(l2Offset);
            _binBitmapL1[l1Index >> 8] = _binBitmapL1[l1Index >> 8].setBit(uint8(l1Index));
        } else {
            _binBitmapL2[l1Index] = _binBitmapL2[l1Index].clearBit(l2Offset);
            if (_binBitmapL2[l1Index] == 0) {
                _binBitmapL1[l1Index >> 8] = _binBitmapL1[l1Index >> 8].clearBit(
                    uint8(l1Index)
                );
            }
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _packFeeDebts(uint128 debtX, uint128 debtY) internal pure returns (uint256) {
        return uint256(debtX) | (uint256(debtY) << 128);
    }

    function _unpackFeeDebts(uint256 packed) internal pure returns (uint128 debtX, uint128 debtY) {
        debtX = uint128(packed);
        debtY = uint128(packed >> 128);
    }

    function _calculatePendingFees(
        uint256 shares,
        uint128 feeGrowthX,
        uint128 feeGrowthY,
        uint128 debtX,
        uint128 debtY
    ) internal pure returns (uint256 pendingX, uint256 pendingY) {
        if (shares == 0) return (0, 0);
        uint256 earnedX = (shares * uint256(feeGrowthX)) / FEE_PRECISION;
        uint256 earnedY = (shares * uint256(feeGrowthY)) / FEE_PRECISION;
        pendingX = earnedX > uint256(debtX) ? earnedX - uint256(debtX) : 0;
        pendingY = earnedY > uint256(debtY) ? earnedY - uint256(debtY) : 0;
    }

    function _updateFeeDebt(
        address account,
        uint24 binId,
        uint256 newShares,
        uint128 feeGrowthX,
        uint128 feeGrowthY
    ) internal {
        uint128 newDebtX = SafeCast.toUint128((newShares * uint256(feeGrowthX)) / FEE_PRECISION);
        uint128 newDebtY = SafeCast.toUint128((newShares * uint256(feeGrowthY)) / FEE_PRECISION);
        _feeDebts[account][binId] = _packFeeDebts(newDebtX, newDebtY);
    }

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

    function _transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert LBPair__TransferFailed();
        }
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert LBPair__TransferFailed();
        }
    }
}
