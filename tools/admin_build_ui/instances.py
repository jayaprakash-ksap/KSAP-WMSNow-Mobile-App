"""WMS environment ("Instance") master list (2026-09-25).

An Instance is exactly what build_lib.Environment already describes - name/
domain/instance/client_id/client_secret for one Oracle Cloud WMS
environment - plus a company it belongs to. Defining it once here, linked
to a Company, replaces retyping (and re-risking a typo in) the same
domain/client_id/secret on every single build for that environment.

Manual entry only (2026-09-25 decision) - this module does not, and is not
meant to, query Oracle for valid instance names. "name" is the same
friendly per-build label build_lib.Environment.name and session logs'
`instance` field already use (e.g. "mycompany_test") - NOT the separate
Environment.instance field (the actual Oracle pod/instance code), which is
still its own field here too. Two different "instance" words already
existed in this codebase before this file did; seeing both together here
is that collision, not a new one.
"""

import json
from pathlib import Path

INSTANCES_PATH = Path(__file__).resolve().parent / "data" / "instances.json"


def _load_raw() -> list:
    if not INSTANCES_PATH.exists():
        return []
    try:
        return json.loads(INSTANCES_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _save_raw(instances: list) -> None:
    INSTANCES_PATH.parent.mkdir(parents=True, exist_ok=True)
    INSTANCES_PATH.write_text(json.dumps(instances, indent=2), encoding="utf-8")


def list_instances(company: str = "") -> list:
    """Newest-defined-first isn't tracked - alphabetical by name, optionally
    narrowed to one company. Includes client_secret (this is an admin-only
    surface already, same trust level as the build form's own secret
    field) - app.py masks it wherever a template might render it."""
    instances = _load_raw()
    if company:
        instances = [i for i in instances if i["company"] == company]
    return sorted(instances, key=lambda i: i["name"].lower())


def find_instance(name: str) -> dict | None:
    for i in _load_raw():
        if i["name"] == name:
            return i
    return None


def add_instance(name: str, company: str, domain: str, instance: str,
                  client_id: str, client_secret: str) -> str | None:
    """Returns an error message, or None on success."""
    name = name.strip()
    company = company.strip()
    if not name:
        return "Instance name is required."
    if not company:
        return "Company is required."
    if not domain.strip() or not instance.strip() or not client_id.strip() or not client_secret:
        return "Domain, Instance, OAuth Client ID, and OAuth Client Secret are all required."
    instances = _load_raw()
    if any(i["name"] == name for i in instances):
        return f'An instance named "{name}" already exists.'
    instances.append({
        "name": name,
        "company": company,
        "domain": domain.strip(),
        "instance": instance.strip(),
        "client_id": client_id.strip(),
        "client_secret": client_secret,
    })
    _save_raw(instances)
    return None


def remove_instance(name: str) -> str | None:
    """Returns an error message, or None on success."""
    instances = _load_raw()
    remaining = [i for i in instances if i["name"] != name]
    if len(remaining) == len(instances):
        return f'No instance named "{name}" was found.'
    _save_raw(remaining)
    return None
