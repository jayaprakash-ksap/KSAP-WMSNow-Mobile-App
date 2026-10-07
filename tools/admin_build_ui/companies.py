"""Company master list (2026-09-25).

A Company is the top-level real-world customer entity (e.g. "Acme Corp") -
what build_lib.py/history.json calls "customer" and what
users.py's account scoping calls "company" (same string, just plugged
into different existing machinery). This module exists so a Company only
has to be typed once, from one screen, instead of free-typed per build -
that free-typing is exactly what produced duplicate/inconsistent customer-
name entries already sitting in history.json before this
existed. See instances.py for the per-environment details (domain/
instance/client_id/secret) that belong to a Company.

Existing history.json records created before this existed keep whatever
customer string they were built with - this module doesn't rewrite
history, so reconciling old duplicate names (if any) is a manual decision
for whoever owns that data, not something done automatically here.
"""

import json
from pathlib import Path

COMPANIES_PATH = Path(__file__).resolve().parent / "data" / "companies.json"


def _load_raw() -> list:
    if not COMPANIES_PATH.exists():
        return []
    try:
        return json.loads(COMPANIES_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _save_raw(companies: list) -> None:
    COMPANIES_PATH.parent.mkdir(parents=True, exist_ok=True)
    COMPANIES_PATH.write_text(json.dumps(companies, indent=2), encoding="utf-8")


def list_companies() -> list:
    return sorted(_load_raw(), key=str.lower)


def add_company(name: str) -> str | None:
    """Returns an error message, or None on success."""
    name = name.strip()
    if not name:
        return "Company name is required."
    companies = _load_raw()
    if any(c.lower() == name.lower() for c in companies):
        return f'A company named "{name}" already exists.'
    companies.append(name)
    _save_raw(companies)
    return None


def remove_company(name: str) -> str | None:
    """Returns an error message, or None on success. Callers (app.py)
    check for dependent instances/users before calling this - kept out of
    this module so it doesn't need to import instances.py/users.py."""
    companies = _load_raw()
    remaining = [c for c in companies if c != name]
    if len(remaining) == len(companies):
        return f'No company named "{name}" was found.'
    _save_raw(remaining)
    return None
