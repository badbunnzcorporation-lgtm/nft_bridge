import express from 'express';
import { db } from '../db/index.js';
import { relayer } from '../services/relayer.js';
import { getQueueStats } from '../queue/index.js';
import { getClientsCount } from '../services/websocket.js';

const router = express.Router();

/**
 * GET /api/stats
 * Get overall bridge statistics
 */
router.get('/', async (req, res, next) => {
  try {
    const query = `
      SELECT 
        COUNT(*) FILTER (WHERE status = 'unlocked') as completed_bridges,
        COUNT(*) FILTER (WHERE status IN ('pending', 'proof_generated', 'root_submitted')) as pending_bridges,
        COUNT(*) FILTER (WHERE status = 'failed') as failed_bridges,
        AVG(EXTRACT(EPOCH FROM (updated_at - created_at))) FILTER (WHERE status = 'unlocked') as avg_bridge_time_seconds,
        COUNT(DISTINCT token_id) as unique_tokens_bridged,
        COUNT(DISTINCT owner_address) as unique_users
      FROM lock_events
    `;
    
    const result = await db.query(query);
    const stats = result.rows[0];

    // Get queue stats
    const queueStats = await getQueueStats();

    // Get WebSocket clients
    const wsClients = getClientsCount();

    res.json({
      bridges: {
        completed: parseInt(stats.completed_bridges),
        pending: parseInt(stats.pending_bridges),
        failed: parseInt(stats.failed_bridges),
        avgTimeSeconds: parseFloat(stats.avg_bridge_time_seconds) || 0,
      },
      tokens: {
        uniqueBridged: parseInt(stats.unique_tokens_bridged),
      },
      users: {
        unique: parseInt(stats.unique_users),
      },
      queues: queueStats,
      websocket: {
        connectedClients: wsClients,
      },
    });
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/stats/relayer
 * Get relayer statistics
 */
router.get('/relayer', async (req, res, next) => {
  try {
    const balances = await relayer.checkBalances();
    const gasPrices = await relayer.getGasPrices();

    const txQuery = `
      SELECT 
        chain,
        tx_type,
        COUNT(*) as count,
        COUNT(*) FILTER (WHERE status = 'confirmed') as confirmed,
        COUNT(*) FILTER (WHERE status = 'failed') as failed,
        AVG(gas_used::numeric) as avg_gas_used
      FROM relayer_transactions
      WHERE created_at > NOW() - INTERVAL '24 hours'
      GROUP BY chain, tx_type
    `;
    
    const txResult = await db.query(txQuery);

    res.json({
      balances,
      gasPrices,
      transactions: txResult.rows,
    });
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/stats/chain/:chain
 * Get statistics for a specific chain
 */
router.get('/chain/:chain', async (req, res, next) => {
  try {
    const { chain } = req.params;

    const query = `
      SELECT 
        COUNT(*) as total_locks,
        COUNT(*) FILTER (WHERE status = 'unlocked') as completed,
        COUNT(*) FILTER (WHERE status IN ('pending', 'proof_generated', 'root_submitted')) as pending,
        MAX(block_number) as last_processed_block,
        COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') as locks_24h
      FROM lock_events
      WHERE chain = $1
    `;
    
    const result = await db.query(query, [chain]);

    res.json(result.rows[0]);
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/stats/recent
 * Get recent bridge activity
 */
router.get('/recent', async (req, res, next) => {
  try {
    const raw = req.query.limit;
    const limit = Math.min(100, Math.max(1, parseInt(raw, 10) || 10));

    const query = `
      SELECT 
        le.token_id,
        le.chain,
        le.status,
        le.created_at,
        le.updated_at,
        ue.tx_hash as unlock_tx_hash,
        EXTRACT(EPOCH FROM (le.updated_at - le.created_at)) as duration_seconds
      FROM lock_events le
      LEFT JOIN unlock_events ue ON le.lock_hash = ue.lock_hash
      ORDER BY le.created_at DESC
      LIMIT $1
    `;
    
    const result = await db.query(query, [limit]);

    res.json(result.rows);
  } catch (error) {
    next(error);
  }
});

export default router;
