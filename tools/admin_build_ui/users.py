"""Admin Build UI user accounts, roles, and company scoping (2026-09-25).

Two independent axes per user:

- role: "builder" (everything today's single ADMIN_USERNAME/ADMIN_PASSWORD
  account could do - generate/rebuild APKs, download build artifacts,
  manage notification emails, PLUS everything a viewer can see) or
  "viewer" (read-only: History, Compare, Logs - Images is unrestricted-
  only for now, see app.py). Managing other users (/users) additionally
  requires being an UNRESTRICTED builder (see below) - a company-scoped
  builder must not be able to create accounts for other companies.

- company: "" (empty) means unrestricted - sees/builds every customer,
  same as the tool always worked before this existed. A non-empty value
  scopes the account to exactly that one customer's build history, logs,
  and build form - they can't see or act on any other customer's data.
  "Customer" is this codebase's existing term (see build_lib.py /
  history.json); "company" is what the request used, same thing here.

Same "local trusted network, test-grade secrets" framing as the rest of
this tool (see app.py's module doc comment) - this is not meant to
withstand a hostile user on the same machine. Passwords are hashed with
werkzeug's own helper (already a Flask dependency, no new package) mainly
so the users.json file itself isn't a list of plaintext passwords if
someone copies it around - not a claim this is hardened auth.
"""

import json
from pathlib import Path

from werkzeug.security import check_password_hash, generate_password_hash

USERS_PATH = Path(__file__).resolve().parent / "data" / "users.json"

ROLES = ("builder", "viewer")


def _load_raw() -> list:
    if not USERS_PATH.exists():
        return []
    try:
        return json.loads(USERS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _save_raw(users: list) -> None:
    USERS_PATH.parent.mkdir(parents=True, exist_ok=True)
    USERS_PATH.write_text(json.dumps(users, indent=2), encoding="utf-8")


def _is_unrestricted_builder(u: dict) -> bool:
    return u["role"] == "builder" and not u.get("company")


def seed_if_empty(default_username: str, default_password: str) -> None:
    """Called once at app startup. If no users.json exists yet, seed it
    with a single unrestricted builder account from the existing
    ADMIN_USERNAME/ADMIN_PASSWORD constants, so an upgrade from the old
    single-account model doesn't lock anyone out."""
    if USERS_PATH.exists():
        return
    _save_raw([{
        "username": default_username,
        "password_hash": generate_password_hash(default_password),
        "role": "builder",
        "company": "",
    }])


def list_users() -> list:
    """Username + role + company only - never returns password hashes to a
    caller that might render them (there's no legitimate reason a template
    needs one)."""
    return [
        {"username": u["username"], "role": u["role"], "company": u.get("company", "")}
        for u in _load_raw()
    ]


def find_user(username: str) -> dict | None:
    for u in _load_raw():
        if u["username"] == username:
            return u
    return None


def verify_login(username: str, password: str) -> dict | None:
    """Returns {"username", "role", "company"} on success, None on bad
    credentials."""
    user = find_user(username)
    if user is None or not check_password_hash(user["password_hash"], password):
        return None
    return {
        "username": user["username"],
        "role": user["role"],
        "company": user.get("company", ""),
    }


def add_user(username: str, password: str, role: str, company: str = "") -> str | None:
    """Returns an error message, or None on success."""
    username = username.strip()
    company = company.strip()
    if not username:
        return "Username is required."
    if not password:
        return "Password is required."
    if role not in ROLES:
        return f"Role must be one of {ROLES}."
    users = _load_raw()
    if any(u["username"] == username for u in users):
        return f'A user named "{username}" already exists.'
    users.append({
        "username": username,
        "password_hash": generate_password_hash(password),
        "role": role,
        "company": company,
    })
    _save_raw(users)
    return None


def remove_user(username: str, requesting_username: str) -> str | None:
    """Returns an error message, or None on success. Refuses to let a
    builder delete their own account from this screen - avoids the
    confusing "logged in but your session no longer maps to a real user"
    state, and guards against the last UNRESTRICTED builder account
    deleting itself and locking everyone out of user management (a
    company-scoped builder can't manage users at all - see
    app.py:unrestricted_builder_required - so a merely non-empty count of
    "builder"-role accounts isn't enough of a guarantee)."""
    if username == requesting_username:
        return "You can't remove your own account while logged in as it."
    users = _load_raw()
    remaining = [u for u in users if u["username"] != username]
    if len(remaining) == len(users):
        return f'No user named "{username}" was found.'
    if not any(_is_unrestricted_builder(u) for u in remaining):
        return "Refusing to remove the last remaining unrestricted builder account."
    _save_raw(remaining)
    return None


def set_role(username: str, role: str, requesting_username: str) -> str | None:
    """Returns an error message, or None on success."""
    if role not in ROLES:
        return f"Role must be one of {ROLES}."
    users = _load_raw()
    target = next((u for u in users if u["username"] == username), None)
    if target is None:
        return f'No user named "{username}" was found.'
    if username == requesting_username and role != "builder":
        return "You can't demote your own account while logged in as it."
    if _is_unrestricted_builder(target) and role != "builder":
        remaining = sum(
            1 for u in users if u["username"] != username and _is_unrestricted_builder(u)
        )
        if remaining == 0:
            return "Refusing to demote the last remaining unrestricted builder account."
    target["role"] = role
    _save_raw(users)
    return None


def set_company(username: str, company: str, requesting_username: str) -> str | None:
    """Returns an error message, or None on success. company="" means
    unrestricted."""
    company = company.strip()
    users = _load_raw()
    target = next((u for u in users if u["username"] == username), None)
    if target is None:
        return f'No user named "{username}" was found.'
    if username == requesting_username and company:
        return "You can't scope your own account while logged in as it."
    if _is_unrestricted_builder(target) and company:
        remaining = sum(
            1 for u in users if u["username"] != username and _is_unrestricted_builder(u)
        )
        if remaining == 0:
            return "Refusing to scope the last remaining unrestricted builder account."
    target["company"] = company
    _save_raw(users)
    return None
