const express = require('express');
const { Pool } = require('pg');
const redis = require('redis');
const helmet = require('helmet');
const morgan = require('morgan');
const { body, param, validationResult } = require('express-validator');
const client = require('prom-client');
const logger = require('./shared/logger');
const { register: sharedRegister, metricsMiddleware, metricsHandler, transactionTotal, databaseQueryDuration, cacheHitRate, dbQueryErrors, dbConnectionErrors, dbConnectionPoolSize } = require('./shared/metrics');
require('dotenv').config();

// #### Prometheus Metrics Setup ####
// #### Use shared register for SLI/SLO metrics ####

const app = express();
const PORT = process.env.PORT || 3001;

// ============================================
// LOGGING SETUP
// ============================================
// Set service name for shared logger
process.env.SERVICE_NAME = 'wallet-service';

// ============================================
// METRICS SETUP
// ============================================
// Use shared register for SLI/SLO metrics (shared/metrics already calls collectDefaultMetrics)
const register = sharedRegister;

// Service-specific metrics (getSingleMetric avoids "already registered" if same register used elsewhere)
const dbConnections = register.getSingleMetric('database_connections_active') ||
  new client.Gauge({
    name: 'database_connections_active',
    help: 'Number of active database connections',
    labelNames: ['database'],
    registers: [register]
  });

const redisOperations = register.getSingleMetric('redis_operations_total') ||
  new client.Counter({
    name: 'redis_operations_total',
    help: 'Total number of Redis operations',
    labelNames: ['operation', 'status'],
    registers: [register]
  });

const transfers = register.getSingleMetric('transfers_total') ||
  new client.Counter({
    name: 'transfers_total',
    help: 'Total number of money transfers',
    labelNames: ['status', 'service', 'amount_range'],
    registers: [register]
  });

const failedTransfers = register.getSingleMetric('failed_transfers_total') ||
  new client.Counter({
    name: 'failed_transfers_total',
    help: 'Total number of failed transfers',
    labelNames: ['reason', 'service'],
    registers: [register]
  });

// ============================================
// MIDDLEWARE
// ============================================
app.use(helmet());
app.use(morgan('combined'));
app.use(express.json({ limit: '10kb' }));

// Correlation ID middleware
app.use((req, res, next) => {
  req.correlationId = req.headers['x-correlation-id'] || `wallet-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
  res.setHeader('X-Correlation-Id', req.correlationId);
  next();
});

// #### Metrics Collection Middleware ####
// #### Use shared metricsMiddleware for SLI/SLO tracking ####
app.use(metricsMiddleware);

// ============================================
// DATABASE CONNECTION
// ============================================
// rejectUnauthorized: false for AWS RDS (RDS TLS cert not in Node default trust store)
const DEFAULT_INSECURE_DB_PASSWORD = 'payflow123';
if (process.env.NODE_ENV === 'production') {
  if (!process.env.DB_PASSWORD || process.env.DB_PASSWORD === DEFAULT_INSECURE_DB_PASSWORD) {
    throw new Error('DB_PASSWORD must be set to a non-default value in production (do not use the default placeholder)');
  }
}
const pool = new Pool({
  host: process.env.DB_HOST || 'postgres',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'payflow',
  user: process.env.DB_USER || 'payflow',
  password: process.env.DB_PASSWORD || DEFAULT_INSECURE_DB_PASSWORD,
  max: parseInt(process.env.PG_POOL_MAX || '5', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,  // 10s for RDS cold start / TLS handshake
  ssl: process.env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
});

function updateDbPoolMetrics() {
  try {
    dbConnectionPoolSize.set({ state: 'active' }, Math.max(0, pool.totalCount - pool.idleCount));
    dbConnectionPoolSize.set({ state: 'idle' }, pool.idleCount);
    dbConnectionPoolSize.set({ state: 'waiting' }, pool.waitingCount || 0);
  } catch (_) {
    /* ignore */
  }
}
setInterval(updateDbPoolMetrics, 15000);
updateDbPoolMetrics();

// Wrap pool.query to measure duration using shared metrics
const originalQuery = pool.query.bind(pool);
pool.query = async function(...args) {
  const start = Date.now();
  const queryType = args[0]?.trim().substring(0, 6).toUpperCase() || 'UNKNOWN';
  try {
    const result = await originalQuery(...args);
    const duration = (Date.now() - start) / 1000;
    databaseQueryDuration.labels(queryType).observe(duration);
    return result;
  } catch (error) {
    const duration = (Date.now() - start) / 1000;
    databaseQueryDuration.labels('error').observe(duration);
    dbQueryErrors.labels(error.code || 'unknown', 'wallet-service').inc();
    throw error;
  }
};

// ============================================
// REDIS CONNECTION
// ============================================
const redisClient = redis.createClient({
  url: process.env.REDIS_URL || 'redis://redis:6379'
});

redisClient.on('error', (err) => logger.error('Redis error:', err));
redisClient.on('connect', () => logger.info('Redis connected'));

// Connect to Redis
(async () => {
  try {
    await redisClient.connect();
  } catch (error) {
    logger.error('Failed to connect to Redis:', error);
  }
})();

// ============================================
// INITIALIZE DATABASE
// ============================================
async function initDB() {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS wallets (
        user_id VARCHAR(50) PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        name VARCHAR(100) NOT NULL,
        balance DECIMAL(15,2) NOT NULL DEFAULT 0.00,
        currency VARCHAR(3) DEFAULT 'USD',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // Create index
    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_wallets_user ON wallets(user_id)
    `);

    logger.info('Database initialized');
  } catch (error) {
    logger.error('Database initialization error:', error);
  } finally {
    client.release();
  }
}

initDB().catch(console.error);

// ============================================
// VALIDATION MIDDLEWARE
// ============================================
const validate = (validations) => {
  return async (req, res, next) => {
    await Promise.all(validations.map(validation => validation.run(req)));
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ 
        error: 'Validation failed',
        details: errors.array() 
      });
    }
    next();
  };
};

// ============================================
// ROUTES
// ============================================

// Health check (return 200 if app can serve; avoid 503 on Redis timeout so k8s liveness doesn't kill pod)
app.get('/health', async (req, res) => {
  let redisOk;
  try {
    await pool.query('SELECT 1');
  } catch (e) {
    logger.error('Health check failed:', e);
    return res.status(503).json({ status: 'unhealthy', error: `database: ${e.message}` });
  }
  try {
    const redisPing = await Promise.race([
      redisClient.ping(),
      new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 2000))
    ]);
    redisOk = redisPing === 'PONG';
  } catch (e) {
    redisOk = false;
  }
  res.json({
    status: 'healthy',
    service: 'wallet-service',
    database: 'connected',
    redis: redisOk ? 'connected' : 'disconnected',
    timestamp: new Date().toISOString()
  });
});

// Metrics endpoint (uses shared metricsHandler)
app.get('/metrics', metricsHandler);

// Get all wallets — must only be called from API gateway (internal); do not expose this service publicly.
app.get('/wallets', async (req, res) => {
  const correlationId = req.correlationId;
  
  try {
    // Try cache first
    const cached = await redisClient.get('wallets:all');
    if (cached) {
      cacheHitRate.labels('wallets', 'hit').inc();
      logger.info('Cache hit for all wallets', { correlationId });
      return res.json(JSON.parse(cached));
    }

    cacheHitRate.labels('wallets', 'miss').inc();
    
    const result = await pool.query('SELECT * FROM wallets ORDER BY name');
    
    // Cache for 30 seconds
    await redisClient.setEx('wallets:all', 30, JSON.stringify(result.rows));
    
    logger.info('Retrieved all wallets', { 
      correlationId,
      count: result.rows.length 
    });
    
    res.json(result.rows);
  } catch (error) {
    logger.error('Failed to get wallets', { 
      correlationId,
      error: error.message 
    });
    res.status(500).json({ error: error.message });
  }
});

// Get wallet by user ID
app.get('/wallets/:userId', 
  validate([
    param('userId').isString().trim().notEmpty()
  ]),
  async (req, res) => {
    const { userId } = req.params;
    const correlationId = req.correlationId;
    
    try {
      // Try cache first
      const cacheKey = `wallet:${userId}`;
      const cached = await redisClient.get(cacheKey);
      
      if (cached) {
        cacheHitRate.labels('wallet', 'hit').inc();
        logger.info('Cache hit for wallet', { correlationId, userId });
        return res.json(JSON.parse(cached));
      }

      cacheHitRate.labels('wallet', 'miss').inc();

      const result = await pool.query(
        'SELECT * FROM wallets WHERE user_id = $1',
        [userId]
      );

      if (result.rows.length === 0) {
        logger.warn('Wallet not found', { correlationId, userId });
        return res.status(404).json({ error: 'Wallet not found' });
      }

      // Cache for 5 seconds (reduce stale balance after transfers)
      await redisClient.setEx(cacheKey, 5, JSON.stringify(result.rows[0]));

      logger.info('Retrieved wallet', { 
        correlationId, 
        userId,
        balance: result.rows[0].balance 
      });

      res.json(result.rows[0]);
    } catch (error) {
      logger.error('Failed to get wallet', { 
        correlationId,
        userId,
        error: error.message 
      });
      res.status(500).json({ error: error.message });
    }
  }
);

// Create wallet (internal use - called by auth service)
app.post('/wallets',
  validate([
    body('user_id').isString().trim().notEmpty(),
    body('name').isString().trim().isLength({ min: 2, max: 100 }),
    body('balance').optional().isFloat({ min: 0 })
  ]),
  async (req, res) => {
    const { user_id, name, balance = 1000.00 } = req.body;
    const correlationId = req.correlationId;

    try {
      const result = await pool.query(
        `INSERT INTO wallets (user_id, name, balance) 
         VALUES ($1, $2, $3) 
         ON CONFLICT (user_id) DO NOTHING
         RETURNING *`,
        [user_id, name, balance]
      );

      if (result.rows.length === 0) {
        logger.warn('Wallet already exists', { correlationId, user_id });
        return res.status(409).json({ error: 'Wallet already exists' });
      }

      // Invalidate cache
      await redisClient.del('wallets:all');

      logger.info('Wallet created', { 
        correlationId,
        user_id,
        balance 
      });

      res.status(201).json(result.rows[0]);
    } catch (error) {
      logger.error('Failed to create wallet', { 
        correlationId,
        user_id,
        error: error.message 
      });
      res.status(500).json({ error: error.message });
    }
  }
);

// Transfer funds (internal use - called by transaction service)
// #### Transfer Endpoint with Metrics Tracking ####
// #### This endpoint tracks transaction metrics and database performance ####
// ============================================
// TRANSFER MONEY ENDPOINT
// ============================================
// This is where money actually moves between wallets
// Called by Transaction Service worker when processing a transaction
//
// Critical: Database Transaction (ACID)
// - BEGIN: Start transaction
// - FOR UPDATE: Lock rows (prevents concurrent modifications)
// - UPDATE: Debit sender, credit receiver
// - COMMIT: Save all changes (or ROLLBACK if error)
//
// Why database transactions?
// - Atomicity: Either both updates happen, or neither
// - Isolation: Row locks prevent race conditions
// - Consistency: Balances always add up correctly
//
// Flow:
// Transaction Service → Wallet Service → PostgreSQL (atomic transfer)
app.post('/wallets/transfer',
  validate([
    body('fromUserId').isString().trim().notEmpty(),
    body('toUserId').isString().trim().notEmpty(),
    body('amount').isFloat({ min: 0.01 })
  ]),
  async (req, res) => {
    const { fromUserId, toUserId, amount } = req.body;
    const correlationId = req.correlationId;
    
    const client = await pool.connect();
    
    try {
      // STEP 1: Start database transaction
      // All operations below will either all succeed (COMMIT) or all fail (ROLLBACK)
      await client.query('BEGIN');
      
      // Track database connection for monitoring
      dbConnections.set({ database: 'postgresql' }, pool.totalCount);

      logger.info('Starting transfer', {
        correlationId,
        fromUserId,
        toUserId,
        amount
      });

      // STEP 2 & 3: Lock both wallets in lexicographic order to avoid deadlock (A→B and B→A)
      const [firstId, secondId] = fromUserId < toUserId ? [fromUserId, toUserId] : [toUserId, fromUserId];
      const first = await client.query(
        'SELECT user_id, balance FROM wallets WHERE user_id = $1 FOR UPDATE',
        [firstId]
      );
      const second = await client.query(
        'SELECT user_id, balance FROM wallets WHERE user_id = $1 FOR UPDATE',
        [secondId]
      );
      const fromWallet = firstId === fromUserId ? first : second;

      // STEP 4: Validate wallets exist
      if (first.rows.length === 0 || second.rows.length === 0) {
        await client.query('ROLLBACK');  // Cancel transaction
        logger.error('Wallet not found in transfer', {
          correlationId,
          fromUserId,
          toUserId
        });
        
        // Track failed transfer for monitoring
        failedTransfers.inc({ reason: 'wallet_not_found', service: 'wallet-service' });
        
        return res.status(404).json({ error: 'Wallet not found' });
      }

      // STEP 5: Check sufficient funds
      // This prevents negative balances
      if (parseFloat(fromWallet.rows[0].balance) < amount) {
        await client.query('ROLLBACK');  // Cancel transaction
        logger.warn('Insufficient funds', {
          correlationId,
          fromUserId,
          available: fromWallet.rows[0].balance,
          requested: amount
        });
        
        // Track failed transfer for monitoring
        failedTransfers.inc({ reason: 'insufficient_funds', service: 'wallet-service' });
        
        return res.status(400).json({ error: 'Insufficient funds' });
      }

      // STEP 6: Debit sender (subtract money)
      // This happens inside the transaction - not committed yet
      await client.query(
        'UPDATE wallets SET balance = balance - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [amount, fromUserId]
      );

      // STEP 7: Credit receiver (add money)
      // This also happens inside the transaction
      await client.query(
        'UPDATE wallets SET balance = balance + $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [amount, toUserId]
      );

      // STEP 8: Commit transaction
      // This saves all changes atomically
      // If this fails, both updates are rolled back (no partial transfer)
      await client.query('COMMIT');

      // Invalidate cache (including balance keys used by GET /wallets/:userId/balance)
      await Promise.all([
        redisClient.del(`wallet:${fromUserId}`),
        redisClient.del(`wallet:${toUserId}`),
        redisClient.del(`wallet:${fromUserId}:balance`),
        redisClient.del(`wallet:${toUserId}:balance`),
        redisClient.del('wallets:all')
      ]);

      logger.info('Transfer completed successfully', {
        correlationId,
        fromUserId,
        toUserId,
        amount
      });

      // Track successful transaction
      transactionTotal.inc({ status: 'success', type: 'transfer', service: 'wallet-service' });
      
      // Track successful transfer
      const amountRange = amount < 100 ? 'small' : amount < 1000 ? 'medium' : 'large';
      transfers.inc({ status: 'success', service: 'wallet-service', amount_range: amountRange });
      
      // Track Redis operations
      redisOperations.inc({ operation: 'del', status: 'success' });

      res.json({ 
        success: true, 
        message: 'Transfer completed',
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      await client.query('ROLLBACK');
      
      // Track failed transaction
      transactionTotal.inc({ status: 'failed', type: 'transfer', service: 'wallet-service' });
      
      // Track failed transfer
      failedTransfers.inc({ reason: 'system_error', service: 'wallet-service' });
      
      logger.error('Transfer failed', {
        correlationId,
        fromUserId,
        toUserId,
        amount,
        error: error.message
      });
      res.status(500).json({ error: error.message });
    } finally {
      client.release();
    }
  }
);

// Get wallet balance (quick endpoint)
app.get('/wallets/:userId/balance',
  validate([
    param('userId').isString().trim().notEmpty()
  ]),
  async (req, res) => {
    const { userId } = req.params;
    const correlationId = req.correlationId;

    try {
      // Try cache first
      const cacheKey = `wallet:${userId}:balance`;
      const cached = await redisClient.get(cacheKey);

      if (cached) {
        cacheHitRate.labels('balance', 'hit').inc();
        return res.json({ balance: parseFloat(cached) });
      }

      cacheHitRate.labels('balance', 'miss').inc();

      const result = await pool.query(
        'SELECT balance FROM wallets WHERE user_id = $1',
        [userId]
      );

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Wallet not found' });
      }

      const balance = result.rows[0].balance;

      // Cache for 10 seconds (balance changes frequently)
      await redisClient.setEx(cacheKey, 10, balance.toString());

      res.json({ balance: parseFloat(balance) });
    } catch (error) {
      logger.error('Failed to get balance', {
        correlationId,
        userId,
        error: error.message
      });
      res.status(500).json({ error: error.message });
    }
  }
);

// Error handling middleware
app.use((err, req, res, next) => {
  logger.error('Unhandled error:', {
    correlationId: req.correlationId,
    error: err.message,
    stack: err.stack
  });
  res.status(err.status || 500).json({
    error: err.message || 'Internal server error',
    correlationId: req.correlationId
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ 
    error: 'Route not found',
    correlationId: req.correlationId
  });
});

// ============================================
// SERVER STARTUP
// ============================================
const server = app.listen(PORT, () => {
  logger.info(`Wallet service running on port ${PORT}`);
});

// Graceful shutdown (12-factor: disposability) with timeout under terminationGracePeriodSeconds
const shutdown = (signal) => {
  logger.info(`${signal} received: closing HTTP server`);
  const deadline = Date.now() + 25000; // 25s
  server.close(async () => {
    logger.info('HTTP server closed');
    try {
      await pool.end();
      await redisClient.quit();
      process.exit(0);
    } catch (err) {
      logger.error('Shutdown error', err);
      process.exit(1);
    }
  });
  setTimeout(() => {
    logger.error('Shutdown timeout, exiting');
    process.exit(1);
  }, Math.max(0, deadline - Date.now()));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = app; // For testing