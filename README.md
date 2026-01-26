# Bad Bunnz Bridge

Trustless bidirectional NFT bridge between Ethereum and MegaETH using merkle proof verification.

## Architecture

### System Overview

The bridge consists of three main components:

1. **Smart Contracts** - On-chain bridge logic with merkle proof verification
2. **Backend Services** - Event indexing, proof generation, and automated relayer
3. **Frontend** - User interface for bridging NFTs (separate repository)

### Bridge Flow

**Ethereum → MegaETH:**
```
User → lockNFT() → Event → Backend indexes → Merkle tree built → 
Relayer submits root → User gets proof → unlockNFTWithProof() → NFT minted/unlocked
```

**MegaETH → Ethereum (Reverse):**
```
User → lockNFTForEthereum() → Event → Backend indexes → Merkle tree built → 
Relayer submits root → User gets proof → unlockNFTWithProof() → Original NFT transferred back
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Smart Contracts                           │
│  ┌──────────────┐         ┌──────────────┐                 │
│  │EthereumBridge│◄───────►│MegaEthBridge │                 │
│  └──────┬───────┘         └──────┬───────┘                 │
│         │                        │                          │
│         └──────────┬─────────────┘                          │
│                    ▼                                        │
│            ┌──────────────┐                                 │
│            │  Bad_Bunnz   │                                 │
│            │   (NFT)      │                                 │
│            └──────────────┘                                 │
└────────────────────┬──────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Backend Services                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │Event Listener│  │Proof Generator│  │   Relayer    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                  │                  │              │
│         └──────────┬───────┴──────────────────┘             │
│                    ▼                                        │
│            ┌──────────────┐                                 │
│            │  PostgreSQL  │                                 │
│            │   Database   │                                 │
│            └──────────────┘                                 │
│                    │                                        │
│                    ▼                                        │
│            ┌──────────────┐                                 │
│            │     Redis    │                                 │
│            │    (Queue)   │                                 │
│            └──────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

## Contracts

### EthereumBridge.sol

Deployed on Ethereum. Handles locking NFTs and unlocking from MegaETH.

**Core Functions:**
- `lockNFT(uint256 tokenId, address recipient)` - Lock NFT for bridging
- `batchLockNFT(uint256[] tokenIds, address recipient)` - Batch lock multiple NFTs
- `unlockNFTWithProof(...)` - Unlock NFT from MegaETH using merkle proof
- `setMegaEthBlockRoot(...)` - Set merkle root for MegaETH locks (rootSubmitter only)
- `pause()` / `unpause()` - Emergency controls (owner only)
- `isApprovedForAll(address user)` - Check if user approved bridge
- `isTokenApproved(uint256 tokenId, address owner)` - Check specific token approval

**State Management:**
- `lockedTokens[tokenId]` - Tracks locked tokens
- `processedLocks[lockHash]` - Prevents replay attacks
- `megaEthBlockRoots[blockNumber]` - Stores merkle roots from MegaETH
- `lockData[lockHash]` - Stores lock data for verification

### MegaEthBridge.sol

Deployed on MegaETH. Handles locking NFTs and minting/unlocking from Ethereum.

**Core Functions:**
- `lockNFTForEthereum(uint256 tokenId, address recipient)` - Lock for reverse bridge
- `batchLockNFTForEthereum(...)` - Batch lock multiple NFTs
- `unlockNFTWithProof(...)` - Unlock/mint NFT from Ethereum using merkle proof
- `setBlockRoot(...)` - Set merkle root for Ethereum locks (rootSubmitter only)
- `pause()` / `unpause()` - Emergency controls (owner only)
- `isApprovedForAll(address user)` - Check if user approved bridge
- `isTokenApproved(uint256 tokenId, address owner)` - Check specific token approval

**State Management:**
- `activeOnMegaETH[tokenId]` - Tracks if token was ever minted on MegaETH
- `lockedTokens[tokenId]` - Tracks locked tokens (for round-trip)
- `processedLocks[lockHash]` - Prevents replay attacks
- `blockRoots[blockNumber]` - Stores merkle roots from Ethereum

**Round-Trip Logic:**
- First time: `activeOnMegaETH[tokenId] = false` → NFT is **minted**
- Round-trip: `activeOnMegaETH[tokenId] = true` → NFT is **unlocked** (no new mint)

### Bad_Bunnz.sol

ERC721C NFT contract with bridge support.

**Bridge Functions:**
- `bridgeMint(address to, uint256 tokenId)` - Mint via bridge (bridge only)
- `bridgeBurn(uint256 tokenId)` - Burn via bridge (bridge only)
- `setBridgeAddress(address bridge)` - Set bridge address (once only, owner only)

**Features:**
- ERC721 Enumerable extension
- ERC2981 Royalties
- Supply cap enforcement
- Marketplace compatible (OpenSea, Blur, etc.)

## Security

### Security Features

1. **Reentrancy Protection** - All critical functions use `nonReentrant` modifier
2. **Access Controls** - Ownable for admin, onlyRootSubmitter for merkle roots
3. **Pause Mechanism** - Emergency stop capability
4. **Cryptographic Verification** - Merkle proof verification using OpenZeppelin
5. **State Management** - Prevents replay attacks, double-minting, double-unlocking
6. **Input Validation** - Zero address checks, array validation, block verification

### Trust Assumptions

- **Relayer Role** - Root submitter can submit merkle roots (should use hardware wallet/multi-sig)
- **First-Come-First-Serve** - Merkle root submission is first-come-first-serve (mitigated by rootSubmitter role)
- **Pause Control** - Owner can pause bridge in emergency

See [SECURITY.md](./SECURITY.md) for detailed security information and vulnerability reporting.

## Backend

### Services

**Event Listener** (`src/services/eventListener.js`)
- Listens to `NFTLocked` events on both chains
- Stores lock data in PostgreSQL
- Queues proof generation jobs

**Proof Generator** (`src/services/proofGenerator.js`)
- Builds merkle trees from lock events in a block
- Generates merkle proofs for each lock
- Stores proofs in database

**Relayer** (`src/services/relayer.js`)
- Monitors pending merkle roots
- Submits roots to destination chains
- Checks relayer balances
- Handles failed transactions

**API Server** (`src/index.js`)
- REST API for bridge status, proofs, stats
- WebSocket server for real-time updates
- Rate limiting and API key protection

### Database Schema

- `lock_events` - All lock events from both chains
- `merkle_proofs` - Generated merkle proofs
- `block_roots` - Submitted merkle roots
- `unlock_events` - Unlock transactions
- `relayer_transactions` - Relayer transaction history
- `bridge_history` - Complete bridge history
- `system_metrics` - System health metrics

### Queue System

- **Proof Generation Queue** - Processes proof generation jobs
- **Root Submission Queue** - Processes root submission jobs
- Uses Redis + Bull for job management

## Setup

### Prerequisites

- Node.js >=18.0.0
- PostgreSQL database
- Redis instance
- Foundry (for contract testing)

### Installation

```bash
npm install
forge install
```

### Environment Variables

Copy `backend/.env.example` to `backend/.env`:

**Required:**
- `DATABASE_URL` - PostgreSQL connection string
- `REDIS_URL` - Redis connection string
- `ETHEREUM_RPC_URL` - Ethereum RPC endpoint
- `ETHEREUM_BRIDGE_ADDRESS` - Ethereum bridge contract address
- `MEGAETH_RPC_URL` - MegaETH RPC endpoint
- `MEGAETH_BRIDGE_ADDRESS` - MegaETH bridge contract address
- `RELAYER_PRIVATE_KEY` - Relayer private key

**Optional:**
- `API_KEY` - API key for endpoint protection
- `AUTO_SUBMIT_ROOTS` - Auto-submit merkle roots (default: false)
- `CONFIRMATION_BLOCKS` - Block confirmations (default: 3)

### Database Migration

```bash
cd backend
npm run db:migrate
```

### Start Services

```bash
# Start API server
cd backend
npm run start

# Start relayer (separate terminal)
cd backend
npm run relayer
```

## Deployment

### Contract Deployment

1. Deploy `Bad_Bunnz` on both chains
2. Deploy `EthereumBridge` on Ethereum
3. Deploy `MegaEthBridge` on MegaETH
4. Set bridge addresses: `badBunnz.setBridgeAddress(bridgeAddress)`
5. Link bridges: `megaBridge.setEthereumBridge(ethBridgeAddress)`
6. Set root submitter: `bridge.setRootSubmitter(relayerAddress)`

### Backend Deployment

Deploy to Railway, Cloudflare Workers, or your preferred platform.

**Services to deploy:**
1. Backend API service
2. Relayer worker service
3. PostgreSQL database
4. Redis cache

## Testing

```bash
# Run Foundry tests
forge test

# Run Hardhat tests
npx hardhat test
```

## Repository Structure

This repository contains:
- `contract/` - Smart contracts (EthereumBridge, MegaEthBridge, Bad_Bunnz)
- `backend/` - Backend services (API, relayer, event listeners)
- `test/` - Contract tests

**Frontend is in a separate repository.**

## License

MIT License - see [LICENSE](./LICENSE) file for details.

## Security

See [SECURITY.md](./SECURITY.md) for security policy and vulnerability reporting.
