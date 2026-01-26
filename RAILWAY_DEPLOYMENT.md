# Railway Deployment Guide

Complete guide to deploy Bad Bunnz Bridge on Railway.

## Overview

You'll deploy **5 services** on Railway:
1. **PostgreSQL Database** - Stores lock events, proofs, and bridge history
2. **Redis** - Job queue for proof generation and root submission
3. **Backend API** - Main API server with event listeners
4. **Relayer Worker** - Automated merkle root submission service
5. **Frontend** - Next.js frontend application

---

## Step 1: Create Railway Project

1. Go to [railway.app](https://railway.app) and sign in
2. Click **"New Project"**
3. Select **"Deploy from GitHub repo"**
4. Connect your GitHub account if needed
5. Select the `nft_bridge` repository (backend + contracts)
6. Railway will create a project

---

## Step 2: Add PostgreSQL Database

1. In your Railway project, click **"+ New"**
2. Select **"Database"** → **"Add PostgreSQL"**
3. Wait for Railway to provision (30-60 seconds)
4. Click on the PostgreSQL service
5. Go to **"Variables"** tab
6. Copy the `DATABASE_URL` value (format: `postgresql://postgres:xxx@xxx.up.railway.app:5432/railway`)

**Save this for later!**

---

## Step 3: Add Redis

1. Click **"+ New"** again
2. Select **"Database"** → **"Add Redis"**
3. Wait for Railway to provision (30-60 seconds)
4. Click on the Redis service
5. Go to **"Variables"** tab
6. Copy the `REDIS_URL` value (format: `redis://default:xxx@xxx.up.railway.app:6379`)

**Save this for later!**

---

## Step 4: Deploy Backend API Service

1. Click **"+ New"** → **"GitHub Repo"**
2. Select `nft_bridge` repository
3. Railway will auto-detect it's a Node.js project
4. Click on the service and rename it to **"backend-api"**

### Configure Backend API

1. Go to **"Settings"** tab
2. Set **Root Directory** to: `backend`
3. Go to **"Variables"** tab and add:

```bash
# Server
PORT=3000
NODE_ENV=production

# Database (from Step 2)
DATABASE_URL=postgresql://postgres:xxx@xxx.up.railway.app:5432/railway

# Redis (from Step 3)
REDIS_URL=redis://default:xxx@xxx.up.railway.app:6379
BULL_REDIS_URL=redis://default:xxx@xxx.up.railway.app:6379

# Ethereum
ETHEREUM_RPC_URL=https://base-sepolia.drpc.org
ETHEREUM_BRIDGE_ADDRESS=0x...  # Your deployed bridge address
ETHEREUM_CHAIN_ID=84532
ETHEREUM_NFT_ADDRESS=0x...  # Your NFT address

# MegaETH
MEGAETH_RPC_URL=https://carrot.megaeth.com/rpc
MEGAETH_BRIDGE_ADDRESS=0x...  # Your deployed bridge address
MEGAETH_CHAIN_ID=6347
MEGAETH_NFT_ADDRESS=0x...  # Your NFT address

# Relayer (IMPORTANT: Keep this secret!)
RELAYER_PRIVATE_KEY=0x...  # Your relayer private key
RELAYER_ADDRESS=0x...  # Derived from private key

# Relayer Settings
AUTO_SUBMIT_ROOTS=true
CONFIRMATION_BLOCKS=3

# API Security
API_KEY=your-secret-api-key-here
RATE_LIMIT_WINDOW_MS=900000
RATE_LIMIT_MAX_REQUESTS=100

# Optional
LOG_LEVEL=info
ENABLE_METRICS=true
```

4. Click **"Deploy"** or Railway will auto-deploy

### Run Database Migration

After the backend deploys:

1. Go to **"Deployments"** tab
2. Click on the latest deployment
3. Click **"View Logs"**
4. Or use Railway CLI:

```bash
railway login
railway link
railway run --service backend-api npm run db:migrate
```

---

## Step 5: Deploy Relayer Worker

1. Click **"+ New"** → **"GitHub Repo"**
2. Select `nft_bridge` repository again
3. Rename service to **"relayer-worker"**

### Configure Relayer Worker

1. Go to **"Settings"** tab
2. Set **Root Directory** to: `backend`
3. Set **Start Command** to: `npm run relayer`
4. Go to **"Variables"** tab
5. **Copy all variables from backend-api** (Railway may have a "Copy from Service" option)
6. Add/verify these are set:
   - `DATABASE_URL`
   - `REDIS_URL`
   - `ETHEREUM_RPC_URL`
   - `ETHEREUM_BRIDGE_ADDRESS`
   - `MEGAETH_RPC_URL`
   - `MEGAETH_BRIDGE_ADDRESS`
   - `RELAYER_PRIVATE_KEY` (critical!)
   - `AUTO_SUBMIT_ROOTS=true`

7. Deploy

---

## Step 6: Deploy Frontend

1. Click **"+ New"** → **"GitHub Repo"**
2. Select `nft_bridge_frontend` repository
3. Railway will auto-detect Next.js
4. Rename service to **"frontend"**

### Configure Frontend

1. Go to **"Variables"** tab and add:

```bash
# Backend API URL (get from backend-api service)
NEXT_PUBLIC_API_BASE_URL=https://backend-api-production.up.railway.app

# RPC Endpoints
NEXT_PUBLIC_BASE_RPC_URL=https://base-sepolia.drpc.org
NEXT_PUBLIC_MEGA_RPC_URL=https://carrot.megaeth.com/rpc

# Chain IDs (hex format)
NEXT_PUBLIC_BASE_CHAIN_ID=0x14a34
NEXT_PUBLIC_MEGA_CHAIN_ID=0x18c7

# Contract Addresses
NEXT_PUBLIC_BAD_BUNNZ_BASE=0x...  # Your NFT address on Base
NEXT_PUBLIC_BAD_BUNNZ_MEGA=0x...  # Your NFT address on MegaETH
NEXT_PUBLIC_ETH_BRIDGE=0x...  # Your bridge address on Base
NEXT_PUBLIC_MEGA_BRIDGE=0x...  # Your bridge address on MegaETH

# WalletConnect
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your-walletconnect-project-id
```

2. Deploy

---

## Step 7: Get Public URLs

After deployment:

1. **Backend API**: Go to `backend-api` service → **"Settings"** → **"Generate Domain"**
2. **Frontend**: Go to `frontend` service → **"Settings"** → **"Generate Domain"**

Update frontend `NEXT_PUBLIC_API_BASE_URL` with the backend URL if needed.

---

## Step 8: Verify Deployment

### Check Backend API

```bash
curl https://your-backend-url.railway.app/health
```

Should return:
```json
{"status":"ok","timestamp":"...","uptime":123}
```

### Check Database

```bash
railway connect postgres
```

Then:
```sql
SELECT COUNT(*) FROM lock_events;
```

### Check Relayer Logs

Go to `relayer-worker` service → **"Deployments"** → **"View Logs"**

Should see:
```
Starting automated relayer
Database connection verified
Relayer service started successfully
```

### Check Frontend

Visit your frontend URL - should load the bridge interface.

---

## Troubleshooting

### Backend won't start

- Check all required environment variables are set
- Check `DATABASE_URL` and `REDIS_URL` are correct
- Check logs: Service → Deployments → View Logs

### Database migration fails

```bash
railway run --service backend-api npm run db:migrate
```

### Relayer not submitting roots

- Check `RELAYER_PRIVATE_KEY` is set correctly
- Check relayer address has funds on both chains
- Check `AUTO_SUBMIT_ROOTS=true`
- Check logs for errors

### Frontend can't connect to backend

- Verify `NEXT_PUBLIC_API_BASE_URL` is correct
- Check backend is running and accessible
- Check CORS settings (should allow all in production)

---

## Cost Estimate

Railway pricing (approximate):
- **PostgreSQL**: ~$5/month (Hobby plan)
- **Redis**: ~$5/month (Hobby plan)
- **Backend API**: ~$5/month (500 hours free, then $0.000463/hour)
- **Relayer Worker**: ~$5/month
- **Frontend**: ~$5/month

**Total**: ~$25-30/month for full stack

---

## Next Steps

1. ✅ All services deployed
2. ✅ Database migrated
3. ✅ Relayer running
4. ✅ Frontend accessible
5. 🔄 Test bridge functionality
6. 🔄 Monitor logs and metrics
7. 🔄 Set up alerts (optional)

---

## Important Notes

- **Keep `RELAYER_PRIVATE_KEY` secret** - Never commit to git
- **Fund relayer address** - Needs ETH on both chains for gas
- **Monitor relayer balance** - Set up alerts if balance gets low
- **Backup database** - Railway provides automatic backups on Pro plan

---

## Support

- Railway Docs: https://docs.railway.app
- Railway Discord: https://discord.gg/railway
- Check service logs for detailed error messages
