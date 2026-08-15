import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One selectable Oracle WMS instance - name shown in the login screen's
/// environment dropdown, the full `domain` + `instance` URL path segment it
/// maps to, and its own OAuth app registration (each environment has been
/// confirmed to need its own client_id/client_secret pair - they are NOT
/// shared across instances, even ones under the same domain).
///
/// `domain` is per-environment, NOT a shared app-wide constant - live-tested
/// 2026-07-11 that two environments ("flow_test" and "flow") can live on
/// COMPLETELY DIFFERENT HOSTS (`tb2.wms.ocs.oraclecloud.com` vs
/// `b2.wms.ocs.oraclecloud.com` - a "test" pod vs its differently-named
/// non-test counterpart), not just different path segments under one fixed
/// domain. Treating domain as fixed silently sent every "flow" request to
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
  int get hashCode => Object.hash(name, domain, instance, clientId, clientSecret);

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
        domain: (j['domain'] as String?) ?? 'https://tb2.wms.ocs.oraclecloud.com',
        instance: j['instance'] as String,
        clientId: j['clientId'] as String,
        clientSecret: j['clientSecret'] as String,
      );
}

/// Which client-side add-ons (built for one specific customer, not part of
/// the generic RF renderer) are currently active - see AppConfig.currentFlags
/// for how this is loaded/applied. Unlike environment locking, this is
/// deliberately a runtime, admin-editable-any-time toggle, not a
/// build-time-only one (2026-07-25 decision) - flipping it takes effect
/// immediately, no rebuild/reinstall needed.
class FeatureFlags {
  final bool podEnabled;
  final bool truckTempEnabled;
  const FeatureFlags(
      {required this.podEnabled, required this.truckTempEnabled});

  // Base app ships with no customer-specific customizations active - each
  // one is opt-in per device via Feature Settings, not on by default.
  static const defaults =
      FeatureFlags(podEnabled: false, truckTempEnabled: false);
}

/// Where captured photos/signatures get uploaded - see UploadService and
/// tools/captured_files_receiver.py. `baseUrl` empty means unconfigured.
class UploadServerConfig {
  final String baseUrl;
  final String token;
  const UploadServerConfig({required this.baseUrl, required this.token});
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
  static const List<Environment> _seedEnvironments = [
    Environment(
      name: 'flow_test',
      domain: 'https://tb2.wms.ocs.oraclecloud.com',
      instance: 'flow_test',
      clientId: '',
      clientSecret: '',
    ),
    // Domain corrected 2026-07-11 (was assumed to share flow_test's
    // tb2.wms.ocs.oraclecloud.com host - live-tested wrong, this environment
    // actually lives on a different host, b2 not tb2).
    Environment(
      name: 'flow',
      domain: 'https://b2.wms.ocs.oraclecloud.com',
      instance: 'flow',
      clientId: '',
      clientSecret: '',
    ),
  ];

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
  //   flutter build apk --release --dart-define=JAPRA_LOCKED_ENVIRONMENTS="name1#domain1#instance1#clientId1#clientSecret1,name2#domain2#instance2#clientId2#clientSecret2"
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
      String.fromEnvironment('JAPRA_LOCKED_ENVIRONMENTS');

  static bool get isLocked => _lockedEnvironmentsDefine.trim().isNotEmpty;

  static List<Environment> _parseLockedEnvironments() {
    return _lockedEnvironmentsDefine.split(',').where((e) => e.trim().isNotEmpty).map((entry) {
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
    await prefs.setString(
        _environmentsPrefsKey, jsonEncode(envs.map((e) => e.toJson()).toList()));
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

  // ---- Feature flags (2026-07-25) ----
  //
  // POD and Truck Temp were built for Flow Logistics specifically - CCI
  // (and any future customer) may have none of that, just standard RF
  // screens the generic renderer already handles. currentFlags is a plain
  // static field (same idiom as `current` below for the selected
  // Environment) - read synchronously from _MenuView/_ScreenView wherever
  // an add-on needs to check whether it's active, loaded once in
  // RuntimeScreen.initState() before the mainmenu can ever render, and
  // updated immediately (memory + persisted) whenever FeatureSettingsScreen
  // changes something - no restart required for a toggle to take effect.
  static const _featureFlagsPrefsKey = 'oracle_custom_app_feature_flags';

  static FeatureFlags currentFlags = FeatureFlags.defaults;

  static Future<FeatureFlags> loadFeatureFlags() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_featureFlagsPrefsKey);
    if (raw == null) return FeatureFlags.defaults;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return FeatureFlags(
      podEnabled: (decoded['podEnabled'] ?? false) as bool,
      truckTempEnabled: (decoded['truckTempEnabled'] ?? false) as bool,
    );
  }

  static Future<void> saveFeatureFlags(FeatureFlags flags) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _featureFlagsPrefsKey,
        jsonEncode({
          'podEnabled': flags.podEnabled,
          'truckTempEnabled': flags.truckTempEnabled,
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
    assert(e != null, 'AppConfig.current not set - select an environment before making requests.');
    return e!;
  }

  static String get instance => _env.instance;
  static String get clientId => _env.clientId;
  static String get clientSecret => _env.clientSecret;

  // ---- derived URLs ----
  static String get base => '${_env.domain}/${_env.instance}';
  static String get tokenUrl => '$base/api/oauth2/token/';
  static String get rwmobileUrl => '$base/wms/lgfapi/v10/htmlrf/get_next_rwmobile_page';
  static String get lgfapiBase => '$base/wms/lgfapi/v10';

  // ---- Truck Temp enhancement rule (Phase 2) ----
  // Inject a "Truck Temp" field before the LPN control, and persist it to
  // ib_shipment.cust_field_1 via lgfapi. Restricted to one specific
  // transaction (2026-07-10 - previously this matched ANY screen with an
  // "lpn"-labeled field, which is most of the RF menu: GR - MARS Imports,
  // MARS Directed/Manual Putaway, Manual Locate LPN, Split IBLPN, MARS
  // Create LPN, RF Lock/Unlock IBLPN, etc. `_RuntimeScreenState` tracks
  // which mainmenu item was tapped to reach the current screen - see
  // `_currentTransactionName` - and only injects the field when that name
  // contains this substring, case-insensitively.
  static const String enhPageTitleMatch = 'mars receive skus - fg';
  static const String enhInsertBeforeLabel = 'lpn';
  static const String enhFieldLabel = 'Truck Temp (\u00b0C)';
  static const String enhSaveEntity = 'ib_shipment';
  // Corrected 2026-07-10 (was 'cust_field_1', a generic text field guessed
  // early on) - the developer's own reference confirms `cust_decimal_1` is
  // the intended decimal-typed custom field for this value.
  static const String enhSaveField = 'cust_decimal_1';
  static const String enhLookupLabelMatch = 'shipment';
  static const String enhLookupQueryParam = 'shipment_nbr';
  // Added 2026-07-10 - the shipment lookup must also be scoped by the
  // session's active facility/company (sourced from the response's own
  // `content.headers.fac_code`/`comp_code`, not typed/guessed), confirmed
  // live: `shipment_nbr` alone is not guaranteed unique across
  // facility/company. Live-tested against the real flow_test instance -
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
}
