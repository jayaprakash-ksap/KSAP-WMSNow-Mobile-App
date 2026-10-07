"""Customer-facing download links for distributing generated builds
(2026-09-28) - see the Distribution Links page in the Admin Build UI.

A link is scoped to one Company, optionally narrowed to one Instance, and
resolves to whichever build is currently marked "active" for it - see
app.py's public /dl/<token> route, which is deliberately reachable with NO
admin login (floor handhelds hit it directly to download the APK; a QR
code encoding this same URL is what actually gets handed to them).

The link's URL never changes once created. Generating a new matching
build normally auto-advances "active" to it (see on_new_build, called
right after a successful build) - but if a build turns out to be broken,
set_active_build() pins the link back to an earlier one and turns OFF
auto-advance, so the SAME url starts serving the older build again
without anything needing to be redistributed. resume_auto_advance() turns
auto-advance back on when you're ready to resume normal updates.

The token in the URL (not the human-readable slug prefix) is the actual
access control - a long random suffix nobody could guess from another
customer's link, since these locked builds carry real OAuth credentials.
"""

import json
import secrets
from datetime import datetime
from pathlib import Path

import build_lib

LINKS_PATH = Path(__file__).resolve().parent / "data" / "distribution_links.json"


def _load_raw() -> list:
    if not LINKS_PATH.exists():
        return []
    try:
        return json.loads(LINKS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _save_raw(links: list) -> None:
    LINKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    LINKS_PATH.write_text(json.dumps(links, indent=2), encoding="utf-8")


def _slugify(text: str) -> str:
    safe = "".join(c.lower() if c.isalnum() else "-" for c in text)
    while "--" in safe:
        safe = safe.replace("--", "-")
    return safe.strip("-") or "link"


def _latest_matching_record_id(customer: str, instance: str) -> str | None:
    """The newest history record for this customer that includes `instance`
    among its baked-in environments - or the newest record overall, if
    instance is blank (the whole-customer case)."""
    for record in build_lib.get_customer_history(customer):  # newest first
        if not instance or any(e["name"] == instance for e in record["environments"]):
            return record["id"]
    return None


def list_links(customer: str = "") -> list:
    links = _load_raw()
    if customer:
        links = [link for link in links if link["customer"] == customer]
    return links


def find_link(token: str) -> dict | None:
    for link in _load_raw():
        if link["token"] == token:
            return link
    return None


def create_link(customer: str, instance: str, requesting_username: str):
    """Returns (link, error) - exactly one of the two is None."""
    customer = customer.strip()
    instance = instance.strip()
    if not customer:
        return None, "Company is required."
    active_record_id = _latest_matching_record_id(customer, instance)
    if active_record_id is None:
        target = f'"{customer}"' + (f' / instance "{instance}"' if instance else "")
        return None, f"No build exists yet for {target} - generate one first."

    slug_base = f"{customer}-{instance}" if instance else customer
    token = f"{_slugify(slug_base)}-{secrets.token_urlsafe(16)}"
    link = {
        "token": token,
        "customer": customer,
        "instance": instance,
        "active_record_id": active_record_id,
        "auto_advance": True,
        "created_by": requesting_username,
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }
    links = _load_raw()
    links.append(link)
    _save_raw(links)
    return link, None


def revoke_link(token: str) -> str | None:
    """Returns an error message, or None on success."""
    links = _load_raw()
    remaining = [link for link in links if link["token"] != token]
    if len(remaining) == len(links):
        return "Link not found."
    _save_raw(remaining)
    return None


def set_active_build(token: str, record_id: str) -> str | None:
    """Explicit pin - a rollback to an older build, or advancing to a
    specific one. Turns auto_advance OFF so a later new build doesn't
    silently override this deliberate choice - see resume_auto_advance."""
    links = _load_raw()
    link = next((link for link in links if link["token"] == token), None)
    if link is None:
        return "Link not found."
    _, record = build_lib.find_record(record_id)
    if record is None or link["customer"] != _customer_of(record_id):
        return "That build doesn't belong to this link's company."
    link["active_record_id"] = record_id
    link["auto_advance"] = False
    _save_raw(links)
    return None


def _customer_of(record_id: str) -> str | None:
    customer, record = build_lib.find_record(record_id)
    return customer if record is not None else None


def resume_auto_advance(token: str) -> str | None:
    """Returns an error message, or None on success."""
    links = _load_raw()
    link = next((link for link in links if link["token"] == token), None)
    if link is None:
        return "Link not found."
    latest = _latest_matching_record_id(link["customer"], link["instance"])
    if latest is not None:
        link["active_record_id"] = latest
    link["auto_advance"] = True
    _save_raw(links)
    return None


def on_new_build(customer: str, record_id: str, instance_names: list) -> None:
    """Called right after a successful build (app.py's _run_job) - advances
    any auto_advance link for this customer whose instance filter matches
    (a blank filter matches any build for this customer)."""
    links = _load_raw()
    changed = False
    for link in links:
        if link["customer"] != customer or not link.get("auto_advance", True):
            continue
        if link["instance"] and link["instance"] not in instance_names:
            continue
        if link["active_record_id"] != record_id:
            link["active_record_id"] = record_id
            changed = True
    if changed:
        _save_raw(links)
