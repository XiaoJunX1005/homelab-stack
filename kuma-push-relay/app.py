#!/usr/bin/env python3
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote, urljoin
from urllib.request import urlopen, Request

HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", "8080"))
KUMA_PUSH_TOKEN = os.environ.get("KUMA_PUSH_TOKEN", "").strip()
KUMA_BASE_URL = os.environ.get("KUMA_BASE_URL", "http://kuma.local/api/push/").rstrip("/") + "/"
DEFAULT_UP_MSG = os.environ.get("DEFAULT_UP_MSG", "watchtower_ok")
DEFAULT_DOWN_MSG = os.environ.get("DEFAULT_DOWN_MSG", "watchtower_failed")
TIMEOUT_SECONDS = float(os.environ.get("KUMA_TIMEOUT", "5"))

if not KUMA_PUSH_TOKEN:
    print("KUMA_PUSH_TOKEN is required", file=sys.stderr)
    sys.exit(1)


def extract_message(body_bytes: bytes, fallback: str) -> str:
    if not body_bytes:
        return fallback
    text = body_bytes.decode("utf-8", errors="ignore").strip()
    if not text:
        return fallback
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                for key in ("message", "msg", "text", "title"):
                    if key in data and isinstance(data[key], str) and data[key].strip():
                        return data[key].strip()
            # If it's JSON but not a dict or missing fields, fall back to raw text
        except Exception:
            pass
    return text


def push_to_kuma(status: str, message: str) -> tuple[int, str]:
    encoded_msg = quote(message)
    url = f"{KUMA_BASE_URL}{KUMA_PUSH_TOKEN}?status={status}&msg={encoded_msg}&ping="
    req = Request(url, method="GET")
    with urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
        body = resp.read().decode("utf-8", errors="ignore")
        return resp.status, body


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path not in ("/up", "/down"):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found")
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length > 0 else b""

        if self.path == "/up":
            status = "up"
            fallback = DEFAULT_UP_MSG
        else:
            status = "down"
            fallback = DEFAULT_DOWN_MSG

        message = extract_message(body, fallback)

        try:
            code, resp_body = push_to_kuma(status, message)
        except Exception as exc:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(f"kuma error: {exc}".encode("utf-8", errors="ignore"))
            return

        if 200 <= code < 300:
            self.send_response(200)
        else:
            self.send_response(502)
        self.end_headers()
        payload = f"pushed {status} ({code}): {resp_body}".encode("utf-8", errors="ignore")
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/health", "/"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"not found")

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    print(f"kuma-push-relay listening on {HOST}:{PORT}")
    server.serve_forever()
