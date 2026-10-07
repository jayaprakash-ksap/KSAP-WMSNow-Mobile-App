#!/usr/bin/env python3
"""Generates customer-locked release builds for WMSNow Redwood Mobile - both
the Android APK and a zipped Windows desktop build, from one run.

Run from anywhere - always builds from the project root (one level up from
this script), regardless of your current directory:

    python tools/generate_customer_build.py

Prompts for the customer's name, one or more WMS environments, which
client-side customizations to bake in, and which platform(s) to build,
then does so with everything baked in via --dart-define (see
AppConfig.isLocked / AppConfig's WMSNOW_LOCKED_FEATURE_FLAGS handling in
lib/config/app_config.dart for what this actually does at runtime: every
environment field becomes read-only in Manage Environments, feature
switches become read-only in Feature Settings, and both settings icons
disappear entirely from the Login screen).

This is now a thin wrapper around tools/build_lib.py - the same module
tools/admin_build_ui/app.py (the browser-based Admin Build UI) uses, so
prefer that if you'd rather not type client secrets into a terminal. Kept
around for quick offline use.

The app is also named after the customer - exactly "<customer name> redwood"
(e.g. customer "ksap_test" -> "ksap_test redwood") - used as the Android
app label, the Windows window title, and the Windows exe's filename.

Output lands in customer_builds/<CustomerName>_<date>/ (gitignored, since
these files have live OAuth secrets compiled into them):
    <customer name> redwood.apk
    <customer name> redwood_windows.zip  (the exe + its required DLLs/data)

Uses getpass for the Client Secret prompt so it isn't echoed to the
terminal or captured in shell/scrollback history.

Does NOT touch the daily-dev build (the plain, unlocked "WMSNow Redwood Mobile"
desktop app) - that's built separately and lives in dev_build/, entirely
outside the build/ folder this script uses.

iOS is NOT covered here - building for iOS requires a Mac running Xcode,
which this script has no way to do from Windows.
"""

import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_lib import (  # noqa: E402
    FEATURE_FLAGS,
    BuildError,
    BuildRequest,
    Environment,
    run_build_request,
    validate_customer_name,
    validate_field,
)


def prompt_field(label: str, hidden: bool = False) -> str:
    while True:
        value = (getpass.getpass(f"  {label}: ") if hidden else input(f"  {label}: ")).strip()
        try:
            return validate_field(label, value)
        except BuildError as e:
            print(f"    {e} Try again.")


def prompt_customer_name() -> str:
    while True:
        value = input("Customer name (e.g. ksap_test): ").strip()
        try:
            return validate_customer_name(value)
        except BuildError as e:
            print(f"  {e}")


def prompt_environment(n: int) -> Environment:
    print(f"\n--- Environment #{n} ---")
    return Environment(
        name=prompt_field("Environment name (e.g. mycompany_test)"),
        domain=prompt_field("Domain (e.g. https://tb2.wms.ocs.oraclecloud.com)"),
        instance=prompt_field("Instance (URL path segment)"),
        client_id=prompt_field("OAuth Client ID"),
        client_secret=prompt_field("OAuth Client Secret", hidden=True),
    )


def prompt_feature_keys() -> set:
    print("\n--- Customizations to bake into this build ---")
    keys = set()
    for f in FEATURE_FLAGS:
        print(f"  {f['title']} - {f['description']}")
        if input(f"  Include '{f['title']}'? (y/N): ").strip().lower() == "y":
            keys.add(f["key"])
        print()
    return keys


def prompt_platforms() -> tuple:
    print("--- Platform(s) to build ---")
    android = input("  Build Android APK? (Y/n): ").strip().lower() != "n"
    windows = input("  Build Windows desktop? (Y/n): ").strip().lower() != "n"
    return android, windows


def prompt_log_server() -> tuple:
    print("--- Log Server (optional) ---")
    print("  Baked into this build so devices upload their session logs "
          "automatically - browsable via the Admin Build UI's Logs page.")
    url = input("  Log Server URL (blank to skip): ").strip()
    if not url:
        return "", ""
    token = input("  Log Server token: ").strip()
    return url, token


def main() -> None:
    print("WMSNow Redwood Mobile - customer build generator (Android + Windows)\n")
    customer = prompt_customer_name()

    environments = [prompt_environment(1)]
    n = 2
    while input("\nAdd another environment for this customer? (y/N): ").strip().lower() == "y":
        environments.append(prompt_environment(n))
        n += 1

    feature_keys = prompt_feature_keys()
    build_android, build_windows = prompt_platforms()
    log_server_url, log_server_token = prompt_log_server()

    req = BuildRequest(
        customer=customer,
        environments=environments,
        feature_keys=feature_keys,
        build_android=build_android,
        build_windows=build_windows,
        log_server_url=log_server_url,
        log_server_token=log_server_token,
    )
    try:
        result = run_build_request(req)
    except BuildError as e:
        print(f"\n{e}")
        sys.exit(1)

    if not result["apk_path"] and not result["windows_path"]:
        sys.exit(1)
    print("\nThese files have live OAuth credentials compiled in - hand them only to this customer.")


if __name__ == "__main__":
    main()
