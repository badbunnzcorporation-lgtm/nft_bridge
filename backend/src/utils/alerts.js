import { config } from '../config/index.js';
import { logger } from './logger.js';

/**
 * Send alert to configured webhook (Slack, Discord, etc.)
 */
export async function sendAlert(title, message, severity = 'warning') {
  if (!config.monitoring.alertWebhookUrl) {
    logger.warn('Alert webhook not configured, skipping alert');
    return;
  }

  try {
    const payload = {
      text: `🚨 *${title}*`,
      attachments: [
        {
          color: severity === 'error' ? 'danger' : 'warning',
          fields: [
            {
              title: 'Message',
              value: message,
              short: false,
            },
            {
              title: 'Severity',
              value: severity,
              short: true,
            },
            {
              title: 'Timestamp',
              value: new Date().toISOString(),
              short: true,
            },
          ],
        },
      ],
    };

    const response = await fetch(config.monitoring.alertWebhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      throw new Error(`Alert webhook returned ${response.status}`);
    }

    logger.info(`Alert sent: ${title}`);
  } catch (error) {
    logger.error('Failed to send alert:', error);
  }
}

/**
 * Send critical alert
 */
export async function sendCriticalAlert(title, message) {
  await sendAlert(title, message, 'error');
}

/**
 * Send info alert
 */
export async function sendInfoAlert(title, message) {
  await sendAlert(title, message, 'info');
}

export default { sendAlert, sendCriticalAlert, sendInfoAlert };
