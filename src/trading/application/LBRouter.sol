// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBFactory} from "../domain/ports/ILBFactory.sol";
import {ILBPair} from "../domain/ports/ILBPair.sol";
import {ILBPairTypes} from "../domain/kernel/ILBPairTypes.sol";
import {IOracleModule} from "../domain/ports/IOracleModule.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract LBRouter is Initializable {

    error LBRouter__ZeroAddress();
    error LBRouter__InvalidPath();
    error LBRouter__InsufficientAmountOut();
    error LBRouter__ExcessiveAmountIn();
    error LBRouter__InvalidDistribution();
    error LBRouter__PairNotFound();
    error LBRouter__DeadlineExceeded();
    error LBRouter__InvalidBinRange();
    error LBRouter__OracleNotSet();
    error LBRouter__Unauthorized();

    ILBFactory public factory;

    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _factory) external initializer {
        if (_factory == address(0)) revert LBRouter__ZeroAddress();
        factory = ILBFactory(_factory);
    }

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

        address pair = factory.getPair(tokenIn, tokenOut, binStep);
        if (pair == address(0)) revert LBRouter__PairNotFound();

        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        _safeApprove(tokenIn, pair, amountIn);

        bool swapForY = tokenIn < tokenOut;

        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            to: to
        });

        ILBPairTypes.SwapResult memory result = ILBPair(pair).swap(params);
        amountOut = result.amountOut;

        _safeApprove(tokenIn, pair, 0);

        // Refund excess tokens on partial fills
        uint256 remaining = IERC20(tokenIn).balanceOf(address(this));
        if (remaining > 0) {
            _safeTransfer(tokenIn, msg.sender, remaining);
        }

        if (amountOut < minAmountOut) {
            revert LBRouter__InsufficientAmountOut();
        }
    }

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

        address pairTokenX = ILBPair(pair).tokenX();
        address pairTokenY = ILBPair(pair).tokenY();
        bool validTokens = (tokenIn == pairTokenX && tokenOut == pairTokenY)
                        || (tokenIn == pairTokenY && tokenOut == pairTokenX);
        if (!validTokens) revert LBRouter__InvalidPath();

        uint16 pairBinStep = ILBPair(pair).binStep();
        address registeredPair = factory.getPair(pairTokenX, pairTokenY, pairBinStep);
        if (registeredPair != pair) revert LBRouter__PairNotFound();

        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        _safeApprove(tokenIn, pair, amountIn);

        bool swapForY = tokenIn < tokenOut;

        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            to: to
        });

        ILBPairTypes.SwapResult memory result = ILBPair(pair).swap(params);
        amountOut = result.amountOut;

        _safeApprove(tokenIn, pair, 0);

        // Refund excess tokens on partial fills
        uint256 remaining = IERC20(tokenIn).balanceOf(address(this));
        if (remaining > 0) {
            _safeTransfer(tokenIn, msg.sender, remaining);
        }

        if (amountOut < minAmountOut) {
            revert LBRouter__InsufficientAmountOut();
        }
    }

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

        if (amountX > 0) {
            _safeTransferFrom(tokenX, msg.sender, address(this), amountX);
            _safeApprove(tokenX, pair, amountX);
        }
        if (amountY > 0) {
            _safeTransferFrom(tokenY, msg.sender, address(this), amountY);
            _safeApprove(tokenY, pair, amountY);
        }

        (uint24[] memory binIds, uint64[] memory distX, uint64[] memory distY) =
            _generateUniformDistribution(activeBinId, binRange);

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: activeBinId,
            idSlippage: 5,
            deadline: deadline,
            to: to
        });

        shares = ILBPair(pair).mint(params);

        if (amountX > 0) _safeApprove(tokenX, pair, 0);
        if (amountY > 0) _safeApprove(tokenY, pair, 0);
    }

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

        if (amountX > 0) {
            _safeTransferFrom(tokenX, msg.sender, address(this), amountX);
            _safeApprove(tokenX, pair, amountX);
        }
        if (amountY > 0) {
            _safeTransferFrom(tokenY, msg.sender, address(this), amountY);
            _safeApprove(tokenY, pair, amountY);
        }

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = binId;

        uint64[] memory distX = new uint64[](1);
        distX[0] = 1e18;

        uint64[] memory distY = new uint64[](1);
        distY[0] = 1e18;

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: binId,
            idSlippage: 0,
            deadline: deadline,
            to: to
        });

        shares = ILBPair(pair).mint(params);

        if (amountX > 0) _safeApprove(tokenX, pair, 0);
        if (amountY > 0) _safeApprove(tokenY, pair, 0);
    }

    /// @notice Sweep stuck tokens from the Router (e.g. from partial fills or rounding)
    function sweepToken(address token, address to) external {
        if (msg.sender != factory.owner()) revert LBRouter__Unauthorized();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            _safeTransfer(token, to, balance);
        }
    }

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

    function _generateUniformDistribution(
        uint24 activeBinId,
        uint24 binRange
    ) internal pure returns (
        uint24[] memory binIds,
        uint64[] memory distX,
        uint64[] memory distY
    ) {
        if (binRange == 0 || binRange > 100) revert LBRouter__InvalidBinRange();
        if (uint256(activeBinId) < uint256(binRange)) revert LBRouter__InvalidBinRange();

        uint256 totalBins = uint256(binRange) * 2 + 1;
        binIds = new uint24[](totalBins);
        distX = new uint64[](totalBins);
        distY = new uint64[](totalBins);

        uint64 sharePerBin = uint64(1e18 / totalBins);
        uint256 centerIndex = uint256(binRange);

        for (uint256 i = 0; i < totalBins; i++) {
            binIds[i] = uint24(uint256(activeBinId) - uint256(binRange) + i);

            if (binIds[i] < activeBinId) {
                distX[i] = 0;
                distY[i] = sharePerBin;
            } else if (binIds[i] > activeBinId) {
                distX[i] = sharePerBin;
                distY[i] = 0;
            } else {
                distX[i] = sharePerBin / 2;
                distY[i] = sharePerBin / 2;
            }
        }

        // Assign rounding remainder to center bin
        uint64 remainder = uint64(1e18 - sharePerBin * uint64(totalBins));
        if (remainder > 0) {
            distX[centerIndex] += remainder / 2;
            distY[centerIndex] += remainder - remainder / 2;
        }
    }

    function generateNormalDistribution(
        uint24 activeBinId,
        uint24 binRange
    ) external pure returns (
        uint24[] memory binIds,
        uint64[] memory distX,
        uint64[] memory distY
    ) {
        if (binRange == 0 || binRange > 100) revert LBRouter__InvalidBinRange();
        if (uint256(activeBinId) < uint256(binRange)) revert LBRouter__InvalidBinRange();

        uint256 totalBins = uint256(binRange) * 2 + 1;
        binIds = new uint24[](totalBins);
        distX = new uint64[](totalBins);
        distY = new uint64[](totalBins);

        uint256 totalWeight;

        uint256[] memory weights = new uint256[](totalBins);
        for (uint256 i = 0; i < totalBins; i++) {
            int256 distance = int256(i) - int256(uint256(binRange));

            uint256 distSquared = uint256(distance * distance);
            weights[i] = 100e18 / (1e18 + distSquared * 1e18);
            totalWeight += weights[i];
        }

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

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert LBRouter__DeadlineExceeded();
    }

    function calculateOptimalBinRange(
        uint16 binStep,
        uint256 expectedVolatilityBps
    ) external pure returns (uint24 binRange) {
        binRange = uint24((expectedVolatilityBps * 100) / uint256(binStep));

        if (binRange < 5) binRange = 5;
        if (binRange > 100) binRange = 100;
    }

    function getRecommendedBinStep(
        uint256 expectedDailyVolatilityBps
    ) external pure returns (uint16 binStep) {
        if (expectedDailyVolatilityBps < 50) {
            return 10;
        }
        else if (expectedDailyVolatilityBps < 200) {
            return 50;
        }
        else {
            return 100;
        }
    }

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

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBRouter: TRANSFER_FAILED"
        );
    }

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
