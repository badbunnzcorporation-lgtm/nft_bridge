import { config } from '../config/index.js';

export function requireApiKey(req, res, next) {
  if (!config.api.key) {
    return next();
  }

  const suppliedKey = req.header('x-api-key');
  if (suppliedKey !== config.api.key) {
    return res.status(401).json({
      error: {
        message: 'Invalid or missing API key',
        status: 401,
      },
    });
  }

  return next();
}

export default { requireApiKey };
