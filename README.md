# Robin DLMM

Compliance-enabled DEX for tokenized stocks on Robinhood Chain.

Built on discrete liquidity bins (Trader Joe V2 / Meteora DLMM model) with an integrated ERC-3643 identity layer — the moat that generic DEX forks can't replicate.

## What This Is

A DLMM (Dynamic Liquidity Market Maker) where every swap, mint, and burn is gated by on-chain KYC verification. Stocks trade in predictable ranges, so concentrated liquidity in discrete bins is a natural fit. The compliance layer ensures only verified investors can participate — a hard requirement for tokenized securities.

## Project Structure

```
src/
├── LBPair.sol                          Core AMM — bins, swaps, liquidity
├── LBFactory.sol                       Pair deployment, fee config, compliance config
├── LBRouter.sol                        User-facing swap & liquidity interface
├── libraries/
│   ├── BinMath.sol                     Bin <> price conversions
│   ├── BitMath.sol                     Bitmap operations for bin traversal
│   ├── SwapHelper.sol                  Single-bin swap math
│   └── FeeHelper.sol                   Dynamic fees (base + volatility + time)
├── interfaces/
│   ├── ILBPair.sol                     Pair interface
│   ├── ILBFactory.sol                  Factory interface
│   ├── ILBPairTypes.sol                Structs (BinState, FeeParameters, etc.)
│   ├── ILBPairErrors.sol               24 custom errors
│   └── ILBPairEvents.sol               Events
├── compliance/
│   ├── ComplianceModule.sol            Rules engine — KYC gate, country blocks, transfer limits
│   ├── IdentityRegistry.sol            Wallet <> Identity mapping, trusted issuers
│   ├── Identity.sol                    OnchainID (ERC-735 claims)
│   ├── ClaimIssuer.sol                 KYC provider — issues/validates/revokes claims
│   └── interfaces/
│       ├── IComplianceModule.sol
│       ├── IIdentityRegistry.sol
│       └── IIdentity.sol
└── mocks/
    └── MockERC20.sol

test/
├── Integration.t.sol                   9 end-to-end DEX tests
├── Compliance.t.sol                    20 compliance tests
├── BinMath.t.sol
└── BitMath.t.sol

script/
└── Deploy.s.sol

diagrams/
└── Robin_DLMM_Architecture.puml       PlantUML architecture diagram
```

## How It Works

### DEX Layer

Three-tier bin step system:
- **10 bp** — large-cap stocks (AAPL, MSFT), tight spreads
- **50 bp** — mid-cap stocks, standard trading
- **100 bp** — small-cap / volatile assets

Each bin uses constant-sum (x+y=k) — zero slippage within a bin. When a bin is drained, the swap continues to the next non-empty bin found via two-level bitmap lookup.

Bin data is packed into a single `uint256` (112 + 112 + 32 bits). Fees auto-compound into reserves.

### Compliance Layer

Every `swap()`, `mint()`, and `burn()` on LBPair checks the recipient against the compliance module:

```
LBPair.swap(to) → ComplianceModule.isVerified(to)
                 → IdentityRegistry.isVerified(wallet)
                 → Identity.getClaimIdsByTopic(KYC)
                 → ClaimIssuer.isClaimValid()
```

If compliance is `address(0)`, checks are skipped (backward compatible).

The compliance module enforces:
- **KYC verification** — wallet must have a valid claim from a trusted issuer
- **Country restrictions** — per-token geographic blocking
- **Transfer limits** — daily and monthly caps

Pairs and the router are whitelisted as intermediaries.

### Trading Flow

1. User approves tokens to Router
2. Router pulls tokens from user, approves Pair
3. Pair checks compliance on recipient
4. Pair executes swap across bins (bitmap traversal)
5. Pair transfers output tokens to user
6. Fees compound into bin reserves

## Quick Start

```bash
forge install
forge build
forge test
```

### Run Specific Test Suites

```bash
# DEX integration tests (9 tests)
forge test --match-contract IntegrationTest -v

# Compliance tests (20 tests)
forge test --match-contract ComplianceTest -v
```

### Test Results

```
Integration:  9/9 passing
Compliance:  20/20 passing
```

## Deploy

```bash
export PRIVATE_KEY=your_key

forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com \
  --broadcast
```

### Robinhood Chain Testnet

| | |
|---|---|
| Chain ID | 46630 |
| RPC | https://rpc.testnet.chain.robinhood.com |
| Explorer | https://explorer.testnet.chain.robinhood.com |
| Gas Token | ETH |

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the full deployment guide.

## Gas Costs

| Operation | Gas |
|-----------|-----|
| Single-bin swap | ~345k |
| Multi-bin swap (3 bins) | ~700k |
| Add liquidity (1 bin) | ~280k |
| Add liquidity (5 bins) | ~626k |
| Remove liquidity | ~250k |

## Architecture

![Architecture](docs/diagrams/output/Robin_DLMM_Smart_Contract_Architecture.png)

Four levels:
1. **Entry** — LBFactory (admin) + LBRouter (users)
2. **Core Engine** — LBPair + ComplianceModule
3. **Support** — Identity stack (ERC-3643) | Libraries (stateless math) | External (ERC-20, Chainlink)
4. **Foundation** — Shared types, interfaces, errors/events

## Status

Unaudited testnet code. Not for production use without a professional security audit.

## License

-
