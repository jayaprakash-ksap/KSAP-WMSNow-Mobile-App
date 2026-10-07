# Functional Specification — WMSNow Redwood Mobile

**Product:** Custom native mobile client for Oracle WMS Redwood Mobile (RF), plus a companion Admin Build UI for generating, distributing, and monitoring customer-locked builds
**Platform:** Android and Windows desktop (both actively built/distributed); iOS/macOS/Linux/web also buildable from the same Flutter codebase but not currently distributed
**Version:** 1.0
**Date:** 2026-09-28
**Project lineage:** `wmsnow_redwood_v3` is a fork of the prior `redwood_v2` codebase, created 2026-07-10 as the active development line — `v2` is kept as a frozen, already-demonstrated POC snapshot and is not modified further. Sections §4.1-§4.9 below describe the base RF client and its first two enhancements (Truck Temp, Split IBLPN photo capture), carried over from the initial `v3` fork; §4.10 onward describe every customer-specific customization and platform capability added since. §7 covers the Admin Build UI, a separate Python/Flask tool used internally to generate, distribute, and monitor these builds — not part of the Flutter app itself.

---

## 1. Purpose

Oracle Custom App is a native mobile client that replicates the Oracle WMS **Redwood Mobile RF** experience — the same screen-by-screen, keyboard-driven workflow warehouse operators use on rugged handheld scanners — while adding enhancements Oracle's standard client does not provide: scan/date-entry helpers on every field, and a growing set of customer-specific customizations (§4.10 onward) such as Truck Temp capture, Proof of Delivery, trailer-driven guided task flows, serial-based receiving, and GS1 barcode handling — each independently toggleable per customer build. A companion Admin Build UI (§7) generates, distributes, and monitors these builds.

Oracle's Redwood Mobile API (`get_next_rwmobile_page`) is documented for native app integration (Android/iOS/Java) but not for browser-based clients, which is why this is a purpose-built native app rather than a wrapped web view.

## 2. Actors

- **Warehouse operator** — logs in with their WMS username/password and performs RF transactions (receiving, putaway, picking, cycle counts, etc.) exactly as they would on a standard RF gun, plus whichever customer-specific customizations (§4.10 onward) are enabled for their build.
- **WMS administrator** — configures facilities, companies, and user permissions in Oracle WMS; not a direct user of this app, but its behavior (active-session handling, permissions) affects what the app can do. Role-based access control for warehouse operators (picker/receiver/supervisor, etc.) is enforced entirely on this side, inside Oracle WMS itself — the app has no access-control logic of its own and simply renders whatever menu/screens Oracle's RF API returns for the logged-in user.
- **Build administrator** — uses the companion Admin Build UI (§7) to generate customer-locked builds, manage the Companies/Instances/Users master data, and monitor uploaded session logs and captured images. Two roles: **builder** (can generate builds, download artifacts, manage notification emails) and **viewer** (read-only: history, logs, images). An account can additionally be scoped to a single company, restricting it to that customer's data only.

## 3. Scope

### In scope
- OAuth2 login against the WMS instance.
- Rendering every screen type the RF API can return: main menu, entry dialogs, informational dialogs, and generic data-entry/list screens — driven entirely by what the server sends, not hardcoded per screen.
- All RF control-key actions available from the menu: Exit App, Previous Screen, Change Language, Change Facility, Change Default Printer, Restrict Company, Page Up/Down (exact set varies per screen, per the server's own response).
- Transparent handling of Oracle's "another active session" check that can occur during login/navigation — the operator should never need to answer a Yes/No prompt for this; the app resolves it automatically.
- Barcode scanning support for rugged Zebra/Honeywell devices (via keystroke injection) and for standard devices with a camera (via an in-app scanner) — a scan icon is available on every text entry field, app-wide.
- A calendar date-picker on every date-type entry field, so the operator can pick a date instead of typing it.
- A set of customer-specific customizations, each independently toggleable per build/device (see §4.10 onward for each): Truck Temp capture; Proof of Delivery (POD) signature/photo capture; Split IBLPN photo capture; Wooden Pallet Task, Mix Area Task, and Full Pallet Task trailer-driven guided flows; Serial Receiving, Combined (Serial/Non-Serial) Receiving, and Pick And Allocate - Serial; Multi Field Barcode - GS1 handling on a standard receiving screen.
- A Feature Settings screen where an operator (on an unlocked/dev build) or a build administrator (at build time, on a locked build) controls which of the above customizations are active.
- License expiry enforcement: a build-locked expiry date blocks login once passed, with no date/countdown ever shown to the operator.
- Local session activity logging on-device, with automatic background upload to the Admin Build UI (at login, at logout, and periodically during a session) when a log server is configured for the build.
- A companion Admin Build UI (§7) for generating customer-locked Android/Windows builds, browsing build history and comparing two builds' code/config, browsing uploaded session logs and captured images, and distributing builds to customer devices via QR code/URL.

### Out of scope (current version)
- Offline operation for the base RF client (the app requires a live connection to the WMS instance for every screen transition). Serial/Non-Serial/Combined Receiving are a partial exception: they capture scans locally and require an explicit operator-triggered Sync before that data reaches WMS, but still require connectivity to perform the Sync itself.
- Any RF transaction logic beyond what the server itself drives — the app does not implement business rules, only rendering and request forwarding, except within the bounded, explicitly-scoped customizations listed above.
- Multi-user/multi-session management within the app itself (one login session at a time, matching how a single RF handheld is used).
- Role-based access control implemented by this app — access control for warehouse operators is entirely Oracle WMS's own responsibility (see §2).

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
- **Restricted to one specific customer receiving transaction only (as of v3)** — earlier this field appeared on every screen with an LPN-labeled field (most of the RF menu); it's now scoped to just this one receiving transaction.
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
- Photos are saved to the app's own local storage on the device, and automatically uploaded to the Admin Build UI's Images page (§7.6) when an Upload Server is configured for the build; otherwise they stay device-local only.

### 4.10 Proof of Delivery (POD)
- Adds a **POD** entry to the main menu (only shown when this customization is enabled).
- The operator picks an order from a searchable dropdown (order number or customer name), captures a signature on-screen, and optionally attaches one or more delivery photos.
- Signature and photos are uploaded to the Admin Build UI's Images page when an Upload Server is configured, alongside Split IBLPN photos.

### 4.11 Wooden Pallet Task
- Augments Oracle's standard "Execute Wooden Pallet Tasks" screen rather than replacing it — the real RF screens/dialogs still drive the transaction.
- The operator scans a trailer number in a client-side-only field shown first on screen; the app looks up that trailer's load, order, and task list via `lgfapi` and displays them before the operator starts the real task.
- Once a task is selected, the app pre-fills the SKU, Qty, and OBLPN fields on the real screens that follow, from the same lookup, so the operator confirms rather than re-keys them.

### 4.12 Mix Area Task
- Augments Oracle's "Execute Task Mix Area (new)" screen. Unlike Wooden Pallet Task, the real task-list buttons stay on screen and are filtered in place by a scanned trailer, rather than being replaced by a separate table.
- Same trailer → load → order → task lookup as Wooden Pallet Task, and the same SKU/Qty/OBLPN pre-fill once a task is selected.
- On Drop Location submission, the app prints a shipping label via `lgfapi`'s print/label/shipping call, using this customer's own Label Designer template and printer (configured per build, not hardcoded — see §7.2).

### 4.13 Full Pallet Task
- Augments Oracle's "Execute Full Pallet Task" screen across a chained sequence of five real screens: trailer lookup, a vehicle-eligibility Approve/Reject questionnaire, then a guided pick-by-SKU/Pallet/LPN flow.
- On Reject, an email notification (Trailer Eligibility Form) is sent via a separate mail-relay service, so a supervisor is notified without the device itself needing SMTP credentials.

### 4.14 Serial Receiving
- Adds a serial-driven receiving flow to the main menu: the operator scans each expected serial number, confirms a manual putaway location per LPN, then explicitly triggers **Sync** to commit the receipt and putaway to WMS.
- Scans are captured and validated locally (duplicate/unknown-serial detection) before Sync, so a batch of scans can be reviewed and corrected before anything reaches WMS.

### 4.15 Combined Receiving (Serial / Non-Serial)
- A single receiving screen with a Serial / Non-Serial toggle: serial-scan receiving (as in §4.14), or shipment-line receiving with an entered quantity per LPN, including partial/short receipt handling.
- Same local-capture-then-Sync model as Serial Receiving — nothing reaches WMS until the operator explicitly syncs.

### 4.16 Pick And Allocate - Serial
- On Oracle's standard "Pick And Allocate" RF screen, adds a Serial Nbr scan field between the item description and the OBLPN field.
- Scanning a serial looks up its inventory via `lgfapi` and pre-fills the Location, IBLPN, Qty, and Serial Nbr fields on the screens that follow — the operator still confirms/presses Enter on each, matching the app's existing pre-fill-not-auto-submit pattern used elsewhere.

### 4.17 Multi Field Barcode - GS1
- On a standard Oracle receiving screen, corrects a combined LPN+Item GS1-128 barcode so it splits correctly under WMS's own native Multi Field Barcode configuration (a fixed-width padding correction applied only to a scan that already matches this exact barcode shape — anything else is left untouched).
- On the same screen, extracts Qty and Expiry Date from a second barcode that combines them with GTIN/Variant, so the operator doesn't have to key those values by hand.
- Which real screen(s) and fields this applies to is customer-specific configuration, decided when the customization is scoped to a customer (see §7.2) — not a setting the operator sees or controls.

### 4.18 Feature Settings
- Reached from the Login screen's top-right icon (alongside Manage Environments). Lists every customization in §4.10-§4.17 (plus Truck Temp and Split IBLPN photo capture) as an independent on/off switch.
- On an unlocked/dev build, every switch is operator-editable and takes effect immediately, with no restart required.
- On a build-locked customer build, every switch instead reflects what was baked in at build time (§7.2) and is shown read-only — the operator cannot enable a customization that wasn't purchased/configured for their build, nor disable one that was.

### 4.19 License expiry
- A customer-locked build has a fixed expiry date baked in at build time. Once the device's clock (or the last date the app has genuinely observed, whichever is later — a deterrent against simply rolling the clock back) passes that date, login is blocked.
- No date, countdown, or any other hint of the expiry is ever shown to the operator at any point before or after expiry — this is an explicit design decision, not an oversight.
- A separate, internal email notification schedule (30/14/7/1/0 days remaining) alerts KSAP staff via the Admin Build UI (§7.7) so a renewal build can be generated and distributed before an active customer is actually blocked.

### 4.20 Session activity logging
- Every login session is recorded to a local log file on-device (RF requests/responses, key operator actions), viewable via a bug-report icon in the app bar (the existing debug sheet, §8 of the Technical Specification).
- When a Log Server is configured for the build, the same log data uploads automatically in the background — at login, at logout, and periodically (every 30 seconds) during an active session — so a session's activity is visible from the Admin Build UI (§7.5) without needing physical access to the device.

## 5. Non-functional requirements

- **Responsiveness:** every operator action should reflect on screen within a few seconds under normal network conditions; requests that don't respond within 25 seconds are treated as a network problem and reported as such.
- **Data-driven UI:** menu options, control keys, and screen fields must always reflect exactly what the server sends for the current screen — nothing about screen layout or available actions is hardcoded per business transaction, since Oracle can change what's available per user/facility/permission without an app update.
- **Session integrity:** only one login is active in the app at a time; ending a session (logout or exit) fully discards credentials and in-progress data before returning to Login.

## 6. Known limitations (current version)

- The OAuth client secret is embedded directly in the app binary (baked in per customer build on a build-locked distribution, see §7.2) rather than exchanged via a backend the app calls — see the Technical/Solution documents for the production recommendation on this point.
- Tapping directly on a not-yet-reached field (e.g. tapping "LPN" while "Dock" is still the active field) does not automatically jump there — the operator advances one field at a time via TAB/submit, matching the field order Oracle expects. Automatic "click ahead and catch up" navigation was considered but not implemented, since skipping over a field with an unconfirmed auto-suggested value needs to be handled carefully (see Solution Document).
- Split IBLPN photos, POD signatures/photos, and session logs only leave the device if an Upload/Log Server is configured for that build (§7.2) — on a build with none configured, they stay device-local only, with no automatic upload.
- Serial/Non-Serial/Combined Receiving capture data locally and require an explicit operator-triggered Sync — data entered but not yet synced is not visible in WMS, and is lost if the app's local storage is cleared before a Sync completes.

## 7. Admin Build UI (companion tool)

A separate Flask (Python) web application, run internally, used to generate customer-locked builds of the mobile app, distribute them, and monitor what's happening on deployed devices. Not installed on any warehouse device — reached by a build administrator via a browser.

### 7.1 Authentication and access control
- Username/password login (server-side hashed). Two roles: **builder** and **viewer** (§2). An account can be scoped to exactly one company, restricting every page (build history, logs, images*) to that customer's data only; an unscoped account sees all companies.
- *Captured images currently cannot be filtered by company (filenames don't carry customer/instance context) and are hidden entirely from any company-scoped account as a result, rather than risk showing one customer's images to another's account.

### 7.2 Generate Build
- A builder picks a Company (from the Companies master list, §7.3), one or more Instances (WMS environment - domain, Oracle instance code, OAuth client ID/secret - from the Instances master list, §7.3), which customizations (§4.10-§4.17, plus Truck Temp/POD/Split IBLPN) to bake in, which platform(s) to build (Android APK, Windows desktop, or both), a License Expiry Date, and optionally a Log Server URL/token.
- Generating a build compiles the app with all of the above baked in at compile time via Flutter's `--dart-define` mechanism — once built, none of it (environment, credentials, which customizations are active, expiry date) can be changed or discovered by the customer's operator; the Manage Environments and Feature Settings screens both become read-only on that build.
- Screen-name/print-config matching for customizations that need to recognize one customer's own Oracle screen naming (Truck Temp, Multi Field Barcode - GS1, Mix Area Task's print settings) is supplied automatically from a developer-maintained table, not typed in on this form — see the Technical Specification §9 for why.
- A **Rebuild** action on any past build pre-fills this form from that build's own record, for a fast renewal/upgrade.

### 7.3 Companies and Instances
- **Companies** is the master customer list — defined once, picked (not retyped) everywhere else in the tool.
- **Instances** is the master WMS-environment list per company (domain, Oracle instance code, OAuth client ID/secret) — likewise defined once and picked on the build form, replacing what used to be free-typed per build.

### 7.4 History and Compare
- Every successful build is recorded: which environments/customizations/platforms were included, when, and by whom. Two builds can be compared side by side — environment/customization differences, and a code-level diff of the app source between the two builds (a plain snapshot comparison, not git-based).

### 7.5 Logs
- Browsable session activity logs uploaded from devices (§4.20), filterable by customer/instance/date, viewable as an expandable per-entry table (timestamp, category, request/response detail).

### 7.6 Images
- Browsable captured POD signatures/photos and Split IBLPN photos (§4.9-§4.10) uploaded from devices, filterable by type and date, with a lightbox preview and per-file download.

### 7.7 License expiry notifications
- A configurable list of internal notification email addresses receives an alert as any customer's current build approaches its License Expiry Date (§4.19) — at 30, 14, 7, 1, and 0 days remaining — so a renewal build can be generated ahead of the app actually blocking login.

### 7.8 Distribution Links
- A build administrator generates a permanent, tokenized URL (and matching QR code) per company/instance that always serves whichever build is currently marked "active" — the customer's IT contact or operator scans the QR code or opens the link on any device (including the RF handheld itself) to download the latest build, with no login required for the download itself.
- A new matching build normally auto-advances the link automatically; a build administrator can instead roll back to a specific earlier build (pinning it, pausing auto-advance) if a new build needs to be pulled, and later resume auto-advance.
