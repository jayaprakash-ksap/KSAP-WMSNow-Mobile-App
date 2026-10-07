import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One selectable Oracle WMS instance - name shown in the login screen's
/// environment dropdown, the full `domain` + `instance` URL path segment it
/// maps to, and its own OAuth app registration (each environment has been
/// confirmed to need its own client_id/client_secret pair - they are NOT
/// shared across instances, even ones under the same domain).
///
/// `domain` is per-environment, NOT a shared app-wide constant - live-tested
/// 2026-07-11 that a customer's test and production environments can live on
/// COMPLETELY DIFFERENT HOSTS (e.g. `tb2.wms.ocs.oraclecloud.com` vs
/// `b2.wms.ocs.oraclecloud.com` - a "test" pod vs its differently-named
/// non-test counterpart), not just different path segments under one fixed
/// domain. Treating domain as fixed silently sent every production request to
/// the wrong host, which returned a generic HTML gateway error page instead
/// of ever reaching Oracle's OAuth layer - looked exactly like a credentials
/// problem until the domain mismatch was found.
class Environment {
  final String name;
  final String domain;
  final String instance;
  final String clientId;
  final String clientSecret;
  const Environment({
    required this.name,
    required this.domain,
    required this.instance,
    required this.clientId,
    required this.clientSecret,
  });

  // Value equality, not the default identity equality - every time the
  // environment list is reloaded from storage (Environment.fromJson), a
  // BRAND NEW object is created for what may be logically "the same"
  // environment. Without this, a previously-selected Environment held by
  // the Login screen's dropdown stops matching any entry in a freshly
  // reloaded list, which crashes DropdownButtonFormField's internal
  // "exactly one matching item" assertion. Found live 2026-07-11 after
  // returning to Login from Manage Environments with a selection already
  // made.
  @override
  bool operator ==(Object other) =>
      other is Environment &&
      name == other.name &&
      domain == other.domain &&
      instance == other.instance &&
      clientId == other.clientId &&
      clientSecret == other.clientSecret;

  @override
  int get hashCode =>
      Object.hash(name, domain, instance, clientId, clientSecret);

  Map<String, dynamic> toJson() => {
        'name': name,
        'domain': domain,
        'instance': instance,
        'clientId': clientId,
        'clientSecret': clientSecret,
      };

  factory Environment.fromJson(Map<String, dynamic> j) => Environment(
        name: j['name'] as String,
        // Falls back to the original fixed domain for entries saved before
        // 2026-07-11 (when domain was still a shared AppConfig constant,
        // not part of the saved JSON) - keeps old persisted data loadable.
        domain:
            (j['domain'] as String?) ?? 'https://tb2.wms.ocs.oraclecloud.com',
        instance: j['instance'] as String,
        clientId: j['clientId'] as String,
        clientSecret: j['clientSecret'] as String,
      );
}

/// Which client-side add-ons (built for one specific customer, not part of
/// the generic RF renderer) are currently active - see AppConfig.currentFlags
/// for how this is loaded/applied. Originally a deliberately runtime,
/// admin-editable-any-time toggle (2026-07-25 decision) - still true for
/// the plain unlocked dev/testing build. On a build-locked customer build
/// (see AppConfig.isLocked), this is now ALSO baked in at compile time via
/// WMSNOW_LOCKED_FEATURE_FLAGS (2026-08-27, see the Admin Build UI under
/// tools/admin_build_ui/) - a natural extension of the same locked-build
/// security model already applied to Environment, not a reversal of the
/// 2026-07-25 decision.
class FeatureFlags {
  final bool podEnabled;
  final bool truckTempEnabled;
  final bool woodenPalletTaskEnabled;
  final bool mixAreaTaskEnabled;
  final bool fullPalletTaskEnabled;
  final bool serialReceivingEnabled;
  final bool pickAllocateSerialEnabled;
  final bool combinedReceivingEnabled;
  final bool multiFieldBarcodeGs1Enabled;
  const FeatureFlags(
      {required this.podEnabled,
      required this.truckTempEnabled,
      required this.woodenPalletTaskEnabled,
      required this.mixAreaTaskEnabled,
      required this.fullPalletTaskEnabled,
      this.serialReceivingEnabled = false,
      this.pickAllocateSerialEnabled = false,
      this.combinedReceivingEnabled = false,
      this.multiFieldBarcodeGs1Enabled = false});

  // Base app ships with no customer-specific customizations active - each
  // one is opt-in per device via Feature Settings, not on by default.
  static const defaults = FeatureFlags(
      podEnabled: false,
      truckTempEnabled: false,
      woodenPalletTaskEnabled: false,
      mixAreaTaskEnabled: false,
      fullPalletTaskEnabled: false,
      serialReceivingEnabled: false,
      pickAllocateSerialEnabled: false,
      combinedReceivingEnabled: false,
      multiFieldBarcodeGs1Enabled: false);

  FeatureFlags copyWith({
    bool? podEnabled,
    bool? truckTempEnabled,
    bool? woodenPalletTaskEnabled,
    bool? mixAreaTaskEnabled,
    bool? fullPalletTaskEnabled,
    bool? serialReceivingEnabled,
    bool? pickAllocateSerialEnabled,
    bool? combinedReceivingEnabled,
    bool? multiFieldBarcodeGs1Enabled,
  }) =>
      FeatureFlags(
        podEnabled: podEnabled ?? this.podEnabled,
        truckTempEnabled: truckTempEnabled ?? this.truckTempEnabled,
        woodenPalletTaskEnabled:
            woodenPalletTaskEnabled ?? this.woodenPalletTaskEnabled,
        mixAreaTaskEnabled: mixAreaTaskEnabled ?? this.mixAreaTaskEnabled,
        fullPalletTaskEnabled:
            fullPalletTaskEnabled ?? this.fullPalletTaskEnabled,
        serialReceivingEnabled:
            serialReceivingEnabled ?? this.serialReceivingEnabled,
        pickAllocateSerialEnabled:
            pickAllocateSerialEnabled ?? this.pickAllocateSerialEnabled,
        combinedReceivingEnabled:
            combinedReceivingEnabled ?? this.combinedReceivingEnabled,
        multiFieldBarcodeGs1Enabled:
            multiFieldBarcodeGs1Enabled ?? this.multiFieldBarcodeGs1Enabled,
      );
}

/// Where captured photos/signatures get uploaded - see UploadService.
/// Received either by the standalone tools/captured_files_receiver.py, or
/// (recommended, 2026-08-27) the Admin Build UI's own /upload route
/// (tools/admin_build_ui/app.py) - same protocol, same captured_images/
/// folder either way, so point this at whichever one you're running.
/// `baseUrl` empty means unconfigured.
class UploadServerConfig {
  final String baseUrl;
  final String token;
  const UploadServerConfig({required this.baseUrl, required this.token});
  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// Where the Full Pallet Task Reject-trailer email gets relayed - see
/// EmailRelayService and tools/trailer_reject_email_receiver.py. Same
/// shape/reasoning as UploadServerConfig: the relay (not this app) holds
/// the actual SMTP credentials, so nothing mail-related is ever embedded
/// in a distributed build. `baseUrl` empty means unconfigured.
class EmailServerConfig {
  final String baseUrl;
  final String token;
  const EmailServerConfig({required this.baseUrl, required this.token});
  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// Where session activity logs (LogService) get uploaded so they're
/// browsable from the Admin Build UI (tools/admin_build_ui/, 2026-08-27)
/// instead of only living in a local folder per device - see
/// LogUploadService and the Admin Build UI's /upload-log route (hosted by
/// the same Flask app that also serves the browsing pages). Same
/// shape/reasoning as UploadServerConfig/EmailServerConfig. `baseUrl`
/// empty means unconfigured - LogsScreen stays fully local-only then,
/// exactly as before this existed.
class LogServerConfig {
  final String baseUrl;
  final String token;
  const LogServerConfig({required this.baseUrl, required this.token});
  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// Central configuration. For a real build, move clientSecret to a backend and
/// have the app call your backend for the token (a device binary cannot safely
/// hold a confidential secret). This is test-grade: direct-to-WMS.
class AppConfig {
  // Suggested default when adding a NEW environment in the Manage
  // Environments form - not otherwise used, since domain is per-Environment
  // now (see Environment's doc comment on why it can't be a shared constant).
  static const String defaultDomain = 'https://tb2.wms.ocs.oraclecloud.com';

  // Baked in per customer build by tools/generate_customer_build.py
  // (2026-07-26) - "<customer name> redwood", e.g. "ksap_test redwood".
  // Unset (the default, every build so far) -> "WMSNow Redwood Mobile", our own
  // daily-dev app. Drives MaterialApp.title and the Login screen
  // heading (lib/main.dart) - the Android app label and Windows window
  // title/exe name are set separately, directly in the native platform
  // files the generator script edits (dart-define can't reach those).
  static const String appName = String.fromEnvironment('WMSNOW_APP_NAME',
      defaultValue: 'WMSNow Redwood Mobile');

  // Seed environments - only ever used to populate persistent storage the
  // FIRST time the app runs (see loadEnvironments()). After that, the
  // persisted list is authoritative; the operator can add/edit/delete
  // environments (including these two, and their domain) via the Manage
  // Environments screen reached from the Login screen's top-right icon
  // (added 2026-07-11 - the app was previously hardwired to a compile-time
  // `environments` constant list, requiring a code change to add a new
  // instance).
  //
  // clientId/clientSecret are deliberately blank here (2026-07-23) - they
  // used to hold live OAuth credentials in source, which meant every clone
  // of this repo carried real secrets. The operator now fills them in once
  // per device via the Manage Environments screen on first run; after that
  // the persisted (not seed) values are what's actually used.
  // No named seed entries (2026-09-28) - a real Oracle instance name/domain
  // here would be one specific customer's, and that would then be baked
  // into every plain dev/testing build regardless of which customer it's
  // for. clientId/clientSecret were already left blank for the same
  // "no real credentials living in source" reason; name/domain/instance now
  // match that same policy. The operator fills in a real environment via
  // the Manage Environments screen on first run - same manual step
  // credentials already required.
  static const List<Environment> _seedEnvironments = [];

  static const _environmentsPrefsKey = 'oracle_custom_app_environments';

  // ---- Build-locked environments (APK distribution control, 2026-07-24) ----
  //
  // Problem: Manage Environments lets an operator add/edit/delete ANY
  // domain/instance/client_id/client_secret - so anyone who gets hold of
  // the APK can point it at a completely different customer's WMS instance.
  // Fix: bake a customer's whole environment (including client_id/secret,
  // as of 2026-07-24 - see below) in at COMPILE TIME via --dart-define, so
  // there's no UI path left to change any of it, and the customer's own
  // operator never has to be handed OAuth credentials to type in.
  //
  // Prefer tools/generate_customer_build.py over building this by hand - it
  // prompts for each field (hiding the secret as you type) and builds the
  // dart-define string correctly. The raw format, if needed directly:
  //   flutter build apk --release --dart-define=WMSNOW_LOCKED_ENVIRONMENTS="name1#domain1#instance1#clientId1#clientSecret1,name2#domain2#instance2#clientId2#clientSecret2"
  // Entries are comma-separated, fields within an entry are `#`-separated -
  // NOT `;` or `|`, both of which get mangled on Windows (flutter is a
  // .bat file; a literal `|` in a --dart-define value gets reinterpreted
  // as a real pipe by the underlying cmd.exe invocation even when quoted,
  // confirmed live 2026-07-24 - "'https:' is not recognized..." was cmd
  // trying to run everything after the `|` as a new command).
  //
  // 2026-07-24 revision: client_id/client_secret are now ALSO baked in here
  // (previously only domain/instance were, and the operator filled in
  // credentials per device via the UI). This doesn't reintroduce the
  // "secrets committed to git" problem the 2026-07-23 change fixed -
  // --dart-define values are a build-time argument, never written to
  // source/git, only into that one customer's compiled APK. Every
  // environment field is read-only in Manage Environments when isLocked
  // (see _EnvironmentFormDialog) - a credential change means generating and
  // redistributing a new APK, not editing one in place.
  //
  // Left unset (the default - every build so far, including all of today's
  // dev/testing), this is a no-op: isLocked is false and _seedEnvironments
  // is used exactly as before.
  static const String _lockedEnvironmentsDefine =
      String.fromEnvironment('WMSNOW_LOCKED_ENVIRONMENTS');

  static bool get isLocked => _lockedEnvironmentsDefine.trim().isNotEmpty;

  static List<Environment> _parseLockedEnvironments() {
    return _lockedEnvironmentsDefine
        .split(',')
        .where((e) => e.trim().isNotEmpty)
        .map((entry) {
      final parts = entry.split('#');
      return Environment(
        name: parts[0],
        domain: parts.length > 1 ? parts[1] : '',
        instance: parts.length > 2 ? parts[2] : '',
        clientId: parts.length > 3 ? parts[3] : '',
        clientSecret: parts.length > 4 ? parts[4] : '',
      );
    }).toList();
  }

  /// Reads the operator's saved environment list, seeding storage with
  /// [_seedEnvironments] the very first time (empty/missing prefs key).
  ///
  /// A locked build (isLocked) never touches SharedPreferences at all -
  /// always returns the compiled-in list fresh from
  /// _parseLockedEnvironments() directly. Deliberate: since every field is
  /// baked in and read-only anyway, going through persisted storage would
  /// only risk loading stale data left over from before a device was ever
  /// locked (a real case hit live 2026-07-24, re-testing on a machine that
  /// had previously run an unlocked build).
  static Future<List<Environment>> loadEnvironments() async {
    if (isLocked) return _parseLockedEnvironments();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_environmentsPrefsKey);
    if (raw == null) {
      await saveEnvironments(_seedEnvironments);
      return _seedEnvironments;
    }
    final decoded = jsonDecode(raw) as List;
    return decoded
        .map((e) => Environment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Persists the full environment list, replacing whatever was saved
  /// before - called after every add/edit/delete in the Manage
  /// Environments screen.
  static Future<void> saveEnvironments(List<Environment> envs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_environmentsPrefsKey,
        jsonEncode(envs.map((e) => e.toJson()).toList()));
  }

  // ---- Upload server (2026-07-23) ----
  //
  // Where UploadService sends captured photos/signatures - see
  // tools/captured_files_receiver.py. Empty baseUrl means the feature is
  // off (unconfigured devices keep today's local-storage-only behavior,
  // still reachable via the in-app Share sheet).
  static const _uploadServerPrefsKey = 'oracle_custom_app_upload_server';

  static Future<UploadServerConfig> loadUploadServer() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_uploadServerPrefsKey);
    if (raw == null) return const UploadServerConfig(baseUrl: '', token: '');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return UploadServerConfig(
      baseUrl: (decoded['baseUrl'] ?? '') as String,
      token: (decoded['token'] ?? '') as String,
    );
  }

  static Future<void> saveUploadServer(UploadServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uploadServerPrefsKey,
        jsonEncode({'baseUrl': config.baseUrl, 'token': config.token}));
  }

  // ---- Email server (2026-08-22) ----
  //
  // Where EmailRelayService sends the Full Pallet Task Reject-trailer
  // notification - see tools/trailer_reject_email_receiver.py. Same
  // unconfigured-by-default shape as the upload server above.
  static const _emailServerPrefsKey = 'oracle_custom_app_email_server';

  static Future<EmailServerConfig> loadEmailServer() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_emailServerPrefsKey);
    if (raw == null) return const EmailServerConfig(baseUrl: '', token: '');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return EmailServerConfig(
      baseUrl: (decoded['baseUrl'] ?? '') as String,
      token: (decoded['token'] ?? '') as String,
    );
  }

  static Future<void> saveEmailServer(EmailServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailServerPrefsKey,
        jsonEncode({'baseUrl': config.baseUrl, 'token': config.token}));
  }

  // ---- Log server (2026-08-27) ----
  //
  // Where LogUploadService sends session activity log files so they're
  // browsable from the Admin Build UI - see tools/admin_build_ui/app.py's
  // /upload-log route. Same unconfigured-by-default shape as the upload/
  // email servers above.
  //
  // BUG FIX 2026-08-27 - live-confirmed on a real locked customer build:
  // Feature Settings (the only place this was ever configurable) is
  // entirely hidden when isLocked (see the Login screen's AppBar), so a
  // locked build had NO WAY to ever configure this - not a network
  // problem, the setting was simply unreachable. Fixed the same way
  // environments already are: bake baseUrl/token in at build time via
  // --dart-define=WMSNOW_LOCKED_LOG_SERVER="baseUrl#token" (see
  // tools/build_lib.py) so a customer's device uploads its logs
  // automatically with zero per-device setup. Left unset (baseUrl empty),
  // this is a no-op - logs just stay local-only, same as before this
  // existed. The unlocked dev/testing build is unaffected either way -
  // Feature Settings there still works exactly as it did.
  static const String _lockedLogServerDefine =
      String.fromEnvironment('WMSNOW_LOCKED_LOG_SERVER');

  static const _logServerPrefsKey = 'oracle_custom_app_log_server';

  static Future<LogServerConfig> loadLogServer() async {
    if (isLocked) {
      final parts = _lockedLogServerDefine.split('#');
      return LogServerConfig(
        baseUrl: parts.isNotEmpty ? parts[0] : '',
        token: parts.length > 1 ? parts[1] : '',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_logServerPrefsKey);
    if (raw == null) return const LogServerConfig(baseUrl: '', token: '');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return LogServerConfig(
      baseUrl: (decoded['baseUrl'] ?? '') as String,
      token: (decoded['token'] ?? '') as String,
    );
  }

  static Future<void> saveLogServer(LogServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_logServerPrefsKey,
        jsonEncode({'baseUrl': config.baseUrl, 'token': config.token}));
  }

  // ---- Feature flags (2026-07-25) ----
  //
  // POD and Truck Temp were built for one customer specifically - another
  // customer may have none of that, just standard RF screens the generic
  // renderer already handles. currentFlags is a plain
  // static field (same idiom as `current` below for the selected
  // Environment) - read synchronously from _MenuView/_ScreenView wherever
  // an add-on needs to check whether it's active, loaded once in
  // RuntimeScreen.initState() before the mainmenu can ever render, and
  // updated immediately (memory + persisted) whenever FeatureSettingsScreen
  // changes something - no restart required for a toggle to take effect.
  static const _featureFlagsPrefsKey = 'oracle_custom_app_feature_flags';

  static FeatureFlags currentFlags = FeatureFlags.defaults;

  // ---- Build-locked feature flags (Admin Build UI, 2026-08-27) ----
  //
  // Baked in by tools/build_lib.py (used by both generate_customer_build.py
  // and tools/admin_build_ui/app.py) via
  // --dart-define=WMSNOW_LOCKED_FEATURE_FLAGS="pod,truckTemp,fullPalletTask"
  // - a comma-separated list of short keys for whichever customizations
  // were checked (an empty string is valid: locked with zero
  // customizations, not "not locked"). Deliberately reuses AppConfig's
  // existing `isLocked` getter (driven by WMSNOW_LOCKED_ENVIRONMENTS)
  // rather than introducing a second, independent lock flag - a build with
  // zero customizations checked would otherwise be indistinguishable from
  // "not locked at all" if this had its own isNotEmpty-based getter. Every
  // customer build this admin tool produces always locks environments and
  // feature flags together, so one shared `isLocked` is correct, not just
  // convenient. The plain unlocked dev/testing build is unaffected -
  // isLocked stays false there, so this whole section is a no-op.
  static const String _lockedFeatureFlagsDefine =
      String.fromEnvironment('WMSNOW_LOCKED_FEATURE_FLAGS');

  static FeatureFlags _parseLockedFeatureFlags() {
    final keys = _lockedFeatureFlagsDefine
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toSet();
    return FeatureFlags(
      podEnabled: keys.contains('pod'),
      truckTempEnabled: keys.contains('truckTemp'),
      woodenPalletTaskEnabled: keys.contains('woodenPalletTask'),
      mixAreaTaskEnabled: keys.contains('mixAreaTask'),
      fullPalletTaskEnabled: keys.contains('fullPalletTask'),
      serialReceivingEnabled: keys.contains('serialReceiving'),
      pickAllocateSerialEnabled: keys.contains('pickAllocateSerial'),
      combinedReceivingEnabled: keys.contains('combinedReceiving'),
      multiFieldBarcodeGs1Enabled: keys.contains('multiFieldBarcodeGs1'),
    );
  }

  static Future<FeatureFlags> loadFeatureFlags() async {
    if (isLocked) return _parseLockedFeatureFlags();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_featureFlagsPrefsKey);
    if (raw == null) return FeatureFlags.defaults;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return FeatureFlags(
      podEnabled: (decoded['podEnabled'] ?? false) as bool,
      truckTempEnabled: (decoded['truckTempEnabled'] ?? false) as bool,
      woodenPalletTaskEnabled:
          (decoded['woodenPalletTaskEnabled'] ?? false) as bool,
      mixAreaTaskEnabled: (decoded['mixAreaTaskEnabled'] ?? false) as bool,
      fullPalletTaskEnabled:
          (decoded['fullPalletTaskEnabled'] ?? false) as bool,
      serialReceivingEnabled:
          (decoded['serialReceivingEnabled'] ?? false) as bool,
      pickAllocateSerialEnabled:
          (decoded['pickAllocateSerialEnabled'] ?? false) as bool,
      combinedReceivingEnabled:
          (decoded['combinedReceivingEnabled'] ?? false) as bool,
      multiFieldBarcodeGs1Enabled:
          (decoded['multiFieldBarcodeGs1Enabled'] ?? false) as bool,
    );
  }

  static Future<void> saveFeatureFlags(FeatureFlags flags) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _featureFlagsPrefsKey,
        jsonEncode({
          'podEnabled': flags.podEnabled,
          'truckTempEnabled': flags.truckTempEnabled,
          'woodenPalletTaskEnabled': flags.woodenPalletTaskEnabled,
          'mixAreaTaskEnabled': flags.mixAreaTaskEnabled,
          'fullPalletTaskEnabled': flags.fullPalletTaskEnabled,
          'serialReceivingEnabled': flags.serialReceivingEnabled,
          'pickAllocateSerialEnabled': flags.pickAllocateSerialEnabled,
          'combinedReceivingEnabled': flags.combinedReceivingEnabled,
          'multiFieldBarcodeGs1Enabled': flags.multiFieldBarcodeGs1Enabled,
        }));
    currentFlags = flags;
  }

  // Set by LoginScreen the moment the operator picks an environment from the
  // dropdown, BEFORE sign-in is attempted - every other AppConfig getter
  // below reads through this rather than a fixed constant. Deliberately not
  // persisted across app launches (2026-07-11 decision) - the operator picks
  // fresh every time rather than silently defaulting to whatever was used
  // last, so the wrong environment can't be hit by mistake.
  static Environment? current;

  static Environment get _env {
    final e = current;
    assert(e != null,
        'AppConfig.current not set - select an environment before making requests.');
    return e!;
  }

  static String get instance => _env.instance;
  static String get clientId => _env.clientId;
  static String get clientSecret => _env.clientSecret;

  // ---- derived URLs ----
  static String get base => '${_env.domain}/${_env.instance}';
  static String get tokenUrl => '$base/api/oauth2/token/';
  static String get rwmobileUrl =>
      '$base/wms/lgfapi/v10/htmlrf/get_next_rwmobile_page';
  static String get lgfapiBase => '$base/wms/lgfapi/v10';
  // `wms/api/` (not `wms/lgfapi/v10/`) - a separate, older API surface used
  // by assign_and_load_oblpn (Wooden Pallet Task, 2026-08-15). Confirmed
  // via a live Postman capture against a different instance - form-
  // urlencoded body, XML response, unlike every lgfapi/v10 call elsewhere.
  static String get apiBase => '$base/wms/api';

  // ---- Truck Temp enhancement rule (Phase 2) ----
  // Inject a "Truck Temp" field before the LPN control, and persist it to
  // ib_shipment.cust_field_1 via lgfapi. Restricted to one specific
  // transaction (2026-07-10 - previously this matched ANY screen with an
  // "lpn"-labeled field, which is most of the RF menu - a lot of screens
  // have one). `_RuntimeScreenState` tracks which mainmenu item was tapped
  // to reach the current screen - see `_currentTransactionName` - and only
  // injects the field when that name contains this substring, case-
  // insensitively.
  //
  // The actual transaction name text is customer-specific (this customer's
  // own screen naming in their WMS), so it's never hardcoded here - it's
  // baked in per build via WMSNOW_TRUCK_TEMP_PAGE_TITLE_MATCH (see
  // tools/build_lib.py), same build-time-injection pattern already used for
  // Environment's client_id/client_secret. Blank (every build that doesn't
  // set it, including the plain dev/testing build) means this never
  // matches anything - see the `.isNotEmpty` guard at every call site,
  // since an empty needle would otherwise make `.contains('')` match every
  // screen.
  static const String truckTempPageTitleMatch =
      String.fromEnvironment('WMSNOW_TRUCK_TEMP_PAGE_TITLE_MATCH');
  static const String enhInsertBeforeLabel = 'lpn';
  static const String enhFieldLabel = 'Truck Temp (\u00b0C)';
  static const String enhSaveEntity = 'ib_shipment';
  // Corrected 2026-07-10 (was 'cust_field_1', a generic text field guessed
  // early on) - the customer's own reference confirms `cust_decimal_1` is
  // the intended decimal-typed custom field for this value.
  static const String enhSaveField = 'cust_decimal_1';
  static const String enhLookupLabelMatch = 'shipment';
  static const String enhLookupQueryParam = 'shipment_nbr';
  // Added 2026-07-10 - the shipment lookup must also be scoped by the
  // session's active facility/company (sourced from the response's own
  // `content.headers.fac_code`/`comp_code`, not typed/guessed), confirmed
  // live: `shipment_nbr` alone is not guaranteed unique across
  // facility/company. Live-tested against a real customer instance -
  // PATCH only succeeds against `/entity/ib_shipment/{id}/` (a query-filtered
  // collection URL returns 405 METHOD_NOT_ALLOWED), so the GET-then-PATCH-by-id
  // pattern stays; only the GET's filters and the target field changed.
  static const String enhFacQueryParam = 'facility_id__code';
  static const String enhCompQueryParam = 'company_id__code';

  // ---- Split IBLPN photo capture enhancement (Phase 3, 2026-07-10) ----
  // A camera button sits before the "Move to LPN" entry field - tappable at
  // any time on that screen (not gated to whichever field currently has
  // focus, unlike the Truck Temp field above, since capturing a photo isn't
  // tied to editing a specific field). The photo is only actually written to
  // local storage when that field is submitted, per the developer's spec -
  // capturing early and saving late means a photo taken before Move to LPN
  // is even reached still gets attached to whatever LPN value is eventually
  // entered.
  //
  // Matched on the field's own `tag` ("to-lpn"), NOT its label text - a live
  // debug-sheet capture on the real Split IBLPN screen (2026-07-10) showed
  // "Move to LPN: " is actually a separate `type: "label"` item, and the
  // entry field that follows it has `label: ""` (blank) - the visible
  // caption and the input box are two distinct page_content items. Matching
  // on label text (as Truck Temp's "lpn" substring does) silently never
  // matched anything here. `tag` is a stable per-field technical identifier
  // present on every entry field in every captured response so far (e.g.
  // "ibdock", "move-qty", "scanned-batch-nbr") and is a more reliable key
  // than label text in general - Truck Temp's matching wasn't switched to
  // it too since that one is already live-verified working and touching it
  // isn't warranted without a reason.
  static const String camInsertBeforeTag = 'to-lpn';
  static const String camFolderName = 'captured_images';

  // ---- Wooden Pallet Task enhancement (2026-08-15) ----
  // Unlike Truck Temp/POD, this is a different customer's first custom
  // screen - see OWMS User Manual_2026.pdf, "Execute Wooden Pallet
  // Tasks". Augments the real, standard RF screen rather than bypassing it
  // (POD's model was explicitly rejected for this feature - see plan
  // quirky-shimmying-haven.md). Live-confirmed 2026-08-15 (debug-sheet
  // capture) that the real screen (Curr Locn/Task Type filters + task list)
  // has no "Trailer"-labeled field of its own to key an injection off of -
  // unlike Truck Temp, the injected Trailer Nbr field is wholly new,
  // client-side only, shown first on screen, and never submitted through
  // the real RF protocol (see _woodenPalletTrailerField in lib/main.dart).
  // Half the functionality today (trailer -> load -> order lookup, display
  // only); the picking/OBLPN half follows separately.
  static const String wpEnhPageTitleMatch = 'wooden pallet';

  // 2026-08-15 correction: once a task is selected, this feature must
  // actually drive the real RF session (real screens/dialogs, rendered
  // normally) rather than building fake screens on top - live-confirmed
  // that skipping the real protocol left the OBLPN never actually created
  // server-side, so assign_and_load_oblpn rejected it as "Not valid
  // Container nbr". These match the REAL screens' own field labels/dialog
  // text (from live reference screenshots), scoping small injections onto
  // them - see plan quirky-shimmying-haven.md.
  // The real OBLPN-scan field is matched by `tag`, NOT label - live-
  // confirmed 2026-08-15 (debug-sheet capture of the real "Pack NC Active
  // Empties" screen) that its label is blank (`""`); the visible "OBLPN: "
  // caption is a separate `type: "label"` item, same "caption vs field are
  // two distinct page_content items" quirk documented on
  // camInsertBeforeTag above. The real screen ALSO already has its own
  // readonly "OBLPN:"/"OBLPN Type:" display fields (tags
  // packnc-oblpn-disp/packnc-oblpn-type) - no cosmetic duplicate injection
  // needed for those anymore, only this one field gets pre-filled.
  static const String wpEnhOblpnFieldTag = 'packnc-lpn-nbr';
  // The real readonly "OBLPN:" display field - its own value (Oracle's one
  // genuinely valid OBLPN for this task) is what wpEnhOblpnFieldTag's
  // scan field gets pre-filled with (see lib/main.dart) - no client-side
  // generation call any more (2026-08-15, live-confirmed a separately
  // generated number was rejected as "Invalid OBLPN").
  static const String wpEnhOblpnDisplayFieldTag = 'packnc-oblpn-disp';
  // SKU and Qty are two separate real current fields, submitted one after
  // the other on the same screen shape (RF's single-current-field model) -
  // both pre-filled from the same WoodenPalletAllocation (item code /
  // alloc_qty). Still label-matched (not live-confirmed against a
  // debug-sheet capture the way wpEnhOblpnFieldTag was) - correct to a tag
  // match too if these turn out to have blank labels like OBLPN did.
  static const String wpEnhSkuLabelMatch = 'sku';
  static const String wpEnhQtyLabelMatch = 'qty';
  static const String wpEnhDropLocationLabelMatch = 'drop location';
  // Matches the real "Task Ended. Do you want to end all OBLPNs?" dialog -
  // excludes it from _RuntimeScreenState's generic yes/no auto-resolve
  // loop (built for Oracle's unrelated "another active session" conflict),
  // so the operator sees real Accept/Do-not-accept choices instead of it
  // being silently auto-answered. Unverified against a live capture of
  // this exact dialog's `dialog_message` - check the debug sheet and
  // correct this if it's still being auto-resolved.
  static const String wpTaskEndedDialogMatch = 'end all oblpns';

  // ---- Mix Area Task enhancement (2026-08-21) ----
  // That same customer's second custom screen, "Execute Task Mix Area
  // (new)" - same
  // augment-the-real-screen architecture as Wooden Pallet Task, but the
  // real task-list buttons stay live and get filtered in place by a
  // scanned trailer, rather than being hidden behind a separate custom
  // order/task table - see plan quirky-shimmying-haven.md. Independent
  // flag from woodenPalletTaskEnabled - each customization is its own
  // opt-in toggle.
  static const String maEnhPageTitleMatch = 'mix area';
  // Assumed same as wpEnhOblpnFieldTag/wpEnhOblpnDisplayFieldTag - this
  // screen's real page_title looks like the same underlying page template
  // family as Wooden Pallet Task's, but NOT live-confirmed for this
  // specific screen - correct via a debug-sheet capture if the OBLPN field
  // doesn't pre-fill.
  static const String maEnhOblpnFieldTag = 'packnc-lpn-nbr';
  static const String maEnhOblpnDisplayFieldTag = 'packnc-oblpn-disp';
  // Label-matched, same unverified caveat as Wooden Pallet Task's own
  // Qty/Drop Location/SKU constants had before their first live test.
  static const String maEnhSkuLabelMatch = 'sku';
  static const String maEnhQtyLabelMatch = 'qty';
  static const String maEnhDropLocationLabelMatch = 'drop location';
  static const String maEnhCurrLocnLabelMatch = 'curr locn';
  static const String maEnhTaskTypeLabelMatch = 'task type';
  // The real "Task:" entry field (2026-09-26) - distinct from Task Type
  // above (a match on 'task' alone would also match "Task Type", so the
  // call site excludes that explicitly, same idiom as Qty excluding "Qty
  // to Pick"). Needed because a task nbr can reach this screen two ways:
  // tapped from a button list (already captured - see onSubmit's existing
  // _maAllocations.any((a) => a.taskNbr == label) check, where a button's
  // "label" IS the task nbr) or scanned/typed directly into this real
  // field (the label is "Task:", the task nbr is the submitted VALUE) -
  // only the first way was ever wired to capture _maSubmittedTaskNbr, so
  // the Qty prefill below silently never fired for the second.
  static const String maEnhTaskLabelMatch = 'task';
  // print/label/shipping's label_designer_code/printer_name (2026-08-21,
  // see MixAreaTaskService.printShippingLabel) identify a specific Label
  // Designer template and printer defined inside one customer's own Oracle
  // WMS instance - like the page-title-match strings above, that's
  // customer-specific configuration, not something this shared source
  // should hardcode. Baked in per build via WMSNOW_MA_LABEL_DESIGNER_CODE /
  // WMSNOW_MA_PRINTER_NAME; blank on any build that doesn't set them
  // (including the plain dev/testing build).
  static const String maEnhLabelDesignerCode =
      String.fromEnvironment('WMSNOW_MA_LABEL_DESIGNER_CODE');
  static const String maEnhPrinterName =
      String.fromEnvironment('WMSNOW_MA_PRINTER_NAME');

  // ---- Multi Field Barcode - GS1 enhancement (2026-09-27) ----
  // Standard Oracle receiving screen, page_title live-confirmed via debug
  // sheet capture. The real transaction name is customer-specific (their
  // own screen naming), so like Truck Temp's truckTempPageTitleMatch above,
  // it's never hardcoded here - baked in per build via
  // WMSNOW_MFB_GS1_PAGE_TITLE_MATCH (see tools/build_lib.py).
  //
  // Unlike Truck Temp, this can apply to MORE THAN ONE real screen for the
  // same customer (2026-09-28) - e.g. both a receiving screen and a
  // separate task-execute screen that both need the same LPN/Qty/Expiry
  // handling. So the dart-define value is a comma-separated list (same
  // convention as WMSNOW_LOCKED_FEATURE_FLAGS), and the match at each call
  // site is "current transaction name contains ANY entry in this list",
  // not one fixed string. An empty list (the default, every build that
  // doesn't set the dart-define) never matches anything - see
  // onMultiFieldBarcodeGs1Screen in main.dart.
  //
  // The supplier's own printed label encodes LPN+Item as one GS1-128 scan
  // (symbology prefix + AI "00" + SSCC value + AI "240" + item code, no
  // parentheses - those only appear in the label's human-readable text, not
  // the actual scanned data) into the real "LPN:" field, which has WMS's
  // native Multi Field Barcode config enabled to split it (Field Identifier
  // 00, Maximum Length 20, Fixed Width) - see
  // multiFieldBarcodeGs1LpnValuePrefix's doc comment for why the raw scan
  // needs a client-side fix before that native split works correctly.
  static const String _multiFieldBarcodeGs1PageTitleMatchDefine =
      String.fromEnvironment('WMSNOW_MFB_GS1_PAGE_TITLE_MATCH');
  static final List<String> multiFieldBarcodeGs1PageTitleMatches =
      _multiFieldBarcodeGs1PageTitleMatchDefine
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .where((s) => s.isNotEmpty)
          .toList();
  static const String multiFieldBarcodeGs1LpnLabelMatch = 'lpn';
  // WMS's Multi Field Barcode config for identifier "00" expects EXACTLY 20
  // fixed-width characters for the LPN value before it looks for the next
  // identifier ("240"). The supplier's printed SSCC is genuinely only 17-18
  // digits (a real barcode, live-confirmed against the physical label), so
  // scanning it as-is makes WMS overshoot into the item code. The fix
  // (2026-09-27, explicit customer request) is inserting "00" right after
  // this prefix (the symbology identifier + the "00" AI marker itself),
  // padding the value to 20 characters - NOT prepending to the very front
  // of the string, which would land before the symbology identifier and
  // break the prefix WMS's own MFB config matches to pick which of its two
  // configs applies: ]C1 for normal items (8-digit item code) or ]C2 for
  // scrub items (7-digit) - both share this same LPN/SSCC padding need
  // (2026-09-28, extended to ]C2 once the customer confirmed this same
  // screen also receives scrub items, not just a separate one as first
  // scoped) since the padding is about the LPN/SSCC length, unrelated to
  // which item-length config applies - the item-length difference itself
  // is exactly what the two separate WMS configs already handle server-
  // side once the right prefix is matched, nothing this app needs to do
  // for that part. Oracle's own MFB config has "Remove Prefix: Yes" for
  // ]C1 (assumed the same for ]C2, not separately confirmed), so the
  // prefix itself is left in the submitted value - WMS strips it on its
  // own side, this app doesn't need to.
  // ]C1 live-confirmed working end-to-end 2026-09-27 (LPN splits correctly,
  // Item auto-resolves via WMS's own Alternate Item Barcode lookup, screen
  // advances to Qty) - the one blocker along the way turned out to be a
  // test-vs-prod Multi Field Barcode Class config difference (an extra
  // Batch row present in test but not prod), not this padding logic. ]C2
  // handling (2026-09-28) is NOT yet live-tested - confirm the same
  // insertion point is correct once a scrub item is actually scanned.
  static const List<String> multiFieldBarcodeGs1LpnValuePrefixes = [
    ']C100',
    ']C200'
  ];

  // Barcode #1 on the same label: one GS1-128 scan combining AI(02) GTIN
  // [14 digits fixed], AI(20) Variant [2 digits fixed], AI(15) Best Before
  // Date YYMMDD [6 digits fixed], and AI(37) Count [variable length - but
  // it's always the LAST field on this label, so "everything remaining"
  // after AI(15)'s value is its value, no separator needed]. Scanned into
  // two DIFFERENT real fields on two DIFFERENT occasions (per the
  // customer's spec): once into Qty (wants just the Count, leading zeros
  // stripped - "0080" on the label reads as "80"), once into Expiry Date
  // (wants the Best Before Date reformatted, not the raw Count). Neither
  // goes through WMS's Multi Field Barcode config at all - both are a
  // client-side extraction of one specific AI's value out of the same
  // multi-AI scan, same idiom as multiFieldBarcodeGs1LpnValuePrefix's
  // positional parsing but selecting a different segment depending on which
  // field is current when the scan happens.
  static const String multiFieldBarcodeGs1QtyLabelMatch = 'qty';
  // Not live-confirmed against a debug-sheet capture yet (unlike LPN/Qty,
  // which were) - correct this to the exact label if the injection doesn't
  // fire once you reach this field.
  static const String multiFieldBarcodeGs1ExpiryLabelMatch = 'exp';

  // ---- Full Pallet Task enhancement (2026-08-22) ----
  // That same customer's third custom screen - same
  // augment-the-real-screen architecture as Wooden Pallet Task/Mix Area
  // Task, chained through five real screens - see plan
  // quirky-shimmying-haven.md. Independent flag from the other two - each
  // customization is its own opt-in toggle.
  static const String fpEnhPageTitleMatch = 'full pallet';
  // Matches the vehicle-eligibility questionnaire screen's ctrl_keys -
  // unverified against a live capture (first thing to check once this is
  // live-tested), matched by checking BOTH labels are present so an
  // unrelated screen with only one of them never false-matches.
  static const String fpEnhApproveCtrlKeyMatch = 'approve';
  static const String fpEnhRejectCtrlKeyMatch = 'reject';

  // ---- Pick And Allocate serial-driven enhancement (2026-09-08) ----
  // Customer POC 2. On the standard "Pick And Allocate" RF screen, inject a
  // Serial Nbr scan field (with a details table) between the item
  // description and the OBLPN field; a serial scan looks the inventory up
  // via lgfapi (see PickAllocateService) and its result then pre-fills the
  // standard Locn / IBLPN / Qty / Serial-Nbrs fields on the following
  // screens (pre-fill only - the operator still presses Enter on each).
  // Every screen of this transaction carries content.headers.page_title
  // "Pick And Allocate", so scoping is by page_title, not the mainmenu
  // button name. Field tags below are from a live debug-sheet capture
  // (2026-09-08).
  static const String paEnhPageTitleMatch = 'pick and allocate';
  static const String paEnhInjectBeforeTag = 'oblpn-nbr';
  static const String paEnhOrderTypeTag =
      'order-type'; // present once order scanned
  static const String paEnhOrderNbrTag = 'order-nbr';
  static const String paEnhLocnBarcodeTag = 'location-barcode';
  static const String paEnhIblpnTag = 'ib-lpn';
  static const String paEnhQtyTag = 'qty'; // NOT order-qty / to-be-picked
  static const String paEnhSerialTag = 'scanned-value';
  static const String paEnhFieldLabel = 'Serial Nbr';

  // ---- Session activity logging (2026-08-22) ----
  // Per-session log files (RF requests/responses, lgfapi/api calls, key
  // user actions) - see LogService and plan quirky-shimmying-haven.md.
  // Same on-device-storage pattern as camFolderName above.
  static const String logFolderName = 'logs';

  // ---- License expiry (2026-09-18) ----
  //
  // Baked in per build via WMSNOW_LICENSE_EXPIRY (ISO "YYYY-MM-DD") - see
  // tools/build_lib.py's BuildRequest.expiry_date and the Admin Build UI's
  // License card. Fixed for the life of the build: there is no remote way
  // to change it once distributed - a renewal or an extension means
  // generating and redistributing a new build with a later date (see
  // tools/admin_build_ui/expiry_notify.py for the "approaching" email
  // alerts that make sure that happens with notice, not a surprise). Left
  // unset (the default on every unlocked dev/testing build), licenseExpiry
  // is null and the app never blocks on this at all.
  //
  // Deliberately NEVER surfaced anywhere in the UI - no countdown, no
  // date, nothing shown to the device user at any point (see the user's
  // explicit instruction). Only isLicenseExpired() is used, purely to
  // decide whether to block login - see LoginScreen in main.dart.
  static const String _licenseExpiryDefine =
      String.fromEnvironment('WMSNOW_LICENSE_EXPIRY');

  static DateTime? get licenseExpiry {
    final raw = _licenseExpiryDefine.trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static const _lastSeenDatePrefsKey = 'oracle_custom_app_last_seen_date';

  /// True once today - or the latest date this device has ever genuinely
  /// observed, whichever is later - is past the baked-in expiry date.
  /// Persisting the latest-seen date means simply rolling the device's
  /// clock backward can't un-expire the app on its own; this is a real
  /// deterrent against the easy version of that trick, not a hard
  /// guarantee (a factory reset/fresh install clears the persisted value).
  static Future<bool> isLicenseExpired() async {
    final expiry = licenseExpiry;
    if (expiry == null) return false; // unlocked dev/testing build - no-op
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final lastSeenMs = prefs.getInt(_lastSeenDatePrefsKey);
    final lastSeen = lastSeenMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lastSeenMs)
        : null;
    if (lastSeen == null || now.isAfter(lastSeen)) {
      await prefs.setInt(_lastSeenDatePrefsKey, now.millisecondsSinceEpoch);
    }
    final effectiveNow =
        (lastSeen != null && lastSeen.isAfter(now)) ? lastSeen : now;
    return effectiveNow.isAfter(expiry);
  }
}
