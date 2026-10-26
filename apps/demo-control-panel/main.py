"""demo-control-panel: a web page that triggers the demo scenarios in-cluster.

Stdlib only. Talks to the Kubernetes API with the pod's ServiceAccount token and
does what the scripts in scripts/ do with kubectl:

- fault toggles patch the fault-config ConfigMap and annotate the target pods so
  the kubelet refreshes the mounted ConfigMap now (scripts/fault-inject.sh)
- bad-version sets APP_VERSION/BAD_RELEASE on transfer-service (rollout)
- load rate sets RATE on the loadgen Deployment (scripts/generate-load.sh)
- fx-rates onboarding server-side-applies the objects rendered from
  charts/fx-rates (mounted as JSON), with Helm ownership metadata so
  scripts/onboard-service.sh can still adopt or remove them

Elastic-side work (SLO reset, detection-delay measurement) stays in scripts/.
"""

import hmac
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
NAMESPACE = os.environ.get("NAMESPACE", "banking")
KIBANA_URL = os.environ.get("KIBANA_URL", "").rstrip("/")
# web-banking browser UI (its own CloudFront distribution).
BANK_URL = os.environ.get("BANK_URL", "").rstrip("/")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "banking-demo")
BASE_VERSION = os.environ.get("BASE_VERSION", "1.4.2")
BAD_VERSION = os.environ.get("BAD_VERSION", "2.0.0")
DEFAULT_LOAD_RATE = int(os.environ.get("DEFAULT_LOAD_RATE", "5"))
FX_MANIFESTS = os.environ.get("FX_MANIFESTS", "/etc/fx-rates/manifests.json")
# CloudFront adds this header; requests straight to the load balancer lack it. Empty = no check (local runs).
ORIGIN_SECRET = os.environ.get("ORIGIN_SECRET", "")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

FAULT_CONFIGMAP = "fault-config"
FIELD_MANAGER = "demo-control-panel"
DEFAULT_LATENCY_MS = 1500
SLO_BREACH_LATENCY_MS = 3000
DEFAULT_ERROR_RATE = 30

# Service that reads each fault key (scripts/fault-inject.sh fault_target).
FAULT_TARGET = {"LATENCY_MS": "transfer-service", "ERROR_RATE": "fraud-check", "SLOW_DB": "accounts-ledger"}

API_SERVER = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
SSL_CTX = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt")) if os.path.exists(SA_DIR) else None

COLLECTION = {
    "Deployment": "/apis/apps/v1/namespaces/{ns}/deployments",
    "Service": "/api/v1/namespaces/{ns}/services",
    "ServiceAccount": "/api/v1/namespaces/{ns}/serviceaccounts",
}

EXPECT = {
    "latency": "Latency threshold alert on transfer-service in ~1-2 min; SLO burn-rate alert in ~4 min if left on.",
    "errors": "fraud-check failure rate rises within ~1 min; error-rate alert in ~1-2 min; correlations meaningful after ~3-5 min.",
    "slow-db": "Slow DB span on accounts-ledger in trace waterfalls within ~1 min; latency alerts in ~5 min.",
    "bad-version": f"service.version {BAD_VERSION} visible in APM after the rollout (~1-2 min); alerts in ~3-5 min; correlations rank {BAD_VERSION} after ~5 min.",
    "slo-breach": "Burn-rate alert typically ~4 min after the fault starts.",
    "fx-onboard": "Pod ready in ~30-60 s; fx-rates in the service inventory and service map within ~1-2 min.",
}


class ActionError(Exception):
    """A request the user can fix (bad value, unknown action)."""


class K8sError(Exception):
    def __init__(self, code, body):
        super().__init__(f"Kubernetes API returned {code}: {body[:300]}")
        self.code = code


# ---------------------------------------------------------------------------
# Kubernetes API
# ---------------------------------------------------------------------------
def k8s(method, path, body=None, content_type="application/json", allow_404=False):
    # Re-read every call: projected ServiceAccount tokens are rotated.
    with open(os.path.join(SA_DIR, "token"), encoding="utf-8") as f:
        token = f.read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API_SERVER + path.format(ns=NAMESPACE),
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": content_type, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code == 404 and allow_404:
            return None
        raise K8sError(e.code, e.read().decode(errors="replace")) from None


def get_deployment(name):
    return k8s("GET", f"/apis/apps/v1/namespaces/{{ns}}/deployments/{name}", allow_404=True)


def container_env(dep, var):
    for item in dep["spec"]["template"]["spec"]["containers"][0].get("env") or []:
        if item.get("name") == var:
            return item.get("value", "")
    return ""


def rollout(dep):
    spec, st = dep.get("spec", {}), dep.get("status", {})
    want = spec.get("replicas", 1)
    done = (
        st.get("observedGeneration", 0) >= dep["metadata"].get("generation", 0)
        and st.get("updatedReplicas", 0) == want
        and st.get("readyReplicas", 0) == want
        and st.get("replicas", 0) == want
    )
    return {"replicas": want, "ready": st.get("readyReplicas", 0), "complete": done}


def fault_data():
    cm = k8s("GET", f"/api/v1/namespaces/{{ns}}/configmaps/{FAULT_CONFIGMAP}")
    return cm.get("data") or {}


def nudge_pods(svc):
    """Annotate pods so the kubelet resyncs them and refreshes mounted ConfigMaps."""
    selector = urllib.parse.quote(f"app.kubernetes.io/name={svc}", safe="")
    pods = k8s("GET", f"/api/v1/namespaces/{{ns}}/pods?labelSelector={selector}")["items"]
    patch = {"metadata": {"annotations": {"banking-demo/fault-config-updated": str(int(time.time()))}}}
    for pod in pods:
        k8s("PATCH", f"/api/v1/namespaces/{{ns}}/pods/{pod['metadata']['name']}", patch,
            "application/merge-patch+json")


def patch_fault(key, val):
    current = fault_data().get(key, "")
    if current == val:
        return f"{key} already {val}; no change."
    k8s("PATCH", f"/api/v1/namespaces/{{ns}}/configmaps/{FAULT_CONFIGMAP}", {"data": {key: val}},
        "application/merge-patch+json")
    svc = FAULT_TARGET[key]
    nudge_pods(svc)
    return f"{key}: '{current or '<unset>'}' -> '{val}' ({svc} picks this up in ~5-20 s)."


def set_env(name, **env):
    dep = get_deployment(name)
    if dep is None:
        raise ActionError(f"Deployment {name} not found in {NAMESPACE}.")
    if all(container_env(dep, k) == v for k, v in env.items()):
        return f"{name} already {' '.join(f'{k}={v}' for k, v in env.items())}; no change."
    container = dep["spec"]["template"]["spec"]["containers"][0]["name"]
    patch = {"spec": {"template": {"spec": {"containers": [
        {"name": container, "env": [{"name": k, "value": v} for k, v in env.items()]}]}}}}
    k8s("PATCH", f"/apis/apps/v1/namespaces/{{ns}}/deployments/{name}", patch,
        "application/strategic-merge-patch+json")
    return f"{name}: {' '.join(f'{k}={v}' for k, v in env.items())} (rolling out)."


def scale(name, replicas):
    k8s("PATCH", f"/apis/apps/v1/namespaces/{{ns}}/deployments/{name}", {"spec": {"replicas": replicas}},
        "application/merge-patch+json")
    return f"{name}: replicas -> {replicas}."


def fx_objects():
    with open(FX_MANIFESTS, encoding="utf-8") as f:
        return json.load(f)


def fx_onboard():
    for obj in fx_objects():
        meta = obj.setdefault("metadata", {})
        meta["namespace"] = NAMESPACE
        # Helm ownership metadata: a later `helm upgrade --install fx-rates` adopts these objects.
        meta.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "Helm"
        meta.setdefault("annotations", {}).update(
            {"meta.helm.sh/release-name": "fx-rates", "meta.helm.sh/release-namespace": NAMESPACE})
        path = f"{COLLECTION[obj['kind']]}/{meta['name']}?fieldManager={FIELD_MANAGER}&force=true"
        k8s("PATCH", path, obj, "application/apply-patch+yaml")
    return "fx-rates applied (ServiceAccount, Deployment, Service with the inject-python annotation only)."


def fx_remove():
    removed = []
    for obj in reversed(fx_objects()):
        name = obj["metadata"]["name"]
        if k8s("DELETE", f"{COLLECTION[obj['kind']]}/{name}", allow_404=True) is not None:
            removed.append(obj["kind"])
    return f"fx-rates removed ({', '.join(removed)})." if removed else "fx-rates is not installed; nothing to do."


def int_value(raw, default, lo, hi, label):
    if raw in (None, ""):
        return default
    if not re.fullmatch(r"\d+", str(raw)) or not lo <= int(raw) <= hi:
        raise ActionError(f"{label} must be an integer {lo}-{hi}, got '{raw}'.")
    return int(raw)


def reset():
    msgs = [
        patch_fault("LATENCY_MS", "0"),
        patch_fault("ERROR_RATE", "0"),
        patch_fault("SLOW_DB", "false"),
        set_env("transfer-service", APP_VERSION=BASE_VERSION, BAD_RELEASE="false"),
        fx_remove(),
        set_env("loadgen", RATE=str(DEFAULT_LOAD_RATE)),
        scale("loadgen", 1),
    ]
    return " ".join(msgs)


ACTIONS = {
    "latency-on": lambda v: (patch_fault("LATENCY_MS", str(int_value(v, DEFAULT_LATENCY_MS, 1, 60000, "Latency (ms)"))), "latency"),
    "latency-off": lambda v: (patch_fault("LATENCY_MS", "0"), None),
    "errors-on": lambda v: (patch_fault("ERROR_RATE", str(int_value(v, DEFAULT_ERROR_RATE, 1, 100, "Error rate (%)"))), "errors"),
    "errors-off": lambda v: (patch_fault("ERROR_RATE", "0"), None),
    "slow-db-on": lambda v: (patch_fault("SLOW_DB", "true"), "slow-db"),
    "slow-db-off": lambda v: (patch_fault("SLOW_DB", "false"), None),
    "bad-version-on": lambda v: (set_env("transfer-service", APP_VERSION=BAD_VERSION, BAD_RELEASE="true"), "bad-version"),
    "bad-version-off": lambda v: (set_env("transfer-service", APP_VERSION=BASE_VERSION, BAD_RELEASE="false"), None),
    "slo-breach-on": lambda v: (patch_fault("LATENCY_MS", str(SLO_BREACH_LATENCY_MS)), "slo-breach"),
    "slo-breach-off": lambda v: (patch_fault("LATENCY_MS", "0"), None),
    "fx-onboard": lambda v: (fx_onboard(), "fx-onboard"),
    "fx-remove": lambda v: (fx_remove(), None),
    "load-rate": lambda v: (set_env("loadgen", RATE=str(int_value(v, DEFAULT_LOAD_RATE, 1, 200, "Rate (req/s)"))) + " " + scale("loadgen", 1), None),
    "load-stop": lambda v: (scale("loadgen", 0), None),
    "reset": lambda v: (reset(), None),
}


def status():
    faults = fault_data()
    ts = get_deployment("transfer-service")
    lg = get_deployment("loadgen")
    fx = get_deployment("fx-rates")
    return {
        "faults": {
            "latency_ms": int(faults.get("LATENCY_MS") or 0),
            "error_rate": int(faults.get("ERROR_RATE") or 0),
            "slow_db": (faults.get("SLOW_DB") or "false") == "true",
        },
        "release": None if ts is None else {
            "version": container_env(ts, "APP_VERSION"),
            "bad": container_env(ts, "BAD_RELEASE") == "true",
            **rollout(ts),
        },
        "loadgen": None if lg is None else {"rate": container_env(lg, "RATE"), **rollout(lg)},
        "fx_rates": None if fx is None else rollout(fx),
        "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def config():
    env = urllib.parse.quote(ENVIRONMENT)
    links = []
    if BANK_URL:
        links.append({"label": "Bank UI", "url": f"{BANK_URL}/"})
    if KIBANA_URL:
        links += [
            {"label": "Service inventory", "url": f"{KIBANA_URL}/app/apm/services?environment={env}"},
            {"label": "Service map", "url": f"{KIBANA_URL}/app/apm/service-map?environment={env}"},
            {"label": "Alerts", "url": f"{KIBANA_URL}/app/observability/alerts"},
            {"label": "SLOs", "url": f"{KIBANA_URL}/app/slos"},
            {"label": "Discover", "url": f"{KIBANA_URL}/app/discover"},
            {"label": "Dashboards", "url": f"{KIBANA_URL}/app/dashboards"},
        ]
    arch = next((f"/static/{n}" for n in ("architecture.svg", "architecture.png", "architecture.jpg", "architecture.webp")
                 if os.path.isfile(os.path.join(STATIC_DIR, n))), None)
    return {
        "namespace": NAMESPACE,
        "environment": ENVIRONMENT,
        "base_version": BASE_VERSION,
        "bad_version": BAD_VERSION,
        "defaults": {"latency_ms": DEFAULT_LATENCY_MS, "error_rate": DEFAULT_ERROR_RATE, "load_rate": DEFAULT_LOAD_RATE},
        "links": links,
        "architecture": arch,
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
                 ".jpg": "image/jpeg", ".webp": "image/webp", ".css": "text/css", ".js": "text/javascript"}
STATIC_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-control-panel"

    def log_message(self, fmt, *args):  # keep the health checks out of the logs
        if not self.path.startswith("/healthz"):
            super().log_message(fmt, *args)

    def send_body(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send_body(code, json.dumps(obj).encode(), "application/json")

    def from_cloudfront(self):
        if not ORIGIN_SECRET:
            return True
        return hmac.compare_digest(self.headers.get("X-Origin-Verify", ""), ORIGIN_SECRET)

    def send_file(self, name):
        path = os.path.join(STATIC_DIR, name)
        ext = os.path.splitext(name)[1].lower()
        if not STATIC_NAME.match(name) or ext not in CONTENT_TYPES or not os.path.isfile(path):
            self.send_json(404, {"error": "not found"})
            return
        with open(path, "rb") as f:
            self.send_body(200, f.read(), CONTENT_TYPES[ext])

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            if path == "/healthz":
                self.send_body(200, b"ok", "text/plain")
            elif not self.from_cloudfront():
                self.send_json(403, {"error": "forbidden"})
            elif path == "/":
                self.send_file("index.html")
            elif path.startswith("/static/"):
                self.send_file(path[len("/static/"):])
            elif path == "/api/status":
                self.send_json(200, status())
            elif path == "/api/config":
                self.send_json(200, config())
            else:
                self.send_json(404, {"error": "not found"})
        except (K8sError, OSError, urllib.error.URLError) as e:
            self.send_json(502, {"error": str(e)})

    def do_POST(self):
        if not self.from_cloudfront():
            self.send_json(403, {"error": "forbidden"})
            return
        if urllib.parse.urlparse(self.path).path != "/api/action":
            self.send_json(404, {"error": "not found"})
            return
        # JSON-only: a cross-site form or no-cors fetch cannot send this content type.
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            self.send_json(415, {"error": "Content-Type must be application/json"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            self.send_json(413, {"error": "request too large"})
            return
        name = None
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
            name = req.get("action")
            if name not in ACTIONS:
                raise ActionError(f"Unknown action '{name}'.")
            message, expect_key = ACTIONS[name](req.get("value"))
            print(f"action {name} value={req.get('value')!r}: {message}", flush=True)
            self.send_json(200, {"ok": True, "message": message, "expect": EXPECT.get(expect_key)})
        except (ActionError, ValueError, AttributeError) as e:
            self.send_json(400, {"ok": False, "error": str(e)})
        except (K8sError, OSError, urllib.error.URLError) as e:
            print(f"action {name} failed: {e}", flush=True)
            self.send_json(502, {"ok": False, "error": str(e)})
        except Exception as e:  # keep the page informed instead of dropping the connection
            print(f"action {name} failed: {e!r}", flush=True)
            self.send_json(500, {"ok": False, "error": f"Internal error: {e!r}"})


if __name__ == "__main__":
    print(f"demo-control-panel listening on :{PORT} (namespace {NAMESPACE})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
