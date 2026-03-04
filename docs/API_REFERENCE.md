# Robin DLMM — API Reference

Contract addresses are on Robinhood Chain Testnet (Chain ID: 46630).

---

## Data Types

```solidity
struct SwapParameters {
    bool swapForY;          // true = sell tokenX for tokenY
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 deadline;       // unix timestamp
    address to;             // recipient
}

struct SwapResult {
    uint256 amountOut;
    uint256 fees;
    uint24 newActiveBinId;
}

struct LiquidityParameters {
    uint24[] binIds;
    uint64[] distributionX; // scaled by 1e18, must sum to 1e18
    uint64[] distributionY; // scaled by 1e18, must sum to 1e18
    uint256 amountX;
    uint256 amountY;
    uint24 activeIdDesired;
    uint24 idSlippage;
    uint256 deadline;
    address to;
}

struct RemoveLiquidityParameters {
    uint24[] binIds;
    uint256[] shares;       // shares to burn per bin
    uint256 minAmountX;
    uint256 minAmountY;
    uint256 deadline;
    address to;
}

struct FeeParameters {
    uint16 baseFee;             // basis points (e.g. 30 = 0.30%)
    uint16 protocolShare;       // basis points of fees to protocol
    uint16 maxVolatilityFee;    // max additional volatility fee (bps)
    uint24 volatilityReference; // reference bin for volatility calc
    uint16 filterPeriod;
    uint16 decayPeriod;
    uint24 reductionFactor;
}

struct OracleDeviationParams {
    uint24 deadzoneBins;    // no extra fee within this distance
    uint24 tier1MaxBins;
    uint16 tier1RatePerBin; // bps per bin in tier 1
    uint24 tier2MaxBins;
    uint16 tier2RatePerBin; // bps per bin in tier 2
    uint16 maxDeviationFee; // hard cap (bps)
}
```

---

## Trader / LP Functions

These are the functions a trader or liquidity provider calls to interact with the DEX.

### Swapping

#### `LBRouter.swapExactTokensForTokens`
Swap tokens via the router (handles token transfers and pair lookup).

```solidity
function swapExactTokensForTokens(
    address tokenIn,
    address tokenOut,
    uint16 binStep,
    uint256 amountIn,
    uint256 minAmountOut,
    address to,
    uint256 deadline
) external returns (uint256 amountOut)
```

| Parameter | Description |
|-----------|-------------|
| tokenIn | Address of token to sell |
| tokenOut | Address of token to buy |
| binStep | Bin step of the pair (10, 50, or 100) |
| amountIn | Amount of tokenIn to swap |
| minAmountOut | Minimum acceptable output (slippage protection) |
| to | Recipient of output tokens |
| deadline | Unix timestamp after which the tx reverts |

**Prerequisite**: Caller must `approve(router, amountIn)` on tokenIn before calling.

---

#### `LBRouter.swapOnPair`
Swap directly on a known pair address (skips pair lookup).

```solidity
function swapOnPair(
    address pair,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address to,
    uint256 deadline
) external returns (uint256 amountOut)
```

**Prerequisite**: Caller must `approve(router, amountIn)` on tokenIn.

---

#### `LBPair.swap`
Direct swap on the pair contract (advanced — caller handles token transfer).

```solidity
function swap(SwapParameters calldata params) external returns (SwapResult memory result)
```

**Prerequisite**: Caller must `approve(pair, amountIn)` on the input token. The pair pulls tokens via `transferFrom`.

---

### Quoting (View — No Gas)

#### `LBRouter.getSwapQuote`
Simulate a swap to get expected output and fees.

```solidity
function getSwapQuote(
    address tokenIn,
    address tokenOut,
    uint16 binStep,
    uint256 amountIn
) external view returns (uint256 amountOut, uint256 fees)
```

---

#### `LBPair.getSwapOut`
Simulate swap output directly on the pair.

```solidity
function getSwapOut(bool swapForY, uint256 amountIn) external view returns (uint256 amountOut, uint256 fees)
```

| Parameter | Description |
|-----------|-------------|
| swapForY | `true` = selling tokenX for tokenY, `false` = opposite |
| amountIn | Amount of input token |

---

### Adding Liquidity

#### `LBRouter.addLiquidityUniform`
Add liquidity uniformly across a symmetric range centered on the active bin.

```solidity
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
) external returns (uint256[] memory shares)
```

| Parameter | Description |
|-----------|-------------|
| activeBinId | Current active bin (center of range) |
| binRange | Number of bins on each side (total bins = 2 * binRange + 1) |
| to | Recipient of LP shares |

**Prerequisite**: Caller must `approve(router, amountX)` on tokenX and `approve(router, amountY)` on tokenY.

---

#### `LBRouter.addLiquiditySpot`
Add liquidity to a single bin.

```solidity
function addLiquiditySpot(
    address tokenX,
    address tokenY,
    uint16 binStep,
    uint256 amountX,
    uint256 amountY,
    uint24 binId,
    address to,
    uint256 deadline
) external returns (uint256[] memory shares)
```

---

#### `LBPair.mint`
Add liquidity with custom distribution (advanced — supports curve, bid-ask, or any shape).

```solidity
function mint(LiquidityParameters calldata params) external returns (uint256[] memory shares)
```

**Prerequisite**: Caller must `approve(pair, amountX)` on tokenX and `approve(pair, amountY)` on tokenY. The `distributionX` and `distributionY` arrays must each sum to exactly 1e18.

---

### Removing Liquidity

#### `LBRouter.removeLiquidity`
Remove liquidity from multiple bins.

```solidity
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
) external returns (uint256 amountX, uint256 amountY)
```

| Parameter | Description |
|-----------|-------------|
| binIds | Array of bin IDs to withdraw from |
| sharesPerBin | Shares to burn in each corresponding bin |
| minAmountX / minAmountY | Slippage protection |

---

#### `LBPair.burn`
Remove liquidity directly on the pair.

```solidity
function burn(RemoveLiquidityParameters calldata params) external returns (uint256 amountX, uint256 amountY)
```

---

### Fee Collection

#### `LBPair.collectFees`
Withdraw accumulated LP trading fees.

```solidity
function collectFees(uint24[] calldata binIds, address account) external returns (uint256 amountX, uint256 amountY)
```

| Parameter | Description |
|-----------|-------------|
| binIds | Bin IDs to collect fees from |
| account | Must be `msg.sender` (only self can collect) |

**Returns**: Total tokenX and tokenY fees transferred to caller.

---

#### `LBPair.getUnclaimedFees` (view)
Check pending fees without collecting.

```solidity
function getUnclaimedFees(address account, uint24[] calldata binIds) external view returns (uint256 amountX, uint256 amountY)
```

---

### Pool State Queries (View)

#### `LBPair.activeId`
```solidity
function activeId() external view returns (uint24)
```
Current trading price bin.

#### `LBPair.tokenX` / `LBPair.tokenY`
```solidity
function tokenX() external view returns (address)
function tokenY() external view returns (address)
```

#### `LBPair.binStep`
```solidity
function binStep() external view returns (uint16)
```
Price spacing between bins in basis points.

#### `LBPair.getBinReserves`
```solidity
function getBinReserves(uint24 binId) external view returns (uint128 reserveX, uint128 reserveY)
```

#### `LBPair.getNextNonEmptyBin`
```solidity
function getNextNonEmptyBin(uint24 binId, bool swapForY) external view returns (uint24 nextBinId)
```
Find the next bin with liquidity in a given direction.

#### `LBPair.getTotalShares`
```solidity
function getTotalShares(uint24 binId) external view returns (uint256)
```

#### `LBPair.balanceOf`
```solidity
function balanceOf(address account, uint24 binId) external view returns (uint256)
```
LP share balance for a specific account in a specific bin.

#### `LBPair.getFeeParameters`
```solidity
function getFeeParameters() external view returns (FeeParameters memory)
```

---

### Oracle Queries (View)

#### `LBRouter.getActiveBinFromOracle`
```solidity
function getActiveBinFromOracle(
    address tokenX, address tokenY, uint16 binStep
) external view returns (uint24 oracleBinId, bool isValid)
```
Get the oracle-derived bin ID (where the oracle thinks the price is).

#### `LBRouter.getOracleDeviation`
```solidity
function getOracleDeviation(
    address tokenX, address tokenY, uint16 binStep
) external view returns (uint24 dexBinId, uint24 oracleBinId, uint24 deviationBins, uint256 extraFeeBps)
```
Check how far the DEX price deviates from the oracle price, and the extra fee being charged.

#### `OracleModule.getOraclePrice`
```solidity
function getOraclePrice(address pair) external view returns (int256 price, uint8 decimals, uint256 updatedAt)
```
Raw Chainlink price data for a pair.

---

### Utility Functions (View)

#### `LBRouter.calculateOptimalBinRange`
```solidity
function calculateOptimalBinRange(uint16 binStep, uint256 expectedVolatilityBps) external pure returns (uint24 binRange)
```
Suggests how many bins to spread liquidity across based on expected volatility.

#### `LBRouter.getRecommendedBinStep`
```solidity
function getRecommendedBinStep(uint256 expectedDailyVolatilityBps) external pure returns (uint16 binStep)
```
Returns 10 (tight), 50 (standard), or 100 (wide) based on expected daily volatility.

#### `LBRouter.generateNormalDistribution`
```solidity
function generateNormalDistribution(
    uint24 activeBinId, uint24 binRange
) external pure returns (uint24[] memory binIds, uint64[] memory distX, uint64[] memory distY)
```
Generates a bell-curve distribution (more liquidity near center, less at edges).

#### `LBFactory.getPair`
```solidity
function getPair(address tokenX, address tokenY, uint16 binStep) external view returns (address pair)
```
Look up the pair address for a token pair at a specific bin step.

#### `LBFactory.getAllPairs`
```solidity
function getAllPairs(address tokenX, address tokenY) external view returns (address[] memory pairs)
```
Returns all pairs for a token pair across all bin steps (10, 50, 100).

#### `LBFactory.computePairAddress`
```solidity
function computePairAddress(address tokenA, address tokenB, uint16 binStep) external view returns (address pair)
```
Deterministic address via CREATE2 — works even before the pair is deployed.

---

## Owner / Agent Functions

These require `onlyOwner` or equivalent access control.

### Factory Administration

#### `LBFactory.createPair`
```solidity
function createPair(
    address tokenX, address tokenY, uint16 binStep, uint24 activeId
) external returns (address pair)
```
Deploy a new LBPair as a BeaconProxy. Validates tokens are ERC-20 and pair doesn't already exist.

#### `LBFactory.setFeeParameters`
```solidity
function setFeeParameters(address pair, FeeParameters calldata feeParams) external
```
Update fee configuration for a deployed pair. Owner only.

#### `LBFactory.setProtocolFeeRecipient`
```solidity
function setProtocolFeeRecipient(address recipient) external
```

#### `LBFactory.transferOwnership`
```solidity
function transferOwnership(address newOwner) external
```

#### `LBFactory.collectProtocolFees`
```solidity
function collectProtocolFees(address pair) external returns (uint256 amountX, uint256 amountY)
```
Withdraw accumulated protocol fees. Caller must be `protocolFeeRecipient`.

#### `LBFactory.upgradePairImplementation`
```solidity
function upgradePairImplementation(address newImplementation) external
```
Upgrade the beacon — ALL pairs upgrade atomically to the new implementation.

#### `LBFactory.setOracleModule`
```solidity
function setOracleModule(address _oracleModule) external
```
Set the oracle module address. New pairs will automatically link to it.

#### `LBFactory.setPairOracle`
```solidity
function setPairOracle(address pair, address oracleModule) external
```
Set or change the oracle on a specific existing pair.

### Oracle Administration

#### `OracleModule.setPriceFeed`
```solidity
function setPriceFeed(address pair, address feed, uint256 maxStaleness) external
```
Link a Chainlink aggregator to a pair. Set `feed = address(0)` to disable.

| Parameter | Description |
|-----------|-------------|
| pair | LBPair address |
| feed | Chainlink AggregatorV3Interface address |
| maxStaleness | Max acceptable age of price data in seconds (e.g. 300) |

#### `OracleModule.setDeviationParams`
```solidity
function setDeviationParams(address pair, OracleDeviationParams calldata params) external
```
Override the default deviation fee schedule for a specific pair.

#### `OracleModule.transferOwnership`
```solidity
function transferOwnership(address newOwner) external
```

### Oracle View Functions (Admin)

#### `OracleModule.getDeviationParams`
```solidity
function getDeviationParams(address pair) external view returns (OracleDeviationParams memory)
```

#### `OracleModule.getDefaultDeviationParams`
```solidity
function getDefaultDeviationParams(uint16 binStep) external pure returns (OracleDeviationParams memory)
```
Returns built-in defaults for bin step 10, 50, or 100.

---

## Architecture

```
src/
├── trading/                              # Bounded Context: DLMM Trading
│   ├── application/LBRouter.sol          # Application Service (orchestrates use cases)
│   ├── infrastructure/
│   │   ├── LBFactory.sol                 # Repository + Factory (creates pairs)
│   │   └── OracleModule.sol              # Adapter (Chainlink → IOracleModule port)
│   └── domain/
│       ├── LBPair.sol                    # Aggregate Root (core AMM logic)
│       ├── ports/                        # Domain-owned interfaces
│       ├── services/                     # Pure libraries (BinMath, BitMath, SwapHelper, FeeHelper)
│       └── kernel/                       # Value objects, events, errors
├── compliance/                           # Bounded Context: Identity & Compliance (ERC-3643)
│   ├── RWAToken.sol                      # ERC-3643 token (compliance in _update hook)
│   ├── ComplianceModule.sol, IdentityRegistry.sol, Identity.sol, ClaimIssuer.sol
│   └── interfaces/
└── shared/                               # Cross-BC utilities (WETH, mocks)
```

Dependency direction: Application → Domain ← Infrastructure. Domain never imports infrastructure.
