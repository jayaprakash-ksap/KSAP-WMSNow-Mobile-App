"""Shared build logic for generating customer-locked release builds of
WMSNow Redwood Mobile - imported by both tools/generate_customer_build.py
(CLI) and tools/admin_build_ui/app.py (the Admin web UI). Kept in exactly
one place so the two entry points can never drift apart.

Builds bake in, via --dart-define, both the customer's WMS environment(s)
(see AppConfig.isLocked in lib/config/app_config.dart) and now also which
client-side customizations are active (see AppConfig's
WMSNOW_LOCKED_FEATURE_FLAGS handling) - decided once by whoever runs a
build, not left for the customer's operator to toggle afterward.
"""

import json
import re
import shutil
import subprocess
import sys
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "customer_builds"

# Build history - one JSON file recording every successful build (customer,
# environments incl. OAuth secrets, which customizations/platforms were
# picked, and where the output landed), so a later build for the same
# customer doesn't need those fields retyped, and so past builds can be
# reviewed/compared (see tools/admin_build_ui/app.py's /history routes).
# Gitignored the same way customer_builds/ is - live OAuth secrets are
# already baked into every build's binary, so keeping the same secrets in
# this local-only JSON file doesn't introduce a new exposure.
HISTORY_PATH = PROJECT_ROOT / "tools" / "admin_build_ui" / "data" / "history.json"

# Source snapshot for the Compare page's code-diff (2026-09-11) - a plain
# copy of lib/ (the Flutter app source) taken at build time, one per build
# record, so two builds can later be diffed even though the working tree
# isn't committed at build time. No git involved on purpose - the admin
# using this tool doesn't need to reason about branches or commits, just
# "pick two builds, see what changed". Gitignored the same way
# HISTORY_PATH's directory already is.
SNAPSHOTS_DIR = PROJECT_ROOT / "tools" / "admin_build_ui" / "data" / "snapshots"

MANIFEST_PATH = PROJECT_ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
MAIN_CPP_PATH = PROJECT_ROOT / "windows" / "runner" / "main.cpp"
RUNNER_RC_PATH = PROJECT_ROOT / "windows" / "runner" / "Runner.rc"

# `#` separates fields within one environment entry, `,` separates entries -
# see AppConfig's doc comment for why not `;` or `|` (both get mangled by
# Windows' cmd.exe when flutter, a .bat file, forwards the argument).
RESERVED_CHARS = "#,"
# Customer name gets embedded directly into XML (AndroidManifest.xml) and
# C++ string literals (main.cpp/Runner.rc) - restricted to a safe charset
# up front rather than trying to escape it correctly for three different
# file formats at once.
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9 _-]+$")

# The client-side customizations this app currently has, in the same
# order/wording as their SwitchListTile in FeatureSettingsScreen
# (lib/main.dart) - `key` is the short token used in the
# WMSNOW_LOCKED_FEATURE_FLAGS dart-define value (see AppConfig's
# _parseLockedFeatureFlags). Keep this list's title/description text in
# sync with main.dart by hand if either changes - there's no automated
# link between the Dart and Python copies.
FEATURE_FLAGS = [
    {
        "key": "pod",
        "title": "POD (Proof of Delivery)",
        "description": "Adds a Proof of Delivery step to the main menu for capturing a "
                        "signature and delivery photos.",
    },
    {
        "key": "truckTemp",
        "title": "Truck Temp",
        "description": "Requires a truck temperature reading during receiving, before "
                        "putaway can continue.",
    },
    {
        "key": "woodenPalletTask",
        "title": "Wooden Pallet Task",
        "description": "Lets the operator scan a trailer number to automatically look up "
                        "its load, order, and task list before starting a Wooden Pallet Task.",
    },
    {
        "key": "mixAreaTask",
        "title": "Mix Area Task",
        "description": "Filters the Mix Area task list down to only the tasks for a "
                        "scanned trailer.",
    },
    {
        "key": "fullPalletTask",
        "title": "Full Pallet Task",
        "description": "Adds trailer lookup, a vehicle eligibility check, and a guided "
                        "pick-by-SKU/Pallet/LPN flow to the Full Pallet Task screen.",
    },
    {
        "key": "serialReceiving",
        "title": "Serial Receiving",
        "description": "Adds a serial-driven receiving flow to the main menu: scan "
                        "expected serials, confirm a manual putaway location per LPN, "
                        "then Sync the receipt and putaway to WMS.",
    },
    {
        "key": "pickAllocateSerial",
        "title": "Pick And Allocate - Serial",
        "description": "On the standard Pick And Allocate RF screen, adds a Serial "
                        "Nbr field: scanning a serial looks up its inventory and "
                        "pre-fills the Locn, IBLPN, Qty and Serial fields on the "
                        "following screens.",
    },
    {
        "key": "combinedReceiving",
        "title": "Receiving Serial/Non Serial",
        "description": "Adds a combined receiving screen with a Serial / Non Serial "
                        "toggle: serial-scan receiving, or shipment-line receiving "
                        "with an entered quantity per LPN. Manual putaway then Sync "
                        "to WMS, same as Serial Receiving.",
    },
    {
        "key": "multiFieldBarcodeGs1",
        "title": "Multi Field Barcode - GS1",
        "description": "On a standard receiving screen: splits a combined LPN+Item "
                        "GS1 barcode to match WMS's Multi Field Barcode config, and "
                        "extracts Qty/Expiry Date from a barcode that combines them "
                        "with GTIN/Variant.",
    },
]

# ---- Per-customer screen/print matching overrides (2026-09-28) ----
#
# A handful of customizations need to match text that lives inside one
# specific customer's own Oracle WMS instance - a real screen/transaction
# name, or a Label Designer template/printer name. That's decided once, at
# development time, when a customization is actually scoped to a customer -
# not something every future build needs someone to retype in a form, and
# not something that should live in lib/ (the Dart source snapshotted for
# the Compare page's code-diff - see SNAPSHOTS_DIR above) since that would
# put one customer's real screen naming in front of anyone diffing a
# DIFFERENT customer's build. Living here instead (server-side Python, never
# shipped to any device) keeps it out of that diff entirely, while still
# getting baked into the right customer's build via the same --dart-define
# mechanism as everything else (see _extra_defines below).
#
# Key by the exact `customer` string used everywhere else in this file
# (the Company name, e.g. from companies.json). Each entry is commented
# with the Oracle RF module name - the stable, cross-customer identifier -
# it corresponds to, since the same module can surface under a different
# screen name per customer, or even more than one screen name for the same
# customer (a customer's own menu can label the same underlying module
# differently in two different places). Extend this dict - don't touch
# lib/ - when asked to point an existing customization at a new
# module/screen/field, whether for this customer or a new one.
#
# Value keys here match BuildRequest's own field names 1:1 (see below) -
# `multi_field_barcode_gs1_page_title_match` accepts a comma-separated list
# (AppConfig.multiFieldBarcodeGs1PageTitleMatches on the Dart side) for
# exactly the "same module, more than one screen name" case.
CUSTOMER_SCREEN_OVERRIDES = {
    "CCI": {
        # Module: "RF-Text: Recv {lpn} Shipment" - screen name "MARS
        # Receive SKUs - FG" (2026-09-27). Feeds the LPN ]C1/]C2 + "00"
        # padding and the Qty/Expiry barcode-#1 extraction - see
        # AppConfig's "Multi Field Barcode - GS1 enhancement" section in
        # lib/config/app_config.dart for what this value gates.
        "multi_field_barcode_gs1_page_title_match": "mars receive skus",
        # Truck Temp's real transaction (2026-07-10) - same screen as
        # above, matched on the fuller title since Truck Temp's injection
        # rule was deliberately scoped tighter (see AppConfig's
        # truckTempPageTitleMatch doc comment).
        "truck_temp_page_title_match": "mars receive skus - fg",
        # Mix Area Task's print/label/shipping call (2026-08-21) - this
        # customer's own Label Designer template + printer.
        "mix_area_label_designer_code": "CCIJO-shipping_label_MIX5",
        "mix_area_printer_name": "KSAPJP",
    },
}


@dataclass
class Environment:
    name: str
    domain: str
    instance: str
    client_id: str
    client_secret: str

    def to_define_entry(self) -> str:
        return f"{self.name}#{self.domain}#{self.instance}#{self.client_id}#{self.client_secret}"


@dataclass
class BuildRequest:
    customer: str
    environments: list  # list[Environment]
    feature_keys: set  # subset of {f["key"] for f in FEATURE_FLAGS}
    build_android: bool = True
    build_windows: bool = True
    # Baked in via WMSNOW_LOCKED_LOG_SERVER (2026-08-27, bug fix - see
    # AppConfig.loadLogServer's doc comment: Feature Settings, the only
    # other place this was configurable, is unreachable on a locked build)
    # - blank means this build's devices just won't upload logs, same as
    # leaving the Email Server unconfigured is fine.
    log_server_url: str = ""
    log_server_token: str = ""
    # License expiry (2026-09-18) - baked into the build via
    # WMSNOW_LICENSE_EXPIRY, checked at app launch (see AppConfig in
    # lib/config/app_config.dart). ISO date "YYYY-MM-DD"; blank means no
    # expiry (the plain unlocked dev build never sets this at all). Fixed
    # at build time - there is no remote way to change it after the APK is
    # built and distributed; a renewal or an extension means generating and
    # redistributing a new build with a later date. See expiry_notify.py
    # for the "expiry approaching" email alerts this same date drives.
    expiry_date: str = ""
    # ---- Customer-specific screen/print matching strings (2026-09-28) ----
    #
    # A handful of client-side customizations need to match text or config
    # that lives inside one specific customer's own Oracle WMS instance -
    # a real screen name, or a Label Designer template/printer name. Not
    # something a builder types into a form each time - see
    # CUSTOMER_SCREEN_OVERRIDES above, which run_build_request() fills
    # these in from automatically (keyed by `customer`) whenever a field
    # below is left blank. A caller only needs to set one of these fields
    # directly for a one-off build that intentionally deviates from that
    # table. Blank (no override on file, and not set here) means that
    # customization's screen/print-name matching never fires for this
    # build - harmless if the customer doesn't have that customization
    # enabled at all.
    truck_temp_page_title_match: str = ""
    # Comma-separated if this customer's padding/extraction requirement
    # spans more than one real screen (see AppConfig's doc comment in
    # lib/config/app_config.dart) - a single fixed string can't cover a
    # customer who needs the same handling on two differently-named
    # screens.
    multi_field_barcode_gs1_page_title_match: str = ""
    mix_area_label_designer_code: str = ""
    mix_area_printer_name: str = ""
    log: list = field(default_factory=list)  # populated as the build runs

    def _print(self, msg: str) -> None:
        self.log.append(msg)
        print(msg)


class BuildError(Exception):
    pass


def validate_field(label: str, value: str) -> str:
    value = value.strip()
    if not value:
        raise BuildError(f"{label} is required.")
    if any(c in value for c in RESERVED_CHARS):
        raise BuildError(f"{label} can't contain '#' or ',' (used as delimiters).")
    return value


def validate_customer_name(value: str) -> str:
    value = value.strip()
    if not value:
        raise BuildError("Customer name is required.")
    if not SAFE_NAME_RE.match(value):
        raise BuildError(
            "Customer name: letters, numbers, spaces, '_' and '-' only "
            "(used in the app name and embedded directly into Android/"
            "Windows source files)."
        )
    return value


def sanitize_filename(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", value)


def validate_expiry_date(value: str) -> str:
    value = value.strip()
    if not value:
        raise BuildError("License Expiry Date is required.")
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        raise BuildError("License Expiry Date must be a valid date (YYYY-MM-DD).")
    return value


@contextmanager
def temporary_app_name(app_name: str, log_fn=print):
    """Rewrites the Android label / Windows window title / Windows file
    metadata to app_name for the duration of the `with` block, then always
    restores the original file content."""
    file_edits = {
        MANIFEST_PATH: [
            ('android:label="WMSNow Redwood Mobile (dev)"', f'android:label="{app_name}"'),
        ],
        MAIN_CPP_PATH: [
            ('window.Create(L"WMSNow Redwood Mobile"', f'window.Create(L"{app_name}"'),
        ],
        RUNNER_RC_PATH: [
            ('VALUE "FileDescription", "WMSNow Redwood Mobile" "\\0"',
             f'VALUE "FileDescription", "{app_name}" "\\0"'),
            ('VALUE "ProductName", "WMSNow Redwood Mobile" "\\0"',
             f'VALUE "ProductName", "{app_name}" "\\0"'),
        ],
    }
    originals = {path: path.read_text(encoding="utf-8") for path in file_edits}
    try:
        for path, replacements in file_edits.items():
            content = originals[path]
            for old, new in replacements:
                if old not in content:
                    log_fn(f"  WARNING: expected text not found in {path.name} - "
                           "app name not applied there, continuing anyway.")
                    continue
                content = content.replace(old, new)
            path.write_text(content, encoding="utf-8")
        yield
    finally:
        for path, content in originals.items():
            path.write_text(content, encoding="utf-8")


def _run_build(args: str, log_fn) -> bool:
    # BUG FIX 2026-09-11 - live-confirmed on a Windows build: `text=True`
    # with no explicit encoding decodes the flutter/CMake/MSBuild
    # subprocess's combined stdout+stderr using Python's Windows default
    # ("charmap"/cp1252), which isn't valid for Unicode characters that
    # toolchain commonly prints (checkmarks, box-drawing, etc.) - one such
    # byte crashed the WHOLE build request with a UnicodeDecodeError before
    # it ever reached record_build(), silently discarding even an
    # already-succeeded Android build from the same request. Decoding as
    # UTF-8 with errors="replace" (undecodable bytes become the U+FFFD
    # placeholder) fixes the crash; this is just progress text shown to the
    # admin, so perfect fidelity on a stray byte doesn't matter.
    result = subprocess.run(
        args, cwd=PROJECT_ROOT, shell=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
    )
    for line in result.stdout.splitlines():
        log_fn(line)
    return result.returncode == 0


def _apply_customer_screen_overrides(req: "BuildRequest") -> None:
    """Fills in any of BuildRequest's screen/print matching fields that
    were left blank, from CUSTOMER_SCREEN_OVERRIDES (see its own doc
    comment) - a caller passing one of these fields explicitly always
    wins over the table, for a one-off build that intentionally deviates
    from it."""
    overrides = CUSTOMER_SCREEN_OVERRIDES.get(req.customer, {})
    for field_name, value in overrides.items():
        if not getattr(req, field_name):
            setattr(req, field_name, value)


def _extra_defines(req: "BuildRequest") -> str:
    """The customer-specific screen/print matching strings (see
    BuildRequest's own doc comment) as a string of --dart-define flags,
    one per field, always passed (empty string is a valid, harmless
    value - see AppConfig's `.isNotEmpty` guards)."""
    values = {
        "WMSNOW_TRUCK_TEMP_PAGE_TITLE_MATCH": req.truck_temp_page_title_match,
        "WMSNOW_MFB_GS1_PAGE_TITLE_MATCH": req.multi_field_barcode_gs1_page_title_match,
        "WMSNOW_MA_LABEL_DESIGNER_CODE": req.mix_area_label_designer_code,
        "WMSNOW_MA_PRINTER_NAME": req.mix_area_printer_name,
    }
    return " ".join(f'--dart-define={k}="{v}"' for k, v in values.items())


def build_android(define_env: str, define_flags: str, define_log_server: str,
                   define_expiry: str, app_name: str, extra_defines: str,
                   dest: Path, log_fn) -> "Path | None":
    log_fn("Building Android APK - this can take a couple of minutes...")
    ok = _run_build(
        f'flutter build apk --release '
        f'--dart-define=WMSNOW_LOCKED_ENVIRONMENTS="{define_env}" '
        f'--dart-define=WMSNOW_LOCKED_FEATURE_FLAGS="{define_flags}" '
        f'--dart-define=WMSNOW_LOCKED_LOG_SERVER="{define_log_server}" '
        f'--dart-define=WMSNOW_LICENSE_EXPIRY="{define_expiry}" '
        f'--dart-define=WMSNOW_APP_NAME="{app_name}" '
        f'{extra_defines}',
        log_fn,
    )
    built = PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not ok or not built.exists():
        log_fn("Android build failed - see output above.")
        return None
    shutil.copy2(built, dest)
    return dest


def build_windows(define_env: str, define_flags: str, define_log_server: str,
                   define_expiry: str, app_name: str, safe_app_name: str,
                   extra_defines: str, dest: Path, log_fn) -> "Path | None":
    log_fn("Building Windows desktop app - this can take a couple of minutes...")
    ok = _run_build(
        f'flutter build windows --release '
        f'--dart-define=WMSNOW_LOCKED_ENVIRONMENTS="{define_env}" '
        f'--dart-define=WMSNOW_LOCKED_FEATURE_FLAGS="{define_flags}" '
        f'--dart-define=WMSNOW_LOCKED_LOG_SERVER="{define_log_server}" '
        f'--dart-define=WMSNOW_LICENSE_EXPIRY="{define_expiry}" '
        f'--dart-define=WMSNOW_APP_NAME="{app_name}" '
        f'{extra_defines}',
        log_fn,
    )
    built_dir = PROJECT_ROOT / "build" / "windows" / "x64" / "runner" / "Release"
    exe_src = built_dir / "wmsnow_redwood_v3.exe"
    if not ok or not exe_src.exists():
        log_fn("Windows build failed - see output above.")
        return None
    # Rename the exe itself to match, so the customer sees <app name>.exe
    # when they unzip, not the generic project filename.
    exe_renamed = built_dir / f"{safe_app_name}.exe"
    exe_src.rename(exe_renamed)
    zip_path_str = shutil.make_archive(str(dest), "zip", root_dir=built_dir)
    exe_renamed.rename(exe_src)
    return Path(zip_path_str)


def run_build_request(req: BuildRequest) -> dict:
    """Runs the full build described by req, appending progress lines to
    req.log as it goes. Returns {"apk_path": Path|None, "windows_path": Path|None}.
    Raises BuildError for validation problems caught before any build
    subprocess is even started."""
    if not req.environments:
        raise BuildError("At least one environment is required.")
    if not req.build_android and not req.build_windows:
        raise BuildError("Pick at least one platform to build.")

    customer = validate_customer_name(req.customer)
    define_expiry = validate_expiry_date(req.expiry_date)
    app_name = f"{customer} redwood"
    safe_app_name = sanitize_filename(app_name)
    _apply_customer_screen_overrides(req)

    define_env = ",".join(e.to_define_entry() for e in req.environments)
    define_flags = ",".join(sorted(req.feature_keys))
    define_log_server = f"{req.log_server_url}#{req.log_server_token}" \
        if req.log_server_url else ""
    extra_defines = _extra_defines(req)

    run_dir = OUTPUT_DIR / f"{sanitize_filename(customer)}_{date.today().isoformat()}"
    run_dir.mkdir(parents=True, exist_ok=True)

    apk_path = None
    windows_path = None
    with temporary_app_name(app_name, log_fn=req._print):
        if req.build_android:
            apk_path = build_android(
                define_env, define_flags, define_log_server, define_expiry, app_name,
                extra_defines, run_dir / f"{safe_app_name}.apk", req._print,
            )
        if req.build_windows:
            windows_path = build_windows(
                define_env, define_flags, define_log_server, define_expiry,
                app_name, safe_app_name, extra_defines,
                run_dir / f"{safe_app_name}_windows", req._print,
            )

    req._print(f"\nApp name: {app_name}")
    if apk_path:
        req._print(f"Android APK:  {apk_path}")
    if windows_path:
        req._print(f"Windows zip:  {windows_path}")
    if not apk_path and not windows_path:
        req._print("Build(s) failed - nothing was produced.")

    record_id = None
    if apk_path or windows_path:
        record_id = record_build(customer, req, apk_path, windows_path)

    return {"apk_path": apk_path, "windows_path": windows_path, "record_id": record_id}


# ---- Build history ----


def _load_history() -> dict:
    if not HISTORY_PATH.exists():
        return {}
    return json.loads(HISTORY_PATH.read_text(encoding="utf-8"))


def _save_history(history: dict) -> None:
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    HISTORY_PATH.write_text(json.dumps(history, indent=2), encoding="utf-8")


def _snapshot_source(record_id: str) -> bool:
    """Copies lib/ as it exists right now into
    data/snapshots/<record_id>/lib - see SNAPSHOTS_DIR's doc comment.
    Returns whether it succeeded; a failure here (disk full, permissions)
    should never fail the build itself, just leave that one record without
    a code diff available later."""
    try:
        shutil.copytree(PROJECT_ROOT / "lib", SNAPSHOTS_DIR / record_id / "lib")
        return True
    except OSError:
        return False


def record_build(customer: str, req: "BuildRequest", apk_path, windows_path) -> str:
    """Appends one record to this customer's build history - called only
    for a build that produced at least one output file (a failed attempt
    isn't something worth remembering as "an APK we gave the customer").
    Returns the new record's id (distribution_links.py uses this to
    auto-advance any evergreen link pointed at this customer/instance)."""
    history = _load_history()
    record_id = uuid.uuid4().hex
    snapshot_ok = _snapshot_source(record_id)
    history.setdefault(customer, []).append({
        "id": record_id,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "snapshot_ok": snapshot_ok,
        "environments": [
            {
                "name": e.name,
                "domain": e.domain,
                "instance": e.instance,
                "client_id": e.client_id,
                "client_secret": e.client_secret,
            }
            for e in req.environments
        ],
        "feature_keys": sorted(req.feature_keys),
        "build_android": req.build_android,
        "build_windows": req.build_windows,
        "log_server_url": req.log_server_url,
        "log_server_token": req.log_server_token,
        "expiry_date": req.expiry_date,
        "truck_temp_page_title_match": req.truck_temp_page_title_match,
        "multi_field_barcode_gs1_page_title_match":
            req.multi_field_barcode_gs1_page_title_match,
        "mix_area_label_designer_code": req.mix_area_label_designer_code,
        "mix_area_printer_name": req.mix_area_printer_name,
        # Which "expiry approaching" email thresholds (see
        # expiry_notify.py) have already been sent for THIS build record -
        # prevents re-sending the same alert every time the check runs.
        # Reset naturally on a fresh build (a rebuild is a new record with
        # its own new expiry_date and an empty list).
        "notified_thresholds": [],
        "apk_path": str(apk_path) if apk_path else None,
        "windows_path": str(windows_path) if windows_path else None,
    })
    _save_history(history)
    return record_id


def list_customers() -> list:
    return sorted(_load_history().keys(), key=str.lower)


def get_customer_history(customer: str) -> list:
    """Newest first."""
    records = _load_history().get(customer, [])
    return sorted(records, key=lambda r: r["timestamp"], reverse=True)


def find_record(record_id: str):
    """Returns (customer, record) or (None, None) if not found - record ids
    are unique across all customers (uuid4), so a flat scan is fine at this
    scale (a handful of customers, a handful of builds each)."""
    history = _load_history()
    for customer, records in history.items():
        for r in records:
            if r["id"] == record_id:
                return customer, r
    return None, None


def latest_record(customer: str):
    """The most recently built record for a customer, or None - the only
    one actually relevant for expiry alerts, since that's what's presumed
    installed on their devices right now."""
    records = get_customer_history(customer)
    return records[0] if records else None


def mark_notified(record_id: str, threshold: int) -> None:
    """Records that the "expiry approaching" email for one threshold (see
    expiry_notify.py) has been sent for this build, so it isn't sent again
    on the next check."""
    history = _load_history()
    for records in history.values():
        for r in records:
            if r["id"] == record_id:
                thresholds = r.setdefault("notified_thresholds", [])
                if threshold not in thresholds:
                    thresholds.append(threshold)
                _save_history(history)
                return
