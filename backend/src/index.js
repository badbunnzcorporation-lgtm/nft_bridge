import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import rateLimit from 'express-rate-limit';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { config } from './config/index.js';
import { logger } from './utils/logger.js';
import { db } from './db/index.js';
import { startAllListeners } from './services/eventListener.js';
import { relayer } from './services/relayer.js';
import { startWebSocketServer } from './services/websocket.js';
import { startQueueProcessors } from './queue/index.js';
import bridgeRoutes from './routes/bridge.js';
import statsRoutes from './routes/stats.js';
import { errorHandler } from './middleware/errorHandler.js';
import { requireApiKey } from './middleware/apiKey.js';

const app = express();

// Trust proxy (e.g. Railway) so rate-limit and X-Forwarded-For work
app.set('trust proxy', 1);

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(morgan('combined', { stream: { write: message => logger.info(message.trim()) } }));

app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
  });
});

const apiRouter = express.Router();

if (config.api.key) {
  apiRouter.use(requireApiKey);
}

if (config.api.rateLimitMaxRequests > 0) {
  const limiter = rateLimit({
    windowMs: config.api.rateLimitWindowMs,
    max: config.api.rateLimitMaxRequests,
    standardHeaders: true,
    legacyHeaders: false,
  });
  apiRouter.use(limiter);
}

apiRouter.use('/bridge', bridgeRoutes);
apiRouter.use('/stats', statsRoutes);

app.use('/api', apiRouter);

app.use(errorHandler);

async function runMigration() {
  try {
    logger.info('Checking database schema...');
    
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = dirname(__filename);
    const schemaPath = join(__dirname, 'db', 'schema.sql');
    const schema = readFileSync(schemaPath, 'utf8');
    
    await db.query(schema);
    logger.info('✅ Database schema initialized');
  } catch (error) {
    if (error.message.includes('already exists') || error.code === '42P07') {
      logger.info('Database schema already exists, skipping migration');
    } else {
      logger.error('Migration failed:', error.message);
      throw error;
    }
  }
}

async function start() {
  try {
    logger.info('Starting Bad Bunnz Bridge Backend...');

    await runMigration();

    app.listen(config.server.port, () => {
      logger.info(`API server listening on port ${config.server.port}`);
    });

    await startWebSocketServer();
    await startQueueProcessors();
    await startAllListeners();

    if (config.relayer.autoSubmitRoots) {
      await relayer.start();
      logger.info('Automated relayer started');
    } else {
      logger.warn('Automated relayer is disabled');
    }

    logger.info('Bad Bunnz Bridge Backend started successfully');

  } catch (error) {
    logger.error('Failed to start backend:', error);
    process.exit(1);
  }
}

process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, shutting down gracefully...');
  await relayer.stop();
  process.exit(0);
});

process.on('SIGINT', async () => {
  logger.info('SIGINT received, shutting down gracefully...');
  await relayer.stop();
  process.exit(0);
});

start();
