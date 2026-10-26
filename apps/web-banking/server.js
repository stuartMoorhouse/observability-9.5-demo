'use strict';

// web-banking: Backend-for-frontend for the demo bank, plus the browser UI in public/.
// No OpenTelemetry SDK here: the OTel Operator injects EDOT Node.js at pod start.
// pino logs are JSON on stdout; the injected pino instrumentation adds trace_id/span_id.
//
// Two listeners on one app: PORT (in-cluster, used by loadgen and probes) and
// PUBLIC_PORT (behind the LoadBalancer and CloudFront), which only answers requests
// carrying the X-Origin-Verify secret that CloudFront adds.

const crypto = require('crypto');
const path = require('path');
const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');

const PORT = parseInt(process.env.PORT || '8080', 10);
const ACCOUNTS_LEDGER_URL = process.env.ACCOUNTS_LEDGER_URL || 'http://accounts-ledger:8080';
const TRANSFER_SERVICE_URL = process.env.TRANSFER_SERVICE_URL || 'http://transfer-service:8080';
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.UPSTREAM_TIMEOUT_MS || '10000', 10);
const PUBLIC_PORT = parseInt(process.env.PUBLIC_PORT || '0', 10);
const ORIGIN_SECRET = process.env.ORIGIN_SECRET || '';
// Set by the OTel Operator on instrumented pods (the node's collector, OTLP/HTTP).
const OTLP_ENDPOINT = (process.env.OTEL_EXPORTER_OTLP_ENDPOINT || '').replace(/\/$/, '');
const DEPLOYMENT_ENVIRONMENT =
  (process.env.OTEL_RESOURCE_ATTRIBUTES || '')
    .split(',')
    .map((kv) => kv.split('='))
    .find(([k]) => k === 'deployment.environment')?.[1] || 'unknown';

const logger = pino({
  base: { service: 'web-banking', version: process.env.APP_VERSION || 'unknown' },
  messageKey: 'message',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (label) => ({ level: label }) },
});

function originVerified(req) {
  if (!ORIGIN_SECRET) return false;
  const given = Buffer.from(req.get('x-origin-verify') || '');
  const expected = Buffer.from(ORIGIN_SECRET);
  return given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

const app = express();
app.disable('x-powered-by');
app.use((req, res, next) => {
  if (PUBLIC_PORT && req.socket.localPort === PUBLIC_PORT && !originVerified(req)) {
    return res.status(403).end();
  }
  return next();
});
app.use(
  pinoHttp({
    logger,
    autoLogging: { ignore: (req) => req.url === '/healthz' || req.url === '/v1/traces' },
    customLogLevel: (_req, res, err) => (err || res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info'),
  })
);

// Browser RUM export: forward OTLP/HTTP trace payloads to the collector unchanged.
// Registered before express.json so the body stays raw. The browser sends an unsampled
// traceparent with these requests, so EDOT records no spans for the forwarding itself.
app.post('/v1/traces', express.raw({ type: () => true, limit: '1mb' }), async (req, res) => {
  if (!OTLP_ENDPOINT) return res.status(503).end();
  try {
    const upstream = await fetch(`${OTLP_ENDPOINT}/v1/traces`, {
      method: 'POST',
      headers: { 'content-type': req.get('content-type') || 'application/json' },
      body: req.body,
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    res.status(upstream.status).type(upstream.headers.get('content-type') || 'application/json');
    return res.send(Buffer.from(await upstream.arrayBuffer()));
  } catch (err) {
    req.log.warn({ err }, 'rum export failed');
    return res.status(502).end();
  }
});

app.use(express.json({ limit: '16kb' }));
app.use(express.static(path.join(__dirname, 'public'), { maxAge: '5m' }));

app.get('/rum-config.js', (_req, res) => {
  const config = {
    serviceName: 'web-banking-frontend',
    version: process.env.APP_VERSION || 'unknown',
    environment: DEPLOYMENT_ENVIRONMENT,
  };
  res.type('application/javascript').set('cache-control', 'no-store');
  res.send(`window.RUM_CONFIG = ${JSON.stringify(config)};\n`);
});

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

const servers = [app.listen(PORT, () => logger.info({ port: PORT }, 'web-banking listening'))];
if (PUBLIC_PORT) {
  if (!ORIGIN_SECRET) logger.warn('PUBLIC_PORT set without ORIGIN_SECRET: public listener rejects all requests');
  servers.push(app.listen(PUBLIC_PORT, () => logger.info({ port: PUBLIC_PORT }, 'web-banking public listener')));
}

function shutdown(signal) {
  logger.info({ signal }, 'shutting down');
  let open = servers.length;
  servers.forEach((s) => s.close(() => (open -= 1) || process.exit(0)));
  setTimeout(() => process.exit(0), 10000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
