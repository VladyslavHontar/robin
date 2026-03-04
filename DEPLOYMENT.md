# Deployment Guide: Robinhood Chain Testnet

## Prerequisites

1. **Node.js v18+** (for npm packages if needed)
2. **Foundry installed** (already set up)
3. **Testnet ETH** in your wallet
4. **Private key** with testnet ETH

## Network Details

- **Network Name**: Robinhood Chain Testnet
- **RPC URL**: `https://rpc.testnet.chain.robinhood.com`
- **Chain ID**: 46630
- **Currency**: ETH
- **Block Explorer**: `https://explorer.testnet.chain.robinhood.com`

## Step 1: Get Testnet ETH

Visit the Robinhood Chain testnet faucet to get test ETH. Check the Robinhood Chain documentation for faucet details.

## Step 2: Set Environment Variables

Create a `.env` file in the project root:

```bash
# Required for deployment
PRIVATE_KEY=your_private_key_here

# Optional for contract verification
ETHERSCAN_API_KEY=your_api_key_here
```

**⚠️ IMPORTANT**: Never commit your `.env` file! It's already in `.gitignore`.

## Step 3: Check Your Balance

```bash
cast balance YOUR_ADDRESS --rpc-url https://rpc.testnet.chain.robinhood.com
```

Make sure you have at least 0.1 ETH for deployment and gas fees.

## Step 4: Simulate Deployment (Dry Run)

Test the deployment without broadcasting:

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_testnet
```

Review the output to ensure everything looks correct.

## Step 5: Deploy Contracts

Deploy to Robinhood Chain testnet:

```bash
forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet \
  --broadcast \
  --verify \
  --via-ir
```

### Deployment flags explained:
- `--broadcast`: Actually send transactions to the network
- `--verify`: Verify contracts on block explorer (requires ETHERSCAN_API_KEY)
- `--via-ir`: Use intermediate representation for optimization (required for LBPair)

### If verification fails

You can verify manually later:

```bash
forge verify-contract \
  --chain-id 46630 \
  --num-of-optimizations 200 \
  --compiler-version 0.8.28 \
  CONTRACT_ADDRESS \
  src/ContractName.sol:ContractName \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api
```

## Step 6: Verify Deployment

After deployment, you'll see output like:

```
=== Deployment Summary ===
Factory: 0x...
Router: 0x...
USDC: 0x...
AAPL: 0x...
TSLA: 0x...
MSFT: 0x...

Pairs:
AAPL/USDC (10bp): 0x...
TSLA/USDC (50bp): 0x...
MSFT/USDC (100bp): 0x...
```

### Verify contracts on block explorer:

1. Visit `https://explorer.testnet.chain.robinhood.com`
2. Search for each contract address
3. Check that contracts are verified (green checkmark)

### Test contract interaction:

```bash
# Check factory owner
cast call FACTORY_ADDRESS "owner()" --rpc-url robinhood_testnet

# Check AAPL/USDC pair
cast call FACTORY_ADDRESS "getPair(address,address,uint16)" \
  AAPL_ADDRESS USDC_ADDRESS 10 \
  --rpc-url robinhood_testnet

# Check pair reserves
cast call PAIR_ADDRESS "getBinReserves(uint24)" 8388608 \
  --rpc-url robinhood_testnet
```

## Latest Deployment (2026-03-03) — Security Hardening Update

**Chain:** Robinhood Chain Testnet (Chain ID 46630)

**Architecture:** Singleton contracts (Factory, Router, OracleModule) are deployed behind
TransparentUpgradeableProxy via CREATE2 with fixed salts. Proxy addresses are **permanent** —
implementations can be upgraded via `script/Upgrade.s.sol` without changing addresses.
Compliance contracts are deployed directly (not proxied).

**What changed:** Full security hardening across all contracts — SafeCast, pause mechanism,
two-step ownership, ECDSA-only claims, canTransfer enforcement, authorized token separation,
dead code removal, and more. See MEMORY.md for full changelog.

### ERC-3643 Compliance Stack (redeployed)
| Contract | Address |
|----------|---------|
| IdentityRegistry | `0xB901D3eAA43f19d26AcB818058337B7c20ef8C6F` |
| ComplianceModule | `0x4655a1ffeE63450AC5cCa225Aa10e25862D477f1` |
| ClaimIssuer | `0x1ED0124DB7B0d0ee03B74b0AA634C03e5545A2EB` |

### DEX Core — Proxy Addresses (permanent, implementations upgraded)
| Contract | Proxy Address | Implementation |
|----------|---------------|----------------|
| LBFactory | `0x3b6579a20C30Dc35aFab2737FD13D3bb5fFF0CFE` | `0x424DA7D2029c67BE01EEa96c25a4Fe8A6bC2e6eb` |
| LBRouter | `0xC7c04dd814dF7bFd9Db5E5b39d4970f14139Ce45` | `0x43089bCF816005733E08E422F8fdb7fDc0615215` |
| OracleModule | `0x24c79c663476Fc95243B62dC7a70B53360d6ec26` | `0x8f9f2c19cDf7DeC6C17adE627bdb9Ca168D5Bccf` |
| LBPair (Beacon) | `0xA2a6CdAfa2350ea64c510Cc7655bBbA3fCEf8257` | `0x69b72bAF4fDee917b823C233a536F140E34eb2c3` |

### Tokens (redeployed)
| Token | Address | Decimals |
|-------|---------|----------|
| USDC (MockERC20) | `0xD04A241B9EB55D1164F3F6ED9537dcA3c5D32E16` | 6 |
| AAPL (RWAToken) | `0x7D9d74738E739B75c7EB846890683815aDd95144` | 18 |
| TSLA (RWAToken) | `0xA94272210A58bD0ED1a19Bdf107dF409Fc1E50df` | 18 |
| MSFT (RWAToken) | `0xADd5f1fb86b4033d1572e2d1D2eC7aA5781D6c75` | 18 |

### Trading Pairs (new, created via upgraded factory)
| Pair | Bin Step | Address |
|------|----------|---------|
| AAPL/USDC | 10bp (0.1%) | `0x23846d281323833219284F7EDC0bC9F64F5C89e2` |
| TSLA/USDC | 50bp (0.5%) | `0x60b17cBCf65f40A56e2e0665f786d22F7b892967` |
| MSFT/USDC | 100bp (1.0%) | `0x22Ade296c6f1253e83C1E2822Dd843924419f95D` |

### Upgrading Trading Implementations

To upgrade contract logic without changing proxy addresses:

```bash
source .env && \
FACTORY_PROXY=0x3b6579a20C30Dc35aFab2737FD13D3bb5fFF0CFE \
ROUTER_PROXY=0xC7c04dd814dF7bFd9Db5E5b39d4970f14139Ce45 \
ORACLE_PROXY=0x24c79c663476Fc95243B62dC7a70B53360d6ec26 \
UPGRADE_FACTORY=true UPGRADE_ROUTER=true UPGRADE_ORACLE=true UPGRADE_PAIR=true \
forge script script/Upgrade.s.sol \
  --rpc-url robinhood_testnet --broadcast --slow --gas-limit 30000000
```

### Redeploying Compliance Stack

Compliance contracts are not proxied. To redeploy with security fixes:

```bash
source .env && \
FACTORY_PROXY=0x3b6579a20C30Dc35aFab2737FD13D3bb5fFF0CFE \
forge script script/DeployCompliance.s.sol \
  --rpc-url robinhood_testnet --broadcast --slow --gas-limit 30000000
```

This creates fresh IdentityRegistry, ComplianceModule, ClaimIssuer, RWA tokens, and pairs.
Existing testnet state (identities, balances) is reset.

### What's Included
- TransparentUpgradeableProxy + CREATE2 for permanent singleton addresses
- Full security hardening: SafeCast, pause mechanism, two-step ownership, ECDSA-only claims
- canTransfer/recordTransfer enforcement for RWA tokens
- authorizedTokens separated from whitelist in ComplianceModule
- Per-LP fee accumulation (MasterChef feeGrowthPerShare pattern)
- Fixed math libraries (BinMath 512-bit mulDivDown, binary exponentiation)
- Oracle module with Chainlink integration, deviation fees, and 24h max staleness
- Beacon proxy pattern for upgradeable pairs
- Three-tier bin step system (10bp, 50bp, 100bp)

## Deployed Contracts Architecture

```
LBFactory Proxy (0x3b6579a...) ── permanent address
├── TransparentUpgradeableProxy → LBFactory Implementation
├── Creates and manages LBPair BeaconProxies (onlyOwner)
├── Sets fee parameters
├── Manages oracle module
├── Two-step ownership (pendingOwner + acceptOwnership)
└── Collects protocol fees

LBRouter Proxy (0xC7c04dd...) ── permanent address
├── TransparentUpgradeableProxy → LBRouter Implementation
├── User-facing interface
├── Simplifies liquidity management
├── Provides swap routing, sweepToken for dust recovery
└── Oracle helper views

LBPair Implementation (0x69b72bA...) — shared via Beacon
├── Manages liquidity bins (constant-sum model)
├── Executes swaps (fee-on-input, LP auto-compounding)
├── Bitmap-indexed bin finding (O(1))
├── Circuit breakers (100 bin max move)
├── SafeCast on all uint112/uint128 downcasts
├── Pause mechanism (whenNotPaused)
└── FoT token rejection

OracleModule Proxy (0x24c79c6...) ── permanent address
├── TransparentUpgradeableProxy → OracleModule Implementation
├── Chainlink price feed integration
├── Price-to-bin conversion
├── Piecewise linear deviation fees
├── Max staleness cap (24h)
└── Two-step ownership

Compliance Stack (redeployed, not proxied)
├── IdentityRegistry (0xB901D3e...) - user identity + trusted issuer management
├── ComplianceModule (0x4655a1f...) - canTransfer, recordTransfer, country/limits
├── ClaimIssuer (0x1ED0124...) - ECDSA-only claim validation (scheme 1)
└── All with two-step ownership + authorizedTokens separation

Tokens (redeployed)
├── USDC (0xD04A241...) - MockERC20, 6 decimals
├── AAPL (0x7D9d747...) - RWAToken (ERC-3643), 18 decimals
├── TSLA (0xA942722...) - RWAToken (ERC-3643), 18 decimals
└── MSFT (0xADd5f1f...) - RWAToken (ERC-3643), 18 decimals
```

## Post-Deployment Testing

### 1. Add Liquidity via Router

```bash
# Approve AAPL
cast send AAPL_ADDRESS "approve(address,uint256)" \
  ROUTER_ADDRESS 1000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url robinhood_testnet

# Approve USDC
cast send USDC_ADDRESS "approve(address,uint256)" \
  ROUTER_ADDRESS 1000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url robinhood_testnet

# Add liquidity (spot concentration)
cast send ROUTER_ADDRESS "addLiquiditySpot(address,address,uint16,uint256,uint256,uint24,address,uint256)" \
  AAPL_ADDRESS USDC_ADDRESS 10 \
  100000000000000000 100000000000000000 \
  8388608 YOUR_ADDRESS 99999999999 \
  --private-key $PRIVATE_KEY \
  --rpc-url robinhood_testnet
```

### 2. Execute a Swap

```bash
# Approve Router to spend AAPL
cast send AAPL_ADDRESS "approve(address,uint256)" \
  ROUTER_ADDRESS 10000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url robinhood_testnet

# Swap AAPL for USDC
cast send ROUTER_ADDRESS "swapExactTokensForTokens(address,address,uint16,uint256,uint256,address,uint256)" \
  AAPL_ADDRESS USDC_ADDRESS 10 \
  5000000000000000 4000000000000000 \
  YOUR_ADDRESS 99999999999 \
  --private-key $PRIVATE_KEY \
  --rpc-url robinhood_testnet
```

### 3. Monitor Transactions

View your transactions on the block explorer:
`https://explorer.testnet.chain.robinhood.com/address/YOUR_ADDRESS`

## Troubleshooting

### "Insufficient funds"
- Get more testnet ETH from faucet
- Check balance: `cast balance YOUR_ADDRESS --rpc-url robinhood_testnet`

### "Contract creation code size exceeds"
- We use `--via-ir` flag to optimize contract size
- Make sure `via_ir = true` is in `foundry.toml`

### "Nonce too low/high"
- Wait a few seconds between transactions
- Check pending transactions on block explorer

### "Verification failed"
- Try manual verification (see Step 5)
- Check that etherscan API URL is correct
- Wait 1-2 minutes after deployment before verifying

### "Gas estimation failed"
- Increase gas limit: add `--gas-limit 10000000` flag
- Check RPC connection: `cast client --rpc-url robinhood_testnet`

## Integration Testing

Run the full integration test suite against deployed contracts:

```bash
# Run all tests
forge test --match-contract IntegrationTest -vv

# Run specific test
forge test --match-test testSwapWithinSingleBin -vvvv

# Gas report
forge test --gas-report
```

## Security Considerations

⚠️ **This is testnet code. Before mainnet deployment:**

1. Complete professional security audit
2. Run extensive fuzz testing
3. Test with large liquidity amounts
4. Implement pause mechanisms
5. Set up monitoring and alerting
6. Deploy behind proxy for upgradeability
7. Implement multi-sig for admin functions
8. Test oracle integration thoroughly
9. Validate circuit breaker thresholds
10. Conduct economic security analysis

## Next Steps

1. ✅ Deploy contracts to testnet
2. ✅ Verify on block explorer
3. 🔄 Create test liquidity pools
4. 🔄 Execute test swaps
5. 🔄 Build frontend interface
6. 🔄 Set up monitoring/analytics
7. 🔄 Security audit
8. 🔄 Mainnet deployment

## Useful Commands

```bash
# Check contract code
cast code CONTRACT_ADDRESS --rpc-url robinhood_testnet

# Call view function
cast call CONTRACT_ADDRESS "FUNCTION_SIG(ARGS)" --rpc-url robinhood_testnet

# Send transaction
cast send CONTRACT_ADDRESS "FUNCTION_SIG(ARGS)" ARGS \
  --private-key $PRIVATE_KEY --rpc-url robinhood_testnet

# Get transaction receipt
cast receipt TX_HASH --rpc-url robinhood_testnet

# Estimate gas
cast estimate CONTRACT_ADDRESS "FUNCTION_SIG(ARGS)" --rpc-url robinhood_testnet

# Get latest block
cast block latest --rpc-url robinhood_testnet
```

## Support

- Documentation: https://docs.robinhood.com/chain
- Block Explorer: https://explorer.testnet.chain.robinhood.com
- Foundry Book: https://book.getfoundry.sh
