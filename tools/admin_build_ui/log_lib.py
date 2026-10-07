"""Parses and lists uploaded session activity log files (see
lib/services/log_service.dart for the format this reads) for the Admin
Build UI's /logs browsing pages.

A log file's name is instance_username_sessionid_date_time_seq.log, but
both instance and username can themselves contain underscores (e.g.
instance "mycompany_test"), so the filename can't be split unambiguously by
position. Instead, the authoritative instance/username come from the
file's own first line - LogService.startSession always writes a
`SESSION` / {"event": "start", "instance": ..., "username": ...} line
before anything else, so every valid log file's first line has this in
unambiguous JSON.
"""

import json
from pathlib import Path

import build_lib

LOGS_DIR = Path(__file__).resolve().parent / "data" / "logs"


def safe_filename(raw: str) -> str:
    """Same reasoning as captured_files_receiver.py's safe_filename - never
    let a header value escape LOGS_DIR."""
    import os
    import re
    name = os.path.basename(raw.strip())
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return name or "upload.log"


def save_upload(filename: str, body: bytes) -> Path:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    dest = LOGS_DIR / safe_filename(filename)
    dest.write_bytes(body)
    return dest


def parse_log_file(path: Path) -> list:
    """Returns a list of {timestamp, category, details} dicts, one per
    line - a line that doesn't parse cleanly is kept as a raw/opaque row
    rather than dropped, so a corrupt line doesn't hide the rest."""
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        parts = line.split(" | ", 2)
        if len(parts) == 3:
            timestamp, category, raw_json = parts
            try:
                details = json.loads(raw_json)
            except ValueError:
                details = raw_json
            rows.append({"timestamp": timestamp, "category": category, "details": details})
        else:
            rows.append({"timestamp": "", "category": "?", "details": line})
    return rows


def _peek_session_info(path: Path) -> dict:
    """Reads just enough of the file to get the SESSION start line's
    instance/username/timestamp - avoids parsing the whole file (which may
    have thousands of lines) just to build the summary list."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            first_line = f.readline()
    except OSError:
        return {"instance": "unknown", "username": "unknown", "timestamp": ""}
    parts = first_line.split(" | ", 2)
    if len(parts) == 3 and parts[1] == "SESSION":
        try:
            details = json.loads(parts[2])
            return {
                "instance": details.get("instance", "unknown"),
                "username": details.get("username", "unknown"),
                "timestamp": parts[0],
            }
        except ValueError:
            pass
    return {"instance": "unknown", "username": "unknown", "timestamp": ""}


def list_log_files() -> list:
    """Newest first. Each entry: filename, instance, username, timestamp,
    date (YYYY-MM-DD, for the date filter), size_bytes."""
    if not LOGS_DIR.exists():
        return []
    entries = []
    for path in LOGS_DIR.glob("*.log"):
        info = _peek_session_info(path)
        timestamp = info["timestamp"] or ""
        entries.append({
            "filename": path.name,
            "instance": info["instance"],
            "username": info["username"],
            "timestamp": timestamp,
            "date": timestamp[:10] if timestamp else "",
            "size_bytes": path.stat().st_size,
        })
    entries.sort(key=lambda e: e["timestamp"], reverse=True)
    return entries


def customer_instances(customer: str) -> set:
    """Every environment name this customer's build history has ever used -
    lets the Logs page narrow the Instance dropdown once a Customer is
    picked. A log's `instance` field is the environment NAME (e.g.
    "mycompany_test"), matching Environment.name in build_lib/AppConfig, not
    the customer's own display name."""
    names = set()
    for record in build_lib.get_customer_history(customer):
        for env in record["environments"]:
            names.add(env["name"])
    return names


def filter_log_files(customer: str = "", instance: str = "", date: str = "") -> list:
    files = list_log_files()
    if customer:
        allowed = customer_instances(customer)
        files = [f for f in files if f["instance"] in allowed]
    if instance:
        files = [f for f in files if f["instance"] == instance]
    if date:
        files = [f for f in files if f["date"] == date]
    return files
