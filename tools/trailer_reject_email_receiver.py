#!/usr/bin/env python3
"""Local relay for WMSNow Redwood Mobile's Full Pallet Task "Reject" email.

Run this on the same machine the project source lives on:

    python tools/trailer_reject_email_receiver.py

It listens on 0.0.0.0:PORT and, on each accepted POST /reject-email,
sends a "Trailer Eligibility Form" email via SMTP - mail
credentials live only here, never inside the distributed app (same
reasoning as captured_files_receiver.py's TOKEN note, and AppConfig's own
note on client_secret, for the same "keep secrets out of the app" idea).

Change TOKEN and the SMTP_* constants below before relying on this beyond
local testing - TOKEN is a shared secret adequate for a trusted
local-network tool, not a production security boundary.

First run on Windows will likely prompt a Firewall "Allow access" dialog -
click Allow for Private networks so the phone/desktop app can reach it
over WiFi.
"""

import http.server
import json
import smtplib
import socketserver
import sys
from email.mime.text import MIMEText

PORT = 8766
TOKEN = "PfZwq8vuPdZWwSYh0M6G8Q"

# SMTP relay settings - edit these before relying on this beyond local
# testing. A plain (non-SSL) submission server on SMTP_PORT 587 with STARTTLS
# is assumed; adjust send_reject_email() below if your mail provider needs
# SMTP_SSL instead.
SMTP_HOST = "smtp.example.com"
SMTP_PORT = 587
SMTP_USERNAME = "change-me@example.com"
SMTP_PASSWORD = "change-me"
MAIL_FROM = "change-me@example.com"
MAIL_TO = "jayaprakash@ksaptech.com"
# This customer's own name for the form - edit per deployment, same idea as
# SMTP_*/MAIL_* above.
FORM_NAME = "Trailer Eligibility Form"


def build_email_body(data: dict) -> str:
    trailer = data.get("trailer", "")
    shipment = data.get("shipment", "")
    status = data.get("status", "Reject")
    timestamp = data.get("timestamp", "")
    username = data.get("username", "")
    return f"""\
{FORM_NAME}

Trailer Number : {trailer}
Shipment Number: {shipment}
Status         : {status}
Timestamp      : {timestamp}
Username       : {username}
"""


def send_reject_email(data: dict) -> None:
    body = build_email_body(data)
    msg = MIMEText(body)
    msg["Subject"] = f"{FORM_NAME} - Reject ({data.get('trailer', '')})"
    msg["From"] = MAIL_FROM
    msg["To"] = MAIL_TO

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
        server.starttls()
        server.login(SMTP_USERNAME, SMTP_PASSWORD)
        server.sendmail(MAIL_FROM, [MAIL_TO], msg.as_string())


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
        if self.path != "/reject-email":
            self._reply(404, "not found")
            return

        if self.headers.get("X-Auth-Token") != TOKEN:
            self._reply(401, "bad token")
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            self._reply(400, "empty body")
            return
        raw = self.rfile.read(length)

        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._reply(400, "invalid JSON body")
            return

        try:
            send_reject_email(data)
        except Exception as e:
            print(f"Failed to send reject email: {e}", file=sys.stderr)
            self._reply(500, f"send failed: {e}")
            return

        print(f"Sent reject email for trailer {data.get('trailer', '')}")
        self._reply(200, "ok")

    def log_message(self, fmt, *args):
        # Quieter default logging - just the one line per email above.
        pass


def main() -> None:
    if TOKEN == "change-me-wmsnow-pod-token":
        print("WARNING: using the default TOKEN - edit this script before "
              "relying on it beyond local testing.", file=sys.stderr)
    if SMTP_HOST == "smtp.example.com":
        print("WARNING: SMTP_* settings are still placeholders - edit them "
              "at the top of this script before relying on this.",
              file=sys.stderr)
    with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"Trailer reject-email relay listening on 0.0.0.0:{PORT}")
        print("Find this machine's LAN IP with `ipconfig` and point the "
              "app's Email Server setting at http://<that-ip>:%d" % PORT)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
