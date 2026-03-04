// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBFactory} from "../domain/ports/ILBFactory.sol";
import {ILBPairTypes} from "../domain/kernel/ILBPairTypes.sol";
import {ILBPair} from "../domain/ports/ILBPair.sol";
import {LBPair} from "../domain/LBPair.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract LBFactory is ILBFactory, Initializable {

    address public override owner;

    address public override protocolFeeRecipient;

    address[] public override allPairs;

    mapping(uint16 => bool) public override isBinStepSupported;

    mapping(address => mapping(address => mapping(uint16 => address))) private _pairs;

    address public oracleModule;

    UpgradeableBeacon public beacon;

    uint16 public constant BIN_STEP_ULTRA_TIGHT = 10;
    uint16 public constant BIN_STEP_STANDARD = 50;
    uint16 public constant BIN_STEP_WIDE = 100;

    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _protocolFeeRecipient,
        address _implementation
    ) external initializer {
        if (_owner == address(0) || _protocolFeeRecipient == address(0) || _implementation == address(0)) {
            revert LBFactory__ZeroAddress();
        }

        owner = _owner;
        protocolFeeRecipient = _protocolFeeRecipient;

        beacon = new UpgradeableBeacon(_implementation, address(this));

        isBinStepSupported[BIN_STEP_ULTRA_TIGHT] = true;
        isBinStepSupported[BIN_STEP_STANDARD] = true;
        isBinStepSupported[BIN_STEP_WIDE] = true;
    }

    function getPair(
        address tokenX,
        address tokenY,
        uint16 binStep
    ) external view override returns (address pair) {
        (address token0, address token1) = _sortTokens(tokenX, tokenY);
        return _pairs[token0][token1][binStep];
    }

    function getAllPairs(
        address tokenX,
        address tokenY
    ) external view override returns (address[] memory pairs) {
        (address token0, address token1) = _sortTokens(tokenX, tokenY);

        uint256 count;
        if (_pairs[token0][token1][BIN_STEP_ULTRA_TIGHT] != address(0)) count++;
        if (_pairs[token0][token1][BIN_STEP_STANDARD] != address(0)) count++;
        if (_pairs[token0][token1][BIN_STEP_WIDE] != address(0)) count++;

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

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function createPair(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint24 activeId
    ) external override onlyOwner returns (address pair) {
        if (tokenX == address(0) || tokenY == address(0)) {
            revert LBFactory__ZeroAddress();
        }
        if (tokenX == tokenY) {
            revert LBFactory__IdenticalTokens();
        }
        if (!isBinStepSupported[binStep]) {
            revert LBFactory__InvalidBinStep(binStep);
        }

        _validateERC20(tokenX);
        _validateERC20(tokenY);

        (address token0, address token1) = _sortTokens(tokenX, tokenY);

        if (_pairs[token0][token1][binStep] != address(0)) {
            revert LBFactory__PairAlreadyExists(token0, token1, binStep);
        }

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, binStep));

        pair = address(new BeaconProxy{salt: salt}(address(beacon), ""));

        LBPair(pair).initialize(token0, token1, binStep, activeId, address(this));

        if (oracleModule != address(0)) {
            LBPair(pair).setOracle(oracleModule);
        }

        _pairs[token0][token1][binStep] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, binStep, pair, allPairs.length);
    }

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

    function setProtocolFeeRecipient(address recipient) external override onlyOwner {
        if (recipient == address(0)) revert LBFactory__ZeroAddress();

        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    address public pendingOwner;

    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert LBFactory__ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert LBFactory__Unauthorized(msg.sender);
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function setPairPaused(address pair, bool _paused) external onlyOwner {
        if (pair == address(0)) revert LBFactory__ZeroAddress();
        LBPair(pair).setPaused(_paused);
    }

    function setOracleModule(address _oracleModule) external onlyOwner {
        oracleModule = _oracleModule;
    }

    function setPairOracle(
        address pair,
        address _oracleModule
    ) external onlyOwner {
        if (pair == address(0)) revert LBFactory__ZeroAddress();
        LBPair(pair).setOracle(_oracleModule);
    }

    function upgradePairImplementation(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert LBFactory__ZeroAddress();
        beacon.upgradeTo(newImplementation);
    }

    function pairImplementation() external view returns (address) {
        return beacon.implementation();
    }

    function computePairAddress(
        address tokenA,
        address tokenB,
        uint16 _binStep
    ) external view override returns (address pair) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, _binStep));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BeaconProxy).creationCode,
                abi.encode(address(beacon), bytes(""))
            )
        );

        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            address(this),
            salt,
            initCodeHash
        )))));
    }

    function collectProtocolFees(
        address pair
    ) external override returns (uint256 amountX, uint256 amountY) {
        if (msg.sender != protocolFeeRecipient) {
            revert LBFactory__Unauthorized(msg.sender);
        }
        if (pair == address(0)) revert LBFactory__ZeroAddress();

        (amountX, amountY) = ILBPair(pair).collectProtocolFees();

        if (amountX > 0) {
            _safeTransfer(ILBPair(pair).tokenX(), protocolFeeRecipient, amountX);
        }
        if (amountY > 0) {
            _safeTransfer(ILBPair(pair).tokenY(), protocolFeeRecipient, amountY);
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBFactory: TRANSFER_FAILED"
        );
    }

    function _validateERC20(address token) private view {
        if (token.code.length == 0) revert LBFactory__NotERC20(token);

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (!success || data.length < 32) revert LBFactory__NotERC20(token);
    }

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

    modifier onlyOwner() {
        if (msg.sender != owner) revert LBFactory__Unauthorized(msg.sender);
        _;
    }
}
