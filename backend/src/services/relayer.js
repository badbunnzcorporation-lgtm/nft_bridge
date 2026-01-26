import { ethers } from 'ethers';
import { logger } from '../utils/logger.js';
import { db } from '../db/index.js';
import { config } from '../config/index.js';
import { broadcastEvent } from './websocket.js';
import { sendAlert } from '../utils/alerts.js';

const BRIDGE_ABI = [
  'function setBlockRoot(uint256 blockNumber, bytes32 root, uint32 lockCount, tuple(uint256 tokenId, address owner, address recipient, uint256 blockNumber, bytes32 lockHash)[] locks) external',
  'function setMegaEthBlockRoot(uint256 blockNumber, bytes32 root, uint32 lockCount, tuple(uint256 tokenId, address owner, address recipient, uint256 blockNumber, bytes32 lockHash)[] locks) external',
  'function unlockNFTWithProof(uint256 tokenId, address recipient, bytes32 lockHash, uint256 blockNumber, bytes32[] calldata proof) external',
  'function batchUnlockNFTWithProof(uint256[] calldata tokenIds, address[] calldata recipients, bytes32[] calldata lockHashes, uint256[] calldata blockNumbers, bytes32[][] calldata proofs) external',
];

export class Relayer {
  constructor() {
    this.ethProvider = new ethers.JsonRpcProvider(config.ethereum.rpcUrl);
    this.megaProvider = new ethers.JsonRpcProvider(config.megaeth.rpcUrl);
    
    this.wallet = new ethers.Wallet(config.relayer.privateKey);
    this.ethSigner = this.wallet.connect(this.ethProvider);
    this.megaSigner = this.wallet.connect(this.megaProvider);

    this.ethBridge = new ethers.Contract(
      config.ethereum.bridgeAddress,
      BRIDGE_ABI,
      this.ethSigner
    );

    this.megaBridge = new ethers.Contract(
      config.megaeth.bridgeAddress,
      BRIDGE_ABI,
      this.megaSigner
    );

    this.isRunning = false;
    this.lastBalanceCheck = 0;
  }

  async start() {
    if (this.isRunning) {
      logger.warn('Relayer is already running');
      return;
    }

    this.isRunning = true;
    logger.info('Starting automated relayer');

    await this.checkBalances();
    this.monitorLoop();

    logger.info('Automated relayer started successfully');
  }

  async stop() {
    this.isRunning = false;
    logger.info('Automated relayer stopped');
  }

  async monitorLoop() {
    while (this.isRunning) {
      try {
        if (Date.now() - this.lastBalanceCheck > 300000) {
          await this.checkBalances();
          this.lastBalanceCheck = Date.now();
        }

        await this.processPendingRoots();
        await new Promise(resolve => setTimeout(resolve, 30000));

      } catch (error) {
        logger.error('Error in relayer monitor loop:', error);
        
        if (config.safety.pauseOnError) {
          await sendAlert('Relayer error', error.message);
          await new Promise(resolve => setTimeout(resolve, 60000));
        }
      }
    }
  }

  async checkBalances() {
    try {
      const ethBalance = await this.ethProvider.getBalance(this.wallet.address);
      const megaBalance = await this.megaProvider.getBalance(this.wallet.address);

      const ethBalanceEth = parseFloat(ethers.formatEther(ethBalance));
      const megaBalanceEth = parseFloat(ethers.formatEther(megaBalance));

      logger.info(`Relayer balances - ETH: ${ethBalanceEth}, MegaETH: ${megaBalanceEth}`);

      if (ethBalanceEth < config.safety.minBalanceEth) {
        await sendAlert('Low balance alert', `Ethereum balance is low: ${ethBalanceEth} ETH`);
      }

      if (megaBalanceEth < config.safety.minBalanceMega) {
        await sendAlert('Low balance alert', `MegaETH balance is low: ${megaBalanceEth} ETH`);
      }

      await db.recordMetric('relayer_balance_eth', ethBalanceEth);
      await db.recordMetric('relayer_balance_mega', megaBalanceEth);

      // Return balance data for stats endpoint
      return {
        ethereum: {
          balance: ethBalanceEth,
          address: this.wallet.address,
          minRequired: config.safety.minBalanceEth,
          isLow: ethBalanceEth < config.safety.minBalanceEth,
        },
        megaeth: {
          balance: megaBalanceEth,
          address: this.wallet.address,
          minRequired: config.safety.minBalanceMega,
          isLow: megaBalanceEth < config.safety.minBalanceMega,
        },
      };
    } catch (error) {
      logger.error('Error checking balances:', error);
      throw error;
    }
  }

  async processPendingRoots() {
    try {
      const pendingRoots = await db.getPendingBlockRoots();

      if (pendingRoots.length === 0) {
        return;
      }

      logger.info(`Processing ${pendingRoots.length} pending root submission(s)`);

      for (const root of pendingRoots) {
        await this.submitBlockRoot(
          root.block_number,
          root.source_chain,
          root.destination_chain,
          root.merkle_root
        );
      }

    } catch (error) {
      logger.error('Error processing pending roots:', error);
      throw error;
    }
  }

  async getFormattedLocks(blockNumber, sourceChain) {
    const lockEvents = await db.getLockEventsByBlock(blockNumber, sourceChain);

    if (!lockEvents.length) {
      throw new Error(`No lock events recorded for block ${blockNumber} on ${sourceChain}`);
    }

    const normalizedBlock = BigInt(blockNumber);
    return lockEvents.map((lock) => {
      const lockBlock = BigInt(lock.block_number);
      if (lockBlock !== normalizedBlock) {
        throw new Error(`Lock ${lock.lock_hash} block mismatch`);
      }
      return {
        tokenId: BigInt(lock.token_id),
        owner: lock.owner_address,
        recipient: lock.recipient_address,
        blockNumber: lockBlock,
        lockHash: lock.lock_hash,
      };
    });
  }

  async submitBlockRoot(blockNumber, sourceChain, destinationChain, merkleRoot) {
    try {
      logger.info(`Submitting root for block ${blockNumber} from ${sourceChain} to ${destinationChain}`);

      const formattedLocks = await this.getFormattedLocks(blockNumber, sourceChain);
      const lockCount = formattedLocks.length;
      const blockNumberBigInt = BigInt(blockNumber);

      let tx, receipt;

      if (destinationChain === 'megaeth') {
        // Submit to MegaETH
        const gasEstimate = await this.megaBridge.setBlockRoot.estimateGas(
          blockNumberBigInt,
          merkleRoot,
          lockCount,
          formattedLocks
        );
        tx = await this.megaBridge.setBlockRoot(
          blockNumberBigInt,
          merkleRoot,
          lockCount,
          formattedLocks,
          {
            gasLimit: gasEstimate * 120n / 100n, // 20% buffer
          }
        );

      } else {
        // Submit to Ethereum
        const gasEstimate = await this.ethBridge.setMegaEthBlockRoot.estimateGas(
          blockNumberBigInt,
          merkleRoot,
          lockCount,
          formattedLocks
        );
        tx = await this.ethBridge.setMegaEthBlockRoot(
          blockNumberBigInt,
          merkleRoot,
          lockCount,
          formattedLocks,
          {
          gasLimit: gasEstimate * 120n / 100n, // 20% buffer
          }
        );
      }

      logger.info(`Root submission transaction sent: ${tx.hash}`);

      await db.createRelayerTransaction({
        txHash: tx.hash,
        chain: destinationChain,
        txType: 'submit_root',
        status: 'pending',
      });

      receipt = await tx.wait(config.relayer.confirmationBlocks);
      logger.info(`Root submitted successfully: ${tx.hash}`);

      await db.updateBlockRootSubmission(blockNumber, sourceChain, destinationChain, {
        submitted: true,
        submissionTxHash: tx.hash,
        submissionTimestamp: new Date(),
      });

      await db.updateRelayerTransaction(tx.hash, {
        status: 'confirmed',
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        gasPrice: receipt.gasPrice ? receipt.gasPrice.toString() : null,
      });

      await db.updateLockEventsByBlock(blockNumber, sourceChain, 'root_submitted');
      broadcastEvent('root_submitted', {
        blockNumber,
        sourceChain,
        destinationChain,
        merkleRoot,
        txHash: tx.hash,
      });

      await db.recordMetric('roots_submitted', 1, destinationChain);
      await db.recordMetric('gas_used_root_submission', parseInt(receipt.gasUsed.toString()), destinationChain);

      return { success: true, txHash: tx.hash };

    } catch (error) {
      logger.error(`Error submitting root for block ${blockNumber}:`, error);

      await db.createFailedTransaction({
        txType: 'submit_root',
        chain: destinationChain,
        payload: JSON.stringify({ blockNumber, sourceChain, destinationChain, merkleRoot }),
        errorMessage: error.message,
      });

      await sendAlert('Root submission failed', `Block ${blockNumber}: ${error.message}`);

      throw error;
    }
  }

  /**
   * Manually trigger unlock (for testing or manual intervention)
   */
  async unlockNFT(tokenId, recipient, lockHash, blockNumber, proof, destinationChain) {
    try {
      logger.info(`Unlocking NFT ${tokenId} on ${destinationChain}`);

      let tx, receipt;

      if (destinationChain === 'megaeth') {
        const gasEstimate = await this.megaBridge.unlockNFTWithProof.estimateGas(
          tokenId, recipient, lockHash, blockNumber, proof
        );
        tx = await this.megaBridge.unlockNFTWithProof(
          tokenId, recipient, lockHash, blockNumber, proof,
          { gasLimit: gasEstimate * 120n / 100n }
        );
      } else {
        const gasEstimate = await this.ethBridge.unlockNFTWithProof.estimateGas(
          tokenId, recipient, lockHash, blockNumber, proof
        );
        tx = await this.ethBridge.unlockNFTWithProof(
          tokenId, recipient, lockHash, blockNumber, proof,
          { gasLimit: gasEstimate * 120n / 100n }
        );
      }

      logger.info(`Unlock transaction sent: ${tx.hash}`);

      receipt = await tx.wait();

      logger.info(`NFT unlocked successfully: ${tx.hash}`);

      return { success: true, txHash: tx.hash };

    } catch (error) {
      logger.error(`Error unlocking NFT ${tokenId}:`, error);
      throw error;
    }
  }

  /**
   * Get current gas prices
   */
  async getGasPrices() {
    const [ethFeeData, megaFeeData] = await Promise.all([
      this.ethProvider.getFeeData(),
      this.megaProvider.getFeeData(),
    ]);

    return {
      ethereum: {
        gasPrice: ethFeeData.gasPrice ? ethers.formatUnits(ethFeeData.gasPrice, 'gwei') : null,
        maxFeePerGas: ethFeeData.maxFeePerGas ? ethers.formatUnits(ethFeeData.maxFeePerGas, 'gwei') : null,
        maxPriorityFeePerGas: ethFeeData.maxPriorityFeePerGas ? ethers.formatUnits(ethFeeData.maxPriorityFeePerGas, 'gwei') : null,
      },
      megaeth: {
        gasPrice: megaFeeData.gasPrice ? ethers.formatUnits(megaFeeData.gasPrice, 'gwei') : null,
        maxFeePerGas: megaFeeData.maxFeePerGas ? ethers.formatUnits(megaFeeData.maxFeePerGas, 'gwei') : null,
        maxPriorityFeePerGas: megaFeeData.maxPriorityFeePerGas ? ethers.formatUnits(megaFeeData.maxPriorityFeePerGas, 'gwei') : null,
      },
    };
  }
}

export const relayer = new Relayer();
