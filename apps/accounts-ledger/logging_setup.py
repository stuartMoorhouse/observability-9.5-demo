"""Structured JSON logging to stdout with optional trace correlation.

No OpenTelemetry SDK is installed in the image. When the OTel Operator injects the
EDOT Python agent, the opentelemetry API is importable at runtime and the active
trace/span IDs are added to every log line so logs correlate with traces.
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

try:  # present only when auto-instrumentation is injected
    from opentelemetry import trace as _otel_trace
except ImportError:  # pragma: no cover
    _otel_trace = None


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str):
        super().__init__()
        self.service = service
        self.version = os.getenv("APP_VERSION", "unknown")

    def format(self, record: logging.LogRecord) -> str:
        doc = {
            "@timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "log.level": record.levelname.lower(),
            "log.logger": record.name,
            "message": record.getMessage(),
            "service.name": self.service,
            "service.version": self.version,
        }
        if _otel_trace is not None:
            ctx = _otel_trace.get_current_span().get_span_context()
            if ctx.is_valid:
                doc["trace.id"] = format(ctx.trace_id, "032x")
                doc["span.id"] = format(ctx.span_id, "016x")
        extra = getattr(record, "fields", None)
        if isinstance(extra, dict):
            doc.update(extra)
        if record.exc_info:
            doc["error.type"] = record.exc_info[0].__name__ if record.exc_info[0] else None
            doc["error.stack_trace"] = self.formatException(record.exc_info)
        return json.dumps(doc, default=str)


def configure(service: str) -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    # Keep handlers added by the injected agent (OTLP log export), replace console ones.
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.StreamHandler)]
    root.addHandler(handler)
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers = []
        lg.propagate = True
    # Access logs are noisy (health probes); request outcome is logged by the app instead.
    logging.getLogger("uvicorn.access").disabled = True
    return logging.getLogger(service)
