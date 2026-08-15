#!/usr/bin/env python3
"""Generates a customer-locked release APK for Japra WMS Mobile.

Run from anywhere - always builds from the project root (one level up from
this script), regardless of your current directory:

    python tools/generate_customer_apk.py

Prompts for the customer's name and one or more WMS environments (name,
domain, instance, OAuth Client ID/Secret), then builds a release APK with
those baked in via --dart-define=JAPRA_LOCKED_ENVIRONMENTS=... (see
AppConfig.isLocked in lib/config/app_config.dart for what this actually
does at runtime: every environment field becomes read-only in Manage
Environments, and there's no way to add a different one). The finished APK
is copied to customer_builds/<CustomerName>_<date>.apk - that folder is
gitignored, since these files have live OAuth secrets compiled into them.

Uses getpass for the Client Secret prompt so it isn't echoed to the
terminal or captured in shell/scrollback history the way typing the full
--dart-define command by hand would risk.
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
            print(f"    Can't contain '#' or ',' (used as delimiters) - try again")
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


def main() -> None:
    print("Japra WMS Mobile - customer APK generator\n")
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

    print("\nBuilding release APK - this can take a couple of minutes...")
    result = subprocess.run(
        f'flutter build apk --release --dart-define=JAPRA_LOCKED_ENVIRONMENTS="{define_value}"',
        cwd=PROJECT_ROOT,
        shell=True,
    )
    if result.returncode != 0:
        print("\nBuild failed - see output above.")
        sys.exit(result.returncode)

    built_apk = PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not built_apk.exists():
        print(f"\nBuild reported success but {built_apk} is missing - check the build output.")
        sys.exit(1)

    OUTPUT_DIR.mkdir(exist_ok=True)
    safe_customer = re.sub(r"[^A-Za-z0-9_-]", "_", customer)
    dest = OUTPUT_DIR / f"{safe_customer}_{date.today().isoformat()}.apk"
    shutil.copy2(built_apk, dest)
    print(f"\nDone: {dest}")
    print("This file has live OAuth credentials compiled in - hand it only to this customer.")


if __name__ == "__main__":
    main()
