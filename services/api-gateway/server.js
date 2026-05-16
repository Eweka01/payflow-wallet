const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const axios = require('axios');
const { authenticate, authorizeOwner, authorizeRole } = require('./middleware/auth');
const { validate, validators } = require('./middleware/validation');

// Return safe error payload for client (avoid leaking internal error.message e.g. ECONNREFUSED)
function clientErrorPayload(err, fallback = 'Service unavailable') {
  const data = err.response?.data;
  if (data && typeof data === 'object' && data.error) return { error: data.error };
  return { error: fallback };
}

const { Counter, Gauge } = require('prom-client');
const { register, metricsMiddleware, metricsHandler, transactionTotal } = require('./shared/metrics');
require('dotenv').config();

const infrastructureHealth = new Gauge({
  name: 'infrastructure_health',
  help: 'Health status of infrastructure services (1=healthy, 0=down)',
  labelNames: ['service', 'type'],
  registers: [register]
});

const circuitBreakerState = new Gauge({
  name: 'circuit_breaker_state',
  help: 'Circuit breaker state (0=closed, 1=open, 2=half-open)',
  labelNames: ['service', 'operation'],
  registers: [register]
});
// Note: api-gateway exports SLI/SLO metrics via `./shared/metrics`. Avoid declaring
// additional unused metrics here; keep this file lean.

const serviceSuccessRate = new Gauge({
  name: 'service_success_rate',
  help: 'Success rate of service operations (0-1)',
  labelNames: ['service', 'operation'],
  registers: [register]
});

const userSignups = new Counter({
  name: 'user_signups_total',
  help: 'Total number of user registrations',
  labelNames: ['status', 'service'],
  registers: [register]
});

const transfers = register.getSingleMetric('transfers_total') ||
  new Counter({
    name: 'transfers_total',
    help: 'Total number of money transfers',
    labelNames: ['status', 'service', 'amount_range'],
    registers: [register]
  });

const failedTransfers = register.getSingleMetric('failed_transfers_total') ||
  new Counter({
    name: 'failed_transfers_total',
    help: 'Total number of failed transfers',
    labelNames: ['reason', 'service'],
    registers: [register]
  });

const app = express();
const PORT = process.env.PORT || 3000;

// Single persistent pool for infrastructure health checks (avoids connection leak)
const { Pool } = require('pg');
if (!process.env.DB_PASSWORD) {
  throw new Error('DB_PASSWORD must be set (api-gateway health check requires database access)');
}
const healthCheckPool = new Pool({
  host: process.env.DB_HOST || 'postgres',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME || 'payflow',
  user: process.env.DB_USER || 'payflow',
  password: process.env.DB_PASSWORD,
  max: 1,
  idleTimeoutMillis: 10000,
  connectionTimeoutMillis: 5000,
  // Secure by default. Only disable CA verification if explicitly configured (e.g. for legacy/self-signed setups).
  ssl: process.env.PGSSLMODE === 'require'
    ? { rejectUnauthorized: process.env.PGSSL_REJECT_UNAUTHORIZED !== 'false' }
    : false
});

const checkInfrastructureHealth = async () => {
  try {
    try {
      const client = await healthCheckPool.connect();
      await client.query('SELECT 1');
      client.release();
      infrastructureHealth.set({ service: 'postgresql', type: 'database' }, 1);
    } catch (error) {
      infrastructureHealth.set({ service: 'postgresql', type: 'database' }, 0);
    }

    try {
      const redis = require('redis');
      const redisClient = redis.createClient({ url: process.env.REDIS_URL || 'redis://redis:6379' });
      await redisClient.connect();
      await redisClient.ping();
      await redisClient.quit();
      infrastructureHealth.set({ service: 'redis', type: 'cache' }, 1);
    } catch (error) {
      infrastructureHealth.set({ service: 'redis', type: 'cache' }, 0);
    }

    // RabbitMQ management UI is often HTTP-only in dev; avoid insecure HTTP checks here.
    // If you need RabbitMQ health, implement an AMQP ping using RABBITMQ_URL instead.
    infrastructureHealth.set({ service: 'rabbitmq', type: 'queue' }, 1);

    // #### Check Internal Microservices ####
    // #### Test all PayFlow services by calling their health endpoints ####
    const services = [
      { name: 'auth-service', port: 3004 },
      { name: 'wallet-service', port: 3001 },
      { name: 'transaction-service', port: 3002 },
      { name: 'notification-service', port: 3003 }
    ];
    
    for (const service of services) {
      try {
        await axios.get(`http://${service.name}:${service.port}/health`, { timeout: 5000 });
        serviceSuccessRate.set({ service: service.name, operation: 'health_check' }, 1);
      } catch (error) {
        serviceSuccessRate.set({ service: service.name, operation: 'health_check' }, 0);
      }
    }
  } catch (error) {
    console.error('Infrastructure health check failed:', error);
  }
};

// #### Circuit Breaker Implementation ####
// #### This prevents cascading failures when services are down ####
// #### Circuit breaker has 3 states: Closed (working), Open (broken), Half-Open (testing) ####
const circuitBreakers = new Map(); // #### Store circuit breaker states ####

// #### Get or create circuit breaker for a service/operation ####
const getCircuitBreaker = (service, operation) => {
  const key = `${service}-${operation}`; // #### Unique key for each service-operation ####
  if (!circuitBreakers.has(key)) { // #### Create new circuit breaker if doesn't exist ####
    circuitBreakers.set(key, {
      state: 0, // #### 0=closed (working), 1=open (broken), 2=half-open (testing) ####
      failures: 0, // #### Count of consecutive failures ####
      lastFailure: null, // #### Timestamp of last failure ####
      threshold: 5, // #### Number of failures before opening circuit ####
      timeout: 60000 // #### Time to wait before trying again (1 minute) ####
    });
  }
  return circuitBreakers.get(key); // #### Return circuit breaker state ####
};

// #### Execute function with circuit breaker protection ####
const executeWithCircuitBreaker = async (service, operation, fn) => {
  const breaker = getCircuitBreaker(service, operation); // #### Get circuit breaker ####
  const now = Date.now(); // #### Current timestamp ####

  // #### Check if circuit breaker should be reset ####
  // #### If circuit is open and timeout has passed, try half-open ####
  if (breaker.state === 1 && (now - breaker.lastFailure) > breaker.timeout) {
    breaker.state = 2; // #### half-open - testing if service is back ####
    circuitBreakerState.set({ service, operation }, 2); // #### Update Prometheus metric ####
  }

  // #### If circuit is open, reject immediately ####
  // #### Don't call the service if it's known to be broken ####
  if (breaker.state === 1) {
    circuitBreakerState.set({ service, operation }, 1); // #### Update metric ####
    throw new Error(`Circuit breaker open for ${service}-${operation}`); // #### Throw error ####
  }

  try {
    const result = await fn(); // #### Try to call the service ####
    // #### Success - reset circuit breaker ####
    breaker.failures = 0; // #### Reset failure count ####
    breaker.state = 0; // #### Set to closed (working) ####
    circuitBreakerState.set({ service, operation }, 0); // #### Update metric ####
    return result; // #### Return successful result ####
  } catch (error) {
    breaker.failures++; // #### Increment failure count ####
    breaker.lastFailure = now; // #### Record failure time ####
    
    // #### If too many failures, open the circuit ####
    if (breaker.failures >= breaker.threshold) {
      breaker.state = 1; // #### open - stop calling this service ####
      circuitBreakerState.set({ service, operation }, 1); // #### Update metric ####
    }
    throw error;
  }
};

// #### Periodic Infrastructure Health Checks ####
// #### Run health checks every 30 seconds to keep metrics updated ####
setInterval(checkInfrastructureHealth, 30000); // #### 30 seconds = 30000 milliseconds ####
checkInfrastructureHealth(); // #### Run initial check immediately ####

// #### Express Middleware Setup ####
// #### These middleware functions run on every request ####

// #### Security Middleware ####
app.use(helmet()); // #### Sets security headers (X-Frame-Options, X-XSS-Protection, etc.) ####
app.set('trust proxy', 1); // #### Trust proxy headers from ingress controller ####
// CORS: with credentials:true, origin cannot be '*' (browser blocks). Use explicit CORS_ORIGIN or reflect request origin.
app.use(cors({
  origin: process.env.CORS_ORIGIN || true, // true = reflect request Origin (same-origin works)
  credentials: true
}));
app.use(morgan('combined')); // #### Log all HTTP requests ####
app.use(express.json({ limit: '10kb' })); // #### Parse JSON bodies, limit to 10KB ####

// #### Rate Limiting Configuration ####
// #### Prevents abuse by limiting requests per IP address ####
const isDevelopment = process.env.NODE_ENV !== 'production'; // #### Check if running in development ####

// #### General Rate Limiter ####
// #### Applies to all API routes ####
const generalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // #### 15 minutes window ####
  max: isDevelopment ? 1000 : 100, // #### 1000 requests in dev, 100 in production ####
  message: 'Too many requests from this IP', // #### Error message ####
  skipSuccessfulRequests: true, // #### Don't count successful requests ####
  standardHeaders: true, // #### Add rate limit headers to response ####
  legacyHeaders: false // #### Don't add legacy headers ####
});

// #### Authentication Rate Limiter ####
// #### Stricter limits for login/register endpoints ####
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // #### 15 minutes window ####
  max: isDevelopment ? 50 : 5, // #### 50 attempts in dev, 5 in prod ####
  message: 'Too many authentication attempts', // #### Error message ####
  skipSuccessfulRequests: true, // #### Don't penalize successful logins ####
  standardHeaders: true, // #### Add rate limit headers ####
  legacyHeaders: false, // #### Don't add legacy headers ####
  handler: (req, res) => { // #### Custom handler for rate limit exceeded ####
    console.log('Rate limit hit:', req.ip, req.path); // #### Log the violation ####
    res.status(429).json({ // #### Return 429 Too Many Requests ####
      error: 'Too many attempts. Please try again in a few minutes.', // #### User-friendly message ####
      retryAfter: '15 minutes' // #### When they can try again ####
    });
  }
});

// #### Transaction Rate Limiter ####
// #### Limits transaction requests to prevent spam ####
const transactionLimiter = rateLimit({
  windowMs: 60 * 1000, // #### 1 minute window ####
  max: isDevelopment ? 100 : 10, // #### 100 requests in dev, 10 in prod ####
  message: 'Too many transaction requests' // #### Error message ####
});

// #### Apply Rate Limiters ####
app.use('/api/', generalLimiter); // #### Apply general limiter to all API routes ####

// #### Metrics Collection Middleware ####
// #### Use shared metricsMiddleware for SLI/SLO tracking ####
app.use(metricsMiddleware);

// Service URLs
const AUTH_SERVICE = process.env.AUTH_SERVICE_URL || 'http://auth-service:3004';
const WALLET_SERVICE = process.env.WALLET_SERVICE_URL || 'http://wallet-service:3001';
const TRANSACTION_SERVICE = process.env.TRANSACTION_SERVICE_URL || 'http://transaction-service:3002';
const NOTIFICATION_SERVICE = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service:3003';

// #### Health Check Endpoint ####
// #### This endpoint reports the health of the API Gateway ####
// #### Available at both /health and /api/health for compatibility ####
const healthCheckHandler = (req, res) => {
  res.json({ 
    status: 'healthy', 
    timestamp: new Date().toISOString(),
    service: 'api-gateway',
    version: process.env.npm_package_version || '1.0.0'
  });
};

app.get('/health', healthCheckHandler);
app.get('/api/health', healthCheckHandler);  // Also available at /api/health for consistency

// #### Metrics Endpoint ####
// #### This endpoint exposes Prometheus metrics (uses shared metricsHandler) ####
app.get('/metrics', metricsHandler);

// ============================================
// AUTH ROUTES (Public)
// ============================================
// #### Auth Routes with Circuit Breaker ####
// #### These routes use circuit breakers to prevent cascading failures ####
app.post('/api/auth/register', authLimiter, async (req, res) => {
  try {
    const response = await executeWithCircuitBreaker('auth-service', 'register', async () => {
      return await axios.post(`${AUTH_SERVICE}/auth/register`, req.body);
    });
    
    // Create default wallet in wallet-service (auth-service no longer owns wallets table)
    const userId = response.data.userId;
    const name = req.body.name || 'Default';
    let walletOk = false;
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        await axios.post(`${WALLET_SERVICE}/wallets`, { user_id: userId, name, balance: 1000 });
        walletOk = true;
        break;
      } catch (walletErr) {
        if (walletErr.response?.status === 409) { walletOk = true; break; }
        if (attempt === 1) await new Promise(r => setTimeout(r, 500));
        else console.error('Wallet creation after register failed:', walletErr.message);
      }
    }
    const payload = { ...response.data };
    if (!walletOk) payload.warning = 'Wallet setup delayed; refresh in a moment.';

    // Track successful registration
    transactionTotal.inc({ status: 'success', type: 'registration', service: 'auth-service' });
    userSignups.inc({ status: 'success', service: 'auth-service' });
    res.status(201).json(payload);
  } catch (error) {
    // Track failed registration
    transactionTotal.inc({ status: 'failed', type: 'registration', service: 'auth-service' });
    userSignups.inc({ status: 'failed', service: 'auth-service' });
    res.status(error.response?.status || 500).json(
      error.response?.data || { error: 'Registration failed' }
    );
  }
});

app.post('/api/auth/login', authLimiter, async (req, res) => {
  try {
    const response = await executeWithCircuitBreaker('auth-service', 'login', async () => {
      return await axios.post(`${AUTH_SERVICE}/auth/login`, req.body);
    });
    
    // Track successful login
    transactionTotal.inc({ status: 'success', type: 'login', service: 'auth-service' });
    res.json(response.data);
  } catch (error) {
    // Track failed login
    transactionTotal.inc({ status: 'failed', type: 'login', service: 'auth-service' });
    res.status(error.response?.status || 500).json(
      error.response?.data || { error: 'Login failed' }
    );
  }
});

app.post('/api/auth/refresh', async (req, res) => {
  try {
    const response = await axios.post(`${AUTH_SERVICE}/auth/refresh`, req.body);
    transactionTotal.inc({ status: 'success', type: 'token_refresh', service: 'auth-service' });
    res.json(response.data);
  } catch (error) {
    transactionTotal.inc({ status: 'failed', type: 'token_refresh', service: 'auth-service' });
    res.status(error.response?.status || 500).json(
      error.response?.data || { error: 'Token refresh failed' }
    );
  }
});

app.post('/api/auth/logout', authenticate, async (req, res) => {
  try {
    const response = await axios.post(
      `${AUTH_SERVICE}/auth/logout`,
      req.body || {},
      {
        headers: {
          Authorization: req.headers.authorization,
          'Content-Type': 'application/json'
        }
      }
    );
    transactionTotal.inc({ status: 'success', type: 'logout', service: 'auth-service' });
    res.json(response.data);
  } catch (error) {
    transactionTotal.inc({ status: 'failed', type: 'logout', service: 'auth-service' });
    res.status(error.response?.status || 500).json(
      error.response?.data || { error: 'Logout failed' }
    );
  }
});

app.get('/api/auth/me', authenticate, async (req, res) => {
  try {
    const response = await axios.get(
      `${AUTH_SERVICE}/auth/me`,
      { headers: { Authorization: req.headers.authorization } }
    );
    transactionTotal.inc({ status: 'success', type: 'get_user', service: 'auth-service' });
    res.json(response.data);
  } catch (error) {
    transactionTotal.inc({ status: 'failed', type: 'get_user', service: 'auth-service' });
    res.status(error.response?.status || 500).json(
      error.response?.data || { error: 'Failed to get user' }
    );
  }
});

// ============================================
// WALLET ROUTES (Protected)
// ============================================
// List wallets for dropdown (e.g. "send money to") — return only user_id and name to avoid leaking balances to other users.
app.get('/api/wallets', 
  authenticate,
  async (req, res) => {
    try {
      const response = await axios.get(`${WALLET_SERVICE}/wallets`, { timeout: 5000 });
      transactionTotal.inc({ status: 'success', type: 'list_wallets', service: 'wallet-service' });
      // Strip balance and sensitive fields; expose only minimal data needed for recipient dropdown
      const minimal = Array.isArray(response.data)
        ? response.data.map((w) => ({ user_id: w.user_id, name: w.name }))
        : response.data;
      res.json(minimal);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'list_wallets', service: 'wallet-service' });
      res.status(error.response?.status || 500).json(clientErrorPayload(error, 'Failed to load wallets'));
    }
  }
);

app.get('/api/wallets/:userId', 
  authenticate,
  validate([validators.userId]),
  authorizeOwner('userId'),
  async (req, res) => {
    try {
      const response = await axios.get(
        `${WALLET_SERVICE}/wallets/${req.params.userId}`,
        { timeout: 5000 }
      );
      transactionTotal.inc({ status: 'success', type: 'get_wallet', service: 'wallet-service' });
      res.json(response.data);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'get_wallet', service: 'wallet-service' });
      res.status(error.response?.status || 500).json(clientErrorPayload(error, 'Failed to load wallet'));
    }
  }
);

// ============================================
// TRANSACTION ROUTES (Protected)
// ============================================
app.post('/api/transactions',
  authenticate,
  transactionLimiter,
  validate(validators.createTransaction),
  authorizeOwner(), // Checks fromUserId from body
  async (req, res) => {
    try {
      // Add user context
      const transactionData = {
        ...req.body,
        initiatedBy: req.user.userId
      };

      const headers = { 'X-User-Id': req.user.userId };
      const idempotencyKey = req.headers['idempotency-key'];
      if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;

      const response = await axios.post(
        `${TRANSACTION_SERVICE}/transactions`,
        transactionData,
        { headers }
      );
      
      // Track successful transaction
      transactionTotal.inc({ status: 'success', type: 'transfer', service: 'transaction-service' });
      transfers.inc({ status: 'completed', service: 'transaction-service', amount_range: 'other' });
      
      res.status(201).json(response.data);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'transfer', service: 'transaction-service' });
      failedTransfers.inc({ reason: error.message || 'unknown', service: 'transaction-service' });
      if (error.response?.status !== 400 && error.response?.status !== 422) {
        console.error('Transaction failed:', error.message);
      }
      res.status(error.response?.status || 500).json(clientErrorPayload(error, 'Transaction failed'));
    }
  }
);

app.get('/api/transactions',
  authenticate,
  validate(validators.pagination),
  async (req, res) => {
    try {
      // Users can only see their own transactions unless admin
      const userId = req.user.role === 'admin' ? req.query.userId : req.user.userId;
      
      const response = await axios.get(`${TRANSACTION_SERVICE}/transactions`, {
        params: { userId, ...req.query }
      });
      transactionTotal.inc({ status: 'success', type: 'list_transactions', service: 'transaction-service' });
      res.json(response.data);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'list_transactions', service: 'transaction-service' });
      res.status(error.response?.status || 500).json(clientErrorPayload(error, 'Failed to load transactions'));
    }
  }
);

app.get('/api/transactions/:txnId',
  authenticate,
  validate([validators.transactionId]),
  async (req, res) => {
    try {
      const response = await axios.get(`${TRANSACTION_SERVICE}/transactions/${req.params.txnId}`);
      
      // Verify user owns this transaction
      const transaction = response.data;
      if (
        transaction.from_user_id !== req.user.userId && 
        transaction.to_user_id !== req.user.userId &&
        req.user.role !== 'admin'
      ) {
        transactionTotal.inc({ status: 'failed', type: 'get_transaction', service: 'transaction-service' });
        return res.status(403).json({ error: 'Access denied' });
      }

      transactionTotal.inc({ status: 'success', type: 'get_transaction', service: 'transaction-service' });
      res.json(transaction);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'get_transaction', service: 'transaction-service' });
      res.status(error.response?.status || 500).json(clientErrorPayload(error, 'Failed to load transaction'));
    }
  }
);

// ============================================
// NOTIFICATION ROUTES (Protected)
// ============================================
app.get('/api/notifications/:userId',
  authenticate,
  validate([validators.userId]),
  authorizeOwner('userId'),
  async (req, res) => {
    try {
      const response = await axios.get(`${NOTIFICATION_SERVICE}/notifications/${req.params.userId}`);
      transactionTotal.inc({ status: 'success', type: 'get_notifications', service: 'notification-service' });
      res.json(response.data);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'get_notifications', service: 'notification-service' });
      res.status(error.response?.status || 500).json(
        error.response?.data || { error: 'Failed to load notifications' }
      );
    }
  }
);

app.put('/api/notifications/:id/read',
  authenticate,
  validate([validators.notificationId]),
  async (req, res) => {
    try {
      const response = await axios.put(
        `${NOTIFICATION_SERVICE}/notifications/${req.params.id}/read`,
        {},
        { headers: { 'X-User-Id': req.user.userId } }
      );
      transactionTotal.inc({ status: 'success', type: 'mark_notification_read', service: 'notification-service' });
      res.json(response.data);
    } catch (error) {
      transactionTotal.inc({ status: 'failed', type: 'mark_notification_read', service: 'notification-service' });
      res.status(error.response?.status || 500).json(
        error.response?.data || { error: 'Failed to mark notification as read' }
      );
    }
  }
);

// ============================================
// ADMIN ROUTES (Admin only)
// ============================================
app.get('/api/admin/metrics',
  authenticate,
  authorizeRole('admin'),
  async (req, res) => {
    try {
      const [walletHealth, txnHealth, notifHealth, authHealth] = await Promise.all([
        axios.get(`${WALLET_SERVICE}/health`).catch(() => ({ data: { status: 'unhealthy' } })),
        axios.get(`${TRANSACTION_SERVICE}/health`).catch(() => ({ data: { status: 'unhealthy' } })),
        axios.get(`${NOTIFICATION_SERVICE}/health`).catch(() => ({ data: { status: 'unhealthy' } })),
        axios.get(`${AUTH_SERVICE}/health`).catch(() => ({ data: { status: 'unhealthy' } }))
      ]);

      res.json({
        gateway: { status: 'healthy' },
        authService: authHealth.data,
        walletService: walletHealth.data,
        transactionService: txnHealth.data,
        notificationService: notifHealth.data
      });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  }
);

// Cached metrics response (30s) to avoid fan-out on every poll
let metricsCache = null;
let metricsCacheExpiry = 0;
const METRICS_CACHE_TTL_MS = 30000;

app.get('/api/metrics', authenticate, async (req, res) => {
  const now = Date.now();
  if (metricsCache && metricsCacheExpiry > now) {
    return res.json(metricsCache);
  }
  try {
    const [walletHealth, txnHealth, notifHealth] = await Promise.all([
      axios.get(`${WALLET_SERVICE}/health`, { timeout: 3000 }).catch(() => ({ data: { status: 'unhealthy' } })),
      axios.get(`${TRANSACTION_SERVICE}/health`, { timeout: 3000 }).catch(() => ({ data: { status: 'unhealthy' } })),
      axios.get(`${NOTIFICATION_SERVICE}/health`, { timeout: 3000 }).catch(() => ({ data: { status: 'unhealthy' } }))
    ]);
    metricsCache = {
      gateway: { status: 'healthy' },
      walletService: { status: walletHealth.data.status },
      transactionService: { status: txnHealth.data.status },
      notificationService: { status: notifHealth.data.status }
    };
    metricsCacheExpiry = now + METRICS_CACHE_TTL_MS;
    res.json(metricsCache);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Error handling middleware — must have exactly 4 params so Express recognises it as error middleware
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(err.status || 500).json({
    error: err.message || 'Internal server error',
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

const server = app.listen(PORT, () => {
  console.log(`Secured API Gateway running on port ${PORT}`);
});

// Graceful shutdown (12-factor: disposability)
const shutdown = (signal) => {
  console.log(`${signal} received: closing HTTP server`);
  const deadline = Date.now() + 25000; // 25s, under terminationGracePeriodSeconds
  server.close(() => {
    console.log('HTTP server closed');
    process.exit(0);
  });
  setTimeout(() => {
    console.error('Shutdown timeout, exiting');
    process.exit(1);
  }, Math.max(0, deadline - Date.now()));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
