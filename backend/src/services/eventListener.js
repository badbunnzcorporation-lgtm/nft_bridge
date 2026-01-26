import { ethers } from 'ethers';
import { logger } from '../utils/logger.js';
import { db } from '../db/index.js';
import { proofQueue, rootQueue } from '../queue/index.js';
import { config } from '../config/index.js';
import { broadcastEvent } from './websocket.js';

const BRIDGE_ABI = [
  'event NFTLocked(uint256 indexed tokenId, address indexed owner, address indexed recipient, bytes32 lockHash, uint256 blockNumber)',
  'event NFTUnlocked(uint256 indexed tokenId, address indexed recipient, bytes32 lockHash)',
  'event BlockRootSet(uint256 indexed blockNumber, bytes32 root)',
  'event MegaEthBlockRootSet(uint256 indexed blockNumber, bytes32 root)',
];

export class EventListener {
  constructor(chainName, rpcUrl, bridgeAddress) {
    this.chainName = chainName;
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.bridge = new ethers.Contract(bridgeAddress, BRIDGE_ABI, this.provider);
    this.isRunning = false;
    this.lastProcessedBlock = null;
  }

  async start() {
    if (this.isRunning) {
      logger.warn(`Event listener for ${this.chainName} is already running`);
      return;
    }

    this.isRunning = true;
    logger.info(`Starting event listener for ${this.chainName}`);

    // Get last processed block from database
    this.lastProcessedBlock = await db.getLastProcessedBlock(this.chainName);
    
    if (!this.lastProcessedBlock) {
      // Start from current block if no history
      this.lastProcessedBlock = await this.provider.getBlockNumber();
      logger.info(`No history found, starting from block ${this.lastProcessedBlock}`);
    }

    // Catch up on missed blocks
    await this.catchUp();

    // Start polling for new blocks (instead of using filters)
    this.startPolling();

    logger.info(`Event listener for ${this.chainName} started successfully`);
  }

  startPolling() {
    // Poll every 12 seconds (average block time)
    const pollInterval = this.chainName === 'megaeth' ? 1000 : 12000;
    
    this.pollingInterval = setInterval(async () => {
      if (!this.isRunning) {
        clearInterval(this.pollingInterval);
        return;
      }

      try {
        const currentBlock = await this.provider.getBlockNumber();
        if (currentBlock > this.lastProcessedBlock) {
          await this.processBlock(currentBlock);
        }
      } catch (error) {
        logger.error(`Error polling blocks on ${this.chainName}:`, error);
      }
    }, pollInterval);

    logger.info(`Started polling for ${this.chainName} every ${pollInterval}ms`);
  }

  async stop() {
    this.isRunning = false;
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
    }
    this.provider.removeAllListeners();
    logger.info(`Event listener for ${this.chainName} stopped`);
  }

  async catchUp() {
    const currentBlock = await this.provider.getBlockNumber();
    const blocksToProcess = currentBlock - this.lastProcessedBlock;

    if (blocksToProcess > 0) {
      logger.info(`Catching up ${blocksToProcess} blocks on ${this.chainName}`);
      
      // Process in batches to avoid overwhelming the system
      const batchSize = 1000;
      for (let i = this.lastProcessedBlock + 1; i <= currentBlock; i += batchSize) {
        const toBlock = Math.min(i + batchSize - 1, currentBlock);
        await this.processBatch(i, toBlock);
      }
    }
  }

  async processBatch(fromBlock, toBlock) {
    try {
      logger.info(`Processing blocks ${fromBlock} to ${toBlock} on ${this.chainName}`);

      // Get all lock events in this range
      const lockFilter = this.bridge.filters.NFTLocked();
      const lockEvents = await this.bridge.queryFilter(lockFilter, fromBlock, toBlock);

      for (const event of lockEvents) {
        const { tokenId, owner, recipient, lockHash, blockNumber } = event.args;
        await this.handleLockEvent(tokenId, owner, recipient, lockHash, blockNumber, event);
      }

      // Get all unlock events
      const unlockFilter = this.bridge.filters.NFTUnlocked();
      const unlockEvents = await this.bridge.queryFilter(unlockFilter, fromBlock, toBlock);

      for (const event of unlockEvents) {
        const { tokenId, recipient, lockHash } = event.args;
        await this.handleUnlockEvent(tokenId, recipient, lockHash, event);
      }

      this.lastProcessedBlock = toBlock;
      await db.updateLastProcessedBlock(this.chainName, toBlock);

    } catch (error) {
      logger.error(`Error processing batch ${fromBlock}-${toBlock} on ${this.chainName}:`, error);
      throw error;
    }
  }

  async processBlock(blockNumber) {
    if (blockNumber <= this.lastProcessedBlock) {
      return; // Already processed
    }

    try {
      await this.processBatch(this.lastProcessedBlock + 1, blockNumber);
    } catch (error) {
      logger.error(`Error processing block ${blockNumber} on ${this.chainName}:`, error);
    }
  }

  async handleLockEvent(tokenId, owner, recipient, lockHash, blockNumber, event) {
    try {
      logger.info(`Lock event detected on ${this.chainName}: Token ${tokenId}, Block ${blockNumber}`);

      const block = await event.getBlock();
      const tx = await event.getTransaction();

      const lockEvent = await db.createLockEvent({
        tokenId: tokenId.toString(),
        ownerAddress: owner,
        recipientAddress: recipient,
        lockHash,
        blockNumber: blockNumber.toString(),
        blockTimestamp: new Date(block.timestamp * 1000),
        chain: this.chainName,
        txHash: tx.hash,
        status: 'pending',
      });

      broadcastEvent('lock', {
        chain: this.chainName,
        tokenId: tokenId.toString(),
        lockHash,
        blockNumber: blockNumber.toString(),
        status: 'pending',
      });

      await proofQueue.add('generate-proof', {
        blockNumber: blockNumber.toString(),
        chain: this.chainName,
        lockHash,
      }, {
        delay: config.relayer.confirmationBlocks * 12000,
        attempts: 3,
        backoff: {
          type: 'exponential',
          delay: 5000,
        },
      });

      logger.info(`Lock event stored and queued for proof generation: ${lockHash}`);

    } catch (error) {
      logger.error(`Error handling lock event on ${this.chainName}:`, error);
      throw error;
    }
  }

  async handleUnlockEvent(tokenId, recipient, lockHash, event) {
    try {
      logger.info(`Unlock event detected on ${this.chainName}: Token ${tokenId}, Lock ${lockHash}`);

      const tx = await event.getTransaction();
      const receipt = await event.getTransactionReceipt();

      await db.updateLockEventStatus(lockHash, 'unlocked');
      await db.createUnlockEvent({
        lockHash,
        tokenId: tokenId.toString(),
        recipientAddress: recipient,
        chain: this.chainName,
        txHash: tx.hash,
        blockNumber: receipt.blockNumber.toString(),
        gasUsed: receipt.gasUsed.toString(),
        status: 'confirmed',
      });

      await db.completeBridgeHistory(lockHash, tx.hash);
      broadcastEvent('unlock', {
        chain: this.chainName,
        tokenId: tokenId.toString(),
        lockHash,
        status: 'unlocked',
        txHash: tx.hash,
      });

      logger.info(`Unlock event processed: ${lockHash}`);

    } catch (error) {
      logger.error(`Error handling unlock event on ${this.chainName}:`, error);
      throw error;
    }
  }
}

// Create listeners for both chains
export const ethereumListener = new EventListener(
  'ethereum',
  config.ethereum.rpcUrl,
  config.ethereum.bridgeAddress
);

export const megaethListener = new EventListener(
  'megaeth',
  config.megaeth.rpcUrl,
  config.megaeth.bridgeAddress
);

// Start both listeners
export async function startAllListeners() {
  await Promise.all([
    ethereumListener.start(),
    megaethListener.start(),
  ]);
  logger.info('All event listeners started');
}

// Stop all listeners
export async function stopAllListeners() {
  await Promise.all([
    ethereumListener.stop(),
    megaethListener.stop(),
  ]);
  logger.info('All event listeners stopped');
}
