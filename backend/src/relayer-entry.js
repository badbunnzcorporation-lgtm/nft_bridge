import { relayer } from './services/relayer.js';
import { config } from './config/index.js';
import { logger } from './utils/logger.js';
import { db } from './db/index.js';

async function startRelayer() {
  try {
    logger.info('Starting standalone relayer service...');

    await db.query('SELECT 1');
    logger.info('Database connection verified');

    await relayer.start();
    logger.info('Relayer service started successfully');

    process.on('SIGTERM', async () => {
      logger.info('SIGTERM received, shutting down relayer...');
      await relayer.stop();
      process.exit(0);
    });

    process.on('SIGINT', async () => {
      logger.info('SIGINT received, shutting down relayer...');
      await relayer.stop();
      process.exit(0);
    });

  } catch (error) {
    logger.error('Failed to start relayer:', error);
    process.exit(1);
  }
}

startRelayer();
