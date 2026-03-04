# Robin DLMM — Mathematics & Logic Reference

This document provides a complete specification of the mathematical foundations, formulas, and algorithmic logic underlying the Robin Dynamic Liquidity Market Maker (DLMM).

---

## Table of Contents

1. [Number Representation](#1-number-representation)
2. [Bin Pricing](#2-bin-pricing)
3. [Binary Exponentiation & 512-bit Arithmetic](#3-binary-exponentiation--512-bit-arithmetic)
4. [Constant-Sum Swap Model](#4-constant-sum-swap-model)
5. [Fee Structure](#5-fee-structure)
6. [Bitmap Indexing](#6-bitmap-indexing)
7. [Liquidity & Shares](#7-liquidity--shares)
8. [Worked Examples](#8-worked-examples)

---

## 1. Number Representation

### 128.128 Fixed-Point Format

All internal prices are stored as `uint256` values in **128.128 fixed-point** format:

```
SCALE = 2^128 = 0x100000000000000000000000000000000
```

A price of **1.0** is represented as `SCALE`. A price of **2.0** is `2 * SCALE`. A price of **0.5** is `SCALE / 2`.

This gives 128 bits of integer range and 128 bits of fractional precision — sufficient to represent any price ratio encountered in financial markets without rounding errors accumulating over thousands of bin steps.

### Conversion Functions

**Human-readable to scaled:**

```
scaledPrice = (humanPrice * SCALE) / 10^decimals
```

**Scaled to human-readable:**

```
humanPrice = (scaledPrice * 10^decimals) / SCALE
```

Where `decimals` is the token's decimal count (e.g., 6 for USDC, 18 for ETH).

### Bin Reserves

Bin reserves use a packed `uint256` storage slot for gas efficiency:

| Bits | Field | Type | Purpose |
|------|-------|------|---------|
| 0–111 | `reserveX` | `uint112` | Token X reserves |
| 112–223 | `reserveY` | `uint112` | Token Y reserves |
| 224–255 | `liquidityIndex` | `uint32` | Pointer to liquidity data |

Maximum reserve per token per bin: `2^112 - 1 ≈ 5.19 × 10^33`.

---

## 2. Bin Pricing

### Core Formula

Each bin has a deterministic price derived from its ID and the pair's bin step:

```
price(binId) = (1 + binStep / 10000)^(binId - INITIAL_BIN_ID)
```

Where:
- `INITIAL_BIN_ID = 2^23 = 8,388,608` — the center of the 24-bit bin ID range
- `binStep` — spacing between bins in basis points (1 bp = 0.01%)
- Price at `INITIAL_BIN_ID` = 1.0 (exactly `SCALE`)

### Positive Exponent (binId > INITIAL_BIN_ID)

```
base = SCALE * (10000 + binStep) / 10000
price = base^exponent    (where exponent = binId - INITIAL_BIN_ID)
```

Example: bin step = 100 bp (1%), one bin above center:
```
base = SCALE * 10100 / 10000 = 1.01 * SCALE
price = 1.01 * SCALE
```

### Negative Exponent (binId < INITIAL_BIN_ID)

To avoid `SCALE^2` overflow, we compute the inverse base directly:

```
inverseBase = SCALE * 10000 / (10000 + binStep)
price = inverseBase^exponent    (where exponent = INITIAL_BIN_ID - binId)
```

This is mathematically equivalent to `1 / (1 + binStep/10000)^exponent` but avoids an extra division by `SCALE`.

### Bin Price Range

Each bin covers a price range `[lower, upper)`:

```
lowerBound(binId) = price(binId)
upperBound(binId) = price(binId + 1)      (exclusive)
```

A price `p` belongs to bin `binId` if: `lowerBound ≤ p < upperBound`.

### Inverse: Price to Bin ID

Given a price, find which bin contains it:

```
binId = floor(log_{1+s}(price / SCALE)) + INITIAL_BIN_ID
```

where `s = binStep / 10000`.

Since logarithms are expensive on-chain, we use **binary search** over `getPriceFromId()`:

```
low, high = bounded search range
while low < high:
    mid = (low + high) / 2
    if getPriceFromId(mid) < price:
        low = mid + 1
    else:
        high = mid
return low - 1  (round down to containing bin)
```

**Search bounds** are clamped to prevent overflow in `_pow`:

```
maxDelta = 440,000 / binStep
```

This ensures intermediate values in binary exponentiation stay within 512-bit capacity.

### Price Ratio Between Bins

```
ratio(binId1, binId2) = price(binId1) * SCALE / price(binId2)
```

Computed using 512-bit `mulDivDown` to avoid overflow.

---

## 3. Binary Exponentiation & 512-bit Arithmetic

### Binary Exponentiation (`_pow`)

Computes `base^exp` where `base` is in 128.128 fixed-point and `exp` is an unsigned integer.

```
function _pow(base, exp) -> result:
    if exp == 0: return SCALE
    if exp == 1: return base

    result = SCALE    // 1.0

    while exp > 0:
        if exp is odd:
            result = mulDivDown(result, base, SCALE)
        exp >>= 1
        if exp > 0:
            base = mulDivDown(base, base, SCALE)

    return result
```

Key detail: the final squaring (`base = base * base`) is skipped when `exp` becomes 0 after the right-shift. This prevents an unnecessary intermediate value that could overflow the 512-bit multiplication.

**Complexity:** O(log₂(exp)) multiplications.

### 512-bit Multiplication with Division (`_mulDivDown`)

Computes `(x * y) / d` without overflow, using 512-bit intermediate multiplication:

**Step 1: 512-bit multiply** `[prod1, prod0] = x * y`

```assembly
mm = mulmod(x, y, 2^256 - 1)
prod0 = x * y              // lower 256 bits
prod1 = mm - prod0 - (mm < prod0)  // upper 256 bits
```

**Step 2: Simple case** — if `prod1 == 0`, no overflow: `result = prod0 / d`.

**Step 3: Full 512-bit division** — when `prod1 > 0`:

1. Subtract remainder: `[prod1, prod0] -= (x * y) mod d`
2. Factor powers of two out of `d`:
   ```
   twos = d & (-d)           // isolate lowest set bit
   d /= twos
   prod0 /= twos
   prod0 |= prod1 * (2^256 / twos)
   ```
3. Compute modular inverse of `d` using Newton's method:
   ```
   inverse = (3 * d) ^ 2       // 4 correct bits
   inverse *= 2 - d * inverse  // 8 bits
   inverse *= 2 - d * inverse  // 16 bits
   inverse *= 2 - d * inverse  // 32 bits
   inverse *= 2 - d * inverse  // 64 bits
   inverse *= 2 - d * inverse  // 128 bits
   inverse *= 2 - d * inverse  // 256 bits (full precision)
   ```
4. `result = prod0 * inverse`

All arithmetic in Step 3 is modular (mod 2^256) and must run inside an `unchecked` block.

**Why 6 iterations?** Each Newton's method iteration doubles precision. Starting from 4 correct bits, we need: 4 → 8 → 16 → 32 → 64 → 128 → 256 bits. Six iterations yield full 256-bit precision.

---

## 4. Constant-Sum Swap Model

### Within a Single Bin: Zero Slippage

Unlike Uniswap's constant product (`x * y = k`), each DLMM bin uses a **constant sum** model:

```
amountOut = amountIn    (1:1 at the bin's fixed price)
```

This means:
- **Zero slippage** for swaps that stay within a single bin
- Price only changes when a bin is fully depleted and the swap crosses to the next bin
- Each bin acts like a limit order at a specific price

### Bin Depletion

When a swap's input exceeds the bin's output reserve:

```
if amountIn > reserveOut:
    amountOut = reserveOut       // take all available
    amountInConsumed = reserveOut // 1:1
    remaining = amountIn - reserveOut
    → move to next bin
```

### Multi-Bin Swap Flow

The swap loop processes bins sequentially:

```
for each bin (up to MAX_BINS_PER_SWAP = 100):
    1. Read bin reserves
    2. Calculate fee for this bin position
    3. Compute max input the bin can accept (including fee)
    4. Consume min(remaining, maxInput)
    5. Deduct fee, compute output
    6. Update bin reserves (LP fee auto-compounds)
    7. Track protocol fee separately
    8. If bin depleted → find next non-empty bin via bitmap
    9. If swap complete → break
```

### Fee-on-Input Model

Fees are deducted from the input amount before the swap:

```
totalConsumed = min(amountInRemaining, maxTotalInput)

where maxTotalInput = reserveOut * 10000 / (10000 - feeBps)

fee = totalConsumed * feeBps / 10000
effectiveInput = totalConsumed - fee
amountOut = effectiveInput    (constant sum: 1:1)
```

The fee is then split:

```
protocolFee = fee * protocolShare / 10000
lpFee = fee - protocolFee
```

**LP fee auto-compounds:** the LP's share of the fee is added directly to the bin's input reserve, increasing the value of LP positions without requiring explicit claiming.

**Protocol fee is tracked separately** in `protocolFeesX` / `protocolFeesY` accumulators and collected via `collectProtocolFees()`.

### Reserve Updates After Swap

```
if swapForY (X → Y):
    reserveX += effectiveInput + lpFee
    reserveY -= amountOut
else (Y → X):
    reserveY += effectiveInput + lpFee
    reserveX -= amountOut
```

### Circuit Breaker

A maximum of `MAX_PRICE_MOVE_BINS = 100` bins can be crossed in a single swap. At 10bp bin step, this corresponds to a ~1% price move. If exceeded, the swap reverts.

### Unconsumed Input

Only the actually consumed portion of the input is pulled from the trader:

```
actualAmountIn = params.amountIn - amountInRemaining
```

If a swap cannot fully execute (insufficient liquidity), the unconsumed input is never transferred from the trader.

---

## 5. Fee Structure

### Fee Components

The total fee for a swap is composed of up to four components:

```
totalFee = baseFee + volatilityFee + oracleDeviationFee
totalFee = applyTimeAdjustment(totalFee)
totalFee = min(totalFee, MAX_TOTAL_FEE)
```

Where `MAX_TOTAL_FEE = 1000 bp (10%)`.

### 5.1 Base Fee

A constant fee set at pair creation:

```
baseFee = feeParameters.baseFee    (default: 30 bp = 0.3%)
```

### 5.2 Volatility Fee

Increases when the swap moves price away from a reference bin:

```
currentDistance = |activeBinId - volatilityReference|
targetDistance  = |targetBinId - volatilityReference|
maxDistance = max(currentDistance, targetDistance)

volatilityFee = min(
    maxDistance * reductionFactor / 10000,
    maxVolatilityFee
)
```

Default parameters: `reductionFactor = 5000` (50%), `maxVolatilityFee = 100 bp` (1%).

The `volatilityReference` bin slowly moves toward the active bin via an exponential moving average:

```
newReference = currentReference + (activeBin - currentReference) / filterPeriod
```

### 5.3 Oracle Deviation Fee

When a Chainlink oracle is configured, an extra fee applies when the DEX price diverges from the oracle price. This incentivizes arbitrageurs to correct the price.

**Piecewise linear formula** based on bin distance:

```
deviation = |activeBinId - oracleBinId|

fee =
  deviation ≤ deadzone        → 0
  deviation ≤ tier1Max        → (deviation - deadzone) × tier1Rate
  deviation ≤ tier2Max        → tier1Fee + (deviation - tier1Max) × tier2Rate
  deviation > tier2Max        → capped at maxDeviationFee
```

Where `tier1Fee = (tier1Max - deadzone) × tier1Rate`.

**Default parameters by bin step:**

| Parameter | 10bp tier | 50bp tier | 100bp tier |
|-----------|-----------|-----------|------------|
| deadzoneBins | 5 | 1 | 1 |
| tier1MaxBins | 20 | 4 | 2 |
| tier1RatePerBin | 2 bp | 10 bp | 20 bp |
| tier2MaxBins | 40 | 8 | 4 |
| tier2RatePerBin | 5 bp | 25 bp | 50 bp |
| maxDeviationFee | 130 bp | 130 bp | 130 bp |

If the oracle feed is unset, stale, or returns invalid data, the deviation fee is 0 — it never blocks trading.

### 5.4 Time-Based Adjustment

Designed for stock trading on Robinhood Chain:

```
if market hours (9:30am – 4:00pm ET / 13:30 – 20:00 UTC):
    adjustedFee = totalFee    (1.0×)
else:
    adjustedFee = totalFee × 1.5    (off-hours multiplier)
```

Off-hours fees are higher because liquidity is typically thinner outside market hours.

### Fee Split

```
protocolFee = totalFee × protocolShare / 10000
lpFee = totalFee - protocolFee
```

Default `protocolShare = 500 bp` (5% of fees go to the protocol).

### Fee Accumulation for LPs

LP fee earnings are tracked per-bin using a fee growth accumulator:

```
feeGrowthPerShare += feesCollected × 1e18 / totalShares
```

An LP's unclaimed fees are:

```
unclaimedFees = (currentFeeGrowth - userFeeGrowthCheckpoint) × userShares / 1e18
```

---

## 6. Bitmap Indexing

### Problem

With up to 2^24 ≈ 16.7 million possible bin IDs, finding the next non-empty bin by linear scan is prohibitively expensive. The bitmap index reduces this to O(1) lookups.

### Two-Level Bitmap Structure

**Level 2 (L2):** Each `uint256` word covers 256 consecutive bins. Bit `i` is set if bin `(groupId * 256 + i)` has liquidity.

```
_binBitmapL2[groupId]    where groupId = binId / 256
bit position = binId % 256
```

**Level 1 (L1):** Each `uint256` word covers 256 L2 groups (= 65,536 bins). Bit `j` is set if any bin in L2 group `j` has liquidity.

```
_binBitmapL1[superGroupId]    where superGroupId = groupId / 256
bit position = groupId % 256
```

### Lookup: Finding the Next Non-Empty Bin

To find the next bin with liquidity when swapping (e.g., searching rightward for higher prices):

1. Check L2 bitmap at the current group for the next set bit in the search direction
2. If not found, check L1 bitmap for the next non-empty group
3. Then check L2 of that group for the first set bit

### Bit Operations (BitMath Library)

**Most Significant Bit (MSB):** Binary search over the 256-bit value:

```
if x ≥ 2^128: x >>= 128, msb = 128
if x ≥ 2^64:  x >>= 64,  msb |= 64
if x ≥ 2^32:  x >>= 32,  msb |= 32
... down to 1-bit granularity
```

**Least Significant Bit (LSB):** Isolate with `x & (-x)`, then find MSB.

**closestBitLeft(bitmap, bit, include):** Find the highest set bit at or below position `bit`. Used when searching for lower-priced bins (swapping Y for X).

**closestBitRight(bitmap, bit, include):** Find the lowest set bit at or above position `bit`. Used when searching for higher-priced bins (swapping X for Y).

**Population count (popCount):** Brian Kernighan's algorithm — repeatedly clear the lowest set bit:

```
count = 0
while x ≠ 0:
    x &= x - 1
    count++
```

### Bitmap Maintenance

When liquidity is added to an empty bin:

```
_binBitmapL2[groupId] = setBit(_binBitmapL2[groupId], binId % 256)
_binBitmapL1[superGroupId] = setBit(_binBitmapL1[superGroupId], groupId % 256)
```

When the last liquidity is removed from a bin:

```
_binBitmapL2[groupId] = clearBit(_binBitmapL2[groupId], binId % 256)
if _binBitmapL2[groupId] == 0:
    _binBitmapL1[superGroupId] = clearBit(_binBitmapL1[superGroupId], groupId % 256)
```

---

## 7. Liquidity & Shares

### Adding Liquidity

When an LP adds liquidity to a bin:

```
if bin is empty:
    shares = sqrt(amountX * amountY)    // geometric mean for initial deposit
else:
    shares = min(
        amountX * totalShares / reserveX,
        amountY * totalShares / reserveY
    )
```

The LP receives `shares` proportional to their contribution relative to existing reserves.

### Removing Liquidity

When an LP burns shares from a bin:

```
amountX = shares * reserveX / totalShares
amountY = shares * reserveY / totalShares
```

Because LP fees auto-compound into reserves, the reserves grow over time, making each share worth more tokens at withdrawal.

### Distribution Strategies

LPs can distribute liquidity across multiple bins using distribution arrays:

```
for each binId in binIds:
    binAmountX = totalAmountX * distributionX[i] / 1e18
    binAmountY = totalAmountY * distributionY[i] / 1e18
    mint shares in bin
```

Common strategies:
- **Uniform:** Equal liquidity in every bin across a range
- **Spot (Concentrated):** Heavier liquidity near the active bin
- **One-sided:** Only token X (above active bin) or only token Y (below active bin)

---

## 8. Worked Examples

### Example 1: Simple Swap Within One Bin

**Setup:** AAPL/USDC pair, binStep = 50bp, active bin = 8,388,608, base fee = 30bp.

Bin reserves: `reserveX = 100 AAPL`, `reserveY = 15,000 USDC`.

**Trader swaps 10 USDC → AAPL:**

1. Fee = 10 × 30 / 10000 = **0.03 USDC**
2. Effective input = 10 - 0.03 = **9.97 USDC**
3. Amount out = 9.97 AAPL (constant sum, 1:1 within bin)
4. LP fee = 0.03 × (10000 - 500) / 10000 = **0.02850 USDC** (auto-compounds)
5. Protocol fee = 0.03 × 500 / 10000 = **0.00150 USDC** (tracked separately)

**After swap:**
- `reserveX = 100 - 9.97 = 90.03 AAPL`
- `reserveY = 15,000 + 9.97 + 0.02850 = 15,009.9985 USDC`

### Example 2: Multi-Bin Swap

**Setup:** Same pair. Trader swaps 20,000 USDC → AAPL.

Bin 8,388,608 has `reserveX = 100 AAPL`. At 30bp fee:

```
maxTotalInput = 100 × 10000 / (10000 - 30) = 100.3009 USDC
```

1. **Bin 8,388,608:** Consumes 100.30 USDC, outputs ~100 AAPL, bin depleted
2. **Bin 8,388,609** (price 1.005× higher): Next bin found via bitmap, swap continues
3. Process repeats until 20,000 USDC fully consumed or max bins reached

Each bin crossed moves the price by `binStep` (50bp = 0.5%).

### Example 3: Oracle Deviation Fee (50bp Bin Step)

**Setup:** Oracle says AAPL = $150 → oracleBinId = X. DEX active bin is 3 bins away.

With default 50bp tier parameters:

```
deviation = 3 bins
deadzone = 1 → passes deadzone
binsInTier1 = 3 - 1 = 2
tier1Fee = 2 × 10bp = 20bp
```

Total fee = 30bp (base) + 20bp (oracle deviation) = **50bp**.

If off-hours: 50 × 1.5 = **75bp**.

### Example 4: Price Calculation

**What price does bin 8,388,618 represent at 100bp step?**

```
exponent = 8,388,618 - 8,388,608 = 10
base = 1.01 (100bp = 1%)
price = 1.01^10 = 1.10462
```

So this bin represents price ≈ **1.1046** relative to the pair's base denomination.

### Example 5: Bin ID from Price

**Given price = 2.0 * SCALE at 100bp step, what bin ID?**

```
log_{1.01}(2.0) = ln(2) / ln(1.01) ≈ 69.66

binId = 8,388,608 + 69 = 8,388,677
```

(Binary search converges to this in ~17 iterations.)

---

## Appendix: Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `SCALE` | 2^128 | Fixed-point price unit (1.0) |
| `INITIAL_BIN_ID` | 8,388,608 (2^23) | Center of bin ID range |
| `MAX_BIN_STEP` | 10,000 bp (100%) | Maximum bin spacing |
| `BASIS_POINT_MAX` | 10,000 | Basis point denominator |
| `MAX_TOTAL_FEE` | 1,000 bp (10%) | Fee hard cap |
| `MAX_BINS_PER_SWAP` | 100 | Circuit breaker: max bins per swap |
| `MAX_PRICE_MOVE_BINS` | 100 | Circuit breaker: max price move |
| `OFF_HOURS_MULTIPLIER` | 15,000 (1.5×) | Off-hours fee multiplier |

## Appendix: Contract-to-Library Mapping

| Contract/Library | Responsibility |
|------------------|----------------|
| `BinMath.sol` | Bin ↔ price conversions, fixed-point `_pow`, 512-bit `_mulDivDown` |
| `BitMath.sol` | MSB/LSB, bitmap traversal (`closestBitLeft`/`Right`), set/clear/test bits |
| `FeeHelper.sol` | Fee calculation: base, volatility, oracle deviation, time adjustment, split |
| `SwapHelper.sol` | Single-bin constant-sum swap logic, reserve updates, price impact |
| `LBPair.sol` | Core pair: swap loop, mint/burn, bin storage, bitmap maintenance |
| `LBFactory.sol` | Pair creation, fee configuration, protocol fee collection |
| `LBRouter.sol` | User-facing entry points, liquidity strategies, oracle helpers |
