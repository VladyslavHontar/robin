# Robin DLMM - Dynamic Liquidity Market Maker

A production-ready DLMM (Dynamic Liquidity Market Maker) for **Robinhood Chain** (Arbitrum Orbit L2), optimized for stock trading with discrete liquidity bins and concentrated liquidity.

## Overview

Robin DLMM is inspired by Meteora DLMM (Solana) and Trader Joe V2 (Avalanche), bringing discrete bin-based AMM functionality to Robinhood Chain with optimizations specific to stock trading.

### Key Features

- **Discrete Liquidity Bins**: Price-step granularity with constant sum (x+y=k) within bins
- **Three-Tier Bin Steps**: 10bp (0.1%), 50bp (0.5%), 100bp (1%) optimized for different asset volatilities
- **Concentrated Liquidity**: Capital efficiency through targeted price ranges
- **Bitmap-Assisted Traversal**: O(1) bin lookup for efficient multi-bin swaps
- **Auto-Compounding Fees**: Fees automatically compound into reserves
- **ERC-1155 Positions**: Fungible shares within bins, NFT-like composability across bins
- **Stock Trading Optimizations**: Time-based fees, circuit breakers, oracle integration support

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         LBRouter.sol                            │
│         User-facing interface for swaps & liquidity             │
└────────────────────┬────────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────────────┐
│                       LBFactory.sol                             │
│         Creates and manages pairs, sets fee parameters          │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ Creates
                     ▼
         ┌───────────────────────┐
         │     LBPair.sol        │
         │  ┌─────────────────┐  │
         │  │  Bin 8388606    │  │ ← Only Y (below active)
         │  ├─────────────────┤  │
         │  │  Bin 8388607    │  │ ← Only Y
         │  ├─────────────────┤  │
         │  │  Bin 8388608    │  │ ← Both X & Y (active)
         │  ├─────────────────┤  │
         │  │  Bin 8388609    │  │ ← Only X
         │  ├─────────────────┤  │
         │  │  Bin 8388610    │  │ ← Only X (above active)
         │  └─────────────────┘  │
         │                       │
         │  Position NFTs        │
         │  (ERC-1155)           │
         └───────────────────────┘
```

## Project Structure

```
robin/
├── src/
│   ├── LBFactory.sol          # Pair deployment & management
│   ├── LBPair.sol             # Core AMM logic (~700 lines)
│   ├── LBRouter.sol           # User-facing interface
│   ├── interfaces/
│   │   ├── ILBFactory.sol
│   │   ├── ILBPair.sol
│   │   ├── ILBPairTypes.sol   # Structs & enums
│   │   ├── ILBPairEvents.sol
│   │   └── ILBPairErrors.sol
│   ├── libraries/
│   │   ├── BinMath.sol        # Bin ↔ price conversions
│   │   ├── BitMath.sol        # Bitmap operations
│   │   ├── SwapHelper.sol     # Swap calculations
│   │   └── FeeHelper.sol      # Dynamic fee logic
│   └── mocks/
│       └── MockERC20.sol      # Testing tokens
├── test/
│   ├── Integration.t.sol      # End-to-end tests (9 tests)
│   ├── BinMath.t.sol          # Unit tests
│   └── BitMath.t.sol          # Unit tests
├── script/
│   └── Deploy.s.sol           # Deployment script
├── DEPLOYMENT.md              # Deployment guide
└── foundry.toml               # Foundry configuration
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js v18+ (recommended)
- Git

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd robin

# Install dependencies (git submodules)
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Run Tests

```bash
# All tests
forge test

# Integration tests only
forge test --match-contract IntegrationTest -vv

# Specific test with traces
forge test --match-test testSwapWithinSingleBin -vvvv

# Gas report
forge test --gas-report
```

### Test Results

```
Integration Tests: 9/9 PASSING ✅
- Deployment verification
- Single-bin liquidity
- Multi-bin liquidity (5 bins)
- Swaps within single bin
- Swaps across multiple bins
- Liquidity removal
- Router swaps
- Quote generation
- Multi-user interactions
```

## Deployment

See [DEPLOYMENT.md](./DEPLOYMENT.md) for comprehensive deployment guide.

### Quick Deploy to Robinhood Chain Testnet

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key_here

# Deploy
forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet \
  --broadcast \
  --verify
```

### Network Details

- **Chain ID**: 46630
- **RPC URL**: https://rpc.testnet.chain.robinhood.com
- **Explorer**: https://explorer.testnet.chain.robinhood.com
- **Currency**: ETH

## How It Works

### Bin System

Each bin represents a discrete price point:
- **Bin ID**: 24-bit identifier (8,388,608 = 1.0 price)
- **Price Formula**: `price = (1 + binStep/10000)^(binId - 8388608)`
- **Constant Sum**: Within each bin, x + y = k (zero slippage)

### Liquidity Distribution

**Spot Concentration** (Limit Orders):
```
Only active bin gets liquidity → tight spread
```

**Uniform Distribution**:
```
Equal liquidity across price range → balanced
```

**Normal Distribution** (Bell Curve):
```
More liquidity near spot → capital efficient
```

### Trading Flow

1. **User** approves tokens
2. **Router** pulls tokens from user
3. **Router** approves Pair
4. **Pair** executes swap across bins:
   - Starts at active bin
   - Drains bin if needed
   - Moves to next non-empty bin (bitmap lookup)
   - Continues until amountIn consumed
5. **Pair** transfers output tokens to user
6. **Fees** auto-compound into reserves

## Gas Costs

| Operation | Gas | Notes |
|-----------|-----|-------|
| Single-bin swap | ~345k | Includes ERC-20 transfers |
| Multi-bin swap (3 bins) | ~700k | Bitmap traversal |
| Add liquidity (1 bin) | ~280k | ERC-1155 mint |
| Add liquidity (5 bins) | ~626k | Batch optimized |
| Remove liquidity | ~250k | ERC-1155 burn |

*Costs on Arbitrum Orbit L2 (Robinhood Chain)*

## Contract Addresses (Testnet)

> Deploy contracts first to populate this section

```
Factory:  0x...
Router:   0x...
USDC:     0x...
AAPL:     0x...
TSLA:     0x...
MSFT:     0x...

Pairs:
AAPL/USDC (10bp):  0x...
TSLA/USDC (50bp):  0x...
MSFT/USDC (100bp): 0x...
```

## Key Concepts

### Bin Steps (Price Granularity)

- **10 bp (0.1%)**: Large-cap stocks (AAPL, MSFT) - tight spreads
- **50 bp (0.5%)**: Mid-cap stocks - standard trading
- **100 bp (1%)**: Small-cap/volatile stocks - wider spreads

### Active Bin

The bin containing the current market price. Swaps start here and move left (for X→Y) or right (for Y→X).

### Shares (ERC-1155)

- Token ID encodes: `(pairAddress, binId)`
- Balance = share amount in that bin
- Fungible within bins
- Transferable as NFTs

### Fees

- **Base Fee**: 0.3% default (adjustable)
- **Volatility Fee**: Dynamic based on price moves
- **Time Adjustment**: 1.5x during off-market hours
- **Auto-Compound**: Fees increase reserves, benefiting LPs

## Advanced Usage

### Add Liquidity via Router

```solidity
// Spot concentration (single bin)
router.addLiquiditySpot(
    tokenX,
    tokenY,
    binStep,
    amountX,
    amountY,
    binId,
    to,
    deadline
);

// Uniform distribution (multiple bins)
router.addLiquidityUniform(
    tokenX,
    tokenY,
    binStep,
    amountX,
    amountY,
    activeBinId,
    binRange,  // ±N bins
    to,
    deadline
);
```

### Execute Swap

```solidity
router.swapExactTokensForTokens(
    tokenIn,
    tokenOut,
    binStep,
    amountIn,
    minAmountOut,
    to,
    deadline
);
```

### Get Quote (View Function)

```solidity
(uint256 amountOut, uint256 fees) = router.getSwapQuote(
    tokenIn,
    tokenOut,
    binStep,
    amountIn
);
```

## Security Considerations

⚠️ **This is testnet/unaudited code**. Before mainnet deployment:

1. ✅ Complete professional security audit
2. ✅ Extensive fuzz testing
3. ✅ Economic security analysis
4. ✅ Multi-sig admin controls
5. ✅ Pause mechanisms
6. ✅ Monitoring & alerting
7. ✅ Oracle integration testing
8. ✅ Circuit breaker validation

### Known Limitations

- No flash loan protection yet
- Circuit breaker thresholds need tuning
- Oracle integration not complete
- No upgrade mechanism (immutable contracts)

## Comparison

| Feature | Robin DLMM | Uniswap V3 | Trader Joe V2 |
|---------|------------|------------|---------------|
| Price Curve | Discrete bins | Continuous | Discrete bins |
| Within Bin | Constant sum | Constant product | Constant sum |
| Bin Lookup | Bitmap O(1) | Linked list | Bitmap O(1) |
| Position NFT | ERC-1155 | ERC-721 | ERC-1155 |
| Fees | Auto-compound | Claimable | Auto-compound |
| Chain | Arbitrum Orbit | Ethereum L1/L2s | Avalanche |

## Development

### Run Integration Tests

```bash
forge test --match-contract IntegrationTest -vv
```

### Format Code

```bash
forge fmt
```

### Generate Gas Report

```bash
forge test --gas-report
```

### Local Development

```bash
# Start local node
anvil

# Deploy to local node
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

## Documentation

- [Deployment Guide](./DEPLOYMENT.md)
- [Foundry Book](https://book.getfoundry.sh)
- [Robinhood Chain Docs](https://docs.robinhood.com/chain)
- [Trader Joe V2 Docs](https://docs.traderjoexyz.com/concepts/liquidity-book)

## Contributing

This is an educational/demonstration project. Contributions welcome!

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## License

MIT License - see LICENSE file for details

## Acknowledgments

- **Trader Joe V2**: Reference implementation for Liquidity Book
- **Meteora DLMM**: Inspiration from Solana ecosystem
- **Uniswap V3**: Concentrated liquidity concepts
- **Robinhood Chain**: Arbitrum Orbit L2 infrastructure

## Support

- **Issues**: GitHub Issues
- **Discussions**: GitHub Discussions
- **Robinhood Chain**: https://docs.robinhood.com/chain

---

Built with ⚡ [Foundry](https://book.getfoundry.sh) for 🦅 [Robinhood Chain](https://robinhood.com/chain)
