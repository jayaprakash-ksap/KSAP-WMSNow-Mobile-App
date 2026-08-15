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
Environments, and there's no way to add a different one). Output lands in
customer_builds/ (gitignored, since these files have live OAuth secrets
compiled into them):
    <CustomerName>_<date>.apk
    <CustomerName>_<date>_windows.zip  (the exe + its required DLLs/data)

Uses getpass for the Client Secret prompt so it isn't echoed to the
terminal or captured in shell/scrollback history the way typing the full
--dart-define command by hand would risk.

iOS is NOT covered here - building for iOS requires a Mac running Xcode,
which this script has no way to do from Windows.
"""

import getpass
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "customer_builds"

# `#` separates fields within one environment entry, `,` separates entries -
# see AppConfig's doc comment for why not `;` or `|` (both get mangled by
# Windows' cmd.exe when flutter, a .bat file, forwards the argument).
_RESERVED_CHARS = "#,"


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


def prompt_environment(n: int) -> str:
    print(f"\n--- Environment #{n} ---")
    name = prompt_field("Environment name (e.g. flow_test)")
    domain = prompt_field("Domain (e.g. https://tb2.wms.ocs.oraclecloud.com)")
    instance = prompt_field("Instance (URL path segment)")
    client_id = prompt_field("OAuth Client ID")
    client_secret = prompt_field("OAuth Client Secret", hidden=True)
    return f"{name}#{domain}#{instance}#{client_id}#{client_secret}"


def run_build(args: str) -> bool:
    result = subprocess.run(args, cwd=PROJECT_ROOT, shell=True)
    return result.returncode == 0


def build_android(define_value: str, dest_stem: Path) -> Path | None:
    print("\nBuilding Android APK - this can take a couple of minutes...")
    ok = run_build(
        f'flutter build apk --release --dart-define=JAPRA_LOCKED_ENVIRONMENTS="{define_value}"'
    )
    built = PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not ok or not built.exists():
        print("Android build failed - see output above.")
        return None
    dest = dest_stem.with_suffix(".apk")
    shutil.copy2(built, dest)
    return dest


def build_windows(define_value: str, dest_stem: Path) -> Path | None:
    print("\nBuilding Windows desktop app - this can take a couple of minutes...")
    ok = run_build(
        f'flutter build windows --release --dart-define=JAPRA_LOCKED_ENVIRONMENTS="{define_value}"'
    )
    built_dir = PROJECT_ROOT / "build" / "windows" / "x64" / "runner" / "Release"
    if not ok or not (built_dir / "japra_redwood_v3.exe").exists():
        print("Windows build failed - see output above.")
        return None
    zip_path_str = shutil.make_archive(
        str(dest_stem) + "_windows", "zip", root_dir=built_dir
    )
    return Path(zip_path_str)


def main() -> None:
    print("Japra WMS Mobile - customer build generator (Android + Windows)\n")
    customer = input("Customer name (used for the output filename): ").strip()
    if not customer:
        print("Customer name is required.")
        sys.exit(1)

    entries = [prompt_environment(1)]
    n = 2
    while input("\nAdd another environment for this customer? (y/N): ").strip().lower() == "y":
        entries.append(prompt_environment(n))
        n += 1

    define_value = ",".join(entries)

    OUTPUT_DIR.mkdir(exist_ok=True)
    safe_customer = re.sub(r"[^A-Za-z0-9_-]", "_", customer)
    dest_stem = OUTPUT_DIR / f"{safe_customer}_{date.today().isoformat()}"

    apk_path = build_android(define_value, dest_stem)
    windows_path = build_windows(define_value, dest_stem)

    print()
    if apk_path:
        print(f"Android APK:  {apk_path}")
    if windows_path:
        print(f"Windows zip:  {windows_path} (unzip and run japra_redwood_v3.exe inside)")
    if not apk_path and not windows_path:
        print("Both builds failed - nothing was produced.")
        sys.exit(1)
    print("\nThese files have live OAuth credentials compiled in - hand them only to this customer.")


if __name__ == "__main__":
    main()
