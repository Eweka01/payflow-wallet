const express = require('express');
const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const redis = require('redis');
const helmet = require('helmet');
const morgan = require('morgan');
const { body, validationResult } = require('express-validator');
const rateLimit = require('express-rate-limit');
const { v4: uuidv4 } = require('uuid');
const {
  metricsMiddleware,
  metricsHandler,
} = require('./shared/metrics');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3004;

app.use(helmet());
app.use(morgan('combined'));
app.use(express.json());
// Collect HTTP request metrics for SLI/SLO dashboards
app.use(metricsMiddleware);

// PostgreSQL connection (ssl required for AWS RDS; PGSSLMODE from app-config)
// rejectUnauthorized: false so RDS TLS cert is accepted (RDS cert not in Node default trust store)
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
  ssl: process.env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
});

// Redis connection for token blacklist
const redisClient = redis.createClient({
  url: process.env.REDIS_URL || 'redis://redis:6379'
});

redisClient.on('error', (err) => console.error('Redis error:', err));
redisClient.connect().catch((err) => console.error('Redis connect error:', err.message));

// JWT Configuration — require secret in production so all replicas use the same key
const JWT_SECRET = process.env.JWT_SECRET || (process.env.NODE_ENV === 'production' ? (() => { throw new Error('JWT_SECRET must be set in production'); })() : 'dev-only-secret-change-in-production');
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '24h';
const REFRESH_TOKEN_EXPIRES_IN = '7d';

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: process.env.NODE_ENV === 'production' ? 20 : 100,
  message: 'Too many authentication attempts, please try again later'
});

// Initialize database
async function initDB() {
  const client = await pool.connect();
  try {
    // Users table
    await client.query(`
      CREATE TABLE IF NOT EXISTS users (
        id VARCHAR(50) PRIMARY KEY,
        email VARCHAR(255) UNIQUE NOT NULL,
        password_hash VARCHAR(255) NOT NULL,
        name VARCHAR(100) NOT NULL,
        role VARCHAR(20) DEFAULT 'user',
        is_active BOOLEAN DEFAULT true,
        email_verified BOOLEAN DEFAULT false,
        two_factor_enabled BOOLEAN DEFAULT false,
        two_factor_secret VARCHAR(255),
        failed_login_attempts INT DEFAULT 0,
        locked_until TIMESTAMP,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_login_at TIMESTAMP,
        last_login_ip VARCHAR(45)
      )
    `);

    // Refresh tokens table
    await client.query(`
      CREATE TABLE IF NOT EXISTS refresh_tokens (
        id SERIAL PRIMARY KEY,
        user_id VARCHAR(50) REFERENCES users(id) ON DELETE CASCADE,
        token VARCHAR(500) UNIQUE NOT NULL,
        expires_at TIMESTAMP NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        ip_address VARCHAR(45),
        user_agent TEXT
      )
    `);

    // Sessions table
    await client.query(`
      CREATE TABLE IF NOT EXISTS user_sessions (
        id SERIAL PRIMARY KEY,
        user_id VARCHAR(50) REFERENCES users(id) ON DELETE CASCADE,
        session_token VARCHAR(500) UNIQUE NOT NULL,
        ip_address VARCHAR(45),
        user_agent TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        expires_at TIMESTAMP NOT NULL,
        is_active BOOLEAN DEFAULT true
      )
    `);

    // Audit log table
    await client.query(`
      CREATE TABLE IF NOT EXISTS audit_logs (
        id SERIAL PRIMARY KEY,
        user_id VARCHAR(50),
        action VARCHAR(100) NOT NULL,
        resource VARCHAR(100),
        ip_address VARCHAR(45),
        user_agent TEXT,
        metadata JSONB,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // Create indexes
    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
      CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_user ON user_sessions(user_id);
      CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON audit_logs(user_id, created_at DESC);
    `);

    console.log('Auth database initialized');
  } finally {
    client.release();
  }
}

initDB().catch(console.error);

// Utility: Audit logging
async function auditLog(userId, action, resource, req, metadata = {}) {
  try {
    await pool.query(
      `INSERT INTO audit_logs (user_id, action, resource, ip_address, user_agent, metadata) 
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        userId,
        action,
        resource,
        req.ip,
        req.get('user-agent'),
        JSON.stringify(metadata)
      ]
    );
  } catch (error) {
    console.error('Audit log error:', error);
  }
}

// Utility: Generate tokens
function generateTokens(userId, email, role) {
  const accessToken = jwt.sign(
    { userId, email, role },
    JWT_SECRET,
    { expiresIn: JWT_EXPIRES_IN }
  );

  const refreshToken = jwt.sign(
    { userId, type: 'refresh' },
    JWT_SECRET,
    { expiresIn: REFRESH_TOKEN_EXPIRES_IN }
  );

  return { accessToken, refreshToken };
}

// Health check (return 200 if app can serve; avoid 503 on Redis timeout so k8s liveness doesn't kill pod)
app.get('/health', async (req, res) => {
  let redisOk;
  try {
    await pool.query('SELECT 1');
  } catch (e) {
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
    service: 'auth-service',
    database: 'connected',
    redis: redisOk ? 'connected' : 'disconnected'
  });
});

// Prometheus metrics endpoint (scraped by Prometheus)
app.get('/metrics', metricsHandler);

// Register new user
app.post('/auth/register',
  authLimiter,
  [
    body('email').isEmail().normalizeEmail().withMessage('Please provide a valid email address'),
    body('password')
      .isLength({ min: 8 }).withMessage('Password must be at least 8 characters long')
      .matches(/^(?=.*[a-z])/).withMessage('Password must contain at least one lowercase letter')
      .matches(/^(?=.*[A-Z])/).withMessage('Password must contain at least one uppercase letter')
      .matches(/^(?=.*\d)/).withMessage('Password must contain at least one number'),
    body('name').trim().isLength({ min: 2, max: 100 }).withMessage('Name must be between 2 and 100 characters')
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const { email, password, name } = req.body;
    const client = await pool.connect();

    try {
      // Check if user exists
      const existing = await client.query(
        'SELECT id FROM users WHERE email = $1',
        [email]
      );

      if (existing.rows.length > 0) {
        return res.status(409).json({ error: 'Email already registered' });
      }

      // Hash password
      const passwordHash = await bcrypt.hash(password, 12);
      const userId = uuidv4();

      // Create user (wallet is created by wallet-service via api-gateway after register)
      await client.query(
        `INSERT INTO users (id, email, password_hash, name, role) 
         VALUES ($1, $2, $3, $4, 'user')`,
        [userId, email, passwordHash, name]
      );

      await auditLog(userId, 'USER_REGISTERED', 'users', req, { email });

      // Generate tokens
      const tokens = generateTokens(userId, email, 'user');

      // Store refresh token so client can refresh access token after expiry (same as login)
      const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days
      await client.query(
        `INSERT INTO refresh_tokens (user_id, token, expires_at, ip_address, user_agent)
         VALUES ($1, $2, $3, $4, $5)`,
        [userId, tokens.refreshToken, expiresAt, req.ip, req.get('user-agent')]
      );

      res.status(201).json({
        message: 'User registered successfully',
        userId,
        user: { id: userId, email, name, role: 'user' },
        ...tokens
      });
    } catch (error) {
      console.error('Registration error:', error);
      res.status(500).json({ error: 'Registration failed' });
    } finally {
      client.release();
    }
  }
);

// Login
app.post('/auth/login',
  authLimiter,
  [
    body('email').isEmail().normalizeEmail(),
    body('password').notEmpty()
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const { email, password } = req.body;
    const client = await pool.connect();

    try {
      // Get user
      const result = await client.query(
        `SELECT id, email, password_hash, name, role, is_active, 
                failed_login_attempts, locked_until 
         FROM users WHERE email = $1`,
        [email]
      );

      if (result.rows.length === 0) {
        return res.status(401).json({ error: 'Invalid credentials' });
      }

      const user = result.rows[0];

      // Check if account is locked
      if (user.locked_until && new Date(user.locked_until) > new Date()) {
        return res.status(423).json({ 
          error: 'Account locked due to multiple failed attempts',
          lockedUntil: user.locked_until
        });
      }

      // Check if account is active
      if (!user.is_active) {
        return res.status(403).json({ error: 'Account is disabled' });
      }

      // Verify password
      const validPassword = await bcrypt.compare(password, user.password_hash);

      if (!validPassword) {
        // Increment failed attempts
        const newAttempts = user.failed_login_attempts + 1;
        const lockUntil = newAttempts >= 5 
          ? new Date(Date.now() + 30 * 60 * 1000) // Lock for 30 minutes
          : null;

        await client.query(
          `UPDATE users 
           SET failed_login_attempts = $1, locked_until = $2 
           WHERE id = $3`,
          [newAttempts, lockUntil, user.id]
        );

        await auditLog(user.id, 'LOGIN_FAILED', 'users', req, { email, attempts: newAttempts });

        return res.status(401).json({ 
          error: 'Invalid credentials',
          attemptsRemaining: Math.max(0, 5 - newAttempts)
        });
      }

      // Reset failed attempts
      await client.query(
        `UPDATE users 
         SET failed_login_attempts = 0, 
             locked_until = NULL, 
             last_login_at = NOW(),
             last_login_ip = $1
         WHERE id = $2`,
        [req.ip, user.id]
      );

      // Generate tokens
      const tokens = generateTokens(user.id, user.email, user.role);

      // Store refresh token
      const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days
      await client.query(
        `INSERT INTO refresh_tokens (user_id, token, expires_at, ip_address, user_agent) 
         VALUES ($1, $2, $3, $4, $5)`,
        [user.id, tokens.refreshToken, expiresAt, req.ip, req.get('user-agent')]
      );

      await auditLog(user.id, 'LOGIN_SUCCESS', 'users', req, { email });

      res.json({
        message: 'Login successful',
        user: {
          id: user.id,
          email: user.email,
          name: user.name,
          role: user.role
        },
        ...tokens
      });
    } catch (error) {
      console.error('Login error:', error);
      res.status(500).json({ error: 'Login failed' });
    } finally {
      client.release();
    }
  }
);

// Refresh token
app.post('/auth/refresh', async (req, res) => {
  const { refreshToken } = req.body;

  if (!refreshToken) {
    return res.status(400).json({ error: 'Refresh token required' });
  }

  try {
    // Verify token
    const decoded = jwt.verify(refreshToken, JWT_SECRET);

    if (decoded.type !== 'refresh') {
      return res.status(401).json({ error: 'Invalid token type' });
    }

    // Check if token exists in database
    const result = await pool.query(
      `SELECT user_id FROM refresh_tokens 
       WHERE token = $1 AND expires_at > NOW()`,
      [refreshToken]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid or expired refresh token' });
    }

    // Get user
    const userResult = await pool.query(
      'SELECT id, email, role FROM users WHERE id = $1 AND is_active = true',
      [decoded.userId]
    );

    if (userResult.rows.length === 0) {
      return res.status(401).json({ error: 'User not found or inactive' });
    }

    const user = userResult.rows[0];

    // Generate new tokens
    const tokens = generateTokens(user.id, user.email, user.role);

    await auditLog(user.id, 'TOKEN_REFRESHED', 'users', req);

    res.json(tokens);
  } catch (error) {
    console.error('Token refresh error:', error);
    res.status(401).json({ error: 'Invalid or expired token' });
  }
});

// Logout — invalidate access token and revoke only the current session's refresh token.
// Client should send refreshToken in body so we revoke only this device/session.
app.post('/auth/logout', async (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];

  if (!token) {
    return res.status(400).json({ error: 'Token required' });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);

    // Add access token to blacklist (expires when token would expire)
    const expiresIn = decoded.exp - Math.floor(Date.now() / 1000);
    if (expiresIn > 0) {
      await redisClient.setEx(`blacklist:${token}`, expiresIn, 'true');
    }

    // Revoke only the current session's refresh token when provided (avoids logging out all devices)
    const refreshToken = req.body?.refreshToken;
    if (refreshToken) {
      await pool.query(
        'DELETE FROM refresh_tokens WHERE token = $1',
        [refreshToken]
      );
    } else {
      // Backward compatibility: if client does not send refreshToken, revoke all sessions for this user
      await pool.query(
        'DELETE FROM refresh_tokens WHERE user_id = $1',
        [decoded.userId]
      );
    }

    await auditLog(decoded.userId, 'LOGOUT', 'users', req);

    res.json({ message: 'Logout successful' });
  } catch (error) {
    console.error('Logout error:', error);
    res.status(500).json({ error: 'Logout failed' });
  }
});

// Verify token (used by other services)
app.post('/auth/verify', async (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Token required' });
  }

  try {
    // Check if token is blacklisted
    const blacklisted = await redisClient.get(`blacklist:${token}`);
    if (blacklisted) {
      return res.status(401).json({ error: 'Token revoked' });
    }

    const decoded = jwt.verify(token, JWT_SECRET);

    res.json({
      valid: true,
      userId: decoded.userId,
      email: decoded.email,
      role: decoded.role
    });
  } catch (error) {
    res.status(401).json({ 
      valid: false, 
      error: 'Invalid or expired token' 
    });
  }
});

// Get current user
app.get('/auth/me', async (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Token required' });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);

    const result = await pool.query(
      `SELECT id, email, name, role, created_at, last_login_at 
       FROM users WHERE id = $1`,
      [decoded.userId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    res.json(result.rows[0]);
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
});

// Change password
app.post('/auth/change-password',
  [
    body('currentPassword').notEmpty(),
    body('newPassword').isLength({ min: 8 }).matches(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/)
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() });
    }

    const token = req.headers.authorization?.split(' ')[1];
    if (!token) {
      return res.status(401).json({ error: 'Token required' });
    }

    const { currentPassword, newPassword } = req.body;

    try {
      const decoded = jwt.verify(token, JWT_SECRET);

      const result = await pool.query(
        'SELECT password_hash FROM users WHERE id = $1',
        [decoded.userId]
      );

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }

      const validPassword = await bcrypt.compare(currentPassword, result.rows[0].password_hash);

      if (!validPassword) {
        return res.status(401).json({ error: 'Current password incorrect' });
      }

      const newPasswordHash = await bcrypt.hash(newPassword, 12);

      await pool.query(
        'UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2',
        [newPasswordHash, decoded.userId]
      );

      // Invalidate current access token so it cannot be used after password change
      const remainingTTL = decoded.exp - Math.floor(Date.now() / 1000);
      if (remainingTTL > 0) {
        await redisClient.setEx(`blacklist:${token}`, remainingTTL, 'true');
      }

      // Revoke all refresh tokens for this user (log out all sessions)
      await pool.query('DELETE FROM refresh_tokens WHERE user_id = $1', [decoded.userId]);

      await auditLog(decoded.userId, 'PASSWORD_CHANGED', 'users', req, { sessionsInvalidated: true });

      res.json({ message: 'Password changed successfully' });
    } catch (error) {
      console.error('Password change error:', error);
      res.status(500).json({ error: 'Password change failed' });
    }
  }
);

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`Auth service listening on 0.0.0.0:${PORT}`);
});

// Graceful shutdown (12-factor: disposability)
const shutdown = (signal) => {
  console.log(`${signal} received: closing HTTP server`);
  const deadline = Date.now() + 25000; // 25s, under terminationGracePeriodSeconds
  server.close(() => {
    console.log('HTTP server closed');
    pool.end().then(() => process.exit(0)).catch(() => process.exit(1));
  });
  setTimeout(() => {
    console.error('Shutdown timeout, exiting');
    process.exit(1);
  }, Math.max(0, deadline - Date.now()));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
