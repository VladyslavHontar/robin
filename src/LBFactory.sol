// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBFactory} from "./interfaces/ILBFactory.sol";
import {ILBPairTypes} from "./interfaces/ILBPairTypes.sol";
import {ILBPair} from "./interfaces/ILBPair.sol";
import {LBPair} from "./LBPair.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";

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

    /// @notice Oracle module address (optional)
    address public oracleModule;

    /// @notice Upgradeable beacon — all pairs are BeaconProxies pointing here
    UpgradeableBeacon public beacon;

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
     * @param _implementation LBPair implementation contract address
     */
    constructor(address _owner, address _protocolFeeRecipient, address _implementation) {
        if (_owner == address(0) || _protocolFeeRecipient == address(0) || _implementation == address(0)) {
            revert LBFactory__ZeroAddress();
        }

        owner = _owner;
        protocolFeeRecipient = _protocolFeeRecipient;

        // Deploy beacon — all pair proxies will point here.
        // The owner of the beacon is this factory; upgrade via upgradePairImplementation().
        beacon = new UpgradeableBeacon(_implementation, address(this));

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

        // Validate both addresses are ERC20 contracts
        _validateERC20(tokenX);
        _validateERC20(tokenY);

        // Sort tokens (token0 < token1)
        (address token0, address token1) = _sortTokens(tokenX, tokenY);

        // Check if pair already exists
        if (_pairs[token0][token1][binStep] != address(0)) {
            revert LBFactory__PairAlreadyExists(token0, token1, binStep);
        }

        // CREATE2: deterministic address derived from (token0, token1, binStep) only.
        // activeId is NOT part of the salt — the address is derivable offline without
        // knowing the initial price, exactly like Solana PDA derivation.
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, binStep));

        // Deploy proxy with empty init data — initialize() is called below in the same
        // transaction, so there is no window for frontrunning.
        pair = address(new BeaconProxy{salt: salt}(address(beacon), ""));

        // Initialize atomically (same tx as deploy — cannot be frontrun)
        LBPair(pair).initialize(token0, token1, binStep, activeId, address(this));

        // Set oracle module if configured
        if (oracleModule != address(0)) {
            LBPair(pair).setOracle(oracleModule);
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
     * @notice Set the oracle module for all new pairs
     * @param _oracleModule OracleModule address (address(0) to disable)
     */
    function setOracleModule(address _oracleModule) external onlyOwner {
        oracleModule = _oracleModule;
    }

    /**
     * @notice Set oracle module on an existing pair
     * @param pair Pair address
     * @param _oracleModule OracleModule address (address(0) to disable)
     */
    function setPairOracle(
        address pair,
        address _oracleModule
    ) external onlyOwner {
        if (pair == address(0)) revert LBFactory__ZeroAddress();
        LBPair(pair).setOracle(_oracleModule);
    }

    /**
     * @notice Upgrade the LBPair implementation for ALL pairs (owner only)
     * @dev This is the Solana-equivalent of redeploying the program — all BeaconProxies
     *      instantly delegate to the new implementation, while pair state is preserved.
     * @param newImplementation New LBPair implementation address
     */
    function upgradePairImplementation(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert LBFactory__ZeroAddress();
        beacon.upgradeTo(newImplementation);
    }

    /**
     * @notice Get the current LBPair implementation address
     * @return Current implementation address
     */
    function pairImplementation() external view returns (address) {
        return beacon.implementation();
    }

    /**
     * @notice Compute the deterministic address of a pair — no chain query needed.
     * @dev Equivalent to Solana PDA derivation. Works before the pair exists.
     *
     *      address = keccak256(0xff ++ factory ++ salt ++ initCodeHash)
     *      salt    = keccak256(token0 ++ token1 ++ binStep)   (token0 < token1)
     *      initCodeHash = keccak256(BeaconProxy.creationCode ++ abi.encode(beacon, ""))
     *
     * @param tokenA One token (order doesn't matter)
     * @param tokenB Other token
     * @param _binStep Bin step in basis points
     * @return pair Deterministic pair address
     */
    function computePairAddress(
        address tokenA,
        address tokenB,
        uint16 _binStep
    ) external view override returns (address pair) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, _binStep));

        // Init code hash: BeaconProxy deployed with (beacon, "") constructor args.
        // This is constant for all pairs within this factory (same beacon address).
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

    /**
     * @notice Collect protocol fees from a pair (fee recipient only)
     * @dev Pair transfers fees to factory, factory forwards to fee recipient.
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

        // Pair sends fees to this factory
        (amountX, amountY) = ILBPair(pair).collectProtocolFees();

        // Forward fees from factory to the fee recipient
        if (amountX > 0) {
            _safeTransfer(ILBPair(pair).tokenX(), protocolFeeRecipient, amountX);
        }
        if (amountY > 0) {
            _safeTransfer(ILBPair(pair).tokenY(), protocolFeeRecipient, amountY);
        }
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Safe ERC20 transfer
     * @param token Token address
     * @param to Recipient
     * @param amount Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "LBFactory: TRANSFER_FAILED"
        );
    }

    /**
     * @notice Validate that an address is an ERC20 token contract
     * @param token Address to validate
     */
    function _validateERC20(address token) private view {
        if (token.code.length == 0) revert LBFactory__NotERC20(token);

        // Try calling decimals() — all ERC20 tokens must implement this
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (!success || data.length < 32) revert LBFactory__NotERC20(token);
    }

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
