import express from 'express';
import { body, param, validationResult } from 'express-validator';
import { db } from '../db/index.js';
import { proofGenerator } from '../services/proofGenerator.js';
import { relayer } from '../services/relayer.js';
import { logger } from '../utils/logger.js';

const router = express.Router();

// Validation middleware
const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ errors: errors.array() });
  }
  next();
};

/**
 * GET /api/bridge/status/:tokenId
 * Get bridge status for a specific token
 */
router.get('/status/:tokenId', 
  param('tokenId').isInt(),
  validate,
  async (req, res, next) => {
    try {
      const { tokenId } = req.params;
      const status = await db.getTokenBridgeStatus(tokenId);
      res.json(status);
    } catch (error) {
      next(error);
    }
  }
);

/**
 * GET /api/bridge/proof/:lockHash
 * Get merkle proof for unlocking
 */
router.get('/proof/:lockHash',
  param('lockHash').isHexadecimal().isLength({ min: 66, max: 66 }),
  validate,
  async (req, res, next) => {
    try {
      const { lockHash } = req.params;
      const proof = await proofGenerator.getProof(lockHash);
      res.json(proof);
    } catch (error) {
      next(error);
    }
  }
);

/**
 * GET /api/bridge/history/:address
 * Get bridge history for an address
 */
router.get('/history/:address',
  param('address').isEthereumAddress(),
  validate,
  async (req, res, next) => {
    try {
      const { address } = req.params;
      const { page = 1, limit = 20 } = req.query;
      const history = await db.getBridgeHistory(address, parseInt(page), parseInt(limit));
      res.json(history);
    } catch (error) {
      next(error);
    }
  }
);

/**
 * GET /api/bridge/pending
 * Get all pending bridge operations
 */
router.get('/pending', async (req, res, next) => {
  try {
    const pending = await db.getPendingLocks();
    res.json(pending);
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/bridge/lock/:lockHash
 * Get detailed info about a specific lock
 */
router.get('/lock/:lockHash',
  param('lockHash').isHexadecimal(),
  validate,
  async (req, res, next) => {
    try {
      const { lockHash } = req.params;
      const lock = await db.getLockEvent(lockHash);
      res.json(lock);
    } catch (error) {
      next(error);
    }
  }
);

/**
 * POST /api/bridge/estimate-gas
 * Estimate gas for unlock operation
 */
router.post('/estimate-gas',
  body('tokenId').isInt(),
  body('recipient').isEthereumAddress(),
  body('chain').isIn(['ethereum', 'megaeth']),
  validate,
  async (req, res, next) => {
    try {
      const { tokenId, recipient, chain } = req.body;
      // Implementation depends on your gas estimation logic
      const estimate = { gasLimit: '200000', gasPrice: '50' };
      res.json(estimate);
    } catch (error) {
      next(error);
    }
  }
);

/**
 * GET /api/bridge/gas-prices
 * Get current gas prices on both chains
 */
router.get('/gas-prices', async (req, res, next) => {
  try {
    const gasPrices = await relayer.getGasPrices();
    res.json(gasPrices);
  } catch (error) {
    next(error);
  }
});

export default router;
