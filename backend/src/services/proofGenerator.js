import { ethers } from 'ethers';
import { MerkleTree } from 'merkletreejs';
import keccak256 from 'keccak256';
import { logger } from '../utils/logger.js';
import { db } from '../db/index.js';
import { rootQueue } from '../queue/index.js';
import { broadcastEvent } from './websocket.js';

export class ProofGenerator {
  constructor() {
    this.processing = new Set();
  }

  /**
   * Generate merkle proof for a specific block
   */
  async generateProofForBlock(blockNumber, chain) {
    const key = `${chain}-${blockNumber}`;
    
    if (this.processing.has(key)) {
      logger.warn(`Already processing proofs for block ${blockNumber} on ${chain}`);
      return;
    }

    this.processing.add(key);

    try {
      logger.info(`Generating proofs for block ${blockNumber} on ${chain}`);

      const locks = await db.getLockEventsByBlock(blockNumber, chain);

      if (locks.length === 0) {
        logger.warn(`No locks found for block ${blockNumber} on ${chain}`);
        this.processing.delete(key);
        return;
      }

      logger.info(`Found ${locks.length} lock(s) in block ${blockNumber}`);

      const leaves = locks.map(lock => {
        const leaf = ethers.solidityPackedKeccak256(
          ['uint256', 'address', 'bytes32', 'uint256'],
          [lock.token_id, lock.recipient_address, lock.lock_hash, blockNumber]
        );
        return leaf;
      });

      const tree = new MerkleTree(leaves, keccak256, { 
        sortPairs: true,
        hashLeaves: false
      });

      const root = '0x' + tree.getRoot().toString('hex');

      logger.info(`Merkle root for block ${blockNumber}: ${root}`);

      for (let i = 0; i < locks.length; i++) {
        const lock = locks[i];
        const leaf = leaves[i];
        const proof = tree.getHexProof(leaf);

        await db.createMerkleProof({
          lockHash: lock.lock_hash,
          proof: JSON.stringify(proof),
          merkleRoot: root,
          blockNumber,
          sourceChain: chain,
          destinationChain: chain === 'ethereum' ? 'megaeth' : 'ethereum',
        });

        await db.updateLockEventStatus(lock.lock_hash, 'proof_generated');
        logger.info(`Proof generated for lock ${lock.lock_hash}`);

        broadcastEvent('proof_generated', {
          lockHash: lock.lock_hash,
          tokenId: lock.token_id,
          chain,
          proof,
          merkleRoot: root,
        });
      }

      await db.createBlockRoot({
        blockNumber,
        sourceChain: chain,
        destinationChain: chain === 'ethereum' ? 'megaeth' : 'ethereum',
        merkleRoot: root,
        lockCount: locks.length,
        submitted: false,
      });

      await rootQueue.add('submit-root', {
        blockNumber,
        sourceChain: chain,
        destinationChain: chain === 'ethereum' ? 'megaeth' : 'ethereum',
        merkleRoot: root,
      }, {
        attempts: 5,
        backoff: {
          type: 'exponential',
          delay: 10000,
        },
      });

      logger.info(`Proofs generated successfully for block ${blockNumber} on ${chain}`);

    } catch (error) {
      logger.error(`Error generating proofs for block ${blockNumber} on ${chain}:`, error);
      
      await db.createFailedTransaction({
        txType: 'generate_proof',
        chain,
        payload: JSON.stringify({ blockNumber, chain }),
        errorMessage: error.message,
      });

      throw error;
    } finally {
      this.processing.delete(key);
    }
  }

  /**
   * Get proof for a specific lock hash
   */
  async getProof(lockHash) {
    try {
      const row = await db.getMerkleProof(lockHash);
      
      if (!row) {
        throw new Error(`Proof not found for lock hash: ${lockHash}`);
      }

      // PostgreSQL JSONB returns already-parsed object/array; column may also be stored as string
      let proofArray = row.proof;
      if (typeof proofArray === 'string') {
        proofArray = proofArray.trim() ? JSON.parse(proofArray) : [];
      }
      if (!Array.isArray(proofArray)) {
        proofArray = [];
      }
      // Empty proof is valid when there's only one lock in the block (single-leaf tree: leaf === root)

      return {
        lockHash,
        proof: proofArray,
        merkleRoot: row.merkle_root,
        blockNumber: row.block_number,
        sourceChain: row.source_chain,
        destinationChain: row.destination_chain,
      };
    } catch (error) {
      logger.error(`Error getting proof for ${lockHash}:`, error);
      throw error;
    }
  }

  /**
   * Verify a proof is valid
   */
  verifyProof(leaf, proof, root) {
    try {
      const tree = new MerkleTree([], keccak256, { sortPairs: true });
      return tree.verify(proof, leaf, root);
    } catch (error) {
      logger.error('Error verifying proof:', error);
      return false;
    }
  }

  /**
   * Get all pending proofs that need root submission
   */
  async getPendingRootSubmissions() {
    try {
      return await db.getPendingBlockRoots();
    } catch (error) {
      logger.error('Error getting pending root submissions:', error);
      throw error;
    }
  }
}

export const proofGenerator = new ProofGenerator();
