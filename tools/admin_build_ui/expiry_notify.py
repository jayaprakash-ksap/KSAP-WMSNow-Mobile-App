"""Expiry-approaching email alerts for licensed customer builds (2026-09-18).

Every build bakes in a license expiry date (see build_lib.BuildRequest
.expiry_date / --dart-define=WMSNOW_LICENSE_EXPIRY) that is checked once at
app launch and is never shown to any device user, ever - see AppConfig in
lib/config/app_config.dart. This module is deliberately the ONLY place
"days remaining" is surfaced at all: an email to whoever is on the
notification list (see notify_settings.py) as a customer's CURRENT (most
recent) build approaches its baked-in expiry, so a renewal build can be
generated and redistributed before the app actually stops letting anyone
log in on that date.

Meant to run continuously alongside the Admin Build UI (see app.py's
background thread) - checked once an hour, which is cheap and
self-correcting: if the process was down for a while, the next check just
sees a smaller "days remaining" than expected and alerts on whichever
threshold is closest to accurate, rather than needing to catch every
individual day it missed.
"""

import smtplib
from datetime import date, datetime
from email.mime.text import MIMEText

import build_lib
import notify_settings

# Edit these before relying on this beyond local testing - same shared
# "trusted local tool" SMTP framing as every other relay in this project
# (see tools/trailer_reject_email_receiver.py).
SMTP_HOST = "smtp.example.com"
SMTP_PORT = 587
SMTP_USERNAME = "change-me@example.com"
SMTP_PASSWORD = "change-me"
MAIL_FROM = "change-me@example.com"

# Days-remaining thresholds that trigger an alert. Each fires at most once
# per build record (tracked via build_lib.mark_notified). 0 covers
# "expires today" for anyone who missed the earlier warnings; nothing
# negative is included here - once it's actually expired, the app itself
# already stops working, which is signal enough on its own.
THRESHOLDS = [30, 14, 7, 1, 0]


def _days_remaining(expiry_date: str) -> "int | None":
    try:
        expiry = datetime.strptime(expiry_date, "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None
    return (expiry - date.today()).days


def _compose(customer: str, record: dict, remaining: int) -> "tuple[str, str]":
    expiry = record["expiry_date"]
    if remaining < 0:
        headline = f"already expired {abs(remaining)} day(s) ago"
    elif remaining == 0:
        headline = "expires TODAY"
    else:
        headline = f"expires in {remaining} day(s)"
    subject = f"[WMSNow] {customer} build license {headline} ({expiry})"
    body = (
        f"Customer: {customer}\n"
        f"Current build's license expiry date: {expiry}\n"
        f"Status: {headline}\n\n"
        f"Build id: {record['id']}\n"
        f"Built on: {record['timestamp']}\n\n"
        "No action happens automatically beyond this email - the app will "
        "simply stop allowing login on the customer's devices once the "
        "expiry date passes. To renew or extend, generate a new build for "
        "this customer with a later License Expiry Date in the Admin "
        "Build UI and get it redistributed to their devices."
    )
    return subject, body


def _send(subject: str, body: str, recipients: list) -> bool:
    if not recipients:
        return False
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = MAIL_FROM
    msg["To"] = ", ".join(recipients)
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
            server.starttls()
            server.login(SMTP_USERNAME, SMTP_PASSWORD)
            server.sendmail(MAIL_FROM, recipients, msg.as_string())
        return True
    except Exception as e:  # noqa: BLE001 - a failed alert must never crash the check loop
        print(f"expiry_notify: failed to send email: {e}")
        return False


def check_and_notify() -> None:
    """Looks at every customer's most recent build and emails the
    notification list once for the nearest expiry threshold reached that
    hasn't already been alerted on. Safe to call repeatedly (e.g. hourly) -
    already-sent thresholds are skipped, so this is a no-op most of the
    time."""
    recipients = notify_settings.load_emails()
    for customer in build_lib.list_customers():
        record = build_lib.latest_record(customer)
        if not record or not record.get("expiry_date"):
            continue
        remaining = _days_remaining(record["expiry_date"])
        if remaining is None:
            continue
        already = set(record.get("notified_thresholds", []))
        # Every threshold this build has reached (remaining <= threshold)
        # but hasn't been alerted on yet. Ascending order so the smallest
        # is the most accurate description of "remaining" right now - if
        # several were missed at once (the tool was off for a while),
        # sending the 30-day version after we're already at 5 days would
        # be misleading.
        reached_unnotified = sorted(
            t for t in THRESHOLDS if remaining <= t and t not in already
        )
        if not reached_unnotified:
            continue
        threshold = reached_unnotified[0]
        subject, body = _compose(customer, record, remaining)
        if _send(subject, body, recipients):
            # Every threshold at or above this one is now moot - mark them
            # all notified so a later check never sends a LESS urgent
            # follow-up (e.g. a "14 days" email arriving after "5 days"
            # already went out).
            for t in reached_unnotified:
                build_lib.mark_notified(record["id"], t)
