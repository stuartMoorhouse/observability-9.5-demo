'use strict';

// web-banking: Backend-for-frontend for the demo bank.
// No OpenTelemetry SDK here: the OTel Operator injects EDOT Node.js at pod start.
// pino logs are JSON on stdout; the injected pino instrumentation adds trace_id/span_id.

const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');

const PORT = parseInt(process.env.PORT || '8080', 10);
const ACCOUNTS_LEDGER_URL = process.env.ACCOUNTS_LEDGER_URL || 'http://accounts-ledger:8080';
const TRANSFER_SERVICE_URL = process.env.TRANSFER_SERVICE_URL || 'http://transfer-service:8080';
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '10000', 10);

const logger = pino({
  base: { service: 'web-banking', version: process.env.APP_VERSION || 'unknown' },
  messageKey: 'message',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (label) => ({ level: label }) },
});

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));
app.use(
  pinoHttp({
    logger,
    autoLogging: { ignore: (req) => req.url === '/healthz' },
    customLogLevel: (_req, res, err) => (err || res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info'),
  })
);

const ACCOUNT_ID = /^[A-Z]{3}-\d{4}$/;

async function callUpstream(url, options = {}) {
  const res = await fetch(url, {
    ...options,
    headers: { 'content-type': 'application/json', ...(options.headers || {}) },
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text };
  }
  return { status: res.status, body };
}

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/accounts/:id/balance', async (req, res, next) => {
  const { id } = req.params;
  if (!ACCOUNT_ID.test(id)) {
    return res.status(400).json({ error: 'invalid account id' });
  }
  try {
    const { status, body } = await callUpstream(`${ACCOUNTS_LEDGER_URL}/ledger/accounts/${encodeURIComponent(id)}/balance`);
    if (status >= 500) {
      req.log.error({ upstream: 'accounts-ledger', status }, 'balance lookup failed');
    }
    return res.status(status).json(body);
  } catch (err) {
    return next(err);
  }
});

app.post('/api/transfers', async (req, res, next) => {
  const { fromAccount, toAccount, amount, currency, targetCurrency } = req.body || {};
  if (!ACCOUNT_ID.test(fromAccount || '') || !ACCOUNT_ID.test(toAccount || '') || !(Number(amount) > 0)) {
    return res.status(400).json({ error: 'fromAccount, toAccount and a positive amount are required' });
  }
  try {
    const payload = {
      fromAccount,
      toAccount,
      amount: Number(amount),
      currency: currency || 'EUR',
      targetCurrency: targetCurrency || currency || 'EUR',
    };
    const { status, body } = await callUpstream(`${TRANSFER_SERVICE_URL}/transfer`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    if (status >= 500) {
      req.log.error({ upstream: 'transfer-service', status, fromAccount, toAccount }, 'transfer failed');
    } else {
      req.log.info({ fromAccount, toAccount, amount: payload.amount, outcome: body.status }, 'transfer processed');
    }
    return res.status(status).json(body);
  } catch (err) {
    return next(err);
  }
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, _next) => {
  req.log.error({ err }, 'request failed');
  res.status(502).json({ error: 'upstream unavailable' });
});

const server = app.listen(PORT, () => logger.info({ port: PORT }, 'web-banking listening'));

function shutdown(signal) {
  logger.info({ signal }, 'shutting down');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 10000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
