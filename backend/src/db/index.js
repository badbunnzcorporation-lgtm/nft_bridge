import pg from 'pg';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

const { Pool } = pg;

const pool = new Pool({
  connectionString: config.database.url,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

pool.on('connect', () => {
  logger.debug('Database connection established');
});

pool.on('error', (err) => {
  logger.error('Unexpected database error:', err);
});

/**
 * Database client with helper methods
 */
export const db = {
  async query(text, params) {
    const start = Date.now();
    try {
      const result = await pool.query(text, params);
      const duration = Date.now() - start;
      logger.debug(`Query executed in ${duration}ms:`, { text, rows: result.rowCount });
      return result;
    } catch (error) {
      logger.error('Database query error:', { text, error: error.message });
      throw error;
    }
  },

  /**
   * Create lock event (idempotent: same lock_hash is ignored so retries don't fail)
   */
  async createLockEvent(data) {
    const query = `
      INSERT INTO lock_events (
        token_id, owner_address, recipient_address, lock_hash,
        block_number, block_timestamp, chain, tx_hash, status
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      ON CONFLICT (lock_hash) DO NOTHING
      RETURNING *
    `;
    const values = [
      data.tokenId,
      data.ownerAddress,
      data.recipientAddress,
      data.lockHash,
      data.blockNumber,
      data.blockTimestamp,
      data.chain,
      data.txHash,
      data.status,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async getLockEvent(lockHash) {
    const query = 'SELECT * FROM lock_events WHERE lock_hash = $1';
    const result = await this.query(query, [lockHash]);
    return result.rows[0];
  },

  async getLockEventsByBlock(blockNumber, chain) {
    const query = `
      SELECT * FROM lock_events 
      WHERE block_number = $1 AND chain = $2
      ORDER BY created_at ASC
    `;
    const result = await this.query(query, [blockNumber, chain]);
    return result.rows;
  },

  async updateLockEventStatus(lockHash, status) {
    const query = `
      UPDATE lock_events 
      SET status = $1, updated_at = NOW()
      WHERE lock_hash = $2
      RETURNING *
    `;
    const result = await this.query(query, [status, lockHash]);
    return result.rows[0];
  },

  async updateLockEventsByBlock(blockNumber, chain, status) {
    const query = `
      UPDATE lock_events 
      SET status = $1, updated_at = NOW()
      WHERE block_number = $2 AND chain = $3
    `;
    await this.query(query, [status, blockNumber, chain]);
  },

  async createMerkleProof(data) {
    const query = `
      INSERT INTO merkle_proofs (
        lock_hash, proof, merkle_root, block_number,
        source_chain, destination_chain
      ) VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (lock_hash) DO UPDATE
      SET proof = $2, merkle_root = $3
      RETURNING *
    `;
    const values = [
      data.lockHash,
      data.proof,
      data.merkleRoot,
      data.blockNumber,
      data.sourceChain,
      data.destinationChain,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async getMerkleProof(lockHash) {
    const query = 'SELECT * FROM merkle_proofs WHERE lock_hash = $1';
    const result = await this.query(query, [lockHash]);
    return result.rows[0];
  },

  async createBlockRoot(data) {
    const query = `
      INSERT INTO block_roots (
        block_number, source_chain, destination_chain,
        merkle_root, lock_count, submitted
      ) VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (block_number, source_chain, destination_chain) DO UPDATE
      SET merkle_root = $4, lock_count = $5
      RETURNING *
    `;
    const values = [
      data.blockNumber,
      data.sourceChain,
      data.destinationChain,
      data.merkleRoot,
      data.lockCount,
      data.submitted || false,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async getPendingBlockRoots() {
    const query = `
      SELECT * FROM block_roots 
      WHERE submitted = false
      ORDER BY block_number ASC
    `;
    const result = await this.query(query);
    return result.rows;
  },

  async updateBlockRootSubmission(blockNumber, sourceChain, destinationChain, data) {
    const query = `
      UPDATE block_roots 
      SET submitted = $1, submission_tx_hash = $2, submission_timestamp = $3
      WHERE block_number = $4 AND source_chain = $5 AND destination_chain = $6
      RETURNING *
    `;
    const values = [
      data.submitted,
      data.submissionTxHash,
      data.submissionTimestamp,
      blockNumber,
      sourceChain,
      destinationChain,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async createUnlockEvent(data) {
    const query = `
      INSERT INTO unlock_events (
        lock_hash, token_id, recipient_address, chain,
        tx_hash, block_number, gas_used, status
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      RETURNING *
    `;
    const values = [
      data.lockHash,
      data.tokenId,
      data.recipientAddress,
      data.chain,
      data.txHash,
      data.blockNumber,
      data.gasUsed,
      data.status,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async createRelayerTransaction(data) {
    const query = `
      INSERT INTO relayer_transactions (
        tx_hash, chain, tx_type, status
      ) VALUES ($1, $2, $3, $4)
      RETURNING *
    `;
    const values = [data.txHash, data.chain, data.txType, data.status];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async updateRelayerTransaction(txHash, data) {
    const query = `
      UPDATE relayer_transactions 
      SET status = $1, block_number = $2, gas_used = $3, 
          gas_price = $4, confirmed_at = NOW()
      WHERE tx_hash = $5
      RETURNING *
    `;
    const values = [
      data.status,
      data.blockNumber,
      data.gasUsed,
      data.gasPrice,
      txHash,
    ];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  async getTokenBridgeStatus(tokenId) {
    const query = `
      SELECT 
        le.*,
        mp.proof,
        mp.merkle_root,
        br.submitted as root_submitted,
        ue.tx_hash as unlock_tx_hash
      FROM lock_events le
      LEFT JOIN merkle_proofs mp ON le.lock_hash = mp.lock_hash
      LEFT JOIN block_roots br ON le.block_number = br.block_number AND le.chain = br.source_chain
      LEFT JOIN unlock_events ue ON le.lock_hash = ue.lock_hash
      WHERE le.token_id = $1
      ORDER BY le.created_at DESC
      LIMIT 1
    `;
    const result = await this.query(query, [tokenId]);
    return result.rows[0];
  },

  async getBridgeHistory(address, page = 1, limit = 20) {
    const offset = (page - 1) * limit;
    const query = `
      SELECT * FROM bridge_history
      WHERE owner_address = $1
      ORDER BY created_at DESC
      LIMIT $2 OFFSET $3
    `;
    const result = await this.query(query, [address, limit, offset]);
    return result.rows;
  },

  async getPendingLocks() {
    const query = `
      SELECT * FROM pending_locks
      ORDER BY created_at ASC
    `;
    const result = await this.query(query);
    return result.rows;
  },

  async completeBridgeHistory(lockHash, unlockTxHash) {
    const query = `
      UPDATE bridge_history
      SET unlock_tx_hash = $1, unlock_timestamp = NOW(), 
          status = 'completed', duration_seconds = EXTRACT(EPOCH FROM (NOW() - lock_timestamp))
      WHERE lock_tx_hash = (SELECT tx_hash FROM lock_events WHERE lock_hash = $2)
    `;
    await this.query(query, [unlockTxHash, lockHash]);
  },

  async recordMetric(name, value, chain = null) {
    const query = `
      INSERT INTO system_metrics (metric_name, metric_value, chain)
      VALUES ($1, $2, $3)
    `;
    await this.query(query, [name, value, chain]);
  },

  async createFailedTransaction(data) {
    const query = `
      INSERT INTO failed_transactions (
        tx_type, chain, payload, error_message, next_retry_at
      ) VALUES ($1, $2, $3, $4, NOW() + INTERVAL '5 minutes')
      RETURNING *
    `;
    const values = [data.txType, data.chain, data.payload, data.errorMessage];
    const result = await this.query(query, values);
    return result.rows[0];
  },

  /**
   * Get/Set last processed block
   */
  async getLastProcessedBlock(chain) {
    const query = `
      SELECT MAX(block_number) as last_block
      FROM lock_events
      WHERE chain = $1
    `;
    const result = await this.query(query, [chain]);
    return result.rows[0]?.last_block || null;
  },

  async updateLastProcessedBlock(chain, blockNumber) {
    // This is tracked automatically via lock_events
    // No separate table needed
    return blockNumber;
  },
};

export default db;
