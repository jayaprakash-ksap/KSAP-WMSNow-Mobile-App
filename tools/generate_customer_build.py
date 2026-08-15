#!/usr/bin/env python3
"""Generates customer-locked release builds for Japra WMS Mobile - both
the Android APK and a zipped Windows desktop build, from one run.

Run from anywhere - always builds from the project root (one level up from
this script), regardless of your current directory:

    python tools/generate_customer_build.py

Prompts for the customer's name and one or more WMS environments (name,
domain, instance, OAuth Client ID/Secret), then builds both platforms with
those baked in via --dart-define=JAPRA_LOCKED_ENVIRONMENTS=... (see
AppConfig.isLocked in lib/config/app_config.dart for what this actually
does at runtime: every environment field becomes read-only in Manage
Environments, and there's no way to add a different one).

The app is also named after the customer - exactly "<customer name> redwood"
(e.g. customer "ksap_test" -> "ksap_test redwood") - used as the Android
app label, the Windows window title, and the Windows exe's filename. This
means temporarily editing three tracked native source files
(AndroidManifest.xml, windows/runner/main.cpp, windows/runner/Runner.rc)
for the duration of the build - see temporary_app_name() below. They are
ALWAYS restored to their original committed content afterward, even if the
build fails or the script is interrupted (try/finally) - `git status`
should show no changes to those 3 files once this script exits.

Output lands in customer_builds/<CustomerName>_<date>/ (gitignored, since
these files have live OAuth secrets compiled into them):
    <customer name> redwood.apk
    <customer name> redwood_windows.zip  (the exe + its required DLLs/data)

Uses getpass for the Client Secret prompt so it isn't echoed to the
terminal or captured in shell/scrollback history the way typing the full
--dart-define command by hand would risk.

Does NOT touch the daily-dev build (the plain, unlocked "Japra WMS Mobile"
desktop app) - that's built separately and lives in dev_build/, entirely
outside the build/ folder this script uses, specifically so running this
script can never again silently overwrite it (a real incident, 2026-07-26).

iOS is NOT covered here - building for iOS requires a Mac running Xcode,
which this script has no way to do from Windows.
"""

import getpass
import re
import shutil
import subprocess
import sys
from contextlib import contextmanager
from datetime import date
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "customer_builds"

MANIFEST_PATH = PROJECT_ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
MAIN_CPP_PATH = PROJECT_ROOT / "windows" / "runner" / "main.cpp"
RUNNER_RC_PATH = PROJECT_ROOT / "windows" / "runner" / "Runner.rc"

# `#` separates fields within one environment entry, `,` separates entries -
# see AppConfig's doc comment for why not `;` or `|` (both get mangled by
# Windows' cmd.exe when flutter, a .bat file, forwards the argument).
_RESERVED_CHARS = "#,"
# Customer name gets embedded directly into XML (AndroidManifest.xml) and
# C++ string literals (main.cpp/Runner.rc) - restricted to a safe charset
# up front rather than trying to escape it correctly for three different
# file formats at once.
_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9 _-]+$")


def prompt_field(label: str, hidden: bool = False) -> str:
    while True:
        value = (getpass.getpass(f"  {label}: ") if hidden else input(f"  {label}: ")).strip()
        if not value:
            print("    (required, try again)")
            continue
        if any(c in value for c in _RESERVED_CHARS):
            print("    Can't contain '#' or ',' (used as delimiters) - try again")
            continue
        return value


def prompt_customer_name() -> str:
    while True:
        value = input("Customer name (e.g. ksap_test): ").strip()
        if not value:
            print("  Customer name is required.")
            continue
        if not _SAFE_NAME_RE.match(value):
            print("  Letters, numbers, spaces, '_' and '-' only (used in the app name "
                  "and gets embedded directly into Android/Windows source files).")
            continue
        return value


def prompt_environment(n: int) -> str:
    print(f"\n--- Environment #{n} ---")
    name = prompt_field("Environment name (e.g. flow_test)")
    domain = prompt_field("Domain (e.g. https://tb2.wms.ocs.oraclecloud.com)")
    instance = prompt_field("Instance (URL path segment)")
    client_id = prompt_field("OAuth Client ID")
    client_secret = prompt_field("OAuth Client Secret", hidden=True)
    return f"{name}#{domain}#{instance}#{client_id}#{client_secret}"


def sanitize_filename(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", value)


@contextmanager
def temporary_app_name(app_name: str):
    """Rewrites the Android label / Windows window title / Windows file
    metadata to app_name for the duration of the `with` block, then always
    restores the original file content - see module docstring."""
    file_edits = {
        MANIFEST_PATH: [
            ('android:label="Japra WMS Mobile (dev)"', f'android:label="{app_name}"'),
        ],
        MAIN_CPP_PATH: [
            ('window.Create(L"Japra WMS Mobile"', f'window.Create(L"{app_name}"'),
        ],
        RUNNER_RC_PATH: [
            ('VALUE "FileDescription", "Japra WMS Mobile" "\\0"',
             f'VALUE "FileDescription", "{app_name}" "\\0"'),
            ('VALUE "ProductName", "Japra WMS Mobile" "\\0"',
             f'VALUE "ProductName", "{app_name}" "\\0"'),
        ],
    }
    originals = {path: path.read_text(encoding="utf-8") for path in file_edits}
    try:
        for path, replacements in file_edits.items():
            content = originals[path]
            for old, new in replacements:
                if old not in content:
                    print(f"  WARNING: expected text not found in {path.name} - "
                          "app name not applied there, continuing anyway.")
                    continue
                content = content.replace(old, new)
            path.write_text(content, encoding="utf-8")
        yield
    finally:
        for path, content in originals.items():
            path.write_text(content, encoding="utf-8")


def run_build(args: str) -> bool:
    result = subprocess.run(args, cwd=PROJECT_ROOT, shell=True)
    return result.returncode == 0


def build_android(define_value: str, app_name: str, dest: Path) -> Path | None:
    print("\nBuilding Android APK - this can take a couple of minutes...")
    ok = run_build(
        f'flutter build apk --release '
        f'--dart-define=JAPRA_LOCKED_ENVIRONMENTS="{define_value}" '
        f'--dart-define=JAPRA_APP_NAME="{app_name}"'
    )
    built = PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not ok or not built.exists():
        print("Android build failed - see output above.")
        return None
    shutil.copy2(built, dest)
    return dest


def build_windows(define_value: str, app_name: str, safe_app_name: str, dest: Path) -> Path | None:
    print("\nBuilding Windows desktop app - this can take a couple of minutes...")
    ok = run_build(
        f'flutter build windows --release '
        f'--dart-define=JAPRA_LOCKED_ENVIRONMENTS="{define_value}" '
        f'--dart-define=JAPRA_APP_NAME="{app_name}"'
    )
    built_dir = PROJECT_ROOT / "build" / "windows" / "x64" / "runner" / "Release"
    exe_src = built_dir / "japra_redwood_v3.exe"
    if not ok or not exe_src.exists():
        print("Windows build failed - see output above.")
        return None
    # Rename the exe itself to match, so the customer sees <app name>.exe
    # when they unzip, not the generic project filename.
    exe_renamed = built_dir / f"{safe_app_name}.exe"
    exe_src.rename(exe_renamed)
    zip_path_str = shutil.make_archive(str(dest), "zip", root_dir=built_dir)
    # Restore the generic name in the shared build/ output - this folder is
    # ephemeral either way (next build overwrites it regardless), but leaves
    # no surprises if something else inspects it before that happens.
    exe_renamed.rename(exe_src)
    return Path(zip_path_str)


def main() -> None:
    print("Japra WMS Mobile - customer build generator (Android + Windows)\n")
    customer = prompt_customer_name()
    app_name = f"{customer} redwood"
    safe_app_name = sanitize_filename(app_name)

    entries = [prompt_environment(1)]
    n = 2
    while input("\nAdd another environment for this customer? (y/N): ").strip().lower() == "y":
        entries.append(prompt_environment(n))
        n += 1

    define_value = ",".join(entries)

    run_dir = OUTPUT_DIR / f"{sanitize_filename(customer)}_{date.today().isoformat()}"
    run_dir.mkdir(parents=True, exist_ok=True)

    with temporary_app_name(app_name):
        apk_path = build_android(define_value, app_name, run_dir / f"{safe_app_name}.apk")
        windows_path = build_windows(
            define_value, app_name, safe_app_name, run_dir / f"{safe_app_name}_windows"
        )

    print(f"\nApp name: {app_name}")
    if apk_path:
        print(f"Android APK:  {apk_path}")
    if windows_path:
        print(f"Windows zip:  {windows_path} (unzip and run {safe_app_name}.exe inside)")
    if not apk_path and not windows_path:
        print("Both builds failed - nothing was produced.")
        sys.exit(1)
    print("\nThese files have live OAuth credentials compiled in - hand them only to this customer.")


if __name__ == "__main__":
    main()
