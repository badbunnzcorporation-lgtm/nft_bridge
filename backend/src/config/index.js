import dotenv from 'dotenv';
dotenv.config();

export const config = {
  server: {
    port: parseInt(process.env.PORT || '3000'),
    env: process.env.NODE_ENV || 'development',
    wsPort: parseInt(process.env.WS_PORT || '3001'),
  },

  ethereum: {
    rpcUrl: process.env.ETHEREUM_RPC_URL,
    bridgeAddress: process.env.ETHEREUM_BRIDGE_ADDRESS,
    nftAddress: process.env.ETHEREUM_NFT_ADDRESS,
    chainId: parseInt(process.env.ETHEREUM_CHAIN_ID || '1'),
  },

  megaeth: {
    rpcUrl: process.env.MEGAETH_RPC_URL,
    bridgeAddress: process.env.MEGAETH_BRIDGE_ADDRESS,
    nftAddress: process.env.MEGAETH_NFT_ADDRESS,
    chainId: parseInt(process.env.MEGAETH_CHAIN_ID || '42069'),
  },

  relayer: {
    privateKey: process.env.RELAYER_PRIVATE_KEY,
    address: process.env.RELAYER_ADDRESS,
    autoSubmitRoots: process.env.AUTO_SUBMIT_ROOTS === 'true',
    confirmationBlocks: parseInt(process.env.CONFIRMATION_BLOCKS || '3'),
  },

  database: {
    url: process.env.DATABASE_URL,
  },

  redis: {
    url: process.env.REDIS_URL || 'redis://localhost:6379',
  },

  api: {
    key: process.env.API_KEY,
    rateLimitWindowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '900000'),
    rateLimitMaxRequests: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '100'),
  },

  monitoring: {
    enableMetrics: process.env.ENABLE_METRICS === 'true',
    metricsPort: parseInt(process.env.METRICS_PORT || '9090'),
    alertWebhookUrl: process.env.ALERT_WEBHOOK_URL,
  },

  logging: {
    level: process.env.LOG_LEVEL || 'info',
    file: process.env.LOG_FILE || './logs/bridge.log',
  },

  queue: {
    redisUrl: process.env.BULL_REDIS_URL || 'redis://localhost:6379',
    proofGenerationConcurrency: parseInt(process.env.PROOF_GENERATION_CONCURRENCY || '5'),
    rootSubmissionConcurrency: parseInt(process.env.ROOT_SUBMISSION_CONCURRENCY || '2'),
  },

  safety: {
    minBalanceEth: parseFloat(process.env.MIN_BALANCE_ETH || '0.1'),
    minBalanceMega: parseFloat(process.env.MIN_BALANCE_MEGA || '1.0'),
    pauseOnError: process.env.PAUSE_ON_ERROR === 'true',
  },
};

// Validate required config
const requiredEnvVars = [
  'ETHEREUM_RPC_URL',
  'ETHEREUM_BRIDGE_ADDRESS',
  'MEGAETH_RPC_URL',
  'MEGAETH_BRIDGE_ADDRESS',
  'RELAYER_PRIVATE_KEY',
  'DATABASE_URL',
];

for (const envVar of requiredEnvVars) {
  if (!process.env[envVar]) {
    throw new Error(`Missing required environment variable: ${envVar}`);
  }
}

export default config;
