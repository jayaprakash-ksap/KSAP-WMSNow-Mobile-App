#!/usr/bin/env python3
"""Admin Build UI for WMSNow Redwood Mobile - a local web app that replaces
running tools/generate_customer_build.py by hand in a terminal.

Run from the project root:

    pip install -r tools/admin_build_ui/requirements.txt
    python tools/admin_build_ui/app.py

Then open http://localhost:5050 in a browser, log in with the
ADMIN_USERNAME/ADMIN_PASSWORD below, fill in the customer's environment(s),
pick which customizations and platform(s) to bake in, and Generate - it
shells out to `flutter build` exactly like the CLI script did (via
tools/build_lib.py, shared by both), just with a form instead of terminal
prompts.

Originally local-machine-only; as of the Distribution Links feature
(2026-09-28) this is meant to be hosted on a real server reachable by a
customer's IT and floor devices, specifically so /dl/<token> (a public,
no-login download link/QR code) can be scanned directly from an RF
handheld. Everything ELSE (login, build generation, history, logs, images,
user/company/instance management) still assumes a trusted operator, not a
public audience - ADMIN_USERNAME/ADMIN_PASSWORD and SECRET_KEY are still
test-grade secrets (same framing as TOKEN in
tools/captured_files_receiver.py) that must be changed for a real
deployment, and the admin-facing routes should sit behind HTTPS/a
reasonable network boundary even though /dl/<token> itself is intentionally
public.
"""

import base64
import io
import os
import sys
import threading
import time
import uuid
from functools import wraps
from pathlib import Path

import qrcode
from flask import (Flask, abort, jsonify, redirect, render_template, request,
                    send_file, session, url_for)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_lib import (  # noqa: E402
    FEATURE_FLAGS,
    BuildError,
    BuildRequest,
    Environment,
    find_record,
    get_customer_history,
    list_customers,
    run_build_request,
    validate_customer_name,
    validate_expiry_date,
)
import log_lib  # noqa: E402
import image_lib  # noqa: E402
import diff_lib  # noqa: E402
import notify_settings  # noqa: E402
import expiry_notify  # noqa: E402
import users  # noqa: E402
import companies  # noqa: E402
import instances  # noqa: E402
import distribution_links  # noqa: E402

# Seeded as the first "builder" account the first time this app runs (see
# users.seed_if_empty) - after that, users.json is the source of truth and
# these two constants are never read again. Manage accounts from the
# Users page once you've logged in, not by editing these.
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "change-me"
SECRET_KEY = "change-me-wmsnow-admin-build-ui-secret"
# Separate from ADMIN_USERNAME/PASSWORD - this gates /upload-log, which the
# APP itself calls unattended (no session login), same "shared secret for a
# trusted local-network tool" framing as every other relay's TOKEN in this
# project (e.g. tools/captured_files_receiver.py).
LOG_UPLOAD_TOKEN = "PfZwq8vuPdZWwSYh0M6G8Q"
# Gates /upload (captured photos/signatures) - same idea as
# LOG_UPLOAD_TOKEN, kept separate so the two can be rotated independently.
# This is now the recommended way to receive captures (2026-08-27) -
# tools/captured_files_receiver.py still works standalone too, same
# protocol, same captured_images/ folder, but running it separately is no
# longer necessary once this app is already running.
UPLOAD_TOKEN = "9Nn5cQvXqR8ZbFhT2mWpLk3s"

app = Flask(__name__)
app.secret_key = SECRET_KEY
users.seed_if_empty(ADMIN_USERNAME, ADMIN_PASSWORD)

# In-memory job tracking - fine for a single-admin local tool; nothing here
# needs to survive a restart of this script.
_jobs = {}
_jobs_lock = threading.Lock()


def login_required(view):
    """Any logged-in user, either role - use this for pages both a builder
    and a viewer should see (Logs, Images, History, Compare)."""
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


def builder_required(view):
    """Builder-role only - use this for anything that generates a build,
    downloads a build artifact, exposes an unmasked OAuth secret, or
    manages notification emails. A logged-in viewer hitting one of these
    gets a plain 403, not a redirect to login (they ARE logged in, they
    just can't do this)."""
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        if session.get("role") != "builder":
            return "Forbidden - your account does not have build access.", 403
        return view(*args, **kwargs)
    return wrapped


def unrestricted_builder_required(view):
    """Builder role AND no company restriction - use this for /users*
    only. A company-scoped builder must not be able to create accounts
    for other companies (or unscope their own), so managing users is a
    step above ordinary build access, not just "any builder"."""
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        if session.get("role") != "builder" or session.get("company"):
            return "Forbidden - only an unrestricted builder account can manage users.", 403
        return view(*args, **kwargs)
    return wrapped


def _customer_allowed(customer: str) -> bool:
    """True if the logged-in user's company scope permits this customer -
    always True for an unrestricted account (session["company"] empty)."""
    scope = session.get("company")
    return not scope or scope == customer


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        user = users.verify_login(
            request.form.get("username", ""), request.form.get("password", "")
        )
        if user is not None:
            session["logged_in"] = True
            session["username"] = user["username"]
            session["role"] = user["role"]
            session["company"] = user["company"]
            return redirect(url_for("home"))
        error = "Invalid username or password."
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/home")
@login_required
def home():
    return render_template("home.html", active="home")


@app.route("/")
@login_required
def index():
    # A viewer has no use for the build form (every action on it is
    # builder-only) - send them straight to something they can actually
    # use, rather than a page that's mostly disabled controls.
    if session.get("role") != "builder":
        return redirect(url_for("history"))
    # Pre-fills the Log Server Token field - the admin is already talking
    # to this exact server, so defaulting the token it expects (and the URL,
    # via JS reading window.location.origin) saves retyping it per build.
    return render_template(
        "build.html", feature_flags=FEATURE_FLAGS, log_upload_token=LOG_UPLOAD_TOKEN,
        locked_company=session.get("company") or None,
        company_list=companies.list_companies(),
        active="build",
    )


FEATURE_TITLES = {f["key"]: f["title"] for f in FEATURE_FLAGS}


def _mask_secret(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 4:
        return "*" * len(value)
    return value[:2] + "*" * (len(value) - 4) + value[-2:]


def _record_summary(record: dict) -> dict:
    """Adds display-friendly fields to a raw history record - feature
    titles, a masked secret for display, and live file-existence checks
    (the customer_builds/ folder a record points to may have been moved or
    cleaned up since it was built)."""
    apk_path = record.get("apk_path")
    windows_path = record.get("windows_path")
    return {
        **record,
        "feature_titles": [FEATURE_TITLES.get(k, k) for k in record["feature_keys"]],
        "environments_display": [
            {**e, "client_secret": _mask_secret(e["client_secret"])}
            for e in record["environments"]
        ],
        "apk_exists": bool(apk_path) and Path(apk_path).exists(),
        "windows_exists": bool(windows_path) and Path(windows_path).exists(),
    }


@app.route("/history")
@login_required
def history():
    scope = session.get("company")
    customers = [scope] if scope else list_customers()
    return render_template("history.html", customers=customers, active="history")


@app.route("/api/history/<customer>")
@login_required
def api_history(customer):
    if not _customer_allowed(customer):
        return jsonify({"error": "Forbidden - not your company."}), 403
    records = get_customer_history(customer)
    return jsonify([_record_summary(r) for r in records])


@app.route("/api/history-record/<record_id>")
@builder_required
def api_history_record(record_id):
    """Used by build.html's "Rebuild" flow to pre-fill the form - the FULL
    (unmasked) secret is returned here, unlike /api/history, since this is
    feeding the same form field an admin would otherwise type the secret
    into by hand, not a read-only display. Builder-only for exactly that
    reason - a viewer must never receive an unmasked OAuth client secret."""
    customer, record = find_record(record_id)
    if record is None:
        return jsonify({"error": "Not found"}), 404
    if not _customer_allowed(customer):
        return jsonify({"error": "Forbidden - not your company."}), 403
    return jsonify({"customer": customer, **record})


@app.route("/history-download/<record_id>/<which>")
@builder_required
def history_download(record_id, which):
    customer, record = find_record(record_id)
    if record is None:
        return "Not found", 404
    if not _customer_allowed(customer):
        return "Forbidden - not your company.", 403
    path = record.get("apk_path") if which == "apk" else record.get("windows_path")
    if not path or not Path(path).exists():
        return "File not available (it may have been moved or deleted since this build)", 404
    return send_file(path, as_attachment=True)


def _diff_environments(envs_a, envs_b):
    by_name_a = {e["name"]: e for e in envs_a}
    by_name_b = {e["name"]: e for e in envs_b}
    rows = []
    for name in sorted(set(by_name_a) | set(by_name_b)):
        ea, eb = by_name_a.get(name), by_name_b.get(name)
        rows.append({
            "name": name,
            "in_a": ea is not None,
            "in_b": eb is not None,
            "domain_a": ea["domain"] if ea else None,
            "domain_b": eb["domain"] if eb else None,
            "domain_differs": bool(ea and eb and ea["domain"] != eb["domain"]),
            "instance_a": ea["instance"] if ea else None,
            "instance_b": eb["instance"] if eb else None,
            "instance_differs": bool(ea and eb and ea["instance"] != eb["instance"]),
            "client_id_a": ea["client_id"] if ea else None,
            "client_id_b": eb["client_id"] if eb else None,
            "client_id_differs": bool(ea and eb and ea["client_id"] != eb["client_id"]),
            # Compared on the real values (never displayed) so the diff
            # can still flag a rotated secret without showing either one.
            "secret_differs": bool(ea and eb and ea["client_secret"] != eb["client_secret"]),
        })
    return rows


def _diff_features(record_a, record_b):
    keys_a, keys_b = set(record_a["feature_keys"]), set(record_b["feature_keys"])
    rows = []
    for f in FEATURE_FLAGS:
        in_a, in_b = f["key"] in keys_a, f["key"] in keys_b
        rows.append({"title": f["title"], "in_a": in_a, "in_b": in_b, "differs": in_a != in_b})
    return rows


@app.route("/compare")
@login_required
def compare():
    customer_a, record_a = find_record(request.args.get("a", ""))
    customer_b, record_b = find_record(request.args.get("b", ""))
    if record_a is None or record_b is None:
        return "One or both builds could not be found.", 404
    if not _customer_allowed(customer_a) or not _customer_allowed(customer_b):
        return "Forbidden - not your company.", 403
    return render_template(
        "compare.html",
        a={"customer": customer_a, **_record_summary(record_a)},
        b={"customer": customer_b, **_record_summary(record_b)},
        env_rows=_diff_environments(record_a["environments"], record_b["environments"]),
        feature_rows=_diff_features(record_a, record_b),
        code_diff=diff_lib.compare_snapshots(record_a["id"], record_b["id"]),
        active="history",
    )


def _run_job(job_id: str, req: BuildRequest) -> None:
    job = _jobs[job_id]
    try:
        result = run_build_request(req)
        with _jobs_lock:
            job["ok"] = bool(result["apk_path"] or result["windows_path"])
            job["apk_path"] = str(result["apk_path"]) if result["apk_path"] else None
            job["windows_path"] = str(result["windows_path"]) if result["windows_path"] else None
        # Auto-advances any Distribution Link for this customer whose
        # instance filter matches - a no-op if none exist, or if the
        # matching one(s) were explicitly rolled back (auto_advance=False).
        if result.get("record_id"):
            distribution_links.on_new_build(
                req.customer, result["record_id"], [e.name for e in req.environments]
            )
    except BuildError as e:
        with _jobs_lock:
            job["ok"] = False
            req.log.append(f"ERROR: {e}")
    except Exception as e:  # noqa: BLE001 - surface anything unexpected to the UI
        with _jobs_lock:
            job["ok"] = False
            req.log.append(f"Unexpected error: {e}")
    finally:
        with _jobs_lock:
            job["done"] = True


# ---- License expiry notification settings (2026-09-18) ----
#
# The one place "days remaining" is ever surfaced at all - never shown to
# any device/end user, only emailed to whoever is on this list. See
# expiry_notify.py / notify_settings.py.


@app.route("/api/notify-emails", methods=["GET"])
@builder_required
def api_notify_emails():
    return jsonify(notify_settings.load_emails())


@app.route("/api/notify-emails/add", methods=["POST"])
@builder_required
def api_notify_emails_add():
    email = (request.get_json(silent=True) or {}).get("email", "")
    return jsonify(notify_settings.add_email(email))


@app.route("/api/notify-emails/remove", methods=["POST"])
@builder_required
def api_notify_emails_remove():
    email = (request.get_json(silent=True) or {}).get("email", "")
    return jsonify(notify_settings.remove_email(email))


# ---- User accounts (2026-09-25) ----
#
# unrestricted_builder_required, not builder_required - a company-scoped
# builder managing who else can log in (or scoping/unscoping accounts,
# including their own) would defeat the point of company scoping.


@app.route("/users")
@unrestricted_builder_required
def users_page():
    # The Companies master list (2026-09-25), not build_lib.list_customers()
    # - a user's Company scope should only ever be one of the clean,
    # explicitly-defined names, never a free-typed historical customer
    # string from before Companies existed.
    return render_template(
        "users.html", account_list=users.list_users(), roles=users.ROLES,
        company_list=companies.list_companies(), active="users",
    )


@app.route("/api/users/add", methods=["POST"])
@unrestricted_builder_required
def api_users_add():
    data = request.get_json(silent=True) or {}
    company = data.get("company", "").strip()
    if company and company not in companies.list_companies():
        return jsonify({"error": f'"{company}" is not a known company - pick one from the list.'}), 400
    error = users.add_user(
        data.get("username", ""), data.get("password", ""), data.get("role", ""), company,
    )
    if error:
        return jsonify({"error": error}), 400
    return jsonify(users.list_users())


@app.route("/api/users/remove", methods=["POST"])
@unrestricted_builder_required
def api_users_remove():
    username = (request.get_json(silent=True) or {}).get("username", "")
    error = users.remove_user(username, session.get("username", ""))
    if error:
        return jsonify({"error": error}), 400
    return jsonify(users.list_users())


@app.route("/api/users/set-role", methods=["POST"])
@unrestricted_builder_required
def api_users_set_role():
    data = request.get_json(silent=True) or {}
    error = users.set_role(
        data.get("username", ""), data.get("role", ""), session.get("username", "")
    )
    if error:
        return jsonify({"error": error}), 400
    return jsonify(users.list_users())


@app.route("/api/users/set-company", methods=["POST"])
@unrestricted_builder_required
def api_users_set_company():
    data = request.get_json(silent=True) or {}
    company = data.get("company", "").strip()
    if company and company not in companies.list_companies():
        return jsonify({"error": f'"{company}" is not a known company - pick one from the list.'}), 400
    error = users.set_company(
        data.get("username", ""), company, session.get("username", "")
    )
    if error:
        return jsonify({"error": error}), 400
    return jsonify(users.list_users())


# ---- Companies and Instances master data (2026-09-25) ----
#
# unrestricted_builder_required, same reasoning as /users* - a company-
# scoped builder must not be able to create a company/instance and hand
# themselves (or someone else) access to it. The build form's OWN instance
# lookup (api_instance_defs_for_build below) is different: any logged-in
# builder can call it, narrowed to companies they're actually allowed to
# build for - that's how a scoped builder picks their own instances.


@app.route("/companies")
@unrestricted_builder_required
def companies_page():
    return render_template("companies.html", company_list=companies.list_companies(), active="companies")


@app.route("/api/companies/add", methods=["POST"])
@unrestricted_builder_required
def api_companies_add():
    name = (request.get_json(silent=True) or {}).get("name", "")
    error = companies.add_company(name)
    if error:
        return jsonify({"error": error}), 400
    return jsonify(companies.list_companies())


@app.route("/api/companies/remove", methods=["POST"])
@unrestricted_builder_required
def api_companies_remove():
    name = (request.get_json(silent=True) or {}).get("name", "")
    dependents = [i["name"] for i in instances.list_instances(name)]
    if dependents:
        return jsonify({"error": (
            f'"{name}" still has instance(s) defined ({", ".join(dependents)}) - '
            "remove those from the Instances page first."
        )}), 400
    scoped_users = [u["username"] for u in users.list_users() if u["company"] == name]
    if scoped_users:
        return jsonify({"error": (
            f'"{name}" still has user(s) scoped to it ({", ".join(scoped_users)}) - '
            "rescope or remove those from the Users page first."
        )}), 400
    error = companies.remove_company(name)
    if error:
        return jsonify({"error": error}), 400
    return jsonify(companies.list_companies())


def _mask_instance(i: dict) -> dict:
    return {**i, "client_secret": _mask_secret(i["client_secret"])}


@app.route("/instances")
@unrestricted_builder_required
def instances_page():
    return render_template(
        "instances.html",
        instance_list=[_mask_instance(i) for i in instances.list_instances()],
        company_list=companies.list_companies(),
        active="instances",
    )


@app.route("/api/instance-defs/add", methods=["POST"])
@unrestricted_builder_required
def api_instance_defs_add():
    data = request.get_json(silent=True) or {}
    if data.get("company", "") not in companies.list_companies():
        return jsonify({"error": "Pick a company from the list."}), 400
    error = instances.add_instance(
        data.get("name", ""), data.get("company", ""), data.get("domain", ""),
        data.get("instance", ""), data.get("client_id", ""), data.get("client_secret", ""),
    )
    if error:
        return jsonify({"error": error}), 400
    return jsonify([_mask_instance(i) for i in instances.list_instances()])


@app.route("/api/instance-defs/remove", methods=["POST"])
@unrestricted_builder_required
def api_instance_defs_remove():
    name = (request.get_json(silent=True) or {}).get("name", "")
    error = instances.remove_instance(name)
    if error:
        return jsonify({"error": error}), 400
    return jsonify([_mask_instance(i) for i in instances.list_instances()])


@app.route("/api/instance-defs")
@builder_required
def api_instance_defs_for_build():
    """Feeds the build form's instance checklist once a Company is picked -
    any builder can call this (not unrestricted-only, unlike the routes
    above), but only for a company they're actually allowed to build for."""
    company = request.args.get("company", "")
    if not _customer_allowed(company):
        return jsonify({"error": "Forbidden - not your company."}), 403
    return jsonify([
        {"name": i["name"], "domain": i["domain"], "instance": i["instance"]}
        for i in instances.list_instances(company)
    ])


# ---- Distribution Links (2026-09-28) ----
#
# /distribution-links itself is login_required (not unrestricted-only) -
# any logged-in account can VIEW the links for their own company (a
# customer's viewer account is exactly who this page is for), scoped
# automatically by session["company"]. Only an unrestricted builder sees
# every company's links and the create/rollback/revoke controls - the
# template hides those for everyone else, and the mutating API routes
# below are unrestricted_builder_required regardless of what the template
# shows, so this isn't just a UI-level restriction.
#
# /dl/<token> and its download route are the one deliberately PUBLIC
# exception in this whole app - no @login_required at all, since a floor
# handheld scanning a QR code has no admin session and shouldn't need one.
# The token itself (not knowledge of the customer/instance names) is what
# gates access - see distribution_links.py's module doc comment.


def _link_with_timestamp(link: dict) -> dict:
    """Adds the active build's own timestamp for display - the link record
    itself only stores the id, same reasoning as _record_summary adding
    display-only fields elsewhere in this file."""
    _, record = find_record(link["active_record_id"])
    return {**link, "active_record_timestamp": record["timestamp"] if record else None}


def _visible_links():
    scope = session.get("company")
    raw = distribution_links.list_links(scope) if scope else distribution_links.list_links()
    return [_link_with_timestamp(link) for link in raw]


@app.route("/distribution-links")
@login_required
def distribution_links_page():
    return render_template(
        "distribution_links.html",
        links=_visible_links(),
        company_list=companies.list_companies(),
        is_unrestricted_builder=session.get("role") == "builder" and not session.get("company"),
        dl_base=request.host_url.rstrip("/"),
        active="distribution",
    )


@app.route("/api/distribution-links/create", methods=["POST"])
@unrestricted_builder_required
def api_distribution_links_create():
    data = request.get_json(silent=True) or {}
    link, error = distribution_links.create_link(
        data.get("customer", ""), data.get("instance", ""), session.get("username", "")
    )
    if error:
        return jsonify({"error": error}), 400
    return jsonify(link)


@app.route("/api/distribution-links/revoke", methods=["POST"])
@unrestricted_builder_required
def api_distribution_links_revoke():
    token = (request.get_json(silent=True) or {}).get("token", "")
    error = distribution_links.revoke_link(token)
    if error:
        return jsonify({"error": error}), 400
    return jsonify({"ok": True})


@app.route("/api/distribution-links/set-active", methods=["POST"])
@unrestricted_builder_required
def api_distribution_links_set_active():
    data = request.get_json(silent=True) or {}
    error = distribution_links.set_active_build(data.get("token", ""), data.get("record_id", ""))
    if error:
        return jsonify({"error": error}), 400
    return jsonify(distribution_links.find_link(data.get("token", "")))


@app.route("/api/distribution-links/resume-auto", methods=["POST"])
@unrestricted_builder_required
def api_distribution_links_resume_auto():
    token = (request.get_json(silent=True) or {}).get("token", "")
    error = distribution_links.resume_auto_advance(token)
    if error:
        return jsonify({"error": error}), 400
    return jsonify(distribution_links.find_link(token))


@app.route("/api/distribution-links/<token>/history")
@unrestricted_builder_required
def api_distribution_links_history(token):
    """Feeds the "roll back to..." picker - every build for this link's
    company (optionally narrowed to its instance), newest first, so an
    admin can pick which one to pin to."""
    link = distribution_links.find_link(token)
    if link is None:
        return jsonify({"error": "Link not found."}), 404
    records = get_customer_history(link["customer"])
    if link["instance"]:
        records = [r for r in records if any(e["name"] == link["instance"] for e in r["environments"])]
    return jsonify([{"id": r["id"], "timestamp": r["timestamp"]} for r in records])


@app.route("/distribution-links/qr/<token>.png")
@login_required
def distribution_link_qr(token):
    link = distribution_links.find_link(token)
    if link is None:
        abort(404)
    scope = session.get("company")
    if scope and link["customer"] != scope:
        abort(403)
    url = f"{request.host_url.rstrip('/')}{url_for('distribution_link_landing', token=token)}"
    img = qrcode.make(url)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@app.route("/dl/<token>")
def distribution_link_landing(token):
    link = distribution_links.find_link(token)
    if link is None:
        return render_template("dl_landing.html", link=None, record=None), 404
    _, record = find_record(link["active_record_id"])
    return render_template("dl_landing.html", link=link, record=record)


@app.route("/dl/<token>/download/<which>")
def distribution_link_download(token, which):
    link = distribution_links.find_link(token)
    if link is None:
        return "Link not found.", 404
    _, record = find_record(link["active_record_id"])
    if record is None:
        return "No build available for this link.", 404
    path = record.get("apk_path") if which == "apk" else record.get("windows_path")
    if not path or not Path(path).exists():
        return "File not available (it may have been moved or deleted since this build).", 404
    return send_file(path, as_attachment=True)


@app.route("/build", methods=["POST"])
@builder_required
def start_build():
    form = request.form
    try:
        customer = validate_customer_name(form.get("customer", ""))
        if customer not in companies.list_companies():
            raise BuildError(f'"{customer}" is not a known company - pick one from the list.')
        if not _customer_allowed(customer):
            raise BuildError(
                f'Your account is restricted to "{session.get("company")}" - '
                f'you can\'t build for "{customer}".'
            )

        # Environments now come from previously-defined Instance records
        # (2026-09-25), not free-typed per build - see instances.py. Each
        # selected name is re-checked against this SAME company (not just
        # "does an instance with this name exist anywhere") so a scoped
        # builder can't smuggle in another company's instance by name.
        environments = []
        for name in form.getlist("instance_names"):
            inst = instances.find_instance(name)
            if inst is None or inst["company"] != customer:
                raise BuildError(f'"{name}" is not a defined instance for "{customer}".')
            environments.append(Environment(
                name=inst["name"], domain=inst["domain"], instance=inst["instance"],
                client_id=inst["client_id"], client_secret=inst["client_secret"],
            ))
        if not environments:
            raise BuildError(
                "Pick at least one instance. If none exist yet for this company, "
                "add one on the Instances page first."
            )

        feature_keys = {f["key"] for f in FEATURE_FLAGS if form.get(f"feature-{f['key']}") == "on"}
        build_android = form.get("build_android") == "on"
        build_windows = form.get("build_windows") == "on"
        # Both optional - a blank URL means that build's devices simply
        # won't upload logs (see BuildRequest.log_server_url's doc comment).
        log_server_url = form.get("log_server_url", "").strip()
        log_server_token = form.get("log_server_token", "").strip()
        expiry_date = validate_expiry_date(form.get("expiry_date", ""))
    except BuildError as e:
        return jsonify({"error": str(e)}), 400

    # Screen/print matching (truck_temp_page_title_match and friends) isn't
    # a form field - run_build_request() fills those in automatically per
    # customer, see build_lib.CUSTOMER_SCREEN_OVERRIDES.
    req = BuildRequest(
        customer=customer,
        environments=environments,
        feature_keys=feature_keys,
        build_android=build_android,
        build_windows=build_windows,
        log_server_url=log_server_url,
        log_server_token=log_server_token,
        expiry_date=expiry_date,
    )
    job_id = uuid.uuid4().hex
    with _jobs_lock:
        _jobs[job_id] = {"done": False, "ok": None, "apk_path": None, "windows_path": None, "req": req}

    thread = threading.Thread(target=_run_job, args=(job_id, req), daemon=True)
    thread.start()
    return jsonify({"job_id": job_id})


@app.route("/status/<job_id>")
@builder_required
def job_status(job_id):
    job = _jobs.get(job_id)
    if job is None:
        return jsonify({"error": "Unknown job"}), 404
    return jsonify({
        "done": job["done"],
        "ok": job["ok"],
        "log_lines": list(job["req"].log),
        "apk_ready": job["apk_path"] is not None,
        "windows_ready": job["windows_path"] is not None,
    })


@app.route("/download/<job_id>/<which>")
@builder_required
def download(job_id, which):
    job = _jobs.get(job_id)
    if job is None:
        return "Unknown job", 404
    path = job.get("apk_path") if which == "apk" else job.get("windows_path")
    if not path:
        return "File not available", 404
    return send_file(path, as_attachment=True)


# ---- Session log upload + browsing (2026-08-27) ----
#
# /upload-log is called by the app itself (LogUploadService), unattended -
# gated by LOG_UPLOAD_TOKEN, NOT the admin session login used everywhere
# else. Every other /logs* route below is a normal admin-facing page.


@app.route("/upload-log", methods=["POST"])
def upload_log():
    if request.headers.get("X-Auth-Token") != LOG_UPLOAD_TOKEN:
        return "bad token", 401
    filename = request.headers.get("X-Filename")
    if not filename:
        return "missing X-Filename header", 400
    body = request.get_data()
    if not body:
        return "empty body", 400
    dest = log_lib.save_upload(filename, body)
    print(f"Received log {dest.name} ({len(body)} bytes)")
    return "ok"


@app.route("/logs")
@login_required
def logs():
    scope = session.get("company")
    customers = [scope] if scope else list_customers()
    return render_template("logs.html", customers=customers, active="logs")


@app.route("/api/log-files")
@login_required
def api_log_files():
    # A scoped account's company OVERRIDES whatever "customer" the client
    # sent (rather than just validating it) - a log file's own filename/
    # instance is the only thing gating what it can see, so there must be
    # no way to reach a wider set via query-string tampering.
    scope = session.get("company")
    customer = scope if scope else request.args.get("customer", "")
    files = log_lib.filter_log_files(
        customer=customer,
        instance=request.args.get("instance", ""),
        date=request.args.get("date", ""),
    )
    return jsonify(files)


@app.route("/api/instances")
@login_required
def api_instances():
    """All distinct instance names seen across uploaded logs, optionally
    narrowed to one customer's known environments - feeds the Instance
    dropdown on the Logs page."""
    scope = session.get("company")
    customer = scope if scope else request.args.get("customer", "")
    all_instances = sorted({f["instance"] for f in log_lib.list_log_files()})
    if not customer:
        return jsonify(all_instances)
    allowed = log_lib.customer_instances(customer)
    return jsonify(sorted(i for i in all_instances if i in allowed))


@app.route("/logs/<filename>")
@login_required
def log_detail(filename):
    path = log_lib.LOGS_DIR / log_lib.safe_filename(filename)
    if not path.exists():
        return "Log file not found", 404
    scope = session.get("company")
    if scope:
        # This one file's own instance (from its SESSION line) must belong
        # to the scoped company's known environments - list_log_files()
        # already resolves that per file, cheaper to look it up there than
        # duplicate log_lib's private SESSION-line parsing here.
        entry = next(
            (f for f in log_lib.list_log_files() if f["filename"] == path.name), None
        )
        if entry is None or entry["instance"] not in log_lib.customer_instances(scope):
            return "Forbidden - not your company.", 403
    rows = log_lib.parse_log_file(path)
    return render_template("log_detail.html", filename=path.name, rows=rows, active="logs")


# ---- Captured photos/signatures (2026-08-27) ----
#
# /upload is called by the app itself (UploadService), unattended - gated
# by UPLOAD_TOKEN, same pattern as /upload-log above. Every other /images*
# route is a normal admin-facing page. Same protocol
# tools/captured_files_receiver.py has always used, same destination
# folder (captured_images/ at the project root) - that script still works
# standalone too, but is no longer necessary once this app is running.


@app.route("/upload", methods=["POST"])
def upload_capture():
    if request.headers.get("X-Auth-Token") != UPLOAD_TOKEN:
        return "bad token", 401
    filename = request.headers.get("X-Filename")
    if not filename:
        return "missing X-Filename header", 400
    body = request.get_data()
    if not body:
        return "empty body", 400
    dest = image_lib.save_upload(filename, body)
    print(f"Received capture {dest.name} ({len(body)} bytes)")
    return "ok"


def unrestricted_required(view):
    """Company-unrestricted accounts only, either role - see the doc
    comment on image_lib.py's module docstring: captured photos/
    signatures carry no customer/company identifier in their filename
    (unlike session logs, which do), so there is currently no reliable way
    to show a company-scoped account only ITS images. Rather than leave
    that gap open (which would defeat the whole point of company scoping)
    or guess at a fragile heuristic, this hides Images entirely from
    scoped accounts until the upload protocol is changed to tag captures
    with a company - see the note left in image_lib.py."""
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        if session.get("company"):
            return ("Forbidden - captured images aren't tagged with a company yet, "
                    "so scoped accounts can't be shown them safely. Ask an "
                    "unrestricted account to check Images for now."), 403
        return view(*args, **kwargs)
    return wrapped


@app.route("/images")
@unrestricted_required
def images():
    return render_template("images.html", active="images")


@app.route("/api/images")
@unrestricted_required
def api_images():
    return jsonify(image_lib.filter_images(
        image_type=request.args.get("type", ""),
        date=request.args.get("date", ""),
    ))


@app.route("/captured_images/<filename>")
@unrestricted_required
def serve_image(filename):
    path = image_lib.IMAGES_DIR / image_lib.safe_filename(filename)
    if not path.exists():
        return "Not found", 404
    return send_file(path)


@app.route("/images/download/<filename>")
@unrestricted_required
def download_image(filename):
    path = image_lib.IMAGES_DIR / image_lib.safe_filename(filename)
    if not path.exists():
        return "Not found", 404
    return send_file(path, as_attachment=True)


def _expiry_check_loop() -> None:
    """Runs expiry_notify.check_and_notify() once at startup, then every
    hour for as long as this process is alive - see expiry_notify.py's doc
    comment on why hourly (not daily) and why this must never crash the
    whole app if a check fails."""
    while True:
        try:
            expiry_notify.check_and_notify()
        except Exception as e:  # noqa: BLE001
            print(f"expiry_notify background check failed: {e}", file=sys.stderr)
        time.sleep(3600)


if __name__ == "__main__":
    if ADMIN_PASSWORD == "change-me":
        print("WARNING: using the default ADMIN_PASSWORD - edit app.py before "
              "relying on this beyond local testing.", file=sys.stderr)
    if LOG_UPLOAD_TOKEN == "PfZwq8vuPdZWwSYh0M6G8Q":
        print("NOTE: LOG_UPLOAD_TOKEN is the shared placeholder token - fine "
              "for local testing, change it before relying on this beyond "
              "that.", file=sys.stderr)
    # Started once, not once per Werkzeug-reloader restart - debug=True
    # spawns a watcher process AND a worker process, and WERKZEUG_RUN_MAIN
    # is only set in the actual worker; without this guard the check (and
    # any email it sends) would fire twice on every reload.
    if not app.debug or os.environ.get("WERKZEUG_RUN_MAIN") == "true":
        threading.Thread(target=_expiry_check_loop, daemon=True).start()
    # 0.0.0.0, not 127.0.0.1 (2026-08-27) - /upload-log needs to accept
    # connections from OTHER devices on the network (phones/tablets running
    # the app), not just this machine. The admin-facing pages are still
    # protected by ADMIN_USERNAME/PASSWORD - same "trusted local network,
    # not the public internet" trust model as every other relay script in
    # this project.
    print("Find this machine's LAN IP with `ipconfig` and point each "
          "device's Log Server setting at http://<that-ip>:5050")
    app.run(host="0.0.0.0", port=5050, debug=True)
