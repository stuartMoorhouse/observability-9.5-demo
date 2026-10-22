// k6 load generator for web-banking.
// Request rate (req/s) from env RATE (Helm value loadgen.rate). ~60% balance reads,
// ~40% transfers, of which ~20% are cross-currency.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://web-banking:8080';
const RATE = parseInt(__ENV.RATE || '5', 10);
const ACCOUNTS = parseInt(__ENV.ACCOUNTS || '50', 10);
const CURRENCIES = ['GBP', 'USD', 'SEK'];

export const options = {
  discardResponseBodies: true,
  scenarios: {
    banking: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '8760h',
      preAllocatedVUs: Math.max(5, RATE * 2),
      maxVUs: Math.max(20, RATE * 10),
    },
  },
};

function account() {
  return `ACC-${1001 + Math.floor(Math.random() * ACCOUNTS)}`;
}

export default function () {
  if (Math.random() < 0.6) {
    const res = http.get(`${BASE_URL}/api/accounts/${account()}/balance`, {
      tags: { name: 'GET /api/accounts/:id/balance' },
    });
    check(res, { 'balance 2xx': (r) => r.status >= 200 && r.status < 300 });
    return;
  }

  const from = account();
  let to = account();
  // Occasionally send same-account transfers so fraud-check denies some.
  if (Math.random() < 0.97) {
    while (to === from) to = account();
  }
  const crossCurrency = Math.random() < 0.2;
  const body = {
    fromAccount: from,
    toAccount: to,
    // Mostly small amounts; ~3% large enough to be denied.
    amount: Math.random() < 0.03 ? 12000 : Math.round((5 + Math.random() * 500) * 100) / 100,
    currency: 'EUR',
    targetCurrency: crossCurrency ? CURRENCIES[Math.floor(Math.random() * CURRENCIES.length)] : 'EUR',
  };
  const res = http.post(`${BASE_URL}/api/transfers`, JSON.stringify(body), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'POST /api/transfers' },
  });
  check(res, { 'transfer not 5xx': (r) => r.status < 500 });
}
