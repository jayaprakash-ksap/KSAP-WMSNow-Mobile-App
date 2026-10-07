# Oracle Custom App Mobile (Flutter)

Native Android/iOS custom client for Oracle WMS Redwood Mobile, with a
**Truck Temp** field injected above LPN on the Receiving screen and saved to
`ib_shipment.cust_field_1` via lgfapi.

This is the supported path: the Redwood Mobile API (`get_next_rwmobile_page`)
is documented for native apps (Android/iOS/Java), unlike browser clients.

## Setup

1. Install Flutter + Android SDK (`flutter doctor` all green for Android).
2. Edit `lib/config/app_config.dart`:
   - `clientId` / `clientSecret` — register a FRESH OAuth app in WMS and paste.
   - `domain` / `instance` — no seed environment is baked in; add one via the app's Manage Environments screen on first run.
3. Get packages:
   ```
   flutter pub get
   ```
4. Run:
   ```
   flutter run                 # on a connected Android device/emulator
   flutter run -d chrome       # quick look in a browser (no scanner)
   ```

## Confirmed request protocol (from live captures)

| Interaction        | Request shape |
|--------------------|---------------|
| Initial / handshake| `{}` |
| Entry submit / menu select (incl. facility code, company code, LPN) | `{htmlrfid, env_name, keyboard_input}` (`env_name` is the actual instance name) |
| Control/action key | `{clientid, htmlrfid, action_keys}` (bare letter/F2, e.g. "F" for Facility - NOT "Ctrl-F"; "Previous Screen" varies by screen, e.g. `W` or `F2` - always read from that screen's own `ctrl_keys`, never hardcoded) |
| Yes/No ("another active session") | `{clientid, htmlrfid, action_keys}` (`A`=yes, `X`=no) - handled entirely automatically in the background, never shown to the user |
| lgfapi PATCH       | `{"fields": {cust_field_1: "..."}}` (trailing slash on URL) |

Session identity (`clientid`/`htmlrfid`) tracks the latest server response
throughout the session - not frozen from login. See `rwmobile_service.dart`'s
top-of-file doc comment for why.

Dialog types handled: `entry`, `info`, `yesno` (auto-resolved, never
rendered), plus `mainmenu` and generic screen (`page_content` fields, which
can themselves be `label`, `button`, or `entry` items).

Control keys (from server `ctrl_keys`): Ctrl-X Exit, F2 Previous, Ctrl-L
Language, Ctrl-F Facility, Ctrl-P Printer, Ctrl-O Company, Ctrl-U/D paging.

## Security note (before production)

The OAuth `clientSecret` cannot be safely embedded in a shipped app binary.
For production: register a **Public** client type, or route the token exchange
through your own backend. This build is test-grade (direct-to-WMS) for speed.

## Truck Temp injection

Configured in `app_config.dart` (`enh*` fields): find the LPN control on the
Receiving screen, insert a Truck Temp field before it, and on submit PATCH the
value onto the shipment's `cust_field_1`. Change `enhSaveField` if your entity
uses a different custom field.

## Barcode scanning

`mobile_scanner` is included for camera scanning. For Zebra/Honeywell rugged
devices, DataWedge injects scans as keystrokes into the focused field, so no
extra code is needed there.
