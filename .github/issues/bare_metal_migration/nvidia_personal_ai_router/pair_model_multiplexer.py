#!/usr/bin/env python3
"""
PAIR Model Multiplexer (OpenAI-compatible LM Studio Masquerade Proxy)

Aggregates multiple concurrent llama-server backend instances into a single
unified OpenAI-compatible API endpoint on port 1235 (or user-specified port).

Features:
- Pure Python 3 standard library: zero external pip dependencies.
- Dynamically aggregates GET /v1/models across all running backend instances.
- Inspects incoming POST requests (chat/completions, completions, embeddings)
  and routes to the backend hosting the requested model.
- Transparent streaming proxy for Server-Sent Events (SSE) token generation.
- Health check endpoint (GET /health, GET /) for PAIR readiness probes.
"""

import argparse
import json
import logging
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [PAIR-Multiplexer] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("pair_multiplexer")

# Global routing registry: model_id -> backend_url
ROUTING_TABLE: dict[str, str] = {}
BACKENDS: list[str] = []
ROUTING_LOCK = threading.Lock()
LAST_REFRESH = 0
REFRESH_INTERVAL = 5.0  # Refresh model catalog every 5 seconds

# Direct opener that bypasses any ambient HTTP_PROXY/HTTPS_PROXY environment variables
DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def normalize_model_name(name: str) -> str:
    """Normalize model identifier for robust lookup."""
    return name.lower().strip().replace("openai/", "")


def refresh_backend_models():
    """Poll each backend /v1/models to build the routing table and merged catalog."""
    global LAST_REFRESH, ROUTING_TABLE
    with ROUTING_LOCK:
        now = time.time()
        if now - LAST_REFRESH < REFRESH_INTERVAL and ROUTING_TABLE:
            return

        new_table: dict[str, str] = {}
        for backend in BACKENDS:
            models_url = f"{backend.rstrip('/')}/v1/models"
            try:
                req = urllib.request.Request(models_url, headers={"User-Agent": "PAIR-Multiplexer/1.0"})
                with DIRECT_OPENER.open(req, timeout=3.0) as resp:
                    if resp.status == 200:
                        data = json.loads(resp.read().decode("utf-8"))
                        for item in data.get("data", []):
                            m_id = item.get("id", "")
                            if m_id:
                                new_table[m_id] = backend
                                new_table[normalize_model_name(m_id)] = backend
                                # Map basename if path-like
                                base = os.path.basename(m_id)
                                if base:
                                    new_table[base] = backend
                                    new_table[normalize_model_name(base)] = backend
            except Exception as e:
                logger.debug("Failed to query %s: %s", models_url, e)

        ROUTING_TABLE = new_table
        LAST_REFRESH = now


def get_target_backend(requested_model: str) -> str:
    """Resolve backend URL for a given model string."""
    refresh_backend_models()
    with ROUTING_LOCK:
        if not BACKENDS:
            return ""

        if not requested_model:
            return BACKENDS[0]

        norm = normalize_model_name(requested_model)

        # 1. Exact match
        if requested_model in ROUTING_TABLE:
            return ROUTING_TABLE[requested_model]
        if norm in ROUTING_TABLE:
            return ROUTING_TABLE[norm]

        # 2. Substring / fuzzy match
        for key, backend in ROUTING_TABLE.items():
            if norm in key or key in norm:
                return backend

        # 3. Fallback to first available backend
        return BACKENDS[0]


def get_merged_models() -> dict:
    """Fetch and merge models from all active backends."""
    merged = []
    seen_ids = set()

    for backend in BACKENDS:
        models_url = f"{backend.rstrip('/')}/v1/models"
        try:
            req = urllib.request.Request(models_url, headers={"User-Agent": "PAIR-Multiplexer/1.0"})
            with DIRECT_OPENER.open(req, timeout=3.0) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode("utf-8"))
                    for item in data.get("data", []):
                        m_id = item.get("id")
                        if m_id and m_id not in seen_ids:
                            seen_ids.add(m_id)
                            merged.append(item)
        except Exception as e:
            logger.debug("Error querying models from %s: %s", models_url, e)

    return {"object": "list", "data": merged}


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class MultiplexerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Suppress routine access logs; only log errors/proxies
        pass

    def do_GET(self):
        # Health checks
        if self.path in ("/", "/health", "/v1/health"):
            payload = json.dumps({"status": "ok", "backends": len(BACKENDS)}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return

        # Models catalog
        if self.path in ("/v1/models", "/models"):
            catalog = get_merged_models()
            payload = json.dumps(catalog).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return

        # Fallback GET proxy
        self.proxy_request("GET", None)

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        self.proxy_request("POST", body)

    def proxy_request(self, method: str, body: bytes | None):
        target_model = ""
        if body and self.path.startswith(("/v1/chat/completions", "/v1/completions", "/v1/embeddings")):
            try:
                parsed = json.loads(body.decode("utf-8"))
                target_model = parsed.get("model", "")
            except Exception:
                pass

        backend = get_target_backend(target_model)
        if not backend:
            self.send_error(503, "No inference backends available")
            return

        target_url = f"{backend.rstrip('/')}{self.path}"
        logger.info("Proxying %s %s (model: '%s') -> %s", method, self.path, target_model or "default", backend)

        # Assemble headers to forward
        headers = {}
        for h_name, h_val in self.headers.items():
            if h_name.lower() not in ("host", "content-length"):
                headers[h_name] = h_val
        if body is not None:
            headers["Content-Length"] = str(len(body))

        req = urllib.request.Request(target_url, data=body if method == "POST" else None, headers=headers, method=method)

        try:
            with DIRECT_OPENER.open(req, timeout=300.0) as resp:
                self.send_response(resp.status)
                for h_name, h_val in resp.headers.items():
                    if h_name.lower() not in ("transfer-encoding",):
                        self.send_header(h_name, h_val)
                self.end_headers()

                # Stream response (unbuffered for SSE chunks)
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        break
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for h_name, h_val in e.headers.items():
                self.send_header(h_name, h_val)
            self.end_headers()
            try:
                err_data = e.read()
                self.wfile.write(err_data)
            except Exception:
                pass
        except Exception as e:
            logger.error("Failed to proxy to %s: %s", target_url, e)
            self.send_error(502, f"Bad Gateway: backend {backend} error: {e}")


def parse_args():
    parser = argparse.ArgumentParser(description="PAIR Multi-Model Llama Multiplexer Proxy")
    parser.add_argument("--bind", "-b", default="0.0.0.0", help="Listen address [default: 0.0.0.0]")
    parser.add_argument("--port", "-p", type=int, default=1235, help="Listen port [default: 1235]")
    parser.add_argument("--backends", required=True, help="Comma-separated backend URLs (e.g. http://127.0.0.1:11235,http://127.0.0.1:11236)")
    parser.add_argument("--pid-file", help="Path to write daemon PID")
    return parser.parse_args()


def main():
    global BACKENDS
    args = parse_args()

    BACKENDS = [b.strip() for b in args.backends.split(",") if b.strip()]
    if not BACKENDS:
        logger.error("No valid backends provided. Exiting.")
        sys.exit(1)

    # Write PID file if requested
    if args.pid_file:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(args.pid_file)), exist_ok=True)
            with open(args.pid_file, "w") as f:
                f.write(str(os.getpid()))
        except Exception as e:
            logger.warning("Failed to write pid file %s: %s", args.pid_file, e)

    server = ThreadedHTTPServer((args.bind, args.port), MultiplexerHandler)

    def shutdown_signal(signum, frame):
        logger.info("Received signal %s. Shutting down multiplexer on port %s...", signum, args.port)
        threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGTERM, shutdown_signal)
    signal.signal(signal.SIGINT, shutdown_signal)

    logger.info("PAIR Model Multiplexer active on http://%s:%s", args.bind, args.port)
    logger.info("Registered backends (%d): %s", len(BACKENDS), ", ".join(BACKENDS))

    try:
        server.serve_forever()
    finally:
        server.server_close()
        if args.pid_file and os.path.exists(args.pid_file):
            try:
                os.remove(args.pid_file)
            except Exception:
                pass
        logger.info("Multiplexer stopped.")


if __name__ == "__main__":
    main()
