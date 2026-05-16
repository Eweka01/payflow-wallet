const jwt = require('jsonwebtoken');
const redis = require('redis');

const JWT_SECRET = process.env.JWT_SECRET || (process.env.NODE_ENV === 'production' ? null : 'dev-only-secret-change-in-production');
const REDIS_URL = process.env.REDIS_URL || 'redis://redis:6379';

let redisClient = null;
function getRedisClient() {
  if (!redisClient) {
    redisClient = redis.createClient({ url: REDIS_URL });
    redisClient.on('error', () => {});
    redisClient.connect().catch(() => {});
  }
  return redisClient;
}

async function authenticate(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  if (!JWT_SECRET) {
    return res.status(503).json({ error: 'JWT_SECRET not configured' });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);

    const rclient = getRedisClient();
    if (rclient?.isOpen) {
      try {
        const blacklisted = await Promise.race([
          rclient.get(`blacklist:${token}`),
          new Promise((_, rej) => setTimeout(() => rej(new Error('redis_timeout')), 300))
        ]);
        if (blacklisted) {
          return res.status(401).json({ error: 'Token revoked' });
        }
      } catch {
        // Redis down: continue without blacklist check to avoid locking out all users
      }
    }

    req.user = {
      userId: decoded.userId,
      email: decoded.email,
      role: decoded.role
    };
    next();
  } catch (error) {
    res.status(401).json({ error: 'Invalid or expired token' });
  }
}

function authorizeOwner(resourceIdParam = 'userId') {
  return (req, res, next) => {
    const resourceId = req.params[resourceIdParam] || req.body.fromUserId;

    if (req.user.userId !== resourceId && req.user.role !== 'admin') {
      return res.status(403).json({
        error: 'Access denied - you can only access your own resources'
      });
    }

    next();
  };
}

function authorizeRole(...roles) {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    if (!roles.includes(req.user.role)) {
      return res.status(403).json({
        error: `Access denied - requires one of: ${roles.join(', ')}`
      });
    }

    next();
  };
}

module.exports = { authenticate, authorizeOwner, authorizeRole };
