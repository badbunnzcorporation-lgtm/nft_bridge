import { WebSocketServer } from 'ws';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

let wss;
const clients = new Set();

/**
 * Start WebSocket server
 */
export async function startWebSocketServer() {
  wss = new WebSocketServer({ port: config.server.wsPort });

  wss.on('connection', (ws, req) => {
    const clientIp = req.socket.remoteAddress;
    logger.info(`WebSocket client connected from ${clientIp}`);
    
    clients.add(ws);

    // Send welcome message
    ws.send(JSON.stringify({
      type: 'connected',
      message: 'Connected to Bad Bunnz Bridge WebSocket',
      timestamp: new Date().toISOString(),
    }));

    // Handle messages from client
    ws.on('message', (message) => {
      try {
        const data = JSON.parse(message.toString());
        handleClientMessage(ws, data);
      } catch (error) {
        logger.error('Error parsing WebSocket message:', error);
      }
    });

    // Handle client disconnect
    ws.on('close', () => {
      clients.delete(ws);
      logger.info(`WebSocket client disconnected from ${clientIp}`);
    });

    // Handle errors
    ws.on('error', (error) => {
      logger.error('WebSocket error:', error);
      clients.delete(ws);
    });

    // Heartbeat
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });
  });

  // Heartbeat interval
  const heartbeatInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        clients.delete(ws);
        return ws.terminate();
      }
      ws.isAlive = false;
      ws.ping();
    });
  }, 30000);

  wss.on('close', () => {
    clearInterval(heartbeatInterval);
  });

  logger.info(`WebSocket server started on port ${config.server.wsPort}`);
}

/**
 * Handle messages from clients
 */
function handleClientMessage(ws, data) {
  switch (data.type) {
    case 'subscribe':
      // Subscribe to specific token updates
      ws.subscribedTokens = ws.subscribedTokens || new Set();
      if (data.tokenId) {
        ws.subscribedTokens.add(data.tokenId);
        logger.info(`Client subscribed to token ${data.tokenId}`);
      }
      break;

    case 'unsubscribe':
      if (ws.subscribedTokens && data.tokenId) {
        ws.subscribedTokens.delete(data.tokenId);
        logger.info(`Client unsubscribed from token ${data.tokenId}`);
      }
      break;

    case 'ping':
      ws.send(JSON.stringify({ type: 'pong', timestamp: new Date().toISOString() }));
      break;

    default:
      logger.warn(`Unknown WebSocket message type: ${data.type}`);
  }
}

/**
 * Broadcast event to all connected clients
 */
export function broadcastEvent(type, data) {
  if (!wss) {
    logger.warn('WebSocket server not initialized');
    return;
  }

  const message = JSON.stringify({
    type,
    data,
    timestamp: new Date().toISOString(),
  });

  let sentCount = 0;
  clients.forEach((client) => {
    if (client.readyState === 1) { // OPEN
      // Check if client is subscribed to this token
      if (data.tokenId && client.subscribedTokens && !client.subscribedTokens.has(data.tokenId)) {
        return; // Skip if not subscribed
      }
      
      client.send(message);
      sentCount++;
    }
  });

  logger.debug(`Broadcast ${type} event to ${sentCount} client(s)`);
}

/**
 * Send event to specific client
 */
export function sendToClient(ws, type, data) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify({
      type,
      data,
      timestamp: new Date().toISOString(),
    }));
  }
}

/**
 * Get connected clients count
 */
export function getClientsCount() {
  return clients.size;
}

/**
 * Close WebSocket server
 */
export function closeWebSocketServer() {
  if (wss) {
    wss.close();
    logger.info('WebSocket server closed');
  }
}

export default {
  startWebSocketServer,
  broadcastEvent,
  sendToClient,
  getClientsCount,
  closeWebSocketServer,
};
