import Queue from 'bull';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { proofGenerator } from '../services/proofGenerator.js';
import { relayer } from '../services/relayer.js';

// Create queues
export const proofQueue = new Queue('proof-generation', config.queue.redisUrl);
export const rootQueue = new Queue('root-submission', config.queue.redisUrl);

/**
 * Process proof generation jobs
 */
proofQueue.process('generate-proof', config.queue.proofGenerationConcurrency, async (job) => {
  const { blockNumber, chain, lockHash } = job.data;
  
  logger.info(`Processing proof generation job for block ${blockNumber} on ${chain}`);
  
  try {
    await proofGenerator.generateProofForBlock(blockNumber, chain);
    logger.info(`Proof generation completed for block ${blockNumber}`);
    return { success: true, blockNumber, chain };
  } catch (error) {
    logger.error(`Proof generation failed for block ${blockNumber}:`, error);
    throw error;
  }
});

/**
 * Process root submission jobs
 */
rootQueue.process('submit-root', config.queue.rootSubmissionConcurrency, async (job) => {
  const { blockNumber, sourceChain, destinationChain, merkleRoot } = job.data;
  
  logger.info(`Processing root submission job for block ${blockNumber}`);
  
  try {
    const result = await relayer.submitBlockRoot(
      blockNumber,
      sourceChain,
      destinationChain,
      merkleRoot
    );
    logger.info(`Root submission completed for block ${blockNumber}`);
    return result;
  } catch (error) {
    logger.error(`Root submission failed for block ${blockNumber}:`, error);
    throw error;
  }
});

/**
 * Queue event handlers
 */
proofQueue.on('completed', (job, result) => {
  logger.info(`Proof generation job ${job.id} completed:`, result);
});

proofQueue.on('failed', (job, error) => {
  logger.error(`Proof generation job ${job.id} failed:`, error);
});

rootQueue.on('completed', (job, result) => {
  logger.info(`Root submission job ${job.id} completed:`, result);
});

rootQueue.on('failed', (job, error) => {
  logger.error(`Root submission job ${job.id} failed:`, error);
});

/**
 * Start queue processors
 */
export async function startQueueProcessors() {
  logger.info('Starting queue processors...');
  
  // Queues are already processing via .process() calls above
  // This function is for any additional setup
  
  logger.info('Queue processors started');
}

/**
 * Get queue stats
 */
export async function getQueueStats() {
  const [proofCounts, rootCounts] = await Promise.all([
    proofQueue.getJobCounts(),
    rootQueue.getJobCounts(),
  ]);

  return {
    proofGeneration: proofCounts,
    rootSubmission: rootCounts,
  };
}

/**
 * Clean old jobs
 */
export async function cleanOldJobs(daysOld = 7) {
  const grace = daysOld * 24 * 60 * 60 * 1000;
  
  await Promise.all([
    proofQueue.clean(grace, 'completed'),
    proofQueue.clean(grace, 'failed'),
    rootQueue.clean(grace, 'completed'),
    rootQueue.clean(grace, 'failed'),
  ]);
  
  logger.info(`Cleaned jobs older than ${daysOld} days`);
}

export default {
  proofQueue,
  rootQueue,
  startQueueProcessors,
  getQueueStats,
  cleanOldJobs,
};
