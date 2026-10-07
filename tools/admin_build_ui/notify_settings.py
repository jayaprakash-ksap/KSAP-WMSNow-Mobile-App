"""Stores the list of email addresses that receive "license expiry
approaching" alerts (see expiry_notify.py).

A single global list, editable from the Admin Build UI - not per-customer,
since one small team typically handles renewals for every customer. This
is deliberately the ONLY place "days remaining" is ever surfaced - never
shown to any device/end user (see lib/config/app_config.dart).
"""

import json
from pathlib import Path

NOTIFY_PATH = Path(__file__).resolve().parent / "data" / "notify_emails.json"


def load_emails() -> list:
    if not NOTIFY_PATH.exists():
        return []
    try:
        return json.loads(NOTIFY_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def save_emails(emails: list) -> None:
    NOTIFY_PATH.parent.mkdir(parents=True, exist_ok=True)
    cleaned = sorted({e.strip() for e in emails if e.strip()})
    NOTIFY_PATH.write_text(json.dumps(cleaned, indent=2), encoding="utf-8")


def add_email(email: str) -> list:
    emails = load_emails()
    email = email.strip()
    if email and email not in emails:
        emails.append(email)
        save_emails(emails)
    return load_emails()


def remove_email(email: str) -> list:
    email = email.strip()
    emails = [e for e in load_emails() if e != email]
    save_emails(emails)
    return emails
