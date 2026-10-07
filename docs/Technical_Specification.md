# Technical Specification — WMSNow Redwood Mobile

**Date:** 2026-09-28 (originally 2026-07-10; sections §4.1-§4.8 describe the base RF client and its first two customizations as originally built, §9 onward describe everything added since, including the companion Admin Build UI)
**Codebase version referenced:** `lib/`, `tools/` (Admin Build UI and build tooling) as of this date
**Project lineage:** Forked from the prior `redwood_v2` codebase on 2026-07-10 as the active development line (see `docs/Solution_Document.md` §2.12 for the fork mechanics: package/app renaming so both builds coexist on one device). `v2` remains untouched as the demonstrated POC snapshot.

---

## 1. Technology Stack

| Layer | Choice |
|---|---|
| Framework | Flutter (Dart SDK `>=3.4.0 <4.0.0`) |
| HTTP client | `package:http` (`^1.2.0`) |
| Barcode scanning | `package:mobile_scanner` (`^7.4.2`, upgraded from `^5.2.3`) — camera-based; rugged Zebra/Honeywell devices use DataWedge keystroke injection instead, requiring no app-side scanning code. Wired into a scan icon on every text entry field app-wide (`_EntryView` and `_ScreenView`), not just server-marked barcode fields. |
| Photo capture | `package:image_picker` (`^1.1.2`) — launches the native camera app for a one-off photo (Split IBLPN, POD) |
| Local file storage | `package:path_provider` (`^2.1.4`) — resolves the app's own private documents directory for saving captured photos and session logs |
| Local file sharing | `package:share_plus` (`^10.1.2`) — lets the operator pull files out of the app's private storage via the OS share sheet, for a non-rooted release build |
| Local key-value persistence | `package:shared_preferences` (`^2.3.2`) — environment list, feature-flag toggles, on an unlocked/dev build only (both are compile-time-fixed and read-only on a build-locked customer build) |
| Lints | `flutter_lints` (`^4.0.0`) |
| Backend | Oracle WMS Cloud, Redwood Mobile RF API (`get_next_rwmobile_page`) + `lgfapi` REST entity API, both on a single WMS instance per environment. No application database of any kind — the app has no server-side data store of its own; every request/response round-trips directly with the customer's Oracle Cloud WMS instance. |
| Auth | OAuth2, `grant_type=password` (Resource Owner Password Credentials) against the WMS's own token endpoint |
| Admin Build UI | Python 3 / Flask, server-rendered (Jinja2) — see §9. Data persisted as flat JSON files (`tools/admin_build_ui/data/*.json`), not a database. |

Target platforms actually built and distributed: **Android** (primary, rugged-device use case) and **Windows desktop** (both produced by the same build pipeline, §9.2). iOS/macOS/Linux/web are buildable from the same Flutter codebase but not currently distributed to any customer.

## 2. Project Folder Structure

```
wmsnow_redwood_v3/
├── lib/
│   ├── main.dart                  # App entry point, all UI (Login + Runtime screens, widgets), session/retry logic,
│   │                               # and most customization injection logic (§7)
│   ├── config/
│   │   └── app_config.dart        # Environment, OAuth app credentials, derived URLs, every customization's
│   │                               # match/config constants, feature-flag model, build-lock parsing, license expiry
│   ├── services/
│   │   ├── auth_service.dart              # OAuth2 login/refresh, holds the current Session
│   │   ├── rwmobile_service.dart          # All Redwood Mobile RF API + lgfapi calls, request/response history
│   │   ├── pod_service.dart               # POD order lookup/submit
│   │   ├── wooden_pallet_service.dart     # Wooden Pallet Task trailer→load→order→task lookup
│   │   ├── mix_area_task_service.dart     # Mix Area Task lookup + print/label/shipping call
│   │   ├── full_pallet_task_service.dart  # Full Pallet Task trailer/order lookup
│   │   ├── pick_allocate_service.dart     # Pick And Allocate - Serial inventory lookup
│   │   ├── serial_receiving_service.dart, nonserial_receiving_service.dart  # Receiving API calls
│   │   ├── receiving_store.dart, nonserial_receiving_store.dart  # Local capture-then-Sync state
│   │   ├── receiving_sync.dart, nonserial_receiving_sync.dart    # The Sync action itself
│   │   ├── log_service.dart, log_upload_service.dart  # Local session logging + background upload
│   │   ├── upload_service.dart            # Captured photo/signature upload
│   │   └── email_relay_service.dart       # Full Pallet Task reject-email relay call
│   ├── pod/, receiving/, logs/    # Screen widgets for POD, the receiving customizations, and the on-device log viewer
├── docs/                          # This document set
│   ├── Functional_Specification.md
│   ├── Technical_Specification.md
│   └── Solution_Document.md
├── android/                       # Flutter-generated Android project (Gradle, manifest, launcher icons)
├── ios/                           # Flutter-generated iOS project (Xcode workspace, Info.plist) - not currently distributed
├── linux/ macos/ web/             # Flutter-generated platform scaffolding for those targets - not currently distributed
├── windows/                       # Flutter-generated Windows project - actively built and distributed (§9.2)
├── test/                          # Automated tests (store/sync logic, login-screen widget test)
├── tools/                         # Server-side build tooling and the Admin Build UI (§9) - Python, never shipped to any device
│   ├── build_lib.py               # Shared build logic (dart-define assembly, history, per-customer overrides)
│   ├── generate_customer_build.py # CLI wrapper around build_lib.py
│   └── admin_build_ui/            # The Flask app itself (§9.1) - app.py, templates/, static/, data/
├── pubspec.yaml                   # Package name, dependencies, SDK constraint
├── pubspec.lock                   # Resolved dependency versions
├── analysis_options.yaml          # Lint configuration (flutter_lints)
└── README.md                      # Setup instructions + confirmed request protocol summary
```

`lib/main.dart` and `lib/config/app_config.dart` remain the core of the app (session/retry engine, dynamic rendering, and every customization's matching logic); each customer-specific customization beyond the first two (Truck Temp, Split IBLPN) has its own dedicated service file under `lib/services/` for its own API calls, keeping `main.dart` limited to UI/injection wiring rather than growing a new API client inline per feature.

## 3. Architecture Overview

```
LoginScreen ──(OAuth2 login)──> AuthService ──> RuntimeScreen ──> RwmobileService ──> Oracle WMS
                                                      │                                (RF + lgfapi)
                                                      └── _send() retry/session engine
                                                             │
                                                    Dynamic widget rendering
                                                    (_MenuView / _EntryView /
                                                     _InfoView / _ScreenView)
```

- **`AuthService`** owns exactly one `Session` (access token, refresh token, username). A fresh `AuthService` is created per login (in `_LoginScreenState`); logging out discards the whole `RuntimeScreen`/`AuthService` pair via Flutter navigation (`pushAndRemoveUntil` back to a new `LoginScreen`), which is what actually clears all session state — there's no explicit `session = null` reset needed.
- **`RwmobileService`** is the single chokepoint for every Redwood Mobile RF call and every `lgfapi` call. It holds:
  - A persistent `http.Client` (reused across calls — avoids a fresh TCP/TLS handshake per request, important since a single conflict-resolution cycle can involve several sequential calls).
  - A minimal cookie jar (`_cookie`): captures and resends the `Set-Cookie` header Oracle's htmlrf endpoint returns (a load-balancer sticky-route cookie, `X-Oracle-HTMLRF-LBS-Route`), mirroring default browser/Postman behavior since Dart's `http.Client` does not do this automatically.
  - `history`: every request/response pair for the session (bounded to 200), surfaced in the on-device debug sheet.
- **`_RuntimeScreenState`** (in `main.dart`) is the app's controller: it owns the current session identity (`clientid`/`htmlrfid`), the current page content, per-session field memory (for the Truck Temp lookup), and the `_send()` method that wraps every RF call with conflict-detection/retry logic.
- **Dynamic rendering widgets** (`_MenuView`, `_EntryView`, `_InfoView`, `_ScreenView`) each take the raw server response `content` and render it — none of them hardcode business-screen layouts; they interpret the generic `type`/`page_content`/`ctrl_keys` shape the server sends for any screen.

## 4. API Integration

### 4.1 Endpoints

| Purpose | URL |
|---|---|
| OAuth2 token | `{domain}/{instance}/api/oauth2/token/` |
| Redwood Mobile RF | `{domain}/{instance}/wms/lgfapi/v10/htmlrf/get_next_rwmobile_page` |
| lgfapi entity (Truck Temp, POD, Wooden Pallet/Mix Area/Full Pallet Task, Pick And Allocate - Serial lookups/saves) | `{domain}/{instance}/wms/lgfapi/v10/entity/{entity}` |
| lgfapi print/label (Mix Area Task shipping label) | `{domain}/{instance}/wms/lgfapi/v10/print/label/shipping` |
| Legacy `api` surface (Wooden Pallet Task's `assign_and_load_oblpn` only — form-urlencoded/XML, unlike every other call here) | `{domain}/{instance}/wms/api/...` |

`domain`/`instance` are configured per environment via `AppConfig` (no seed value is baked into shared source - see Environment Manager on first run).

### 4.2 Authentication

`POST` to the token endpoint with HTTP Basic auth (`clientId:clientSecret`, base64-encoded) and form-encoded body:
- Login: `grant_type=password&username=...&password=...`
- Refresh: `grant_type=refresh_token&refresh_token=...`

Response: `{access_token, refresh_token, expires_in, token_type, scope}`. The access token is sent as `Authorization: Bearer <token>` on every subsequent call. On a `401`, `RwmobileService._post()` transparently calls `AuthService.refresh()` once and retries the same request with the new token — this is independent of RF session identity (see §4.4) and cannot desynchronize it.

### 4.3 Redwood Mobile RF request/response shapes (confirmed via live testing, 2026-07-09)

All requests are `POST` to the single `get_next_rwmobile_page` endpoint; the shape of the JSON body determines what's being submitted:

| Interaction | Request body |
|---|---|
| Initial handshake (once per login) | `{}` |
| Menu selection / any entry field submit (facility code, company code, LPN, SKU, Qty, Batch, Expiry, free text, etc.) | `{"clientid": "<id>", "htmlrfid": "...", "env_name": "<instance>", "keyboard_input": "<value>"}` |
| Control/action key (Change Facility, Restrict Company, Page Up/Down, Previous Screen, End LPN, Exit, etc.) | `{"clientid": "<id>", "htmlrfid": "...", "action_keys": "<key>"}` |
| Field-cursor advance with no value (multi-field screens only) | `{"clientid": "<id>", "htmlrfid": "...", "env_name": "<instance>", "action_key": "TAB"}` — note `action_key` is **singular** here, unlike every other action-key call |
| Yes/No ("another active session") answer | `{"clientid": "<id>", "htmlrfid": "...", "action_keys": "A"}` (yes) or `"X"` (no) |

Notes:
- `env_name` is the actual instance name, not empty — this holds for every `keyboard_input` submission including facility code and company code. There is no dedicated field for facility/company code; they use the same generic `keyboard_input` shape as any other entry.
- `clientid` is included on **every** request now, including `keyboard_input` — simple screens (menu, facility/company code) worked without it, but a multi-field transactional screen could not reliably get past a recurring session conflict without it. One consistent shape is used everywhere rather than special-casing by screen type.
- `action_keys` values are bare letters or `F2` (e.g. `"F"` for Change Facility), never a `"Ctrl-"`-prefixed string, even though the on-screen label reads e.g. "Ctrl-F: Change Facility."
- The key that means "Previous Screen" is **not fixed** — it must be read from the current screen's own `ctrl_keys` array each time (commonly `W`, but some screens use `F2`). The client never hardcodes this, and remembers the last known value across responses that don't carry their own `ctrl_keys` at all (see §4.6).
- `sendTab()`'s request only moves the cursor forward with **no value**. Submitting a real value via the normal `keyboard_input` call already advances the cursor to the next field on its own (and can trigger server-side auto-population of other fields as a side effect) — TAB is only for explicitly skipping a field that's genuinely being left empty. Attempting to TAB past a field that has an unconfirmed, server-suggested value fails with a `dialog_type: "info"` / `"Required Field"` response; that value must be explicitly (re-)submitted via `keyboard_input` first.

### 4.4 Response envelope and session identity

Every response includes `htmlrfid` and (except for the initial `{}` handshake response, where it's also present) `clientid` at the top level, alongside a `type` (`mainmenu`, `dialog`, or `page`) and a `content` object holding `headers`, `ctrl_keys`, and `page_content`.

**Session identity tracks the latest response, continuously.** `_RuntimeScreenState._captureSession()` updates its `clientid`/`htmlrfid` from every single response, and every subsequent request uses whatever was most recently captured. This was arrived at after extensive live testing (see `docs/Solution_Document.md`) showed that Oracle's own echoed `clientid`/`htmlrfid` do change across a session, and that always adopting the latest value is what avoids "this user session has expired" errors — an earlier design that froze identity at login was tried first and reverted.

### 4.5 The "another active session" conflict and its resolution

A subset of responses come back as a `dialog` with `dialog_type: "yesno"` and `dialog_message: "Another active session exists for same username. That session will end. Proceed?"`. This is confirmed to be routine, expected behavior of this Oracle environment — it can occur on the very first action after a fresh login on a never-before-used account, and does not indicate an application bug.

`_RuntimeScreenState._send()` handles this entirely internally, for every occurrence (never surfaced to the UI):

1. Send the original request.
2. If the response is a yesno dialog, send `action_keys: "A"` using the currently tracked `clientid`/`htmlrfid`, with a short pacing delay (400ms) between repeated attempts.
3. Repeat step 2 up to `_maxYesAttempts` (currently 6) times — clearing this conflict has been observed to need anywhere from 1 to 3+ consecutive "A" answers, unpredictably; the bound exists so a genuinely stuck session doesn't retry forever (an earlier, much larger bound of ~300 attempts was found to likely be manufacturing its own runaway conflict rather than draining a real backlog).
4. Once cleared, a successful "A" response is itself already equivalent to the main menu — so for an ordinary action (which wanted a *specific* result, not the generic main menu), the original request is replayed once more to get its real result. The one exception is the initial `{}` bootstrap handshake: replaying `{}` here would create a second, orphaning session, so it is never replayed — the cleared response (already the main menu) is used directly.
5. If still unresolved after the bound is reached, a one-time snack-bar message tells the operator to ask a WMS admin to check active RF sessions for their account.

### 4.6 Dynamic screen rendering

- **Control-key actions are shown from one universal "Actions" menu in the shared `AppBar`** (top-right, added 2026-07-09), populated from whatever the *current* response's `content.ctrl_keys` contains — every screen type gets the same menu (mainmenu, dialogs, and generic transaction screens alike). The display label strips the `"Ctrl-X: "` prefix off `ctrl_keys[i].value`; the actual submitted key is taken verbatim from `ctrl_keys[i].key`. (Earlier, this menu only existed inside the mainmenu-specific widget, so a generic multi-field screen had no UI path to its own control keys at all — e.g. "Ctrl-E: End LPN" was unreachable even though the server offered it.)
- **`mainmenu`** responses: `content.page_content` is a list of rows, each containing `menu_button` items (`{name, index}`) rendered as a tappable list.
- **`dialog`** responses: `content.dialog_type` selects the widget — `entry` or `barcode` (identical shape; text field + Submit/Cancel), `info` (message + OK), or `yesno` (never reaches the UI; see §4.5).
- **`page`** (generic screen) responses: `content.page_content` is flattened into a list of items, each rendered per its own `type`:
  - `label` → plain text.
  - `button` → a tappable card (used e.g. for the Restrict Company company list); tapping submits that item's `index` immediately via `keyboard_input`.
  - `entry` → see §4.6.1 below — no longer a flat list of independently-editable boxes.

None of the above hardcodes a business-screen layout — every screen the server can return, current or future, renders correctly as long as it uses this same generic shape.

#### 4.6.1 Multi-field sequential entry (`_ScreenView`)

Oracle tracks a single current-field cursor server-side on multi-field screens, exactly like a physical RF terminal — confirmed live end-to-end on a real receiving transaction (Dock → Shipment → LPN → SKU → Qty → Batch → Expiry → End LPN, all real data, all committed successfully). `_ScreenView` reflects this directly:

- The field the server marks `"focus": true` (falling back to the first entry field if none is marked) is the only one that's genuinely editable, with a real blinking cursor (an explicit `FocusNode` per field, re-focused via `WidgetsBinding.instance.addPostFrameCallback` every time the active field changes — a one-shot `autofocus` does not work here since the same `_ScreenView` State persists across the whole transaction).
- Every other field is rendered read-only, showing whatever value the server most recently reported for it (including auto-populated values, e.g. Shipment/Shipment Type filling in right after Dock is submitted).
- Each entry field has its own small TAB icon-button (enabled only on the current field) that is **smart**: if the field currently has text in it, pressing TAB submits that value (via `keyboard_input`, which auto-advances on its own); only if the field is genuinely empty does it send the bare `action_key: "TAB"` skip request. This avoids silently discarding typed input that the operator intended to submit.
- A field's displayed text is only resynced from the server's value when it is **not** the current field, or the moment it **just became** current in this exact response (tracked via a `previousCurrentLabel` comparison) — this second case was a real bug: a field auto-populated in the same response that also hands it focus (e.g. Shipment) was previously never displayed, because "is current" was wrongly treated as synonymous with "the user is actively typing here, don't touch it."
- Truck Temp injection (§4.7) is tied specifically to the LPN-labeled field's submission now, not unconditionally to whichever field happens to be submitted.

#### 4.6.2 Widget-state-reuse pitfalls (general lesson, not just this screen)

Two real bugs came from the same underlying Flutter behavior: a `StatefulWidget` with no explicit `key`, placed in the same structural tree position across rebuilds, has its `State` **reused** (not recreated) even when the data it represents has completely changed:

- `_EntryView` (used for `entry`/`barcode` dialogs) had no key, so two consecutive but semantically distinct prompts (e.g. Batch Nbr immediately followed by Expiry Date) shared the same text controller — whatever was typed for the first prompt was still sitting in the field for the second. Fixed with `key: ValueKey('$_renderCount-$_htmlrfid')`, where `_renderCount` is a monotonically-incrementing counter bumped every time a new response is rendered — a deterministic guarantee of a fresh key per response, not reliant on `htmlrfid` happening to differ (which it normally does, but isn't guaranteed).
- The "Previous Screen" key lookup (§4.3) was recomputed fresh from every response and fell back to a hardcoded `"W"` whenever the current response had no `ctrl_keys` at all — which info/error dialogs (e.g. `"Invalid format"`) typically don't. On a screen whose real key was `"F2"`, this meant dismissing an error silently sent the wrong key, and Oracle just re-returned the identical error unchanged. Fixed by persisting the last known-good key across responses and only updating it when a response actually provides a fresh match.

#### 4.6.3 Scan and date-picker helpers on every field (v3)

`mobile_scanner` was already a pubspec dependency in v2 but unused. As of v3:
- A reusable `_scanBarcode(context)` helper pushes a full-screen `_BarcodeScannerScreen` (a bare `MobileScanner` widget) and pops the route with the first decoded `Barcode.rawValue`. Wired into both `_EntryView` (single-field dialogs — shown unless the field is `masked`) and each entry row in `_ScreenView` (shown only when that field `isCurrent`, matching the existing TAB/submit button gating).
- A `_pickDate(context, controller)` helper calls `showDatePicker` and writes the result back into the field as `MM/DD/YYYY`. Shown additionally (alongside the scan icon) whenever a field's label/prompt text contains "date" (`_looksLikeDateField()`), case-insensitively — the RF API has no dedicated date field type, so this is a text-based heuristic, consistent with how the Truck Temp/photo-capture injections already key off label/tag text.
- Requires `<uses-permission android:name="android.permission.CAMERA"/>` in `AndroidManifest.xml` (previously absent — added for `mobile_scanner`'s actual first use).

### 4.7 Truck Temp enhancement (lgfapi)

Configured via `AppConfig`'s `enh*` constants, substantially reworked in v3:

- **Scoped to one specific transaction.** `truckTempPageTitleMatch` (baked in per build via `WMSNOW_TRUCK_TEMP_PAGE_TITLE_MATCH` — the real transaction name is that customer's own screen naming, so it's never a literal in shared source) is matched against `_RuntimeScreenState._currentTransactionName` — the name of whichever mainmenu item was tapped to reach the current screen, captured in `_MenuView`'s `onSelect(index, name)` callback and held until the next mainmenu tap. Previously the Truck Temp field appeared on *every* screen with an `"lpn"`-labeled entry field (most of the RF menu); this restricts injection to the one intended transaction. The camera-capture feature (§4.8) deliberately does **not** use this same transaction-name scoping — see that section for why.
- **Field renamed**: `enhSaveField` is now `"cust_decimal_1"` (was `"cust_field_1"`, an initial guess) — confirmed against the customer's own reference as the correct decimal-typed custom field for this value.
- **Lookup scoped by facility and company, not shipment_nbr alone.** `RwmobileService.findEntity()` was generalized from a single `(queryParam, value)` pair to `Map<String, String> query`, ANDed together as query-string filters. The Truck Temp lookup now passes three: `enhLookupQueryParam` (`"shipment_nbr"`), `enhFacQueryParam` (`"facility_id__code"`), and `enhCompQueryParam` (`"company_id__code"`) — live-tested that `shipment_nbr` alone is not guaranteed unique across facility/company. The facility/company values come from `content.headers.fac_code`/`comp_code` on the current response (captured into `_RuntimeScreenState._facCode`/`_compCode`, persisted across responses the same "only overwrite on a fresh non-empty value" pattern as `_previousScreenKey` — not every response repeats `headers`).
- **PATCH still targets `/entity/ib_shipment/{id}/`, not a query-filtered collection URL** — live-tested 2026-07-10 that PATCHing the same query-filtered shape used for the GET returns `405 METHOD_NOT_ALLOWED`; the GET-then-PATCH-by-id pattern from v2 was correct and is unchanged.
- **Lookup timing and auto-lock.** The lookup (`_lookupTruckTemp`) fires the moment the Shipment field is confirmed (`onSubmit` callback, label matching `enhLookupLabelMatch`), not at save time — this is also when the shipment's `id` is cached (`_truckTempShipmentId`) for later reuse. If `cust_decimal_1` already has a value, the field displays it **read-only** (`_truckTempLocked = true`, `_truckTempExistingValue` holds the value) — `_ScreenView`'s injected field syncs its controller text from this and sets `readOnly: true`; `submitCurrent()`'s `injectsTruckTemp` check requires `!widget.truckTempLocked`, so an already-recorded value is never re-submitted.
- **Save deferred to End LPN, not the LPN field's own submission.** Submitting the LPN field only captures the typed value into `_RuntimeScreenState._pendingTruckTemp` (via the `onSubmit` callback's `injectedTemp` parameter) — it does **not** call `RwmobileService.patchField()` at that point. The actual PATCH fires inside the AppBar Actions `PopupMenuButton`'s `onSelected`, specifically when the selected key matches whichever `ctrl_keys` entry's value contains "end lpn" (looked up per-response the same way as `previousScreenKey`, stored in a local `endLpnKey` — not persisted across responses, since End LPN is only ever pressable while it's actually showing in the current screen's own Actions menu). `_saveTruckTemp()` now uses the cached `_truckTempShipmentId` directly rather than re-querying `findEntity()`.
- All Truck Temp state (`_truckTempShipmentId`, `_truckTempExistingValue`, `_truckTempLocked`, `_pendingTruckTemp`) resets to blank whenever a fresh mainmenu item is tapped (same `onSelect` callback that sets `_currentTransactionName`).
- If no shipment has been entered yet, or it isn't found, the operator is told why the save didn't happen via a snackbar, rather than failing silently.

### 4.8 Split IBLPN photo capture (lgfapi-free, local only — v3)

- `image_picker`'s `ImagePicker().pickImage(source: ImageSource.camera)` launches the native camera app for a one-off photo; the returned `XFile` is held in `_ScreenViewState._capturedPhoto` until persisted.
- The **Capture Photo** button (`_capturePhotoRow()`) is inserted immediately before whichever entry field has `tag == AppConfig.camInsertBeforeTag` (`"to-lpn"`) — **matched on the field's `tag`, not its label text**, unlike every other injection in this app. A live debug-sheet capture of the real Split IBLPN screen (2026-07-10) showed "Move to LPN: " is actually a separate `type: "label"` page_content item, and the entry field that follows it has `label: ""` (blank) — the visible caption and the input box are two distinct items, so label-substring matching (which worked for Truck Temp's "lpn" match) silently matched nothing here. `tag` is a stable per-field technical identifier present on every entry field seen so far (e.g. `"ibdock"`, `"move-qty"`, `"scanned-batch-nbr"`) and was the fix.
- This feature is **not** scoped by `_currentTransactionName` (unlike Truck Temp) — an earlier attempt to gate it on the mainmenu button text containing "split iblpn" silently hid the button entirely, because the real button text couldn't be assumed to literally contain that substring. Since `"to-lpn"` as a tag is specific enough to be safe on its own, the transaction-name scoping was dropped for this feature rather than debugged further, to avoid the same class of fragility.
- The button is enabled regardless of which field currently has focus (unlike the scan/calendar icons in §4.6.3, which are gated to `isCurrent`) — capturing a photo isn't an edit to a specific field, so there's no reason to restrict it to the current-field cursor model.
- **Persistence is deferred to the Move to LPN field's own submission** (`submitCurrent()`, same `isMoveToLpnField` tag check): `_persistCapturedPhoto(moveToLpnValue)` resolves `getApplicationDocumentsDirectory()`, ensures a `captured_images` subfolder exists, and copies the picked file to `SplitIBLPN_<sanitized-lpn-value>_<epoch-ms>.jpg`. `_capturedPhoto` resets to `null` after a successful copy, requiring a fresh capture for the next LPN.
- Storage is local-only by design — the app's private documents directory (`/data/data/com.example.wmsnow_redwood_v3/app_flutter/captured_images/` on Android) is not reachable by a plain `adb pull` on a non-rooted device; retrieving a photo for review requires `adb shell run-as com.example.wmsnow_redwood_v3 cat app_flutter/captured_images/<file>` (works because debug builds are always `run-as`-accessible), or an equivalent on-device file manager. (Since superseded by the Upload Server/Admin Build UI - see later sections/memory - but the local-only fallback path described here is still accurate.)

## 5. Error Handling

- All network calls in `_send()` have a 25-second timeout; a timeout shows a snackbar and leaves the current screen unchanged (safe to retry).
- Non-JSON or non-2xx responses from the RF endpoint are captured into a synthetic error map (`_error`/`_status`/`_body`) rather than throwing, so a malformed response can't hang the UI — it's visible in the debug sheet for diagnosis.
- Any uncaught exception during a `_send()` call is caught and shown as a generic error snackbar.

## 6. Security Considerations

- The OAuth `clientSecret` is embedded directly in the compiled app binary — baked in per customer build (§9.2) rather than typed in by the operator. **This is not a production-grade secret-handling model** — a device binary cannot hold a confidential OAuth secret safely. The production recommendation remains: register the OAuth application as a **Public** client type, or route the token exchange through a backend the app calls instead of talking to Oracle's token endpoint directly. This applies equally to the Label Designer/screen-name matching values baked in the same way (§9.1) — none of these are treated as strongly protected, only kept out of the git-tracked source and out of any other customer's build.
- Credentials (WMS username/password) are held only in memory for the lifetime of the login session (`AuthService.session`), never persisted to disk, and are discarded on logout via object disposal (no explicit secure-storage or persistence layer currently exists — none is needed since nothing is saved between app launches).
- A build-locked customer build cannot be repointed at a different WMS instance, cannot have its customizations toggled, and cannot be used past its baked-in license expiry date (§9.5) — all three are compile-time-fixed with no in-app override path.
- The Admin Build UI (§10) requires authentication for every page except the public download landing page (`/dl/<token>`, gated by an unguessable random token, not the company/instance name) and is not currently deployed behind HTTPS by default — see §10.7 for the pre-production recommendation on this point.

## 7. Build & Run

```
flutter pub get
flutter run                         # connected Android device/emulator
flutter run -d chrome               # quick look in a browser (no scanner)
flutter build apk --debug           # build a debug APK
flutter build apk --release         # build a release APK
flutter build windows --release     # build the Windows desktop app
flutter install -d <device-id>      # install onto a connected device
```

A customer-locked build (both Android and Windows, environment/customizations/expiry baked in) is produced via `python tools/generate_customer_build.py` (CLI) or the Admin Build UI's Generate Build page (§10.2) — not by calling `flutter build` directly, since the `--dart-define` flags involved are numerous and must stay in sync between platforms.

`flutter analyze` should be run after any change to `lib/` — the project currently analyzes clean apart from a small number of pre-existing `use_build_context_synchronously`/`curly_braces_in_flow_control_structures` info-level lints, none of which are errors.

## 8. Testing Approach

- **`test/`** contains automated tests for the two most business-logic-heavy pieces of client-side state — `receiving_store_test.dart` and `nonserial_receiving_store_test.dart` (Serial/Non-Serial Receiving's local capture-then-Sync store: partial receipt, split lines, excess/short handling, sync gating) — plus `widget_test.dart` (a smoke test confirming the Login screen renders). `flutter test` is run as part of the standard verification loop for any change to these areas.
- **On-device debug sheet** (bug-report icon in the app bar): shows the currently tracked `clientid`/`htmlrfid`, the current Bearer token, and the full request/response history for the session (up to 200 exchanges) — the primary tool for diagnosing any unexpected behavior, since it shows the *exact* JSON exchanged with Oracle for each step. This is what surfaced the Split IBLPN "Move to LPN" blank-label/`tag` structure (§4.8), and every subsequent customer-specific customization's exact field/screen shape (§9) — a live debug-sheet capture from the customer is the standard way any new screen's exact request/response shape gets confirmed, rather than guessed.
- **Live API verification**: because this API's behavior is not publicly documented, contested or ambiguous behavior has been resolved by testing directly against the real WMS instance (via curl/PowerShell, or by pasting Postman captures) rather than by reasoning about the code alone — see `docs/Solution_Document.md` for the methodology and its results. This includes confirming the Truck Temp PATCH shape (§4.7): a query-filtered collection PATCH was tried live and found to return 405 before falling back to the already-correct `/id/`-based approach.
- **On-device verification via ADB**: builds are installed and driven directly on connected test devices for every change (`flutter build apk --debug` + `flutter install --debug -d <device-id>`), including screenshots (`adb exec-out screencap`) to visually confirm UI changes, and `adb shell run-as <pkg> ...` to inspect/pull files from the app's private storage (used to confirm a captured photo actually persisted correctly).

## 9. Client-Side Customization Architecture

Every customer-specific customization (§4.10-§4.17 of the Functional Specification, plus Truck Temp/Split IBLPN) follows the same architectural pattern, so a new one is additive rather than a redesign:

1. **A `FeatureFlags` field** (`lib/config/app_config.dart`) gates the whole customization on/off, editable on an unlocked/dev build via the Feature Settings screen, or fixed at compile time on a locked build via `WMSNOW_LOCKED_FEATURE_FLAGS` (a comma-separated list of short keys, e.g. `pod,truckTemp,multiFieldBarcodeGs1`).
2. **A screen-scope check** — most customizations only activate on one specific Oracle transaction, matched by substring against `_RuntimeScreenState._currentTransactionName` (the mainmenu button label that was tapped to reach the current screen; the RF API itself has no dedicated "which transaction is this" field). Computed once per relevant callback as a local `onXScreen` boolean and reused, not re-evaluated per field.
3. **A field-level check** — within a matched screen, the customization further matches on a specific field's label text or `tag` (Oracle's response includes both; `tag` is used wherever a field's visible caption turns out to be a separate `label`-type item with a blank field label, a recurring pattern first found on Split IBLPN's "Move to LPN" field, §4.8).
4. **Injection or extraction, not new RF calls** — most customizations either inject a client-side-only UI element (a field, a button) ahead of a real field, or transform a value on its way into/out of a real field's own submission; the underlying RF transaction itself is always the real one Oracle drives, never bypassed or faked.

### 9.1 Customer-specific matching data

Two customization categories need to recognize text that is a specific customer's own Oracle configuration, not something universal:

- **Screen/transaction names** (Truck Temp, Multi Field Barcode - GS1) — the same underlying Oracle RF *module* can be labeled with a different screen name per customer, or even more than one screen name for the same customer, so this is a list, not a single fixed string, and is matched case-insensitively.
- **Print configuration** (Mix Area Task's Label Designer template code and printer name) — likewise this customer's own Oracle configuration, not a value this app invents.

Neither is a compile-time literal in `lib/` — both are baked in per build via `--dart-define` (empty string on any build that doesn't set them, which is a safe no-op given the guards described above — an empty match string is never allowed to silently match everything). The actual values are supplied automatically by `tools/build_lib.py`'s `CUSTOMER_SCREEN_OVERRIDES` table (a plain Python dict, keyed by customer name, one entry per customer that needs one), not typed into the Admin Build UI's form. This keeps a customer's real screen/print naming out of the Dart source that's compiled into every build and snapshotted for the Compare page's code-diff (§10.4) — a different customer's build diff never reveals it. Extending an existing customization to a new module/screen/field, or to a new customer, is a one-entry addition to that table, referenced by the stable Oracle RF module name so the same module can be recognized across customers even when its screen name differs.

### 9.2 Build-time locking mechanism

A customer-locked build bakes in, via Flutter's `--dart-define` (resolved at compile time through `String.fromEnvironment`, not readable or overridable at runtime):

| Dart-define | Content |
|---|---|
| `WMSNOW_LOCKED_ENVIRONMENTS` | One or more `name#domain#instance#clientId#clientSecret` entries, comma-separated |
| `WMSNOW_LOCKED_FEATURE_FLAGS` | Comma-separated short keys for active customizations |
| `WMSNOW_LOCKED_LOG_SERVER` | `url#token`, or blank |
| `WMSNOW_LICENSE_EXPIRY` | ISO `YYYY-MM-DD`, or blank (never expires) |
| `WMSNOW_APP_NAME` | `"<customer name> redwood"` — drives the Android label, Windows window title/exe name, and `MaterialApp.title` |
| `WMSNOW_TRUCK_TEMP_PAGE_TITLE_MATCH`, `WMSNOW_MFB_GS1_PAGE_TITLE_MATCH`, `WMSNOW_MA_LABEL_DESIGNER_CODE`, `WMSNOW_MA_PRINTER_NAME` | Customer-specific matching/print data, §9.1 |

`AppConfig.isLocked` (driven by whether `WMSNOW_LOCKED_ENVIRONMENTS` is non-empty) is the single flag every locked-build behavior keys off: Manage Environments and Feature Settings both become read-only, and the seed/default environment list is empty in every build (locked or not) — a real customer environment name is never a compile-time default, avoiding the same cross-build-diff exposure as §9.1.

### 9.3 Session activity logging

`LogService` writes one file per session under the app's private storage (`instance_username_sessionid_date_time_seq.log`), recording RF/`lgfapi` requests-responses and key operator actions as JSON lines. `LogUploadService` posts the same data to a configured Log Server (`WMSNOW_LOCKED_LOG_SERVER`, or the equivalent Feature Settings field on an unlocked build) at login, at logout, and every 30 seconds while a session is active — best-effort; a failed upload doesn't block or interrupt the operator, and the local file remains as the source of truth (viewable via the on-device debug sheet, §8) regardless of upload success.

### 9.4 Captured file upload

`UploadService` posts captured photos/signatures (POD, Split IBLPN) to a configured Upload Server, using the same protocol the Admin Build UI's `/upload` route implements (§10.6) — multipart form upload with a shared bearer token, not tied to the operator's own WMS credentials.

### 9.5 License expiry

`AppConfig.isLicenseExpired()` compares `WMSNOW_LICENSE_EXPIRY` against `max(DateTime.now(), last-seen-date persisted in SharedPreferences)` — the persisted last-seen date means simply rolling the device clock backward cannot un-expire the app on its own (a real deterrent, not a hard guarantee — a factory reset/fresh install clears it). Checked once on the Login screen's `initState`, before any credentials are entered; never surfaced as a date, countdown, or any other hint to the operator at any point, by explicit design.

## 10. Admin Build UI

A separate Flask (Python 3) application (`tools/admin_build_ui/`), server-rendered with Jinja2 templates, run internally on infrastructure KSAP controls — never installed on, or reachable from, any warehouse device except via the public download link (§10.8). Not built with Flutter and shares no runtime code with the mobile app; the two communicate only via the upload/log HTTP endpoints described above and by `--dart-define` values computed at build time.

### 10.1 Authentication and authorization
- Session-cookie-based login; passwords hashed with `werkzeug.security` (`generate_password_hash`/`check_password_hash`), stored in `data/users.json`.
- Two roles, enforced via route decorators: `builder_required` (build/download/manage), and a plain `login_required` for read-only pages available to both roles (`viewer` included). `unrestricted_builder_required` additionally requires an unscoped account, for pages that manage cross-customer master data (Companies, Instances, Users).
- Company scoping: a user account optionally carries a single company name (`session["company"]`); every data-returning route filters by it where applicable, and `_customer_allowed()`/`_visible_links()` are the shared checks used throughout `app.py` to enforce this consistently rather than per-route ad hoc filtering.

### 10.2 Generate Build
- `POST /build` validates the request (customer known, instance(s) belong to that customer, expiry date well-formed) and starts a background thread running `build_lib.run_build_request()`, tracked by a job id the browser polls (`GET /status/<job_id>`) for live progress output and completion.
- `build_lib.py` is the single shared implementation used by both the web UI and `tools/generate_customer_build.py` (a terminal-prompt CLI, kept for offline use) — never duplicated, so the two entry points cannot drift apart.
- On success, `record_build()` appends an entry to `data/history.json` (environments including OAuth secrets, active customizations, platform(s), expiry date) and copies `lib/` as it exists at that moment into `data/snapshots/<record_id>/lib` for later code-diffing (§10.4) — no git involved, a plain filesystem copy.
- `data/`, `customer_builds/` (build output), and the snapshot copies are all gitignored — this data (including live OAuth secrets, already compiled into the binaries themselves) is local to whichever machine runs the Admin Build UI, not committed to source control.

### 10.3 Companies, Instances, Users (master data)
- Three small JSON-file-backed modules (`companies.py`, `instances.py`, `users.py`), each with simple CRUD, replacing what used to be free-typed customer/environment strings per build (a source of real duplicate/inconsistent entries before these existed, e.g. `"CCI TEST"` vs `"cci_test"`).
- Referential guards prevent deleting a Company that still has Instances or scoped Users pointing at it.

### 10.4 History and Compare
- `GET /api/history/<customer>` returns that customer's build records (masked OAuth secrets by default; `/api/history-record/<id>` returns the unmasked version, builder-only, used to pre-fill a Rebuild).
- `GET /compare?a=<id>&b=<id>` diffs two records: environment/customization/platform differences, and a line-level code diff between their two `data/snapshots/` copies (`difflib`-based, not git).

### 10.5 Logs
- `LogUploadService` (§9.3) posts to `POST /upload-log`; files land under `data/logs/`, named `instance_username_sessionid_date_time_seq.log`. Browsable/filterable by customer → instance → date; a log's own first line is authoritative for instance/username (not parsed from the filename, since both can themselves contain underscores).

### 10.6 Images
- `UploadService` (§9.4) posts to `POST /upload`; files land under `data/captured_images/`. Filterable by type (POD Signature / Split IBLPN Photo / Other) and date. Cannot currently be filtered or restricted by company (filenames carry no customer/instance context) — hidden entirely from a company-scoped account as a result (§7.1 of the Functional Specification).

### 10.7 License expiry notifications
- `expiry_notify.py`, run periodically (external scheduler, e.g. Windows Task Scheduler or cron — not a built-in always-on process of the Flask app itself), scans `data/history.json` for each customer's current build's `expiry_date`, and emails the configured notification address list (`data/notify_emails.json`) at 30/14/7/1/0 days remaining, tracking which thresholds have already fired per build record (`notified_thresholds`) so the same alert isn't repeated.

### 10.8 Distribution Links
- `distribution_links.py` manages tokenized links (`data/distribution_links.json`): a long random token (not the customer/instance name) is the actual access gate for the fully public `GET /dl/<token>` landing page and `GET /dl/<token>/download/<which>` download route — no login required for either, by design, since this is what a customer's own IT/operators use.
- Each link tracks an `active_record_id` and an `auto_advance` flag. `on_new_build()` is called after every successful build (§10.2) and advances any matching link's `active_record_id` automatically, unless a build administrator has pinned it to an earlier build (`set_active_build()`, which also clears `auto_advance`) — `resume_auto_advance()` re-enables it and jumps to the latest matching build.
- The QR code (`GET /distribution-links/qr/<token>.png`) is generated server-side on request via the `qrcode` package into an in-memory PNG, not stored as a file.

### 10.9 Deployment note
This application is intended to be hosted on a real, reachable server (not just an admin's own workstation) once `/dl/<token>` is used for actual customer distribution, so customer devices — including RF handhelds on a different network — can reach it. It is not currently deployed behind HTTPS by default; this should be addressed (a reverse proxy with TLS termination, e.g. nginx/Caddy, or a platform-managed certificate) before any production customer-facing use, since login credentials and the download links both currently travel in whatever the deployment's own transport is.
