// Browser RUM: OpenTelemetry web SDK. Spans go to web-banking's same-origin /v1/traces
// proxy (no CORS, collector stays private). The fetch instrumentation adds a W3C
// traceparent header to same-origin /api calls, so each browser span is the root of
// the backend trace through web-banking, transfer-service and the ledger.

import { trace } from '@opentelemetry/api';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { BatchSpanProcessor, WebTracerProvider } from '@opentelemetry/sdk-trace-web';

// Set by the server in /rum-config.js from the pod's environment.
const config = window.RUM_CONFIG || {};

const provider = new WebTracerProvider({
  resource: resourceFromAttributes({
    'service.name': config.serviceName || 'web-banking-frontend',
    'service.version': config.version || 'unknown',
    'deployment.environment': config.environment || 'unknown',
  }),
  spanProcessors: [
    new BatchSpanProcessor(
      new OTLPTraceExporter({
        url: `${window.location.origin}/v1/traces`,
        // Unsampled parent (flags 00): the backend's parentbased sampler then records
        // nothing for the export request, so the proxy does not show up in APM.
        headers: { traceparent: '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00' },
      }),
      { scheduledDelayMillis: 1000 }
    ),
  ],
});
provider.register();

registerInstrumentations({
  instrumentations: [
    new DocumentLoadInstrumentation(),
    new FetchInstrumentation({ ignoreUrls: [/\/v1\/traces$/] }),
  ],
});

export const tracer = trace.getTracer('web-banking-frontend');
