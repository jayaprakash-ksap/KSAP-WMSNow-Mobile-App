# Functional Specification — Japra WMS Mobile

**Product:** Custom native mobile client for Oracle WMS Redwood Mobile (RF)
**Platform:** Android (primary), iOS/desktop/web also buildable from the same Flutter codebase
**Version:** 0.1.0
**Date:** 2026-07-10
**Project lineage:** `japra_redwood_v3` is a fork of `ksap_redwood_v2`, created 2026-07-10 as the active development line — `v2` is kept as a frozen, already-demonstrated POC snapshot and is not modified further; all customization work described below (from §4.5 onward, "as of v3") lives only in `v3`. Both can be installed on the same test device simultaneously (distinct package IDs: `com.example.ksap_redwood_v2` vs `com.example.japra_redwood_v3`).

---

## 1. Purpose

Oracle Custom App is a native mobile client that replicates the Oracle WMS **Redwood Mobile RF** experience — the same screen-by-screen, keyboard-driven workflow warehouse operators use on rugged handheld scanners — while adding enhancements Oracle's standard client does not provide: capturing a **Truck Temp** reading during a specific receiving transaction, scan/date-entry helpers on every field, and a **photo capture** step during LPN splitting.

Oracle's Redwood Mobile API (`get_next_rwmobile_page`) is documented for native app integration (Android/iOS/Java) but not for browser-based clients, which is why this is a purpose-built native app rather than a wrapped web view.

## 2. Actors

- **Warehouse operator** — logs in with their WMS username/password and performs RF transactions (receiving, putaway, picking, cycle counts, etc.) exactly as they would on a standard RF gun.
- **WMS administrator** — configures facilities, companies, and user permissions in Oracle WMS; not a direct user of this app, but its behavior (active-session handling, permissions) affects what the app can do.

## 3. Scope

### In scope
- OAuth2 login against the WMS instance.
- Rendering every screen type the RF API can return: main menu, entry dialogs, informational dialogs, and generic data-entry/list screens — driven entirely by what the server sends, not hardcoded per screen.
- All RF control-key actions available from the menu: Exit App, Previous Screen, Change Language, Change Facility, Change Default Printer, Restrict Company, Page Up/Down (exact set varies per screen, per the server's own response).
- Transparent handling of Oracle's "another active session" check that can occur during login/navigation — the operator should never need to answer a Yes/No prompt for this; the app resolves it automatically.
- Truck Temp capture on the "MARS Receive SKUs - FG" transaction specifically, saved to the shipment record.
- Barcode scanning support for rugged Zebra/Honeywell devices (via keystroke injection) and for standard devices with a camera (via an in-app scanner) — a scan icon is available on every text entry field, app-wide.
- A calendar date-picker on every date-type entry field, so the operator can pick a date instead of typing it.
- Photo capture during the Split IBLPN transaction, saved locally on the device.

### Out of scope (current version)
- Offline operation (the app requires a live connection to the WMS instance for every screen transition).
- Any RF transaction logic beyond what the server itself drives — the app does not implement business rules, only rendering and request forwarding.
- Multi-user/multi-session management within the app itself (one login session at a time, matching how a single RF handheld is used).

## 4. User Flows

### 4.1 Login
1. Operator enters WMS username and password.
2. App authenticates against Oracle's OAuth2 token endpoint.
3. On success, the app performs the initial RF handshake and shows the main menu.
4. On failure (bad credentials, network issue), an inline error message is shown and the operator can retry.

### 4.2 Main Menu
- Presents the numbered list of menu options exactly as returned by the server (e.g. "Task Auto," "LPN Inquiry," "Rcv ASN Units," etc. — the actual list depends on the logged-in user's permissions and facility).
- Tapping an item navigates into that transaction.

### 4.3 Control-key actions
An **Actions** menu in the top-right of every screen (not just the main menu) exposes whichever control-key actions the *current* screen supports — this set changes screen to screen and even step to step within one transaction (e.g. "End LPN" only appears once an LPN has an item line entered). Typical actions include:
- **Change Facility** — prompts for a facility code; submitting it switches the active facility and returns to an updated main menu.
- **Restrict Company** — presents a tappable list of eligible companies (or lets the operator type a company code directly); selecting one restricts the session to that company.
- **Change Language**, **Change Default Printer** — present their respective entry/selection dialogs.
- **Page Up / Page Down** — paginate long lists.
- **Apply Lock**, **Switch UOM**, **End LPN**, **Attachment**, and other transaction-specific actions that appear only inside specific multi-step transactions (e.g. Receiving).
- **Exit App** — ends the RF session server-side and returns the operator to the Login screen.
- **Previous Screen** — steps back one screen/field. (Note: on some screens this is triggered by a different physical key than on others — the app always uses whatever the server currently designates for "Previous Screen," matching real RF terminal behavior, and continues using that same key correctly even if an error message temporarily interrupts the screen.)

### 4.4 Data entry / generic screens
- Screens can present a mix of read-only labels, tappable choice buttons (e.g. a list of companies), and free-text/barcode entry fields (e.g. Dock, Shipment, Trailer, LPN).
- Tappable choice items (buttons) submit immediately on tap.
- Barcode-type fields can be filled either by camera-scanning within the app or, on rugged devices with DataWedge configured, by the hardware scanner injecting keystrokes directly into the focused field.
- **Every text entry field (as of v3)** shows a small scanner icon beside it — tapping it opens the device camera to scan a barcode and fills the field with the decoded value, exactly like the dedicated barcode-type fields but available everywhere, not only where the server marks a field as barcode-capable.
- **Every field whose prompt/label mentions "date" (as of v3)** additionally shows a calendar icon beside it — tapping it opens a standard date picker and fills the field in `MM/DD/YYYY` format instead of requiring the operator to type it.

### 4.5 Multi-field sequential entry (e.g. Receiving)
Some screens present several fields that must be filled **one at a time, in order** — matching a real RF terminal, which tracks a single active field ("cursor") server-side rather than allowing free-form jumping between fields:
- Only the current field is editable (shown with a visible cursor); every other field on screen is read-only, showing whatever value has already been confirmed for it (including values Oracle auto-fills based on an earlier entry — e.g. entering a Dock number can automatically populate the Shipment and Shipment Type fields).
- Each field has its own small **TAB** button beside it. Pressing it does the right thing automatically: if the operator has typed something, it submits that value (which advances to the next field on its own); if the field is left empty, it explicitly skips to the next field with no value.
- A field the server has already auto-suggested a value for still needs that value explicitly confirmed (typed/kept, then submitted) before it can be skipped — pressing TAB on it without confirming first is rejected with a "Required Field" message, matching real terminal behavior.
- Entering an invalid value (e.g. a badly-formatted date) shows an inline error the operator can dismiss to retry the same field, without losing anything already entered earlier in the transaction.
- Ending one LPN's line entries (via the Actions menu's "End LPN," where offered) returns to the top of the screen ready for the next LPN, with Dock/Shipment/Trailer/Type still filled in from the same receiving session.

### 4.6 Session conflict ("another active session")
- Oracle's RF backend occasionally requires an explicit confirmation that starting/continuing this session is intentional (this can happen right after login, or on the very next action, and is a normal, expected part of this WMS environment's behavior, not an error).
- The app answers this automatically, in the background. The operator never sees a Yes/No prompt for it — screens simply appear, with a brief pause if a confirmation round-trip was needed.
- If this cannot be resolved after several automatic attempts, the operator sees a message asking them to have a WMS administrator check active RF sessions for their account.

### 4.7 Truck Temp enhancement
- **Restricted to the "MARS Receive SKUs - FG" transaction only (as of v3)** — earlier this field appeared on every screen with an LPN-labeled field (most of the RF menu); it's now scoped to just this one receiving transaction.
- An extra **Truck Temp (°C)** field is shown immediately above the LPN field (not part of Oracle's standard screen).
- The moment the Shipment field is confirmed, the app looks up that shipment's record. If it already has a Truck Temp on file, the field displays that value **read-only** — the operator cannot re-enter or overwrite an already-recorded reading. If it's blank, the field stays editable as before.
- The operator enters a temperature reading; the app remembers it, but does **not** save it yet at that point.
- The actual save happens when the operator presses **Ctrl-E: End LPN** from the Actions menu (as of v3 — previously this saved immediately on submitting the LPN field, before the rest of that LPN's details were even entered). If the field was already locked (a value was already on file), End LPN does not re-save anything.
- If no shipment has been entered yet in the session, or the shipment can't be found, the operator is told why the save didn't happen (rather than it failing silently).

### 4.8 Logging out
- Exiting via the Exit App control key, or answering "No" to any session-related prompt that requires it, ends the RF session on the server and returns the operator to the Login screen with all session data cleared.

### 4.9 Split IBLPN photo capture (as of v3)
- On the Split IBLPN screen, a **Capture Photo** button sits between the Move Qty and Move to LPN fields.
- The operator can tap it at any time while on this screen (not tied to which field currently has focus) to open the device's camera and take a photo; a green checkmark confirms one has been captured, and tapping again retakes it.
- The photo is only written to storage once the Move to LPN field itself is submitted — capturing early and submitting later still attaches the photo correctly.
- Photos are saved to the app's own local storage on the device (not uploaded anywhere), named after the LPN value and a timestamp so multiple captures don't collide.

## 5. Non-functional requirements

- **Responsiveness:** every operator action should reflect on screen within a few seconds under normal network conditions; requests that don't respond within 25 seconds are treated as a network problem and reported as such.
- **Data-driven UI:** menu options, control keys, and screen fields must always reflect exactly what the server sends for the current screen — nothing about screen layout or available actions is hardcoded per business transaction, since Oracle can change what's available per user/facility/permission without an app update.
- **Session integrity:** only one login is active in the app at a time; ending a session (logout or exit) fully discards credentials and in-progress data before returning to Login.

## 6. Known limitations (current version)

- The OAuth client secret is embedded directly in the app for development/test convenience; see the Technical/Solution documents for the production recommendation.
- Tapping directly on a not-yet-reached field (e.g. tapping "LPN" while "Dock" is still the active field) does not automatically jump there — the operator advances one field at a time via TAB/submit, matching the field order Oracle expects. Automatic "click ahead and catch up" navigation was considered but not implemented, since skipping over a field with an unconfirmed auto-suggested value needs to be handled carefully (see Solution Document).
- Split IBLPN photos stay on the device's local storage only — there is no automatic upload/sync to any server or shared location. Retrieving them for review currently requires a manual pull off the device (e.g. via ADB, for a debug build), by design/decision, not as a gap to be fixed.
