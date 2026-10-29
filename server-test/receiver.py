#!/usr/bin/env python3
import argparse
import json
import os
import re
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST_RE = re.compile(r"[^A-Za-z0-9._-]+")


def safe_hostname(value: str) -> str:
    value = (value or "UNKNOWN").strip().upper()
    value = HOST_RE.sub("-", value).strip("-")
    return (value or "UNKNOWN")[:63]


class Receiver(BaseHTTPRequestHandler):
    server_version = "cmkagent-test-receiver/1.0"

    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok", "time": int(time.time())})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/v1/agent":
            self._json(404, {"error": "not found"})
            return

        expected = self.server.token
        if expected:
            auth = self.headers.get("Authorization", "")
            if auth != f"Bearer {expected}":
                self._json(401, {"error": "invalid token"})
                return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > 2 * 1024 * 1024:
            self._json(400, {"error": "invalid payload size"})
            return

        raw = self.rfile.read(length)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            self._json(400, {"error": "payload must be utf-8"})
            return

        if "<<<check_mk>>>" not in text or "<<<local" not in text:
            self._json(400, {"error": "not a Checkmk agent payload"})
            return

        hostname = safe_hostname(self.headers.get("X-CMK-Hostname", "UNKNOWN"))
        data_dir = self.server.data_dir
        data_dir.mkdir(parents=True, exist_ok=True)

        target = data_dir / f"{hostname}.agent"
        meta = data_dir / f"{hostname}.json"

        fd, temp_name = tempfile.mkstemp(prefix=f".{hostname}.", dir=str(data_dir))
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_name, target)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)

        metadata = {
            "hostname": hostname,
            "received_at": int(time.time()),
            "remote_ip": self.client_address[0],
            "agent_version": self.headers.get("X-CMK-Agent-Version", ""),
            "transport": self.headers.get("X-CMK-Transport", ""),
            "bytes": len(raw),
            "file": str(target),
        }
        meta.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        self._json(200, {"status": "accepted", "hostname": hostname, "bytes": len(raw)})

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {fmt % args}")


def main():
    parser = argparse.ArgumentParser(description="Minimal test receiver for cmkagent hybrid push")
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--data-dir", default="./push-cache")
    parser.add_argument("--token", default="")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.listen, args.port), Receiver)
    server.data_dir = Path(args.data_dir).resolve()
    server.token = args.token
    print(f"Listening on http://{args.listen}:{args.port}")
    print(f"POST endpoint: /api/v1/agent")
    print(f"Cache dir: {server.data_dir}")
    print("Token: " + ("enabled" if args.token else "disabled (test only)"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
