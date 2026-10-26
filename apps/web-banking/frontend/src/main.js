// Demo bank UI: balance lookup and transfer form against the web-banking /api routes.
// Each user action is a named root span ("Check balance", "Submit transfer"); the
// instrumented fetch inside it continues the trace into the backend. The trace ID is
// shown on screen so the presenter can paste it into Kibana.

import { SpanStatusCode } from '@opentelemetry/api';
import { tracer } from './rum';

const $ = (id) => document.getElementById(id);

function traced(name, attributes, fn) {
  // fetch is called synchronously inside the callback, so the fetch span is a child
  // even with the default (stack) context manager.
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      const result = await fn(span);
      // A declined transfer (403) is a business outcome, not a failure.
      if (result.status >= 500) {
        span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${result.status}` });
      }
      return { ...result, traceId: span.spanContext().traceId };
    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      return { ok: false, status: 0, body: { error: err.message }, traceId: span.spanContext().traceId };
    } finally {
      span.end();
    }
  });
}

async function request(url, options) {
  const res = await fetch(url, options);
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body };
}

function money(amount, currency) {
  return new Intl.NumberFormat(undefined, { style: 'currency', currency }).format(amount);
}

function showResult(el, { ok, status, body, traceId }, message) {
  el.hidden = false;
  el.className = `result ${ok ? 'ok' : 'error'}`;
  el.querySelector('.message').textContent = message;
  const reason = (body.reasons || []).join(', ') || body.error || body.message || 'request failed';
  el.querySelector('.detail').textContent = ok ? '' : `HTTP ${status || 'network error'}: ${reason}`;
  el.querySelector('.trace').textContent = traceId;
}

async function loadBalance() {
  const account = $('account').value;
  $('balance').textContent = '...';
  const result = await traced('Check balance', { 'bank.account_id': account }, () =>
    request(`/api/accounts/${encodeURIComponent(account)}/balance`)
  );
  if (result.ok) {
    $('balance').textContent = money(result.body.balance, result.body.currency);
  } else {
    $('balance').textContent = 'Unavailable';
  }
  showResult($('balance-result'), result, result.ok ? 'Balance loaded' : 'Could not load balance');
}

async function submitTransfer(event) {
  event.preventDefault();
  const button = $('transfer-submit');
  button.disabled = true;
  const payload = {
    fromAccount: $('account').value,
    toAccount: $('to-account').value,
    amount: Number($('amount').value),
    currency: 'EUR',
    targetCurrency: $('target-currency').value,
  };
  const result = await traced(
    'Submit transfer',
    {
      'bank.from_account': payload.fromAccount,
      'bank.to_account': payload.toAccount,
      'bank.amount': payload.amount,
      'bank.target_currency': payload.targetCurrency,
    },
    () =>
      request('/api/transfers', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      })
  );
  button.disabled = false;
  let message = 'Transfer failed';
  if (result.body.status === 'completed') {
    message = `Transfer completed: ${money(result.body.credited, payload.targetCurrency)} sent to ${payload.toAccount}`;
  } else if (result.body.status === 'rejected') {
    message = 'Transfer declined by fraud checks';
  }
  showResult($('transfer-result'), result, message);
  if (result.ok) loadBalance();
}

function populateAccounts() {
  for (const id of ['account', 'to-account']) {
    const select = $(id);
    for (let n = 1001; n <= 1050; n += 1) {
      select.add(new Option(`ACC-${n}`, `ACC-${n}`));
    }
  }
  $('to-account').value = 'ACC-1002';
}

populateAccounts();
$('account').addEventListener('change', loadBalance);
$('refresh').addEventListener('click', loadBalance);
$('transfer-form').addEventListener('submit', submitTransfer);
loadBalance();
