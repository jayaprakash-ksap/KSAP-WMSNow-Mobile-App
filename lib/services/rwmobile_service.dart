import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'auth_service.dart';
import 'log_service.dart';

/// All confirmed request shapes for the Redwood Mobile API live here.
///
/// Envelopes:
///   screen selection / entry submit (incl. facility/company code): {clientid, htmlrfid, env_name, keyboard_input}
///   RF key action (e.g. F, A, X)                                 : {clientid, htmlrfid, action_keys}
///   field-cursor advance with no value (multi-field screens)     : {clientid, htmlrfid, env_name, action_key: "TAB"} (SINGULAR key name)
///
/// clientid is included on every one of the above. Oracle Support
/// (KB864369) said clientid is "not mandatory" in the body - dropping it
/// entirely from EVERY request was tried once (2026-07-07) and made things
/// categorically worse live (endless bouncing between the main menu and the
/// yesno conflict dialog, plus server-side "WMS connectivity issue" errors)
/// - reverted the same day. It was later (2026-07-09) omitted specifically
/// from keyboard_input calls, which worked for simple screens (menu
/// selection, facility/company code) but a multi-field transactional screen
/// could not get past a recurring session
/// conflict without it - adding clientid back to keyboard_input fixed that
/// and stayed clean through a full multi-step transaction. One consistent
/// shape (always include clientid) is used now rather than special-casing
/// by screen type.
///
/// Session identity (clientid/htmlrfid) TRACKS THE LATEST response, always
/// - RuntimeScreen._captureSession() (main.dart) updates both from every
/// response, no freezing. This reverses an earlier frozen-from-login model:
/// extensive live testing on 2026-07-09 (independently and by the developer
/// in Postman) repeatedly showed the frozen model producing "this user
/// session has expired" once the live session moved onto a different
/// htmlrfid than the one pinned at login. See [[project_wmsnow_redwood]] (dev
/// memory) for the full history if this area needs revisiting again.
///
/// One request/response pair, kept for the on-device debug history.
class RwExchange {
  final Map<String, dynamic> request;
  final Map<String, dynamic> response;
  final DateTime at;
  // The Bearer token actually used for THIS specific call - captured per
  // exchange (not just read from the current live session) so the user can
  // directly compare token consistency across the whole history instead of
  // only ever seeing "whatever the token is right now".
  final String token;
  // Wall-clock time for just the HTTP round-trip (request sent -> response
  // received) - added 2026-07-26 to actually measure a reported "screens
  // feel half a second slower" rather than guess whether it's the network/
  // server or the app. Shown in the debug sheet.
  final Duration elapsed;
  RwExchange(this.request, this.response, this.at, this.token, this.elapsed);
}

class RwmobileService {
  final AuthService auth;
  RwmobileService(this.auth);

  // A shared, persistent client so repeated calls reuse the same TCP/TLS
  // connection (HTTP keep-alive) instead of paying a fresh handshake every
  // time - package:http's top-level post()/get()/patch() functions each
  // spin up and immediately close a new Client(), which is expensive when
  // the app can legitimately fire dozens to hundreds of sequential requests
  // (e.g. the stale-session drain loop).
  final http.Client _client = http.Client();

  Map<String, dynamic>? lastRequest;
  Map<String, dynamic>? lastResponse;

  // Dart's http.Client does not maintain a cookie jar the way a browser or
  // Postman does. Oracle's htmlrf endpoint sets a load-balancer sticky-route
  // cookie (X-Oracle-HTMLRF-LBS-Route) on responses; mirror the standard
  // capture-and-resend behavior so requests keep landing on whichever
  // backend node the session actually lives on, same as Postman does by
  // default. Not confirmed to be the cause of the "another active session"
  // conflict (a live test resending just this cookie for one hop still hit
  // the conflict) - kept as a sound, low-risk match of normal HTTP client
  // behavior rather than a claimed fix.
  String? _cookie;

  // Every exchange this session, not just the last one - a multi-step retry
  // dance (conflict -> yes -> auto-retry -> maybe another conflict -> manual
  // retap) overwrites lastRequest/lastResponse at every step, so by the time
  // something looks wrong on screen the one exchange that actually failed is
  // already gone. Bounded so a long session doesn't grow unboundedly.
  final List<RwExchange> history = [];
  static const _maxHistory = 200;

  void dispose() => _client.close();

  Future<Map<String, dynamic>> _post(Map<String, dynamic> payload,
      {bool retried = false}) async {
    lastRequest = payload;
    final tokenUsed = auth.session!.accessToken;
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(AppConfig.rwmobileUrl),
      headers: {
        'Authorization': 'Bearer $tokenUsed',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_cookie != null) 'Cookie': _cookie!,
      },
      body: jsonEncode(payload),
    );
    final elapsed = DateTime.now().difference(started);
    final setCookie = res.headers['set-cookie'];
    if (setCookie != null) {
      // Only need the name=value pair, not the Path/Secure/HttpOnly
      // attributes, to resend it as a request Cookie header.
      _cookie = setCookie.split(';').first;
    }
    if (res.statusCode == 401 && !retried) {
      if (await auth.refresh()) return _post(payload, retried: true);
    }
    // Robust: never throw on a non-JSON / error body (which would hang the UI).
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(res.body);
      data = decoded is Map<String, dynamic>
          ? decoded
          : {'_raw': decoded.toString()};
    } catch (_) {
      data = {
        '_error': 'Non-JSON response',
        '_status': res.statusCode,
        '_body': res.body,
      };
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      data = {'_status': res.statusCode, ...data};
    }
    lastResponse = data;
    history.add(RwExchange(payload, data, DateTime.now(), tokenUsed, elapsed));
    if (history.length > _maxHistory) history.removeAt(0);
    LogService.log('RF', {
      'request': payload,
      'response': data,
      'status': res.statusCode,
      'elapsed_ms': elapsed.inMilliseconds,
    });
    return data;
  }

  /// Initial page / login handshake.
  Future<Map<String, dynamic>> start() => _post({});

  /// Submit a typed entry value or a menu selection index - used for EVERY
  /// entry dialog (facility code, company code, LPN, plain menu input, etc),
  /// not just plain text fields. The field is `keyboard_input`, not `input`
  /// - confirmed against the user's functional spec (matches the flow
  /// diagram's own "Send keyboard_input" label).
  ///
  /// `env_name` is the actual instance name, confirmed
  /// live on 2026-07-09 from the customer's own Postman session for BOTH
  /// the facility code and the company code submissions - both used
  /// `env_name` with the real instance name as the value in `keyboard_input`,
  /// not a dedicated field.
  ///
  /// `clientid` IS included here (added 2026-07-09) - live-tested on a
  /// multi-field transactional screen: the same
  /// keyboard_input call WITHOUT clientid could not get past a recurring
  /// session conflict, but WITH clientid (matching the customer's own
  /// working Postman capture) it went through cleanly and stayed clean for
  /// the rest of a full multi-step transaction (Dock -> Shipment -> LPN ->
  /// SKU -> Qty -> Batch -> Expiry -> End LPN). Simple screens (menu
  /// selection, facility code, company code) had earlier been confirmed
  /// working WITHOUT clientid, but including it is harmless there and this
  /// keeps one consistent request shape for every keyboard_input call
  /// rather than special-casing by screen type.
  Future<Map<String, dynamic>> sendInput(
          int clientid, String htmlrfid, String value) =>
      _post({
        'clientid': '$clientid', // STRING
        'htmlrfid': htmlrfid,
        'env_name': AppConfig.instance,
        'keyboard_input': value,
      });

  /// Move the RF cursor to the next field WITHOUT submitting a value -
  /// added 2026-07-09 for multi-field transactional screens (e.g. Receiving)
  /// where Oracle tracks a single current-field cursor server-side, just
  /// like a physical RF terminal, and does not allow jumping to an
  /// arbitrary field. Live-confirmed request shape: note the field is
  /// `action_key` (SINGULAR), not `action_keys` (plural) - a different
  /// shape from every other action-key call in this file. Live-confirmed
  /// behavior: submitting a real value via sendInput() already advances the
  /// cursor on its own (no TAB needed after genuinely entering something) -
  /// this method is only for explicitly skipping a field with no input.
  /// Skipping a field that already has an auto-populated SUGGESTED value
  /// (shown by the server but not yet confirmed via sendInput) fails with a
  /// "Required Field" info dialog - that value must be explicitly
  /// (re-)submitted via sendInput() before TAB will move past it, even
  /// though the field visually already shows a value.
  Future<Map<String, dynamic>> sendTab(int clientid, String htmlrfid) => _post({
        'clientid': '$clientid', // STRING
        'htmlrfid': htmlrfid,
        'env_name': AppConfig.instance,
        'action_key': 'TAB',
      });

  /// Send a control/action key. clientid IS required here - see class-level
  /// doc comment.
  Future<Map<String, dynamic>> sendActionKey(
      int clientid, String htmlrfid, String key) {
    return _post({
      'clientid': '$clientid', // STRING
      'htmlrfid': htmlrfid,
      'action_keys': key,
    });
  }

  /// Answer a yes/no dialog. "No" sends action_keys "X" per the functional
  /// spec, NOT "N" - this ends the session and logs the user out back to the
  /// Login page (same code as the generic Ctrl-X "Exit App" control key).
  /// clientid IS required here - see class-level doc comment.
  Future<Map<String, dynamic>> sendYesNo(
      int clientid, String htmlrfid, String answer) {
    final key = answer == 'yes' ? 'A' : 'X';
    return _post({
      'clientid': '$clientid', // STRING
      'htmlrfid': htmlrfid,
      'action_keys': key,
    });
  }

  // ---- lgfapi: Truck Temp persistence ----

  /// [query] is ANDed together as query-string filters (e.g. `shipment_nbr`,
  /// `facility_id__code`, `company_id__code`) - generalized 2026-07-10 from a
  /// single-filter version once shipment_nbr alone was confirmed not unique
  /// enough across facility/company to safely key a lookup on.
  Future<Map<String, dynamic>?> findEntity(
      String entity, Map<String, String> query) async {
    final qs = query.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final url = '${AppConfig.lgfapiBase}/entity/$entity?$qs';
    final started = DateTime.now();
    final res = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${auth.session!.accessToken}'},
    );
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (res.statusCode != 200) {
      LogService.log('LGFAPI_GET',
          {'url': url, 'status': res.statusCode, 'elapsed_ms': elapsedMs});
      return null;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final count = (data['result_count'] ?? 0) as int;
    LogService.log('LGFAPI_GET', {
      'url': url,
      'status': res.statusCode,
      'elapsed_ms': elapsedMs,
      'result_count': count,
    });
    if (count == 0) return null;
    return (data['results'] as List).first as Map<String, dynamic>;
  }

  /// PATCH requires the update wrapped in a "fields" object (confirmed from the
  /// REST API guide); a flat body yields "Field data is required". Must target
  /// a specific `/{id}/` resource - live-tested 2026-07-10 that PATCHing the
  /// query-filtered collection URL (the same shape used for the GET lookup)
  /// returns 405 METHOD_NOT_ALLOWED, so the id from findEntity() is required.
  Future<bool> patchField(
      String entity, int id, String fieldKey, String value) async {
    final url = '${AppConfig.lgfapiBase}/entity/$entity/$id/';
    final started = DateTime.now();
    final res = await _client.patch(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${auth.session!.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'fields': {fieldKey: value}
      }),
    );
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    LogService.log('LGFAPI_PATCH', {
      'url': url,
      'field': fieldKey,
      'value': value,
      'status': res.statusCode,
      'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      'ok': ok,
    });
    return ok;
  }

  // ---- lgfapi: generic list/action calls (POD, 2026-07-23) ----
  //
  // Unlike findEntity()/patchField() above (built narrowly for the Truck
  // Temp single-record lookup/update), POD needs raw access to whatever
  // shape a given lgfapi path returns - lists of ids, nested sub-resource
  // collections (.../container/{id}/orders/), and no-body action endpoints
  // (.../mark_delivered/). These two are intentionally thin passthroughs;
  // PodService owns interpreting the response shape per call site.

  /// GET `$lgfapiBase$path` with [query] as `&`-joined filters. Returns the
  /// decoded JSON body as-is (caller reads `results`/`result_count`/etc) -
  /// never throws on a non-2xx/non-JSON response, matching _post()'s
  /// robustness so one bad call can't hang the POD screen.
  Future<Map<String, dynamic>> lgfapiGet(String path,
      [Map<String, String> query = const {}]) async {
    final qs = query.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final url = '${AppConfig.lgfapiBase}$path${qs.isEmpty ? '' : '?$qs'}';
    final started = DateTime.now();
    final res = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${auth.session!.accessToken}'},
    );
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    try {
      final decoded = jsonDecode(res.body);
      final data =
          decoded is Map<String, dynamic> ? decoded : {'results': decoded};
      LogService.log('LGFAPI_GET', {
        'url': url,
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        'response': data,
      });
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'_status': res.statusCode, ...data};
      }
      return data;
    } catch (_) {
      // BUG FIX 2026-08-22 - live-confirmed a 204 No Content response (a
      // legitimate SUCCESS with an intentionally empty body) was landing
      // here via jsonDecode('') throwing, and got unconditionally treated
      // as an `_error` - Full Pallet Task's pack_full_lpn call actually
      // succeeded server-side (LPN packed) but the app showed "Scan
      // failed". A 2xx status here means the call genuinely succeeded with
      // no body to report - return an empty success map, not an error one.
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      LogService.log('LGFAPI_GET', {
        'url': url,
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        if (!ok) 'error': 'Non-JSON response',
      });
      return ok
          ? {}
          : {'_error': 'Non-JSON response', '_status': res.statusCode};
    }
  }

  /// POST `$lgfapiBase$path` with an optional JSON [body] - used for
  /// no-payload action endpoints like `mark_delivered`. Returns whether the
  /// response was 2xx.
  Future<bool> lgfapiPost(String path, [Map<String, dynamic>? body]) async {
    final url = '${AppConfig.lgfapiBase}$path';
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${auth.session!.accessToken}',
        'Content-Type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    );
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    LogService.log('LGFAPI_POST', {
      'url': url,
      'body': body,
      'status': res.statusCode,
      'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      'ok': ok,
    });
    return ok;
  }

  /// POST `$lgfapiBase$path` with a JSON [body], returning the decoded
  /// response body - unlike [lgfapiPost] above (which only reports 2xx/not,
  /// fine for action endpoints with nothing worth reading back), this is
  /// for endpoints whose response is actually needed (e.g.
  /// print/label/shipping's own success/message fields, Mix Area Task,
  /// 2026-08-21). Same non-throwing robustness as lgfapiGet.
  Future<Map<String, dynamic>> lgfapiPostJson(
      String path, Map<String, dynamic> body) async {
    final url = '${AppConfig.lgfapiBase}$path';
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${auth.session!.accessToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    try {
      final decoded = jsonDecode(res.body);
      final data =
          decoded is Map<String, dynamic> ? decoded : {'results': decoded};
      LogService.log('LGFAPI_POST_JSON', {
        'url': url,
        'body': body,
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        'response': data,
      });
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'_status': res.statusCode, ...data};
      }
      return data;
    } catch (_) {
      // BUG FIX 2026-08-22 - same fix as lgfapiGet's catch block above:
      // a 2xx status with an empty/unparseable body (live-confirmed via a
      // real 204 No Content from pack_full_lpn) is a genuine success, not
      // an error - only report `_error` for a genuinely non-2xx status.
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      LogService.log('LGFAPI_POST_JSON', {
        'url': url,
        'body': body,
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        if (!ok) 'error': 'Non-JSON response',
      });
      return ok
          ? {}
          : {'_error': 'Non-JSON response', '_status': res.statusCode};
    }
  }

  /// POST `$apiBase$path` as form-urlencoded (not JSON) - assign_and_load_
  /// oblpn (Wooden Pallet Task, 2026-08-15) is on the older `wms/api/`
  /// surface, which takes form fields and returns XML rather than JSON, so
  /// this returns the raw response body for the caller to parse (see
  /// WoodenPalletService.assignAndLoadOblpn). Passing a Map as [fields]
  /// to package:http's post() auto-encodes it as
  /// application/x-www-form-urlencoded, matching the explicit header below.
  Future<String> apiPostForm(String path, Map<String, String> fields) async {
    final url = '${AppConfig.apiBase}$path';
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${auth.session!.accessToken}',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: fields,
    );
    LogService.log('API_POST_FORM', {
      'url': url,
      'fields': fields,
      'status': res.statusCode,
      'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      'response': res.body,
    });
    return res.body;
  }
}
