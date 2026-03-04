# Robin DLMM

Compliance-enabled Dynamic Liquidity Market Maker for tokenized securities on [Robinhood Chain](https://explorer.testnet.chain.robinhood.com).

Built on the discrete liquidity bin model (inspired by [Trader Joe Liquidity Book](https://github.com/traderjoe-xyz/joe-v2) and [Meteora DLMM](https://docs.meteora.ag/dlmm-concepts)) with an integrated ERC-3643 identity layer for on-chain KYC enforcement.

## Overview

Robin DLMM is a decentralized exchange designed for tokenized stock trading. Unlike traditional AMMs, it uses **discrete liquidity bins** — each bin represents a specific price point with constant-sum (x+y=k) mechanics, meaning zero slippage within a single bin.

Every swap, mint, and burn is gated by on-chain identity verification through a compliance module, making it suitable for regulated tokenized securities (RWA).

### Why DLMM for Stocks?

- Stocks trade in predictable ranges — concentrated liquidity is a natural fit
- Discrete bins allow precise price points with tight spreads
- Three-tier bin step system: **10bp** (large-cap), **50bp** (mid-cap), **100bp** (volatile)
- More capital efficient than constant-product (x*y=k) AMMs

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Entry Layer                       │
│         LBFactory (admin)    LBRouter (users)        │
└──────────────┬───────────────────┬──────────────────┘
               │                   │
┌──────────────▼───────────────────▼──────────────────┐
│                   Core Engine                        │
│    LBPair (bins, swaps, liquidity, fees)             │
│    ComplianceModule (KYC, country, limits)            │
└──────────────┬───────────────────┬──────────────────┘
               │                   │
┌──────────────▼──────┐  ┌────────▼──────────────────┐
│   Math Libraries    │  │    Identity Stack          │
│  BinMath, BitMath   │  │  IdentityRegistry          │
│  FeeHelper          │  │  Identity (ERC-735)         │
│  SwapHelper         │  │  ClaimIssuer (ECDSA)        │
│  SafeCast           │  │  RWAToken (ERC-3643)        │
└─────────────────────┘  └───────────────────────────┘
```

### Smart Contracts

| Contract | Description |
|----------|-------------|
| **LBPair** | Core pool — manages bins, executes swaps, handles liquidity and fee distribution |
| **LBFactory** | Deploys and manages LBPair instances via BeaconProxy |
| **LBRouter** | User-facing interface for swaps and liquidity operations |
| **OracleModule** | Chainlink price feed integration and deviation-based fees |
| **ComplianceModule** | KYC verification, country restrictions, transfer limits |
| **IdentityRegistry** | Maps wallets to on-chain identities and trusted claim issuers |
| **ClaimIssuer** | Issues and validates ECDSA-signed KYC claims |
| **RWAToken** | ERC-20 with embedded compliance checks on every transfer |

### Compliance Flow

```
User → LBPair.swap(to)
         → ComplianceModule.canTransfer(token, from, to, amount)
           → IdentityRegistry.isVerified(wallet)
             → Identity.getClaimIdsByTopic(KYC_TOPIC)
               → ClaimIssuer.isClaimValid(identity, claimId)
```

Whitelisted addresses (pairs, router) bypass compliance checks. If no compliance module is set, checks are skipped entirely.

## Key Mechanisms

### Bin-Based Liquidity

Each bin holds reserves of token X and token Y at a specific price. Swaps consume liquidity from the active bin; when depleted, the price moves to the next non-empty bin found via **bitmap traversal** (O(1) lookup using a three-level hierarchy).

### Fee Structure

- **Base fee** — flat fee per swap (configurable per pair)
- **Volatility fee** — scales with distance from reference bin
- **Time adjustment** — higher fees outside market hours (1.5x multiplier)
- **Oracle deviation fee** — penalizes trades deviating from Chainlink price
- Fees auto-compound into bin reserves for LPs

### Security

- SafeCast on all integer downcasts
- Reentrancy guards on state-changing functions
- Circuit breaker (max 100 bins per swap)
- Pause mechanism on all pool operations
- Two-step ownership on all admin contracts
- ECDSA-only claim validation with signature malleability protection
- Fee-on-transfer token rejection

## Project Structure

```
src/
├── trading/
│   ├── application/        LBRouter
│   ├── domain/
│   │   ├── LBPair.sol      Core pool contract
│   │   ├── kernel/         Types, errors, events
│   │   ├── ports/          Interfaces
│   │   └── services/       BinMath, BitMath, FeeHelper, SwapHelper, SafeCast
│   └── infrastructure/     LBFactory, OracleModule
├── compliance/
│   ├── RWAToken.sol        ERC-3643 security token
│   ├── ComplianceModule.sol
│   ├── IdentityRegistry.sol
│   ├── Identity.sol
│   ├── ClaimIssuer.sol
│   └── interfaces/
└── shared/
    ├── WETH.sol
    └── mocks/

test/
├── Integration.t.sol      End-to-end DEX tests
├── Compliance.t.sol        Compliance + KYC tests
├── Oracle.t.sol            Oracle module tests
├── FeeAccumulation.t.sol   LP fee tracking tests
├── BinMath.t.sol
└── BitMath.t.sol
```

## Build & Test

```bash
forge install
forge build
forge test
```

## Network

| | |
|---|---|
| Chain | Robinhood Chain (Arbitrum Orbit L2) |
| Chain ID | 46630 |
| Explorer | https://explorer.testnet.chain.robinhood.com |

## Status

Testnet. Unaudited. Not for production use.

## License

Business Source License 1.1 — see [LICENSE](./LICENSE).

Converts to MIT on 2030-03-03.
