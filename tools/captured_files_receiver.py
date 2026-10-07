#!/usr/bin/env python3
"""Local receiver for WMSNow Redwood Mobile's captured photos/signatures.

Run this on the same machine the project source lives on:

    python tools/captured_files_receiver.py

It listens on 0.0.0.0:PORT and writes every accepted upload into
`captured_images/` next to THIS script (i.e. <project root>/captured_images)
- not a hardcoded absolute path. That means copying this exact file into a
different `wmsnow_redwood_v*` project folder later makes it write into that
folder's own captured_images automatically, no code changes needed.

Change TOKEN below before relying on this beyond local testing - it's a
shared secret adequate for a trusted local-network test tool, not a
production security boundary (see AppConfig's own note on client_secret
for the same "test-grade" framing elsewhere in this project).

First run on Windows will likely prompt a Firewall "Allow access" dialog -
click Allow for Private networks so the phone can reach it over WiFi.
"""

import http.server
import os
import re
import socketserver
import sys
from pathlib import Path

PORT = 8765
TOKEN = "PfZwq8vuPdZWwSYh0M6G8Q"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEST_DIR = PROJECT_ROOT / "captured_images"

_UNSAFE_CHARS = re.compile(r"[^A-Za-z0-9_.-]")


def safe_filename(raw: str) -> str:
    """Strips any path component and disallowed characters - the one thing
    that must never happen is an X-Filename header like `../../x` writing
    outside DEST_DIR."""
    name = os.path.basename(raw.strip())
    name = _UNSAFE_CHARS.sub("_", name)
    return name or "upload.bin"


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, status: int, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, "ok")
        else:
            self._reply(404, "not found")

    def do_POST(self):
        if self.path != "/upload":
            self._reply(404, "not found")
            return

        if self.headers.get("X-Auth-Token") != TOKEN:
            self._reply(401, "bad token")
            return

        raw_name = self.headers.get("X-Filename")
        if not raw_name:
            self._reply(400, "missing X-Filename header")
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            self._reply(400, "empty body")
            return
        body = self.rfile.read(length)

        DEST_DIR.mkdir(parents=True, exist_ok=True)
        name = safe_filename(raw_name)
        dest = DEST_DIR / name
        # The app's own filenames already carry a millisecond timestamp, so
        # collisions should be rare - guard anyway rather than silently
        # overwrite an existing capture.
        counter = 1
        stem, suffix = dest.stem, dest.suffix
        while dest.exists():
            dest = DEST_DIR / f"{stem}_{counter}{suffix}"
            counter += 1

        try:
            dest.write_bytes(body)
        except OSError as e:
            self._reply(500, f"write failed: {e}")
            return

        print(f"Received {dest.name} ({len(body)} bytes) -> {dest}")
        self._reply(200, "ok")

    def log_message(self, fmt, *args):
        # Quieter default logging - just the one line per upload above.
        pass


def main() -> None:
    DEST_DIR.mkdir(parents=True, exist_ok=True)
    if TOKEN == "change-me-wmsnow-pod-token":
        print("WARNING: using the default TOKEN - edit this script before "
              "relying on it beyond local testing.", file=sys.stderr)
    with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"Captured files receiver listening on 0.0.0.0:{PORT}")
        print(f"Writing uploads to: {DEST_DIR}")
        print("Find this machine's LAN IP with `ipconfig` and point the "
              "app's Upload Server setting at http://<that-ip>:%d" % PORT)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
