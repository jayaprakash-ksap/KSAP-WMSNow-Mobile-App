import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'config/app_config.dart';
import 'logs/logs_screen.dart';
import 'pod/captured_files_screen.dart';
import 'pod/pod_screen.dart';
import 'receiving/combined_receiving_screen.dart';
import 'receiving/serial_receiving_screen.dart';
import 'services/auth_service.dart';
import 'services/email_relay_service.dart';
import 'services/full_pallet_task_service.dart';
import 'services/log_service.dart';
import 'services/log_upload_service.dart';
import 'services/mix_area_task_service.dart';
import 'services/pick_allocate_service.dart';
import 'services/rwmobile_service.dart';
import 'services/upload_service.dart';
import 'services/wooden_pallet_service.dart';

void main() => runApp(const WmsNowRedwoodApp());

class WmsNowRedwoodApp extends StatelessWidget {
  const WmsNowRedwoodApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2A4B54)),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}

// ============================================================ LOGIN
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _auth = AuthService();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  // Loaded from persistent storage (see AppConfig.loadEnvironments) rather
  // than a fixed compile-time list - the operator can add/edit/delete
  // entries via the top-right "Manage Environments" screen (2026-07-11).
  List<Environment> _environments = [];
  bool _loadingEnvs = true;

  // No default - the operator picks an environment fresh every launch
  // (2026-07-11 decision), rather than the app silently reusing whatever was
  // selected last, so the wrong WMS instance can't be hit by mistake.
  Environment? _selectedEnv;

  // License expiry (2026-09-18) - checked once on screen load, before the
  // operator can do anything else. Null while the check is still in
  // flight (SharedPreferences is async) so the normal login form doesn't
  // flash on screen for a moment on an actually-expired build; true means
  // blocked. Never shows a date/countdown - see AppConfig.isLicenseExpired.
  bool? _licenseExpired;

  @override
  void initState() {
    super.initState();
    _loadEnvironments();
    AppConfig.isLicenseExpired().then((expired) {
      if (mounted) setState(() => _licenseExpired = expired);
    });
  }

  Future<void> _loadEnvironments() async {
    final envs = await AppConfig.loadEnvironments();
    if (!mounted) return;
    setState(() {
      _environments = envs;
      _loadingEnvs = false;
      // A previously-selected environment may have just been edited/deleted
      // in the Manage Environments screen. Re-point to whichever NEW
      // instance has the same name (picking up any edited fields), or clear
      // the selection if it was deleted - critically, this must REPLACE
      // `_selectedEnv`, not just decide keep-vs-clear, because leaving it
      // pointing at the old (now content-stale) object crashes
      // DropdownButtonFormField's "exactly one matching item" assertion the
      // moment its fields no longer match any entry in the reloaded list,
      // even with Environment's `==` now doing value comparison.
      if (_selectedEnv != null) {
        Environment? match;
        for (final e in envs) {
          if (e.name == _selectedEnv!.name) {
            match = e;
            break;
          }
        }
        _selectedEnv = match;
      }
    });
  }

  Future<void> _openEnvironmentManager() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const EnvironmentManagerScreen(),
    ));
    await _loadEnvironments();
  }

  Future<void> _openFeatureSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const FeatureSettingsScreen(),
    ));
  }

  Future<void> _login() async {
    if (_selectedEnv == null) {
      setState(() => _error = 'Select an environment first.');
      return;
    }
    AppConfig.current = _selectedEnv;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Start the session log BEFORE attempting login, so a failed attempt
      // (bad password, misconfigured environment) is still captured - see
      // LogService.startSession's doc comment.
      await LogService.startSession(
          instance: _selectedEnv!.instance, username: _user.text.trim());
      // Fire-and-forget (2026-09-26) - catches up anything a previous
      // session couldn't push (device was offline, relay wasn't running,
      // etc.) without making the operator wait on it to log in. Not
      // awaited on purpose - see syncPendingInBackground's doc comment.
      unawaited(LogUploadService.syncPendingInBackground());
      await _auth.login(_user.text.trim(), _pass.text);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => RuntimeScreen(auth: _auth),
      ));
    } catch (e) {
      // Dart's Exception.toString() prepends "Exception: " - stripped here
      // so the operator sees just the actual message (see
      // AuthService._describeLoginFailure for what that message contains).
      final msg = e.toString();
      setState(() => _error = msg.startsWith('Exception: ')
          ? msg.substring('Exception: '.length)
          : msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Blocks the entire login screen - no fields, no way through, nothing
    // shown but a plain generic message (no date, no "days left", nothing
    // that reveals anything about the expiry itself, per instruction).
    // Checked before anything else renders; while the check is still
    // pending (_licenseExpired == null) the normal screen renders as
    // usual, exactly like an unlocked build with no expiry set at all.
    if (_licenseExpired == true) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 56, color: Colors.black45),
                SizedBox(height: 16),
                Text(
                  'This app is no longer active.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                Text(
                  'Please contact your WMSNow representative.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Activity Logs',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const LogsScreen(),
            )),
          ),
          // Hidden entirely on a build-locked app (2026-08-27) - every
          // field either screen would let the operator look at is already
          // fixed and read-only (see AppConfig.isLocked), so there's
          // nothing left for them to do there. This is what actually
          // delivers "the app should start with Login only" for a locked
          // customer build.
          if (!AppConfig.isLocked) ...[
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Feature Settings',
              onPressed: _openFeatureSettings,
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Manage Environments',
              onPressed: _openEnvironmentManager,
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          // Warehouse illustration background (2026-08-21) - replaces the
          // earlier Material-icon watermark. A static bundled asset (no
          // network fetch, no runtime processing), so it's decoded once and
          // cached by Flutter's own image cache - no ongoing performance
          // cost. bottomCenter keeps the illustration itself (bottom half
          // of the source image) anchored in frame across both the tall
          // mobile aspect ratio and the wide desktop window, rather than
          // letting BoxFit.cover crop it unpredictably per platform.
          // cacheWidth bounds the DECODED bitmap to the device's actual
          // physical pixel width - without it, Flutter decodes the source
          // PNG at its full 1255px width regardless of how small the
          // screen actually renders it, wasting decode time/memory on a
          // low-end device for no visible gain.
          Positioned.fill(
            child: Image.asset(
              'assets/images/warehouse_bg.png',
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
              cacheWidth: (MediaQuery.of(context).size.width *
                      MediaQuery.of(context).devicePixelRatio)
                  .round(),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                // The form sits on its own near-opaque card rather than
                // directly on the illustration - keeps every label/value
                // sharply legible regardless of how busy the image behind
                // it is, per the "text must stay clearly readable" ask.
                child: Card(
                  elevation: 6,
                  color: Colors.white.withValues(alpha: 0.94),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(AppConfig.appName,
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold)),
                        const Text('Oracle WMS Redwood client',
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 24),
                        DropdownButtonFormField<Environment>(
                          initialValue: _selectedEnv,
                          decoration: InputDecoration(
                            labelText: 'Environment',
                            border: const OutlineInputBorder(),
                            helperText: _loadingEnvs
                                ? 'Loading...'
                                : _environments.isEmpty
                                    ? 'None configured - tap the settings icon above to add one'
                                    : null,
                          ),
                          items: _environments
                              .map((e) => DropdownMenuItem(
                                  value: e, child: Text(e.name)))
                              .toList(),
                          onChanged: (_busy || _loadingEnvs)
                              ? null
                              : (e) => setState(() => _selectedEnv = e),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _user,
                          decoration: const InputDecoration(
                              labelText: 'WMS username',
                              border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pass,
                          obscureText: true,
                          decoration: const InputDecoration(
                              labelText: 'Password',
                              border: OutlineInputBorder()),
                          onSubmitted: (_) => _login(),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _busy ? null : _login,
                          child: _busy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Sign in'),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!,
                              style: const TextStyle(color: Colors.red)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================ ENVIRONMENTS
/// Lets the operator add/edit/delete the WMS environments offered on the
/// Login screen's dropdown - reached via that screen's top-right settings
/// icon (2026-07-11). Changes are persisted immediately on every add/edit/
/// delete (AppConfig.saveEnvironments), not batched behind a separate "Save"
/// step, so nothing is lost if the operator navigates back without an
/// explicit confirm.
class EnvironmentManagerScreen extends StatefulWidget {
  const EnvironmentManagerScreen({super.key});
  @override
  State<EnvironmentManagerScreen> createState() =>
      _EnvironmentManagerScreenState();
}

class _EnvironmentManagerScreenState extends State<EnvironmentManagerScreen> {
  List<Environment> _environments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final envs = await AppConfig.loadEnvironments();
    if (!mounted) return;
    setState(() {
      _environments = envs;
      _loading = false;
    });
  }

  Future<void> _persist() => AppConfig.saveEnvironments(_environments);

  Future<void> _add() async {
    final env = await showDialog<Environment>(
      context: context,
      builder: (_) => const _EnvironmentFormDialog(),
    );
    if (env == null) return;
    setState(() => _environments = [..._environments, env]);
    await _persist();
  }

  Future<void> _edit(int index) async {
    final env = await showDialog<Environment>(
      context: context,
      builder: (_) => _EnvironmentFormDialog(existing: _environments[index]),
    );
    if (env == null) return;
    setState(() => _environments = [
          for (var i = 0; i < _environments.length; i++)
            i == index ? env : _environments[i],
        ]);
    await _persist();
  }

  Future<void> _delete(int index) async {
    final env = _environments[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete environment?'),
        content: Text('"${env.name}" will be removed. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _environments = [
          for (var i = 0; i < _environments.length; i++)
            if (i != index) _environments[i],
        ]);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Environments'),
        actions: [
          // Hidden entirely on a build-locked app (2026-07-24, see
          // AppConfig.isLocked) - the seeded environment(s) are already the
          // only ones this build can ever use, so there's nothing valid to
          // add.
          if (!AppConfig.isLocked)
            IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add environment',
                onPressed: _add),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _environments.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No environments configured yet.\nTap + above to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _environments.length,
                  itemBuilder: (_, i) {
                    final env = _environments[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: ListTile(
                        title: Text(env.name),
                        subtitle: Text(instanceUrlPreview(env)),
                        onTap: () => _edit(i),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            // Every field is read-only on a locked build
                            // (2026-07-24) - "Edit" would be misleading, so
                            // this becomes a plain view action instead.
                            icon: Icon(AppConfig.isLocked
                                ? Icons.visibility_outlined
                                : Icons.edit),
                            tooltip: AppConfig.isLocked ? 'View' : 'Edit',
                            onPressed: () => _edit(i),
                          ),
                          // Locked builds can't delete their seeded
                          // environment(s) - doing so would leave the
                          // operator stuck with no way to add a replacement
                          // (Add is hidden too, see the AppBar above).
                          if (AppConfig.isLocked)
                            const Tooltip(
                              message: 'Locked by this app build',
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(Icons.lock_outline, size: 20),
                              ),
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Delete',
                              onPressed: () => _delete(i),
                            ),
                        ]),
                      ),
                    );
                  },
                ),
    );
  }
}

String instanceUrlPreview(Environment env) => '${env.domain}/${env.instance}/';

/// Lets an admin turn customer-specific client-side add-ons (POD, Truck
/// Temp - see FeatureFlags' doc comment) on or off at any time, not just at
/// build time - reached from the Login screen, same open-access precedent
/// as Manage Environments (no PIN/login-role system exists in this app).
/// Each toggle applies immediately (persisted + AppConfig.currentFlags
/// updated together in AppConfig.saveFeatureFlags) - no restart needed.
class FeatureSettingsScreen extends StatefulWidget {
  const FeatureSettingsScreen({super.key});
  @override
  State<FeatureSettingsScreen> createState() => _FeatureSettingsScreenState();
}

class _FeatureSettingsScreenState extends State<FeatureSettingsScreen> {
  FeatureFlags _flags = FeatureFlags.defaults;
  EmailServerConfig _emailConfig =
      const EmailServerConfig(baseUrl: '', token: '');
  LogServerConfig _logConfig = const LogServerConfig(baseUrl: '', token: '');
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final flags = await AppConfig.loadFeatureFlags();
    final emailConfig = await AppConfig.loadEmailServer();
    final logConfig = await AppConfig.loadLogServer();
    if (!mounted) return;
    setState(() {
      _flags = flags;
      _emailConfig = emailConfig;
      _logConfig = logConfig;
      _loading = false;
    });
  }

  Future<void> _set(FeatureFlags flags) async {
    setState(() => _flags = flags);
    await AppConfig.saveFeatureFlags(flags);
  }

  /// Mirrors CapturedFilesScreen._editUploadServer's dialog almost exactly
  /// (lib/pod/captured_files_screen.dart) - same Server URL/Token shape,
  /// just a different AppConfig-backed config (see EmailServerConfig's doc
  /// comment on why this is a separate relay from the Upload Server).
  Future<void> _editEmailServer() async {
    final urlCtrl = TextEditingController(text: _emailConfig.baseUrl);
    final tokenCtrl = TextEditingController(text: _emailConfig.token);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Email Server (Reject notification relay)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.5:8766',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Matches tools/trailer_reject_email_receiver.py running on '
              'the project machine. Leave Server URL blank to skip sending '
              'the Reject notification email (rejecting the trailer in '
              'Oracle still works either way).',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final config = EmailServerConfig(
      baseUrl: urlCtrl.text.trim(),
      token: tokenCtrl.text.trim(),
    );
    await AppConfig.saveEmailServer(config);
    if (!mounted) return;
    setState(() => _emailConfig = config);
  }

  /// Mirrors _editEmailServer above almost exactly - a different
  /// AppConfig-backed config feeding a different relay (see
  /// LogServerConfig's doc comment on why this is separate from both the
  /// Upload Server and the Email Server).
  Future<void> _editLogServer() async {
    final urlCtrl = TextEditingController(text: _logConfig.baseUrl);
    final tokenCtrl = TextEditingController(text: _logConfig.token);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log Server (Admin Build UI)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.5:5050',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Matches the Admin Build UI (tools/admin_build_ui/app.py) '
              'running on the project machine - uploads this device\'s '
              'session logs so they\'re browsable from there. Leave Server '
              'URL blank to keep logs local-only (Activity Logs still works '
              'either way).',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final config = LogServerConfig(
      baseUrl: urlCtrl.text.trim(),
      token: tokenCtrl.text.trim(),
    );
    await AppConfig.saveLogServer(config);
    if (!mounted) return;
    setState(() => _logConfig = config);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feature Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Baked in by this app's build when locked (2026-08-27,
                // see AppConfig's WMSNOW_LOCKED_FEATURE_FLAGS handling) -
                // read-only here, same reasoning as Manage Environments'
                // locked fields (AppConfig.isLocked's doc comment).
                if (AppConfig.isLocked)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(children: [
                      Icon(Icons.lock_outline, size: 18, color: Colors.black54),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Customizations are locked by this app build.',
                          style: TextStyle(color: Colors.black54, fontSize: 13),
                        ),
                      ),
                    ]),
                  ),
                SwitchListTile(
                  title: const Text('POD (Proof of Delivery)'),
                  subtitle: const Text(
                      'Adds a Proof of Delivery step to the main menu for capturing a '
                      'signature and delivery photos.'),
                  value: _flags.podEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) => _set(_flags.copyWith(podEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Truck Temp'),
                  subtitle: const Text(
                      'Requires a truck temperature reading during receiving, before '
                      'putaway can continue.'),
                  value: _flags.truckTempEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) => _set(_flags.copyWith(truckTempEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Wooden Pallet Task'),
                  subtitle: const Text(
                      'Lets the operator scan a trailer number to automatically look up '
                      'its load, order, and task list before starting a Wooden Pallet Task.'),
                  value: _flags.woodenPalletTaskEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) =>
                          _set(_flags.copyWith(woodenPalletTaskEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Mix Area Task'),
                  subtitle: const Text(
                      'Filters the Mix Area task list down to only the tasks for a '
                      'scanned trailer.'),
                  value: _flags.mixAreaTaskEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) => _set(_flags.copyWith(mixAreaTaskEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Full Pallet Task'),
                  subtitle: const Text(
                      'Adds trailer lookup, a vehicle eligibility check, and a guided '
                      'pick-by-SKU/Pallet/LPN flow to the Full Pallet Task screen.'),
                  value: _flags.fullPalletTaskEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) => _set(_flags.copyWith(fullPalletTaskEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Serial Receiving'),
                  subtitle: const Text(
                      'Adds a serial-driven receiving flow to the main menu: scan '
                      'expected serials, confirm a manual putaway location per LPN, '
                      'then Sync the receipt and putaway to WMS.'),
                  value: _flags.serialReceivingEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) => _set(_flags.copyWith(serialReceivingEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Pick And Allocate - Serial'),
                  subtitle: const Text(
                      'On the standard Pick And Allocate RF screen, adds a Serial '
                      'Nbr field: scanning a serial looks up its inventory and '
                      'pre-fills the Locn, IBLPN, Qty and Serial fields on the '
                      'following screens.'),
                  value: _flags.pickAllocateSerialEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) =>
                          _set(_flags.copyWith(pickAllocateSerialEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Receiving Serial/Non Serial'),
                  subtitle: const Text(
                      'Adds a combined receiving screen with a Serial / Non Serial '
                      'toggle: serial-scan receiving, or shipment-line receiving '
                      'with an entered quantity per LPN. Manual putaway then Sync '
                      'to WMS, same as Serial Receiving.'),
                  value: _flags.combinedReceivingEnabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) =>
                          _set(_flags.copyWith(combinedReceivingEnabled: v)),
                ),
                SwitchListTile(
                  title: const Text('Multi Field Barcode - GS1'),
                  subtitle: const Text(
                      'On a standard receiving screen: splits a combined LPN+Item '
                      'GS1 barcode to match WMS\'s Multi Field Barcode config, and '
                      'extracts Qty/Expiry Date from a barcode that combines them '
                      'with GTIN/Variant.'),
                  value: _flags.multiFieldBarcodeGs1Enabled,
                  onChanged: AppConfig.isLocked
                      ? null
                      : (v) =>
                          _set(_flags.copyWith(multiFieldBarcodeGs1Enabled: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email Server (Reject notification)'),
                  subtitle: Text(_emailConfig.isConfigured
                      ? _emailConfig.baseUrl
                      : 'Not configured - Reject email will be skipped'),
                  onTap: _editEmailServer,
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Log Server (Admin Build UI)'),
                  subtitle: Text(_logConfig.isConfigured
                      ? _logConfig.baseUrl
                      : 'Not configured - logs stay local-only on this device'),
                  onTap: _editLogServer,
                ),
              ],
            ),
    );
  }
}

class _EnvironmentFormDialog extends StatefulWidget {
  final Environment? existing;
  const _EnvironmentFormDialog({this.existing});
  @override
  State<_EnvironmentFormDialog> createState() => _EnvironmentFormDialogState();
}

class _EnvironmentFormDialogState extends State<_EnvironmentFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _domain = TextEditingController(
      text: widget.existing?.domain ?? AppConfig.defaultDomain);
  late final _instance =
      TextEditingController(text: widget.existing?.instance ?? '');
  late final _clientId =
      TextEditingController(text: widget.existing?.clientId ?? '');
  late final _clientSecret =
      TextEditingController(text: widget.existing?.clientSecret ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _domain.dispose();
    _instance.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty ||
        _domain.text.trim().isEmpty ||
        _instance.text.trim().isEmpty ||
        _clientId.text.trim().isEmpty ||
        _clientSecret.text.trim().isEmpty) {
      setState(() => _error = 'All fields are required.');
      return;
    }
    Navigator.of(context).pop(Environment(
      name: _name.text.trim(),
      // Trim any trailing slash so instanceUrlPreview/AppConfig.base don't
      // end up with a double slash between domain and instance.
      domain: _domain.text.trim().replaceFirst(RegExp(r'/+$'), ''),
      instance: _instance.text.trim(),
      clientId: _clientId.text.trim(),
      clientSecret: _clientSecret.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppConfig.isLocked
          ? 'Environment (locked by this app build)'
          : widget.existing == null
              ? 'Add Environment'
              : 'Edit Environment'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            enabled: !AppConfig.isLocked,
            decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. mycompany_test',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          // Added 2026-07-11 - domain is per-environment, not a shared app
          // constant (two environments can live on entirely different hosts,
          // e.g. tb2.wms.ocs.oraclecloud.com vs b2.wms.ocs.oraclecloud.com -
          // confirmed live). Previously this wasn't configurable at all and
          // silently used one fixed domain for every environment.
          //
          // Every field, including Client ID/Secret, is read-only on a
          // build-locked app (revised 2026-07-24 - previously only
          // Domain/Instance were locked, with the operator still filling in
          // credentials per device; now the whole environment is baked in
          // at build time by tools/generate_customer_build.py, so there's
          // nothing left for the UI to let anyone edit). A credential
          // change means generating and redistributing a new APK, not
          // editing one in place - see AppConfig.isLocked's doc comment.
          TextField(
            controller: _domain,
            enabled: !AppConfig.isLocked,
            decoration: const InputDecoration(
                labelText: 'Domain',
                hintText: 'e.g. https://tb2.wms.ocs.oraclecloud.com',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instance,
            enabled: !AppConfig.isLocked,
            decoration: const InputDecoration(
                labelText: 'Instance (URL path segment)',
                hintText: 'e.g. mycompany_test',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientId,
            enabled: !AppConfig.isLocked,
            decoration: const InputDecoration(
                labelText: 'OAuth Client ID', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientSecret,
            enabled: !AppConfig.isLocked,
            decoration: const InputDecoration(
                labelText: 'OAuth Client Secret', border: OutlineInputBorder()),
            maxLines: 2,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ]),
      ),
      actions: AppConfig.isLocked
          ? [
              FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close')),
            ]
          : [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel')),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
    );
  }
}

// ============================================================ RUNTIME
class RuntimeScreen extends StatefulWidget {
  final AuthService auth;
  const RuntimeScreen({super.key, required this.auth});
  @override
  State<RuntimeScreen> createState() => _RuntimeScreenState();
}

class _RuntimeScreenState extends State<RuntimeScreen> {
  late final RwmobileService _rw = RwmobileService(widget.auth);
  Map<String, dynamic>? _page;
  bool _busy = true;
  // Incremented every time a new response is rendered - used as a widget
  // key for _EntryView so it always gets a genuinely fresh state (and text
  // controller) per response, rather than relying on htmlrfid happening to
  // differ (it normally does, but this is a deterministic guarantee rather
  // than an assumption). Added 2026-07-09 alongside the htmlrfid-based key
  // to fix stale text carrying over between consecutive entry/barcode
  // dialogs (e.g. Batch Nbr's typed value showing up in Expiry Date).
  int _renderCount = 0;

  // Remembers the last screen's "Previous Screen" ctrl_key, persisted
  // across responses that don't carry their own ctrl_keys at all (e.g. an
  // "Invalid format" info dialog interrupting an entry field) - added
  // 2026-07-09. Recomputing this fresh from EVERY response and falling back
  // to a hardcoded "W" whenever the current response has no ctrl_keys meant
  // dismissing an error on a screen that actually uses "F2" silently sent
  // the wrong key, which Oracle ignored - looking exactly like "OK/Back
  // does nothing" on that error dialog.
  String _previousScreenKey = 'W';
  // remembers entered values by label so the enhancement engine can key saves
  final Map<String, String> _memory = {};

  // Name of the mainmenu item that was tapped to enter whatever transaction
  // is currently on screen - added
  // 2026-07-10 so the Truck Temp injection (see
  // AppConfig.truckTempPageTitleMatch) can be scoped to one specific
  // transaction instead of matching every
  // screen that happens to have an "lpn"-labeled field. The RF API itself
  // gives no reliable per-screen "which transaction is this" signal other
  // than the name shown on the mainmenu button that led here, so this is
  // tracked client-side rather than read off the response. Set once when a
  // mainmenu item is tapped and left untouched while navigating within that
  // same transaction (including through End LPN, which loops back to the
  // top of the same screen rather than to the mainmenu).
  String _currentTransactionName = '';

  // Active facility/company code, sourced from `content.headers.fac_code`/
  // `comp_code` on every response (added 2026-07-10 for the Truck Temp
  // shipment lookup, which needs both to scope the query safely). Persisted
  // across responses the same way as `_previousScreenKey` - not every
  // response necessarily repeats these, so only overwrite when a response
  // actually supplies a fresh, non-empty value.
  String _facCode = '';
  String _compCode = '';

  // Session identity: TRACK LATEST, updated from every response. Reversed
  // from an earlier frozen-forever model (pinned to the very first response,
  // never updated again) after extensive live testing on 2026-07-09 - both
  // independently and by the developer directly in Postman - repeatedly
  // showed that resolving an "another active session" conflict requires
  // adopting whatever htmlrfid/clientid the most recent response echoes.
  // The frozen model routinely produced "this user session has expired"
  // once the live session moved onto a different htmlrfid than the one
  // pinned at login; always tracking the latest values does not.
  int _sessionClientId = 0;
  String _sessionHtmlrfid = '';

  void _captureSession(Map<String, dynamic> res) {
    final cid = res['clientid'];
    if (cid is int && cid != 0) _sessionClientId = cid;
    if (cid is String && cid.isNotEmpty) {
      _sessionClientId = int.tryParse(cid) ?? _sessionClientId;
    }
    final hid = res['htmlrfid'];
    if (hid is String && hid.isNotEmpty) _sessionHtmlrfid = hid;
  }

  bool _started = false;

  bool _isYesNo(Map<String, dynamic> res) {
    final c = (res['content'] ?? {}) as Map<String, dynamic>;
    return res['type'] == 'dialog' && c['dialog_type'] == 'yesno';
  }

  /// True only for yes/no dialogs this app should silently auto-answer
  /// without ever showing the operator - Oracle's generic "another active
  /// session" conflict (see _send()'s doc comment). A yesno dialog that's a
  /// genuine operator decision (e.g. Wooden Pallet Task's "Task Ended...
  /// do you want to end all OBLPNs?", 2026-08-15) must NOT be silently
  /// auto-answered - excluded here by message rather than assumed safe by
  /// default, so any other/future yesno dialog keeps today's
  /// conflict-clearing behavior unchanged unless it's explicitly proven to
  /// need a real operator choice, the same way this one was.
  bool _isAutoResolvableYesNo(Map<String, dynamic> res) {
    if (!_isYesNo(res)) return false;
    final c = (res['content'] ?? {}) as Map<String, dynamic>;
    final msg = (c['dialog_message'] ?? '').toString().toLowerCase();
    if (msg.contains(AppConfig.wpTaskEndedDialogMatch)) return false;
    return true;
  }

  // Keeps the server's copy of this session's log close to current while
  // the session is still running (2026-09-26), not just at login/logout -
  // re-sends the whole file each tick (same idempotent, overwrite-based
  // design as LogUploadService.syncAll itself; see its doc comment) rather
  // than an incremental/delta upload, which would need persistent offset
  // state on top of a flaky warehouse WiFi connection and risks duplicating
  // or corrupting the server's copy on a retry/race. A session log is plain
  // text (tens-hundreds of KB even for a full shift), so re-sending the
  // whole thing every 30s is not a meaningful bandwidth cost - a no-op if
  // this build has no Log Server configured at all.
  Timer? _logSyncTimer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _logSyncTimer = Timer.periodic(const Duration(seconds: 30),
        (_) => LogUploadService.syncPendingInBackground());
  }

  @override
  void dispose() {
    _logSyncTimer?.cancel();
    _rw.dispose();
    super.dispose();
  }

  /// Fire the initial {} EXACTLY once. If the widget rebuilds/re-inits, a second
  /// {} would create a NEW session (new clientid) and orphan the first - which
  /// makes the htmlrfid we answer with stale, so the server spawns yet another
  /// session and re-shows the dialog. The guard prevents that.
  Future<void> _bootstrap() async {
    if (_started) return;
    _started = true;
    // Must finish before the mainmenu can ever render, since _MenuView
    // reads AppConfig.currentFlags synchronously (see FeatureFlags' doc
    // comment) - awaited here rather than fired-and-forgotten.
    AppConfig.currentFlags = await AppConfig.loadFeatureFlags();
    await _send(() => _rw.start(), isBootstrap: true);
  }

  String get _htmlrfid => _sessionHtmlrfid;
  int get _clientid => _sessionClientId;

  static const _networkTimeout = Duration(seconds: 25);
  // Live-verified this needs to be at least 2, not 1 (see the comment in
  // _send() below) - set with headroom above that observed baseline.
  static const _maxYesAttempts = 6;
  // Small pacing gap between consecutive auto-yes retries specifically
  // (not between the yes and replaying the original action - that gap was
  // live-tested and is not what causes this conflict, see the doc comment
  // in rwmobile_service.dart). This is just a little breathing room between
  // repeated attempts at the same still-transitioning conflict.
  static const _yesRetryDelay = Duration(milliseconds: 400);

  /// [isBootstrap] must be true only for the one-time initial {} handshake -
  /// it must never be retried (a second {} orphans the first session).
  /// For every ordinary action (menu tap, control key, entry submit), a
  /// conflict that gets silently auto-resolved only refreshes the home page
  /// - it does NOT carry out the original action - so that action must be
  /// retried once against the now-clean session to get its real result.
  /// Returns true if a page was actually rendered, false if this call bailed
  /// out early (timeout, error, or a conflict that never cleared).
  Future<bool> _send(Future<Map<String, dynamic>> Function() call,
      {bool isBootstrap = false}) async {
    // Refuse to fire a second request while one is still in flight. The busy
    // overlay alone doesn't guarantee this (see the AbsorbPointer note in
    // build()) - two overlapping requests sharing the same frozen session
    // identity look to the server exactly like a genuine second device,
    // which can spuriously trigger "another active session" on its own.
    // Skipped for the bootstrap call specifically: `_busy` starts true (so
    // the very first frame shows a spinner before bootstrap even runs), and
    // this guard running before bootstrap's own setState would otherwise
    // silently skip the one-time {} handshake entirely, leaving _page null
    // forever. `_started` already makes bootstrap re-entry-proof on its own.
    if (_busy && !isBootstrap) return false;
    setState(() => _busy = true);
    try {
      var res = await call().timeout(_networkTimeout);
      _captureSession(res);
      var attempt = 0;
      // Every "another active session" conflict is resolved automatically,
      // in the background, for the ENTIRE app session - including the very
      // first one right after login. Never shown to the user as a dialog.
      // Reversed 2026-07-09 from an earlier design that showed the
      // first-ever conflict interactively: live testing (both independently
      // and by the developer directly in Postman) confirmed this conflict is
      // routine, expected Oracle behavior that the client is meant to answer
      // itself, not something requiring a user decision - the developer's
      // own reference document instructs sending action_keys "A" whenever it
      // appears, with no user prompt described anywhere in that flow.
      while (_isAutoResolvableYesNo(res) && attempt < _maxYesAttempts) {
        // Live-verified against Oracle on 2026-07-09: clearing this conflict
        // is NOT always a single "yes", and it can recur more than once in a
        // row even on a completely fresh, never-before-used account - this
        // looks like a structural handoff step in this Oracle environment's
        // RF login, not backlog/flakiness. `_maxYesAttempts` gives headroom
        // above the observed "usually 1-3" range. Repeatedly re-sending
        // "yes" unboundedly (previously up to 300 rounds, in an earlier
        // design) was likely creating the very runaway conflict it was meant
        // to drain, hence a bound still applies.
        if (attempt > 0) await Future.delayed(_yesRetryDelay);
        res = await _rw
            .sendYesNo(_clientid, _htmlrfid, 'yes')
            .timeout(_networkTimeout);
        _captureSession(res);
        attempt++;
        if (_isAutoResolvableYesNo(res)) continue;
        // A cleared "A" response IS already the mainmenu - confirmed in
        // every live test today. For an ordinary action that means it's
        // only the generic mainmenu, not the action's real result, so the
        // original call must be replayed to get that. For the bootstrap {}
        // specifically, the mainmenu IS the desired result already -
        // replaying call() here would fire a SECOND {}, which orphans the
        // session (see _bootstrap()'s doc comment), so it's skipped.
        if (!isBootstrap) {
          res = await call().timeout(_networkTimeout);
          _captureSession(res);
        }
      }
      if (_isAutoResolvableYesNo(res)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Session conflict did not clear after multiple attempts - ask a WMS admin to check RF sessions for this user.')));
        }
        return false;
      }
      setState(() {
        _page = res;
        _renderCount++;
      });
      return true;
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No response from WMS server after 25s - check the connection and try again.')));
      }
      return false;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fires an action_keys "X" request (Ctrl-X Exit App, or "No" on the
  /// session-conflict dialog) and unconditionally returns to the Login
  /// screen afterward - per the spec, "X" always ends the RF session
  /// server-side, so there's nothing left worth rendering from its response.
  Future<void> _sendAndLogout(
      Future<Map<String, dynamic>> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await call().timeout(_networkTimeout);
    } catch (_) {
      // Logging out regardless of whether this final call succeeded.
    }
    // Fire-and-forget (2026-09-26), same reasoning as the login-time sync -
    // this just-finished session's log is complete now and won't grow any
    // further, so this is the best moment to push it, but logout must stay
    // fast regardless of whether the relay is reachable.
    unawaited(LogUploadService.syncPendingInBackground());
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  /// Sends a ctrl_key action - shared by the Actions popup menu and the
  /// Wooden Pallet Task Back/Tasks-in-Progress buttons (2026-08-15), which
  /// send specific keys directly rather than going through that menu. "X"
  /// is always Exit App server-side (see _sendAndLogout) - kept special-cased
  /// here exactly as before so both callers behave identically for it.
  Future<void> _sendCtrlKey(String key) async {
    LogService.log('ACTION', {'type': 'ctrl_key', 'key': key});
    if (key == 'X') {
      await _sendAndLogout(() => _rw.sendActionKey(_clientid, _htmlrfid, key));
    } else {
      await _send(() => _rw.sendActionKey(_clientid, _htmlrfid, key));
    }
  }

  // ---- Truck Temp enhancement ----

  // The record found for whichever shipment is currently on screen, and
  // whatever value (if any) `cust_decimal_1` already holds for it - added
  // 2026-07-10. Looked up the moment the Shipment field is confirmed (see
  // `_lookupTruckTemp` below), NOT re-derived at save time, so the field the
  // operator sees and the field that gets patched are guaranteed to be the
  // same record. Reset whenever a fresh mainmenu transaction is entered (see
  // `onSelect` in build()).
  int? _truckTempShipmentId;
  String? _truckTempExistingValue;
  bool _truckTempLocked = false;

  // Typed Truck Temp value captured when the LPN field is submitted, but not
  // yet PATCHed - per the developer's spec (2026-07-10), the actual save
  // must happen when the operator presses End LPN (Ctrl-E), not immediately
  // on submitting the LPN field (which is only the START of that LPN's line
  // entries - Item/Qty/Batch/Expiry are still to come). See the Actions
  // PopupMenuButton's onSelected in build().
  String? _pendingTruckTemp;

  /// Looks up the shipment's existing Truck Temp value (if any) as soon as
  /// the Shipment field is confirmed on screen. Per the developer's spec: if
  /// `cust_decimal_1` already has a value for this shipment, the injected
  /// field should just display it, read-only - it should NOT be re-entered
  /// or re-saved. If it's blank, the field stays editable as before.
  /// `facility_id__code`/`company_id__code` come from the response's own
  /// `content.headers.fac_code`/`comp_code` (see build()) - live-tested
  /// 2026-07-10 that `shipment_nbr` alone is not a safe-enough key on its own
  /// (the same shipment_nbr could in principle exist under a different
  /// facility/company).
  Future<void> _lookupTruckTemp(String shipmentNbr) async {
    if (_facCode.isEmpty || _compCode.isEmpty) return;
    final rec = await _rw.findEntity(AppConfig.enhSaveEntity, {
      AppConfig.enhLookupQueryParam: shipmentNbr,
      AppConfig.enhFacQueryParam: _facCode,
      AppConfig.enhCompQueryParam: _compCode,
    });
    if (!mounted) return;
    final existing = rec?[AppConfig.enhSaveField]?.toString() ?? '';
    setState(() {
      _truckTempShipmentId = rec?['id'] as int?;
      _truckTempExistingValue = existing.isEmpty ? null : existing;
      _truckTempLocked = _truckTempExistingValue != null;
    });
  }

  Future<void> _saveTruckTemp(String temp) async {
    final id = _truckTempShipmentId;
    if (id == null) {
      _toast('Truck Temp not saved: shipment not resolved yet this session.');
      return;
    }
    final ok = await _rw.patchField(
        AppConfig.enhSaveEntity, id, AppConfig.enhSaveField, temp);
    _toast(ok
        ? 'Truck Temp $temp saved.'
        : 'Truck Temp save failed (check lgfapi permission).');
  }

  // ---- Wooden Pallet Task enhancement (2026-08-15) ----
  //
  // Display-only, half-of-the-full-feature lookup - see
  // plan quirky-shimmying-haven.md. Fired the moment the Trailer field is
  // submitted (see build()'s onSubmit), same injection point as Truck
  // Temp's shipment lookup. wpTrailerNbr also doubles as "has a lookup been
  // attempted this transaction" for _ScreenView's display gating (null =
  // never attempted, so nothing renders before the first submit).
  late final _wpService = WoodenPalletService(_rw);
  WoodenPalletLoad? _wpLoad;
  List<WoodenPalletOrder> _wpOrders = const [];
  bool _wpLoading = false;
  String? _wpTrailerNbr;
  String? _wpError;

  Future<void> _lookupWoodenPallet(String trailerNbr) async {
    // Manual: trailer numbers are entered/displayed in capital letters -
    // shouldn't depend on how DataWedge/keyboard happened to send it.
    final trailer = trailerNbr.trim().toUpperCase();
    if (trailer.isEmpty) return;
    LogService.log('ACTION', {'type': 'wp_trailer_submit', 'trailer': trailer});
    setState(() {
      _wpLoading = true;
      _wpTrailerNbr = trailer;
      _wpLoad = null;
      _wpOrders = const [];
      _wpError = null;
    });
    try {
      final load = await _wpService.fetchLoad(trailer);
      var orders = const <WoodenPalletOrder>[];
      if (load != null && load.externallyPlannedLoadNbr.isNotEmpty) {
        orders = await _wpService.fetchOrders(load.externallyPlannedLoadNbr);
        // 2026-08-15 - drop orders whose tasks are all already
        // completed/packed, so a finished order doesn't keep showing up
        // here only to lead to an empty task table.
        orders = await _wpService.filterOrdersWithOpenTasks(orders);
      }
      if (!mounted) return;
      setState(() {
        _wpLoad = load;
        _wpOrders = orders;
        _wpLoading = false;
      });
    } catch (e) {
      // Best-effort, like Truck Temp's lookup - a failed lookup never blocks
      // the operator's real RF submission, which always still happens
      // regardless (see build()'s onSubmit).
      if (!mounted) return;
      setState(() {
        _wpLoading = false;
        _wpError = 'Wooden Pallet lookup failed: $e';
      });
    }
  }

  // Task-details step (2026-08-15, "finish the full") - fired when the
  // operator taps one of the orders from _lookupWoodenPallet's result.
  // wpSelectedOrderNbr doubles as "are we viewing task details" for
  // _ScreenView (null = still on the order list).
  List<WoodenPalletAllocation>? _wpAllocations;
  bool _wpAllocationsLoading = false;
  String? _wpAllocationsError;
  String? _wpSelectedOrderNbr;

  Future<void> _lookupWoodenPalletAllocations(String orderNbr) async {
    LogService.log('ACTION', {'type': 'wp_order_tap', 'order_nbr': orderNbr});
    setState(() {
      _wpAllocationsLoading = true;
      _wpSelectedOrderNbr = orderNbr;
      _wpAllocations = null;
      _wpAllocationsError = null;
    });
    try {
      final allocations = await _wpService.fetchAllocations(orderNbr);
      if (!mounted) return;
      setState(() {
        _wpAllocations = allocations;
        _wpAllocationsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _wpAllocationsLoading = false;
        _wpAllocationsError = 'Task lookup failed: $e';
      });
    }
  }

  // wpSubmittedTaskNbr - the task nbr genuinely submitted to the real RF
  // session (see _submitWoodenPalletTask below) - used to find the
  // matching WoodenPalletAllocation (Locn/SKU/Qty) for the later real
  // SKU/Qty screen.
  String? _wpSubmittedTaskNbr;
  // Whatever was actually submitted into the real OBLPN field - captured
  // in onWoodenPalletOblpnFieldSubmit below, this is what
  // assign_and_load_oblpn must use. 2026-08-15 correction: this used to be
  // OUR OWN generated suggestion (via seq_counter/get_next_number,
  // counter_code "BLIND_LPN_NBR" then "OBLPN") pre-filled into the field -
  // live-confirmed that number was never valid ("Invalid OBLPN" once
  // submitted to the real session), because Oracle's own real readonly
  // "OBLPN:" display field (tag wpEnhOblpnDisplayFieldTag) already shows
  // the ONE genuinely valid OBLPN for this task. The generation API call
  // is gone entirely now - the editable field is pre-filled by reading
  // that real display field's own value instead (see
  // _ScreenViewState.build()).
  String? _wpConfirmedOblpnNbr;

  /// Clears every Wooden Pallet Task field back to its pre-transaction
  /// state - shared by a fresh mainmenu selection and by finishing one
  /// pallet's Drop Location submission (2026-08-15), so our client UI
  /// doesn't stay re-armed with stale selections once the real session
  /// moves on to whatever screen comes next.
  void _resetWoodenPalletState() {
    _wpLoad = null;
    _wpOrders = const [];
    _wpLoading = false;
    _wpTrailerNbr = null;
    _wpError = null;
    _wpAllocations = null;
    _wpAllocationsLoading = false;
    _wpAllocationsError = null;
    _wpSelectedOrderNbr = null;
    _wpSubmittedTaskNbr = null;
    _wpConfirmedOblpnNbr = null;
  }

  /// Submits the checked task's nbr into the real RF session's current
  /// field (2026-08-15 correction - this used to never touch the real
  /// session at all, which is why assign_and_load_oblpn rejected the OBLPN
  /// as never having been really created).
  Future<void> _submitWoodenPalletTask(String taskNbr) async {
    LogService.log('ACTION', {'type': 'wp_task_submit', 'task_nbr': taskNbr});
    final ok = await _send(() => _rw.sendInput(_clientid, _htmlrfid, taskNbr));
    if (ok) setState(() => _wpSubmittedTaskNbr = taskNbr);
  }

  /// Step 5 (2026-08-15) - the one genuinely stateful/write call outside
  /// the RF protocol itself in this whole feature; fired right after the
  /// real Drop Location field is submitted (see onSubmit below). loadNbr
  /// comes from the very first trailer lookup (_wpLoad), facCode/compCode
  /// from the live response headers, same as every other step - see
  /// WoodenPalletService.assignAndLoadOblpn. Shows the response's own
  /// message in a popup, success or failure - nothing further is defined
  /// past this point yet.
  Future<void> _assignAndLoadWoodenPalletOblpnAndShowResult() async {
    String message;
    try {
      final result = await _wpService.assignAndLoadOblpn(
        oblpnNbr: _wpConfirmedOblpnNbr ?? '',
        facCode: _facCode,
        compCode: _compCode,
        loadNbr: _wpLoad?.loadNbr ?? '',
      );
      message = result.message;
    } catch (e) {
      message = 'assign_and_load_oblpn failed: $e';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Message'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK')),
        ],
      ),
    );
  }

  // ---- Mix Area Task enhancement (2026-08-21) ----
  //
  // Unlike Wooden Pallet Task, the real task-list buttons stay live and
  // get filtered in place rather than replaced by a custom table - see
  // plan quirky-shimmying-haven.md. _maAllocations doubles as both the
  // "which tasks belong to this trailer" filter set (by taskNbr) AND the
  // source for the later Qty prefill once one is tapped.
  late final _maService = MixAreaTaskService(_rw);
  List<WoodenPalletAllocation> _maAllocations = const [];
  bool _maLoading = false;
  String? _maTrailerNbr;
  String? _maError;
  String? _maSubmittedTaskNbr;
  String? _maConfirmedOblpnNbr;

  Future<void> _lookupMixAreaTrailer(String trailerNbr) async {
    final trailer = trailerNbr.trim().toUpperCase();
    if (trailer.isEmpty) return;
    LogService.log('ACTION', {'type': 'ma_trailer_submit', 'trailer': trailer});
    setState(() {
      _maLoading = true;
      _maTrailerNbr = trailer;
      _maAllocations = const [];
      _maError = null;
    });
    try {
      final allocations = await _maService.fetchAllocationsForTrailer(trailer);
      if (!mounted) return;
      setState(() {
        _maAllocations = allocations;
        _maLoading = false;
      });
    } catch (e) {
      // Best-effort, like Wooden Pallet Task's trailer lookup - a failed
      // lookup never blocks the operator's real RF submission.
      if (!mounted) return;
      setState(() {
        _maLoading = false;
        _maError = 'Mix Area lookup failed: $e';
      });
    }
  }

  void _resetMixAreaState() {
    _maAllocations = const [];
    _maLoading = false;
    _maTrailerNbr = null;
    _maError = null;
    _maSubmittedTaskNbr = null;
    _maConfirmedOblpnNbr = null;
  }

  /// The final action for this transaction (2026-08-21) - print/label/
  /// shipping instead of Wooden Pallet Task's assign_and_load_oblpn. Per
  /// the user's explicit instruction: on success, show a fixed "Print
  /// Successful" message (not the API's own response text) - and,
  /// deliberately unlike Wooden Pallet Task, no client state reset or
  /// extra navigation afterward. Whatever real screen Oracle sends next
  /// (the task list again, or a "no more tasks" message) should just
  /// render normally.
  Future<void> _printMixAreaShippingLabelAndShowResult() async {
    // Starts running immediately, before showDialog even opens - the grey
    // barrier below covers the network wait too, not just the final
    // message once it's already known (2026-09-26 correction: previously
    // there was no visual feedback at all between tapping Submit and this
    // dialog finally appearing - the operator could navigate the screen
    // behind it in the meantime, as reported during testing). Same
    // reasoning as Full Pallet Task's _busyDialogThen, but this dialog
    // needs an explicit OK (a terminal per-transaction result, not a
    // quick auto-dismissing status) and both outcomes show their own text
    // in it, so it's written directly here rather than reusing that helper.
    final future = _printShippingLabelMessage();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => FutureBuilder<String>(
        future: future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const AlertDialog(
              content: SizedBox(
                  height: 48,
                  child: Center(child: CircularProgressIndicator())),
            );
          }
          return AlertDialog(
            title: const Text('Message'),
            content: Text(snapshot.data!),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('OK')),
            ],
          );
        },
      ),
    );
  }

  /// The actual print/label/shipping call plus its message text, split out
  /// of _printMixAreaShippingLabelAndShowResult (2026-09-26) so that
  /// function can start this running and open the dialog in the same
  /// breath, letting the dialog's own FutureBuilder await this SAME Future
  /// rather than the message already being fully computed by the time the
  /// barrier appears.
  Future<String> _printShippingLabelMessage() async {
    try {
      final result = await _maService.printShippingLabel(
        facCode: _facCode,
        compCode: _compCode,
        containerNbr: _maConfirmedOblpnNbr ?? '',
      );
      // No live-confirmed success/message field shape yet for this
      // endpoint - falls back to showing the fixed success message
      // whenever the call didn't throw, since lgfapiPostJson only
      // surfaces `_error`/`_status` keys on a genuine failure. On failure,
      // dump Oracle's own response body (whatever key it uses for the
      // real reason isn't confirmed yet either) rather than just the bare
      // status code - this call never appears in the debug sheet (that
      // only logs the RF protocol, not lgfapi/api calls), so this is the
      // only way to see why a 400/etc happened without external tools.
      final failed =
          result.containsKey('_error') || result.containsKey('_status');
      return failed
          ? 'Print failed (${result['_status'] ?? '?'}): ${jsonEncode(result)}'
          : 'Print Successful';
    } catch (e) {
      return 'print/label/shipping failed: $e';
    }
  }

  // ---- Full Pallet Task enhancement (2026-08-22) ----
  //
  // Five real screens chained together - see plan quirky-shimmying-haven.md.
  // Screen 1 (Tasks:) follows Wooden Pallet Task's exact hide-and-replace
  // pattern (2026-08-22 correction, after two live tests): live-confirmed
  // the real screen has no trailer concept of its own (an earlier attempt
  // to sendInput the trailer into its real current field got "Invalid
  // Entry" - that field is tagged "task-list", expecting a task nbr), and
  // per the user's explicit follow-up instruction, the real Tasks:/Curr
  // Locn/Task Type/task-button content should stay hidden throughout, same
  // as Wooden Pallet Task - only the trailer field, then a client-built
  // Trailer/TMP/TFP/Customer Name + task list, are ever shown. Only
  // picking a task and submitting it (_submitFullPalletTask) finally
  // touches the real RF session.
  late final _fpService = FullPalletTaskService(_rw);
  FullPalletLoad? _fpLoad;
  List<WoodenPalletOrder> _fpOrders = const [];
  // Auto-picked: the first order for this trailer's load - the reference
  // mockups only ever show a single order per trailer/load; if multiple
  // genuinely occur, this needs an order-picker step, per the plan's
  // live-verify list.
  String? _fpOrderNbr;
  bool _fpLoading = false;
  String? _fpTrailerNbr;
  String? _fpError;
  int? _fpTmp;
  int? _fpTfp;
  List<WoodenPalletAllocation> _fpTasks = const [];
  List<FullPalletSkuGroup> _fpSkuGroups = const [];
  bool _fpSkuLoading = false;
  String? _fpSkuError;
  // Already fully-picked lines for this order, shown read-only alongside
  // _fpSkuGroups (2026-10-07) - see FullPalletTaskService.
  // fetchCompletedSkuGroups's doc comment. Fetched and failure-handled
  // independently of _fpSkuGroups/_fpSkuError: a failure here shouldn't
  // block the pending-lines table the operator actually needs to act on,
  // so it's silently left empty rather than surfacing its own error UI.
  List<FullPalletSkuGroup> _fpCompletedSkuGroups = const [];
  // Container nbrs already confirmed picked/fulfilled this transaction -
  // keyed by container_nbr, not by group, so a scan can be matched back to
  // whichever group actually contains it (see _scanFullPalletLpn). A
  // substitute pick (2026-10-07 correction) marks the ORIGINALLY
  // ALLOCATED container number it fulfilled, not the scanned LPN's own
  // number - the scanned LPN's number was never one of group.containerNbrs
  // to begin with (that's what makes it a substitute), so recording it
  // here instead would never match anything. This also doubles as "which
  // of this group's slots are still unfulfilled" - see _scanFullPalletLpn's
  // target-container selection for a substitute.
  final Set<String> _fpPickedContainers = {};

  /// How many of [group]'s pallets have been accounted for so far (normal
  /// picks and substitutes alike - both mark the real allocated container
  /// number they fulfilled in _fpPickedContainers). The single source of
  /// truth for both the per-SKU "All tasks completed" message and the
  /// overall allDone/_finishFullPalletTasks check, so the two can never
  /// disagree.
  int _fpPickedCountFor(FullPalletSkuGroup group) =>
      group.containerNbrs.where(_fpPickedContainers.contains).length;

  String get _fpCustomerName {
    for (final o in _fpOrders) {
      if (o.orderNbr == _fpOrderNbr) return o.custName;
    }
    return '';
  }

  /// Trailer submit (step 1) - purely client-side lgfapi lookup (load,
  /// order, TMP, TFP, customer name, task list), same as Wooden Pallet
  /// Task's own trailer lookup - never touches the real RF session (see
  /// this section's doc comment on why).
  Future<void> _lookupFullPalletTrailer(String trailerNbr) async {
    final trailer = trailerNbr.trim().toUpperCase();
    if (trailer.isEmpty) return;
    LogService.log('ACTION', {'type': 'fp_trailer_submit', 'trailer': trailer});
    setState(() {
      _fpLoading = true;
      _fpTrailerNbr = trailer;
      _fpLoad = null;
      _fpOrders = const [];
      _fpOrderNbr = null;
      _fpTmp = null;
      _fpTfp = null;
      _fpTasks = const [];
      _fpError = null;
    });
    try {
      final load = await _fpService.fetchLoad(trailer);
      var orders = const <WoodenPalletOrder>[];
      if (load != null && load.externallyPlannedLoadNbr.isNotEmpty) {
        orders = await _fpService.fetchOrders(load.externallyPlannedLoadNbr);
      }
      final orderNbr = orders.isNotEmpty ? orders.first.orderNbr : null;
      int? tmp;
      int? tfp;
      var tasks = const <WoodenPalletAllocation>[];
      if (orderNbr != null) {
        tmp = await _fpService.fetchTmp(orderNbr);
        tfp = await _fpService.fetchTfp(orderNbr);
        tasks = await _fpService.fetchTasks(orderNbr);
      }
      if (!mounted) return;
      setState(() {
        _fpLoad = load;
        _fpOrders = orders;
        _fpOrderNbr = orderNbr;
        _fpTmp = tmp;
        _fpTfp = tfp;
        _fpTasks = tasks;
        _fpLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fpLoading = false;
        _fpError = 'Full Pallet Task lookup failed: $e';
      });
    }
  }

  void _resetFullPalletState() {
    _fpLoad = null;
    _fpOrders = const [];
    _fpOrderNbr = null;
    _fpLoading = false;
    _fpTrailerNbr = null;
    _fpError = null;
    _fpTmp = null;
    _fpTfp = null;
    _fpTasks = const [];
    _fpSkuGroups = const [];
    _fpCompletedSkuGroups = const [];
    _fpSkuLoading = false;
    _fpSkuError = null;
    _fpPickedContainers.clear();
  }

  // ---- Pick And Allocate serial-driven enhancement (2026-09-08) ----
  // See AppConfig.paEnh* . The serial scanned into the injected field on
  // the Pick And Allocate screen is looked up via lgfapi; the result
  // (_paLookup) then pre-fills the standard Locn/IBLPN/Qty/Serial fields on
  // the following screens. Reset on a fresh mainmenu selection and whenever
  // a new order is scanned (see onSubmit).
  late final _paService = PickAllocateService(_rw);
  PaSerialLookup? _paLookup;
  bool _paLookupLoading = false;
  String? _paLookupError;

  void _resetPickAllocateState() {
    _paLookup = null;
    _paLookupLoading = false;
    _paLookupError = null;
  }

  Future<void> _lookupPickAllocateSerial(String serial) async {
    final s = serial.trim();
    if (s.isEmpty || _paLookupLoading) return;
    setState(() {
      _paLookupLoading = true;
      _paLookupError = null;
      _paLookup = null;
    });
    LogService.log('ACTION', {'type': 'pa_serial_lookup', 'serial': s});
    final result = await _paService.lookup(s);
    if (!mounted) return;
    setState(() {
      _paLookupLoading = false;
      if (result.ok) {
        _paLookup = result;
      } else {
        _paLookupError = result.message;
      }
    });
  }

  /// Reject (step 2) - fires the email relay BEFORE the real ctrl_key, per
  /// the plan's "custom side-effect right before a specific ctrl_key"
  /// pattern (matches Truck Temp's deferred PATCH on End LPN). Never
  /// blocks the real Reject action on the email's own success/failure -
  /// per the user's explicit instruction, a failed email send is fine.
  Future<void> _rejectFullPalletTrailer(String ctrlKey) async {
    LogService.log(
        'ACTION', {'type': 'fp_reject', 'trailer': _fpTrailerNbr ?? ''});
    final emailConfig = await AppConfig.loadEmailServer();
    final sent = await EmailRelayService.sendRejectNotice(
      config: emailConfig,
      trailer: _fpTrailerNbr ?? '',
      shipment: _fpLoad?.shipmentNbr ?? '',
      username: widget.auth.username,
    );
    if (emailConfig.isConfigured && !sent) {
      _toast(
          'Reject email could not be sent (relay unreachable) - Oracle Reject still proceeding.');
    }
    await _sendCtrlKey(ctrlKey);
  }

  /// Back on the client-built Trailer/TMP/TFP/Customer + task screen -
  /// sends the same "Previous Screen" action Wooden Pallet Task's own Back
  /// button already uses (previousScreenKey), matching that button's
  /// 2026-08-15 correction (ctrl_key "X" would be Exit App, not Back).
  Future<void> _backFullPallet() async {
    LogService.log('ACTION', {'type': 'fp_back'});
    await _send(
        () => _rw.sendActionKey(_clientid, _htmlrfid, _previousScreenKey));
  }

  /// Mix Pallet Task (2026-08-22, rewritten 2026-10-06 after the debug-sheet
  /// captured from the fourth live test) - this button lives on our OWN
  /// client-built table, which sits on top of whatever real screen the
  /// "VMT-Execute Full Pallet Task New" transaction is currently showing.
  /// Getting onto the real "Execute Task Mix Area" screen requires backing
  /// out to the mainmenu and tapping its real menu item for real (not a
  /// hardcoded `_currentTransactionName` switch) - confirmed working by the
  /// debug sheet (keyboard_input "6" -> the real screen's content, correct
  /// page_title).
  ///
  /// That same debug sheet also disproves the earlier "submit the trailer
  /// first" theory: the real screen's ONLY field is tag "task-list",
  /// barcode_types ["Task"] - submitting the trailer into it is flatly
  /// rejected ("Invalid Entry"), live-confirmed. The "scan a trailer to
  /// filter the list" behavior the user sees when navigating here manually
  /// is this app's OWN pre-existing client-side filter
  /// (_lookupMixAreaTrailer/widget.maTrailerNbr - see its own doc comment),
  /// never a real Oracle submission at all. So the trailer is never sent to
  /// Oracle here either - _lookupMixAreaTrailer is called purely to
  /// populate _maAllocations/_maTrailerNbr client-side, same as if the
  /// operator had typed it, so the real screen looks right if they ever
  /// land back on it and so the Qty/OBLPN prefill matching below has data
  /// to match against.
  ///
  /// The task itself is picked by submitting its candidate button's INDEX
  /// (what a real tap on it actually sends - see the generic
  /// onSubmit(name, idx, null) handling further down in this file, which
  /// submits `idx`, not `name`) against that same unfiltered button list -
  /// the debug sheet's menu-tap response already includes it (index "3" for
  /// this task), trailer or no trailer. Because this calls _rw.sendInput
  /// directly rather than going through that generic onSubmit closure (only
  /// reachable from a real tapped widget), _maSubmittedTaskNbr - which that
  /// closure would otherwise set, and which the Qty/OBLPN prefill on the
  /// next screen keys off - is set here by hand, under the identical
  /// condition that closure uses.
  Future<void> _selectMixPalletTask(String taskNbr) async {
    LogService.log(
        'ACTION', {'type': 'fp_mix_pallet_task', 'task_nbr': taskNbr});
    final trailer = _fpTrailerNbr;
    // Step 1: back out of Full Pallet Task to the real mainmenu - same
    // ctrl_key _backFullPallet already uses from this exact screen.
    await _send(
        () => _rw.sendActionKey(_clientid, _htmlrfid, _previousScreenKey));
    // Step 2: tap the real "Mix Area Task" menu item - matched by the same
    // substring already used to detect this transaction's own screens
    // (AppConfig.maEnhPageTitleMatch), not a guessed exact menu label.
    final menuItem = _menuButtonMatching(_page, AppConfig.maEnhPageTitleMatch);
    if (menuItem == null) {
      _toast(
          'Could not find the Mix Area Task menu item - please open it manually.');
      return;
    }
    _currentTransactionName = menuItem['name']!;
    _resetWoodenPalletState();
    _resetMixAreaState();
    _resetFullPalletState();
    _resetPickAllocateState();
    await _send(
        () => _rw.sendInput(_clientid, _htmlrfid, menuItem['index']!));
    // Step 3: client-side only (see doc comment above) - never sent to
    // Oracle, just mirrors what a manual trailer scan here would set.
    if (trailer != null && trailer.isNotEmpty) {
      await _lookupMixAreaTrailer(trailer);
    }
    // Step 4: pick the task by its candidate button's index (a real tap),
    // falling back to a plain task-nbr submit only if no matching button is
    // found, so this never regresses silently if the response shape differs.
    final idx = _buttonIndexForTaskNbr(_page, taskNbr);
    if (idx != null) {
      if (_maAllocations.any((a) => a.taskNbr == taskNbr)) {
        _maSubmittedTaskNbr = taskNbr;
      }
      await _send(() => _rw.sendInput(_clientid, _htmlrfid, idx));
      return;
    }
    await _submitFullPalletTaskNbr(taskNbr);
  }

  /// Finds the first real mainmenu item (type 'menu_button') whose name
  /// contains [substringLower] and returns its {'index', 'name'} - used to
  /// genuinely tap a menu item by name rather than guessing an exact label.
  /// Mirrors _MenuView's own row-flattening of page_content.
  Map<String, String>? _menuButtonMatching(
      Map<String, dynamic>? page, String substringLower) {
    if (page == null) return null;
    final content = (page['content'] ?? {}) as Map<String, dynamic>;
    final rows = (content['page_content'] ?? []) as List;
    for (final row in rows) {
      for (final c in (row as List)) {
        final f = (c as Map).cast<String, dynamic>();
        if (f['type'] != 'menu_button') continue;
        final v = (f['value'] ?? {}) as Map;
        final name = (v['name'] ?? '').toString();
        if (name.toLowerCase().contains(substringLower)) {
          return {'index': (v['index'] ?? '').toString(), 'name': name};
        }
      }
    }
    return null;
  }

  /// Finds the quick-select button whose name matches [taskNbr] in [page]'s
  /// page_content and returns its index (the string a real tap on that
  /// button actually submits) - see _selectMixPalletTask's doc comment.
  /// Mirrors _ScreenView._fields()'s row-flattening, since this runs
  /// against the raw lgfapi response rather than the widget tree.
  String? _buttonIndexForTaskNbr(Map<String, dynamic>? page, String taskNbr) {
    if (page == null) return null;
    final content = (page['content'] ?? {}) as Map<String, dynamic>;
    final rows = (content['page_content'] ?? []) as List;
    for (final row in rows) {
      for (final c in (row as List)) {
        final f = (c as Map).cast<String, dynamic>();
        if (f['type'] != 'button') continue;
        final v = (f['value'] ?? {}) as Map;
        if (v['name']?.toString() == taskNbr) {
          return v['index']?.toString();
        }
      }
    }
    return null;
  }

  /// Shared by both Mix Pallet Task and Full Pallet Task (2026-08-22) -
  /// live-confirmed a task already In Progress (status_id 30) must have
  /// "Ctrl-P: Exec Tasks in Progress" sent BEFORE its nbr, or Oracle
  /// rejects the plain sendInput as "Invalid Entry" - a fresh/open task
  /// (status_id 10) submits directly, no Ctrl-P needed. The status lookup
  /// is best-effort like every other lgfapi lookup in this app: if it
  /// fails or the task isn't found, this just falls through to the plain
  /// submit rather than blocking the operator.
  Future<void> _submitFullPalletTaskNbr(String taskNbr) async {
    try {
      final statusId = await _fpService.fetchTaskStatusId(taskNbr);
      if (statusId == 30) {
        await _send(() => _rw.sendActionKey(_clientid, _htmlrfid, 'P'));
      }
    } catch (_) {
      // Best-effort - fall through to the plain submit below regardless.
    }
    await _send(() => _rw.sendInput(_clientid, _htmlrfid, taskNbr));
  }

  /// Full Pallet Task (2026-08-22, corrected after the third live test) -
  /// same client-built-button correction as Mix Pallet Task above: submits
  /// the picked task nbr for real (via _submitFullPalletTaskNbr, handling
  /// the In Progress/Ctrl-P case), then fetches the SKU/Pallet/Pick table
  /// for the already-known order (the given queries key off order_nbr, not
  /// task_nbr - see FullPalletTaskService's doc comments).
  Future<void> _lookupFullPalletSkus(String taskNbr) async {
    LogService.log('ACTION', {
      'type': 'fp_full_pallet_task',
      'task_nbr': taskNbr,
      'order_nbr': _fpOrderNbr ?? ''
    });
    final orderNbr = _fpOrderNbr;
    if (orderNbr == null) {
      // No order nbr known - can't look up SKUs at all, so there's nothing
      // to hide the real screen behind; let it show through same as always.
      await _submitFullPalletTaskNbr(taskNbr);
      return;
    }
    // Set BEFORE submitting the task nbr, not after (2026-10-06 fix - see
    // onFullPalletSkuScreen's doc comment) - submitting is what makes
    // Oracle respond with its real OBLPN screen and triggers a rebuild;
    // fpSkuLoading needs to already be true at that first rebuild so the
    // real screen is hidden from the very start of this step, not only
    // once the SKU fetch below finishes.
    setState(() {
      _fpSkuLoading = true;
      _fpSkuGroups = const [];
      _fpCompletedSkuGroups = const [];
      _fpSkuError = null;
      _fpPickedContainers.clear();
    });
    await _submitFullPalletTaskNbr(taskNbr);
    try {
      final groups = await _fpService.fetchSkuGroups(orderNbr);
      if (!mounted) return;
      setState(() {
        _fpSkuGroups = groups;
        _fpSkuLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fpSkuLoading = false;
        _fpSkuError = 'SKU lookup failed: $e';
      });
    }
    // Best-effort, independent of the pending-lines fetch above (2026-10-07)
    // - a failure here just leaves the read-only completed section empty
    // rather than surfacing its own error state, since it's purely
    // informational and shouldn't block or alarm the operator over the
    // lines they actually still need to act on.
    try {
      final completed = await _fpService.fetchCompletedSkuGroups(orderNbr);
      if (!mounted) return;
      setState(() => _fpCompletedSkuGroups = completed);
    } catch (_) {
      // Swallow - see comment above.
    }
  }

  /// LPN scan (step 4) - a distinct lgfapi action call, not a real RF
  /// field submission (see FullPalletTaskService.packFullLpn's doc
  /// comment).
  ///
  /// SKU-line selection restored (2026-10-06, reversing the same-day
  /// removal) - the operator must check a line before scanning, and
  /// [group] is that selection, always known with certainty. That makes
  /// three cases decidable up front, instead of guessing from the scan
  /// alone:
  /// - [value] is one of [group]'s own containerNbrs - the normal case,
  ///   strict validation, attributed directly to [group].
  /// - [value] belongs to a DIFFERENT group's containerNbrs - the operator
  ///   selected one line but scanned another line's LPN (the original bug
  ///   report this selection exists to catch) - rejected outright, no API
  ///   call.
  /// - [value] doesn't match any group at all - a genuine substitute for
  ///   the selected line - confirmed via the "Do you want to substitute
  ///   the LPN?" dialog (matching the same confirmation this scenario
  ///   already shows on the real Oracle/Flexi screens elsewhere in this
  ///   WMS, per the customer's own Flexi user guide, FEFO section), then
  ///   the relaxed-validation call, attributed to [group].
  Future<void> _scanFullPalletLpn(String lpn, FullPalletSkuGroup group) async {
    final value = lpn.trim();
    if (value.isEmpty) return;
    if (!group.containerNbrs.contains(value)) {
      FullPalletSkuGroup? wrongLine;
      for (final g in _fpSkuGroups) {
        if (g.containerNbrs.contains(value)) {
          wrongLine = g;
          break;
        }
      }
      if (wrongLine != null) {
        // Centered dialog, not _toast's bottom SnackBar (2026-10-07 fix) -
        // matches every other message in this screen (Picked, All tasks
        // completed, Substitute LPN).
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Wrong SKU line'),
            content: Text(
                'This LPN belongs to SKU ${wrongLine!.sku}, not the selected line (${group.sku}). Select that line, or scan the LPN for ${group.sku}.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK')),
            ],
          ),
        );
        return;
      }
    }
    final substitute = !group.containerNbrs.contains(value);
    // Which of this group's already-allocated slots the substitute will
    // fulfill (2026-10-07) - picked up front, before the confirm dialog,
    // so its SKU-named wording and the eventual packFullLpn call both see
    // the same target. Oracle needs this as oblpn_number: live-confirmed
    // sending the scanned (unallocated) container as oblpn_number gets
    // "No such IBLPN" back even when that exact container demonstrably
    // exists - the real, pre-allocated container is the one Oracle has an
    // OBLPN record for. If every slot is already fulfilled, there's
    // nothing left to substitute into - this shouldn't be reachable from
    // the UI (the group would already show "All tasks completed"), but is
    // guarded rather than sending a guessed/stale target.
    String? targetContainer;
    if (substitute) {
      final openSlots =
          group.containerNbrs.where((c) => !_fpPickedContainers.contains(c));
      targetContainer = openSlots.isEmpty ? null : openSlots.first;
      if (targetContainer == null) {
        _toast('All pallets for SKU ${group.sku} are already picked.');
        return;
      }
    }
    if (substitute) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Substitute LPN'),
          content: Text(
              'Do you want to substitute the LPN for SKU ${group.sku}?\n\n$value'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('OK')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    LogService.log('ACTION', {
      'type': 'fp_lpn_scan',
      'lpn': value,
      'sku': group.sku,
      'substitute': substitute,
      if (targetContainer != null) 'target_oblpn': targetContainer,
    });
    // The Future starts running the instant packFullLpn is called, before
    // showDialog even opens - so the barrier below covers this wait too,
    // not just the "Picked" confirmation once it's already done (2026-09-26
    // correction: previously the grey-out only appeared once the network
    // call had ALREADY resolved and _showQuickMessage was called, leaving
    // the actual wait after tapping Submit with no visual feedback at all).
    final future = _fpService.packFullLpn(
      facCode: _facCode,
      compCode: _compCode,
      lpn: value,
      oblpnNumber: targetContainer,
      substitute: substitute,
    );
    final result = await _busyDialogThen(future, successMessage: 'Picked');
    final failed =
        result.containsKey('_error') || result.containsKey('_status');
    if (failed) {
      _toast('Scan failed: ${jsonEncode(result)}');
      return;
    }
    setState(() {
      _fpPickedContainers.add(substitute ? targetContainer! : value);
    });
    if (_fpPickedCountFor(group) >= group.containerNbrs.length) {
      await _showQuickMessage(
          'All tasks are completed for the selected SKU - ${group.sku}');
    }
    final allDone = _fpSkuGroups.isNotEmpty &&
        _fpSkuGroups.every(
            (g) => _fpPickedCountFor(g) >= g.containerNbrs.length);
    if (allDone) await _finishFullPalletTasks();
  }

  /// Brief, centered, auto-dismissing message (2026-08-22) - for the two
  /// in-progress LPN-scan messages (Picked / All tasks for SKU), which
  /// don't need an operator tap to continue, just to be seen. Awaiting
  /// this (rather than fire-and-forget) makes a run of several in a row
  /// show one at a time instead of overlapping.
  Future<void> _showQuickMessage(String message) {
    if (!mounted) return Future.value();
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop();
          }
        });
        return AlertDialog(content: Text(message, textAlign: TextAlign.center));
      },
    );
  }

  /// Same centered, greyed-background barrier as _showQuickMessage, but
  /// opened BEFORE [future] resolves rather than after - covers whatever
  /// gap there'd otherwise be between the operator tapping Submit and the
  /// network call actually finishing (2026-09-26, per the user's testing:
  /// the grey-out was only appearing once the result was already known,
  /// with no feedback during the wait itself). One continuous dialog the
  /// whole time, so the grey-out and the confirmation text appear and
  /// disappear together, never as two separate overlays with a gap or
  /// flicker between them. A failed result (has `_error`/`_status`) skips
  /// the confirmation text and closes as soon as it's known, unchanged
  /// from before - the caller still shows its own error via _toast.
  Future<Map<String, dynamic>> _busyDialogThen(
    Future<Map<String, dynamic>> future, {
    required String successMessage,
  }) async {
    if (!mounted) return future;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snapshot) {
          const spinner = AlertDialog(
            content: SizedBox(
                height: 48, child: Center(child: CircularProgressIndicator())),
          );
          if (!snapshot.hasData) return spinner;
          final data = snapshot.data!;
          final failed =
              data.containsKey('_error') || data.containsKey('_status');
          Future.delayed(
              failed ? Duration.zero : const Duration(milliseconds: 700), () {
            if (Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop(data);
            }
          });
          return failed
              ? spinner // one last frame before the immediate pop above
              : AlertDialog(
                  content: Text(successMessage, textAlign: TextAlign.center));
        },
      ),
    );
    return result ?? await future;
  }

  /// Tasks Completed (2026-08-22) - unlike the two in-progress messages
  /// above, this is the terminal state for the whole Full Pallet Task
  /// flow, so it gets a real blocking dialog with an explicit OK - per the
  /// user's request, pressing OK returns to the Trailer Nbr screen: sends
  /// the real "Previous Screen" action (same as the client table's own
  /// Back button) to get the real RF session off the SKU/OBLPN screen,
  /// then resets all Full Pallet Task client state so the Trailer field
  /// shows fresh rather than the stale task/SKU tables.
  Future<void> _finishFullPalletTasks() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Message'),
        content: const Text('Tasks Completed'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK')),
        ],
      ),
    );
    LogService.log('ACTION', {'type': 'fp_tasks_completed_ok'});
    await _send(
        () => _rw.sendActionKey(_clientid, _htmlrfid, _previousScreenKey));
    if (mounted) setState(_resetFullPalletState);
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy && _page == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final page = _page;
    if (page == null) {
      return const Scaffold(body: Center(child: Text('No page.')));
    }

    final type = page['type'] as String?;
    final content = (page['content'] ?? {}) as Map<String, dynamic>;
    // Whichever ctrl_key is actually labeled "Previous Screen" on THIS
    // page - not a fixed key. Confirmed live: mainmenu/dialog screens use
    // "W" (Ctrl-W), but other screens (e.g. "Rcv ASN Units") use "F2"
    // instead. Only update the remembered key when THIS response actually
    // has a match - an info/error dialog interrupting a screen (e.g.
    // "Invalid format") typically has no ctrl_keys of its own at all, so it
    // must keep using whatever key the screen it interrupted was using,
    // not reset to a hardcoded default.
    for (final k in (content['ctrl_keys'] ?? []) as List) {
      final m = k as Map;
      final value = (m['value'] ?? '').toString().toLowerCase();
      if (value.contains('previous screen')) {
        _previousScreenKey = (m['key'] ?? 'W').toString();
        break;
      }
    }
    final previousScreenKey = _previousScreenKey;

    // Whichever ctrl_key on THIS screen means "End LPN" (if offered at all
    // right now - e.g. "Ctrl-E: End LPN") - added 2026-07-10 so the Truck
    // Temp PATCH (see _pendingTruckTemp) can be deferred until this exact
    // action instead of firing immediately when the LPN field is submitted.
    // Not persisted across responses like previousScreenKey - End LPN is
    // only ever pressed while it's actually showing in the current screen's
    // own Actions menu, so there's no "error dialog with no ctrl_keys"
    // fallback case to worry about here.
    String? endLpnKey;
    for (final k in (content['ctrl_keys'] ?? []) as List) {
      final m = k as Map;
      if ((m['value'] ?? '').toString().toLowerCase().contains('end lpn')) {
        endLpnKey = (m['key'] ?? '').toString();
        break;
      }
    }

    // Active facility/company code for the Truck Temp shipment lookup - see
    // `_lookupTruckTemp`. Same "persist last known good value" pattern as
    // `_previousScreenKey` above: not every response necessarily repeats
    // `headers`, so only overwrite when THIS response actually has one.
    final headers = (content['headers'] ?? {}) as Map;
    final facCode = (headers['fac_code'] ?? '').toString();
    final compCode = (headers['comp_code'] ?? '').toString();
    if (facCode.isNotEmpty) _facCode = facCode;
    if (compCode.isNotEmpty) _compCode = compCode;

    Widget body;
    if (type == 'dialog') {
      final dtype = content['dialog_type'] as String?;
      // `barcode` (e.g. Batch Nbr, Expiry Date prompts inside a multi-field
      // transaction) uses the identical shape to `entry` - confirmed live
      // 2026-07-09 - so it's rendered the same way.
      if (dtype == 'entry' || dtype == 'barcode') {
        final message = (content['dialog_message'] ?? '') as String;
        // Wooden Pallet Task's Drop Location prompt (2026-08-15) - live-
        // confirmed this is a dialog_type "entry" (_EntryView), NOT a
        // page_content field like every other injection in this feature -
        // _ScreenView's field loop never had a chance to prefill it. No
        // page_content/tag to match on here, only dialog_message.
        final isWpDropLocationPrompt =
            AppConfig.currentFlags.woodenPalletTaskEnabled &&
                _currentTransactionName
                    .toLowerCase()
                    .contains(AppConfig.wpEnhPageTitleMatch) &&
                message
                    .toLowerCase()
                    .contains(AppConfig.wpEnhDropLocationLabelMatch);
        // Mix Area Task's Drop Location prompt (2026-08-21) - same
        // dialog_type "entry" shape as Wooden Pallet Task's.
        final isMaDropLocationPrompt =
            AppConfig.currentFlags.mixAreaTaskEnabled &&
                _currentTransactionName
                    .toLowerCase()
                    .contains(AppConfig.maEnhPageTitleMatch) &&
                message
                    .toLowerCase()
                    .contains(AppConfig.maEnhDropLocationLabelMatch);
        body = _EntryView(
          // Without a key, Flutter reuses the same _EntryViewState (and its
          // text controller) across consecutive dialogs in the same tree
          // slot - e.g. Batch Nbr immediately followed by Expiry Date. That
          // left whatever was typed for the PREVIOUS prompt still sitting in
          // the text field for the next one. `_renderCount` increments on
          // every single rendered response - a deterministic guarantee of a
          // fresh key per response (htmlrfid normally also differs, but is
          // included too rather than relied on alone). Fixed 2026-07-09.
          key: ValueKey('$_renderCount-$_htmlrfid'),
          message: message,
          masked: (content['masked'] ?? false) as bool,
          forceCaps: (content['force_caps'] ?? false) as bool,
          maxLength: content['max_length'] as int?,
          allowCancel: (content['allow_cancel'] ?? false) as bool,
          initialValue:
              (isWpDropLocationPrompt || isMaDropLocationPrompt) ? 'DROP' : '',
          onSubmit: (v) async {
            _memory[message.isEmpty ? 'input' : message] = v;
            final ok =
                await _send(() => _rw.sendInput(_clientid, _htmlrfid, v));
            // Drop Location submitted for real -> fire assign_and_load_oblpn
            // (this dialog never goes through _ScreenView's onSubmit, where
            // every OTHER wooden pallet trigger lives - hooked here
            // instead). Once done, this one pallet is complete - resets our
            // client state and heads back toward the mainmenu rather than
            // leaving our Trailer/Order/Task UI re-armed for whatever real
            // screen the session loops to next (live-confirmed confusing).
            if (ok && isWpDropLocationPrompt) {
              await _assignAndLoadWoodenPalletOblpnAndShowResult();
              _resetWoodenPalletState();
              await _send(() =>
                  _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey));
            }
            // Mix Area Task (2026-08-21) - deliberately NO reset/forced
            // navigation afterward, per the user's explicit instruction:
            // let the real session's own next response (more tasks, or
            // "no more tasks") render normally.
            if (ok && isMaDropLocationPrompt) {
              await _printMixAreaShippingLabelAndShowResult();
            }
          },
          onCancel: () => _send(
              () => _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
        );
      } else if (dtype == 'info') {
        body = _InfoView(
          message: (content['dialog_message'] ?? '') as String,
          onOk: () => _send(
              () => _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
        );
      } else if (dtype == 'yesno') {
        // Most yesno dialogs are auto-resolved inside _send() before _page
        // is ever set (see _isAutoResolvableYesNo's doc comment) - this
        // branch is only reached by the ones excluded from that (e.g.
        // Wooden Pallet Task's "Task Ended..." dialog, 2026-08-15), which
        // need a real operator decision instead of a silent answer.
        final ctrlKeys = ((content['ctrl_keys'] as List?) ?? const [])
            .map((k) => (k as Map).cast<String, dynamic>())
            .toList();
        body = _YesNoView(
          message: (content['dialog_message'] ?? '') as String,
          ctrlKeys: ctrlKeys,
          onAnswer: (key) =>
              _send(() => _rw.sendActionKey(_clientid, _htmlrfid, key)),
        );
      } else {
        // Defensive fallback for any other/unrecognized dialog_type.
        body = _InfoView(
          message: (content['dialog_message'] ?? '') as String,
          onOk: () => _send(
              () => _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
        );
      }
    } else if (type == 'mainmenu') {
      body = _MenuView(
        content: content,
        onSelect: (index, name) {
          LogService.log('ACTION', {'type': 'menu_select', 'name': name});
          if (name == 'POD - Proof of Delivery') {
            // Bespoke screen, not an RF transaction - see _MenuView's doc
            // comment on the synthetic entry. Pushed on top of the current
            // mainmenu rather than routed through _send()/sendInput(), so
            // the live RF session (clientid/htmlrfid) is completely
            // untouched while the operator is on POD.
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PodScreen(
                rw: _rw,
                facCode: _facCode,
                compCode: _compCode,
              ),
            ));
            return;
          }
          if (name == 'Serial Receiving') {
            // Same synthetic-entry handling as POD above - bespoke
            // lgfapi-backed flow, RF session left untouched.
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SerialReceivingScreen(
                rw: _rw,
                facCode: _facCode,
                compCode: _compCode,
              ),
            ));
            return;
          }
          if (name == 'Receiving Serial/Non Serial') {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CombinedReceivingScreen(
                rw: _rw,
                facCode: _facCode,
                compCode: _compCode,
              ),
            ));
            return;
          }
          _currentTransactionName = name;
          // Fresh transaction - any shipment/Truck Temp state from whatever
          // was on screen before no longer applies.
          _truckTempShipmentId = null;
          _truckTempExistingValue = null;
          _truckTempLocked = false;
          _pendingTruckTemp = null;
          // Fresh transaction - any Wooden Pallet lookup from whatever was
          // on screen before no longer applies.
          _resetWoodenPalletState();
          _resetMixAreaState();
          _resetFullPalletState();
          _resetPickAllocateState();
          _send(() => _rw.sendInput(_clientid, _htmlrfid, index));
        },
      );
    } else {
      body = _ScreenView(
        content: content,
        transactionName: _currentTransactionName,
        truckTempPrefill: _truckTempExistingValue,
        truckTempLocked: _truckTempLocked,
        paLookup: _paLookup,
        paLookupLoading: _paLookupLoading,
        paLookupError: _paLookupError,
        onPaSerialSubmit: _lookupPickAllocateSerial,
        wpLoad: _wpLoad,
        wpOrders: _wpOrders,
        wpLoading: _wpLoading,
        wpTrailerNbr: _wpTrailerNbr,
        wpError: _wpError,
        wpAllocations: _wpAllocations,
        wpAllocationsLoading: _wpAllocationsLoading,
        wpAllocationsError: _wpAllocationsError,
        wpSelectedOrderNbr: _wpSelectedOrderNbr,
        wpSubmittedTaskNbr: _wpSubmittedTaskNbr,
        onWoodenPalletTrailerSubmit: _lookupWoodenPallet,
        onWoodenPalletOrderTap: _lookupWoodenPalletAllocations,
        onWoodenPalletTaskSubmit: _submitWoodenPalletTask,
        // The real OBLPN field's label is blank (see
        // AppConfig.wpEnhOblpnFieldTag's doc comment), so it can't be
        // matched by label inside onSubmit below like Drop Location is -
        // _ScreenViewState calls this directly instead, from the same spot
        // it already knows onWoodenPalletOblpnScreen && isCurrent.
        onWoodenPalletOblpnFieldSubmit: (value) => _wpConfirmedOblpnNbr = value,
        // "Back" - live-corrected 2026-08-15: ctrl_key "X" turned out to be
        // Exit App on the real screen behind this (see _sendCtrlKey's doc
        // comment), which logged the operator straight out - not what
        // "Back" should do. Now sends the same "Previous Screen" action the
        // app's own top-left back arrow already uses (previousScreenKey,
        // e.g. "W") instead of a hardcoded key.
        onWoodenPalletBack: () => _send(
            () => _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
        onWoodenPalletTasksInProgress: () => _sendCtrlKey('P'),
        maAllocations: _maAllocations,
        maLoading: _maLoading,
        maTrailerNbr: _maTrailerNbr,
        maError: _maError,
        maSubmittedTaskNbr: _maSubmittedTaskNbr,
        onMixAreaTrailerSubmit: _lookupMixAreaTrailer,
        // Same blank-label caveat as onWoodenPalletOblpnFieldSubmit.
        onMixAreaOblpnFieldSubmit: (value) => _maConfirmedOblpnNbr = value,
        fpLoad: _fpLoad,
        fpOrderNbr: _fpOrderNbr,
        fpCustomerName: _fpCustomerName,
        fpLoading: _fpLoading,
        fpTrailerNbr: _fpTrailerNbr,
        fpError: _fpError,
        fpTmp: _fpTmp,
        fpTfp: _fpTfp,
        fpTasks: _fpTasks,
        fpSkuGroups: _fpSkuGroups,
        fpCompletedSkuGroups: _fpCompletedSkuGroups,
        fpSkuLoading: _fpSkuLoading,
        fpSkuError: _fpSkuError,
        fpPickedCountFor: _fpPickedCountFor,
        onFullPalletTrailerSubmit: _lookupFullPalletTrailer,
        onFullPalletBack: _backFullPallet,
        onFullPalletReject: _rejectFullPalletTrailer,
        onFullPalletMixPalletTask: _selectMixPalletTask,
        onFullPalletFullPalletTask: _lookupFullPalletSkus,
        onFullPalletLpnScan: _scanFullPalletLpn,
        onCtrlKeyPressed: (key) => _sendCtrlKey(key),
        onSubmit: (label, value, injectedTemp) async {
          if (value.isNotEmpty) _memory[label] = value;
          // Pick And Allocate (2026-09-08) - a new order being scanned
          // starts a fresh transaction, so any serial lookup from a
          // previous order no longer applies. The Order Nbr field is only
          // editable/current on the first screen, so this fires exactly
          // once per order.
          if (AppConfig.currentFlags.pickAllocateSerialEnabled &&
              label.toLowerCase().contains('order nbr') &&
              (_paLookup != null || _paLookupError != null)) {
            _paLookup = null;
            _paLookupError = null;
          }
          // The Shipment field just being confirmed is the earliest reliable
          // point at which its value is final - look up whether this
          // shipment already has a Truck Temp recorded (see
          // _lookupTruckTemp's doc comment).
          if (AppConfig.currentFlags.truckTempEnabled &&
              value.isNotEmpty &&
              label.toLowerCase().contains(AppConfig.enhLookupLabelMatch)) {
            await _lookupTruckTemp(value);
          }
          // Wooden Pallet Task (2026-08-15) - see onWoodenPalletOblpnFieldSubmit
          // below for capturing the confirmed OBLPN (that real field has a
          // blank label, so it can't be matched here the way Drop Location
          // is just below).
          final onWoodenPalletTransaction =
              AppConfig.currentFlags.woodenPalletTaskEnabled &&
                  _currentTransactionName
                      .toLowerCase()
                      .contains(AppConfig.wpEnhPageTitleMatch);
          if (injectedTemp != null && injectedTemp.isNotEmpty) {
            // Captured now, but NOT patched yet - see _pendingTruckTemp's
            // doc comment. The actual PATCH fires when End LPN is pressed.
            _pendingTruckTemp = injectedTemp;
          }
          // Mix Area Task (2026-08-21) - a tapped real task button already
          // calls this same onSubmit(name, idx, null) via the existing
          // generic type=='button' handling (untouched) - `label` here IS
          // that button's name, i.e. the task nbr. Captured for our own
          // bookkeeping (which WoodenPalletAllocation to use for the later
          // Qty prefill) by matching against the already-fetched
          // allocation list, since there's no other reliable way to tell
          // "this onSubmit call came from a task button" apart from a
          // normal field submit.
          if (AppConfig.currentFlags.mixAreaTaskEnabled &&
              _currentTransactionName
                  .toLowerCase()
                  .contains(AppConfig.maEnhPageTitleMatch) &&
              _maAllocations.any((a) => a.taskNbr == label)) {
            _maSubmittedTaskNbr = label;
          }
          // Second way a task nbr reaches this screen (2026-09-26 fix) -
          // scanned/typed directly into the real "Task:" field rather than
          // tapped from a button list. Here `label` is the FIELD's label
          // ("Task:") and the task nbr is the submitted VALUE instead - see
          // AppConfig.maEnhTaskLabelMatch's doc comment for why the button
          // case above never covered this.
          if (AppConfig.currentFlags.mixAreaTaskEnabled &&
              _currentTransactionName
                  .toLowerCase()
                  .contains(AppConfig.maEnhPageTitleMatch) &&
              label.toLowerCase().contains(AppConfig.maEnhTaskLabelMatch) &&
              !label
                  .toLowerCase()
                  .contains(AppConfig.maEnhTaskTypeLabelMatch) &&
              _maAllocations.any((a) => a.taskNbr == value)) {
            _maSubmittedTaskNbr = value;
          }
          // Multi Field Barcode - GS1 (2026-09-27, extended 2026-09-28 for
          // ]C2/scrub items, 2026-09-28 for multi-screen support) - computed
          // once and reused below, same "onXScreen" idiom as
          // onWoodenPalletTransaction above.
          // multiFieldBarcodeGs1PageTitleMatches supports more than one real
          // screen name at once (comma-separated in the build-time value,
          // see AppConfig's doc comment) - a customer's padding/extraction
          // requirement isn't always confined to a single screen, so this
          // matches if the current transaction name contains ANY listed
          // entry, not just one fixed string.
          final onMultiFieldBarcodeGs1Screen =
              AppConfig.currentFlags.multiFieldBarcodeGs1Enabled &&
                  AppConfig.multiFieldBarcodeGs1PageTitleMatches.any(
                      (m) => _currentTransactionName.toLowerCase().contains(m));
          // LPN padding - see AppConfig.multiFieldBarcodeGs1LpnValuePrefixes'
          // doc comment for why this padding is needed before WMS's own
          // Multi Field Barcode config can correctly split the scanned
          // LPN+Item value. Only touches a value that actually looks like
          // this exact scan (]C1 or ]C2 + the "00" identifier) - a manually
          // typed LPN without that prefix, or a scan on any other screen, is
          // left untouched.
          if (onMultiFieldBarcodeGs1Screen &&
              label
                  .toLowerCase()
                  .contains(AppConfig.multiFieldBarcodeGs1LpnLabelMatch)) {
            for (final prefix
                in AppConfig.multiFieldBarcodeGs1LpnValuePrefixes) {
              if (value.startsWith(prefix)) {
                value = '${prefix}00${value.substring(prefix.length)}';
                break;
              }
            }
          }
          // Qty field (2026-09-27) - see
          // _parseMultiFieldBarcodeGs1Barcode1's doc comment. Same barcode
          // #1 as Expiry Date below, scanned on a separate occasion - only
          // the Count portion is used here, leading zeros stripped.
          if (onMultiFieldBarcodeGs1Screen &&
              label
                  .toLowerCase()
                  .contains(AppConfig.multiFieldBarcodeGs1QtyLabelMatch)) {
            final parsed = _parseMultiFieldBarcodeGs1Barcode1(value);
            if (parsed != null) value = _stripLeadingZeros(parsed.count);
          }
          // Expiry Date field (2026-09-27) - same barcode #1, this time
          // using the Best Before Date portion, reformatted from GS1's
          // YYMMDD to what Oracle's date fields expect on this instance.
          if (onMultiFieldBarcodeGs1Screen &&
              label
                  .toLowerCase()
                  .contains(AppConfig.multiFieldBarcodeGs1ExpiryLabelMatch)) {
            final parsed = _parseMultiFieldBarcodeGs1Barcode1(value);
            final formatted =
                parsed == null ? null : _yymmddToMmDdYyyy(parsed.expiryYYMMDD);
            if (formatted != null) value = formatted;
          }
          final ok =
              await _send(() => _rw.sendInput(_clientid, _htmlrfid, value));
          // Drop Location submitted for real -> fire assign_and_load_oblpn,
          // matching Truck Temp's "deferred action right after a specific
          // field's real submission" pattern (there: PATCH on End LPN).
          if (ok &&
              onWoodenPalletTransaction &&
              label
                  .toLowerCase()
                  .contains(AppConfig.wpEnhDropLocationLabelMatch)) {
            await _assignAndLoadWoodenPalletOblpnAndShowResult();
          }
        },
        onTab: () => _send(() => _rw.sendTab(_clientid, _htmlrfid)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip:
              type == 'mainmenu' ? 'Back (Log out)' : 'Back (Previous Screen)',
          // BUG FIX 2026-08-21: on the mainmenu specifically, there is no
          // real "previous screen" - it's the top of the navigation tree.
          // Sending previousScreenKey from here anyway got back a
          // response shape our generic parser doesn't handle ("type
          // '_Map<dynamic, dynamic>' is not a subtype of type
          // 'Map<String, dynamic>' in type cast"), live-confirmed on the
          // desktop build - likely some kind of session-end response,
          // not a normal page/dialog. Mirrors Exit App's own semantics
          // instead (_sendAndLogout: always navigates back to Login
          // afterward, regardless of this call's own outcome) rather than
          // relying on parsing whatever Oracle actually sends back here.
          onPressed: () => type == 'mainmenu'
              ? _sendAndLogout(() =>
                  _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey))
              : _send(() =>
                  _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
        ),
        title: Text((content['headers']?['app_title'] ?? 'RF') as String),
        actions: [
          // Every screen's own ctrl_keys (Exit App, Change Facility, End
          // LPN, Apply Lock, Switch UOM, etc.) shown here - added
          // 2026-07-09. Previously this menu only existed inside _MenuView
          // for mainmenu screens; a generic _ScreenView screen (e.g. a
          // multi-field Receiving transaction) had NO way to reach its own
          // ctrl_keys at all, which looked like specific actions (e.g.
          // "Ctrl-E: End LPN") had disappeared, when really the UI never
          // exposed them on that screen type in the first place. Centralized
          // here so every screen type gets the same actions menu.
          if ((content['ctrl_keys'] as List?)?.isNotEmpty ?? false)
            PopupMenuButton<String>(
              tooltip: 'Actions',
              onSelected: (key) async {
                // Deferred Truck Temp PATCH (see _pendingTruckTemp) fires
                // right here, before the End LPN action itself is sent -
                // this is the one specific point in the whole transaction
                // the developer's spec designates for actually saving it.
                if (endLpnKey != null &&
                    key == endLpnKey &&
                    (_pendingTruckTemp?.isNotEmpty ?? false)) {
                  final temp = _pendingTruckTemp!;
                  _pendingTruckTemp = null;
                  await _saveTruckTemp(temp);
                }
                await _sendCtrlKey(key);
              },
              itemBuilder: (_) => (content['ctrl_keys'] as List).map((k) {
                final m = k as Map;
                final rawKey = (m['key'] ?? '') as String;
                final label = ((m['value'] ?? '') as String)
                    .replaceFirst(RegExp(r'^.*?:\s*'), '');
                return PopupMenuItem<String>(value: rawKey, child: Text(label));
              }).toList(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Text('Actions'),
                  Icon(Icons.arrow_drop_down),
                ]),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Captured Files (photos/signatures)',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const CapturedFilesScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Activity Logs',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const LogsScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Debug: request/response history',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => _DebugSheet(
                history: _rw.history,
                currentClientId: _sessionClientId,
                currentHtmlrfid: _sessionHtmlrfid,
                bearerToken: widget.auth.session?.accessToken ?? '',
              ),
            ),
          ),
        ],
      ),
      body: Stack(children: [
        body,
        if (_busy)
          const Positioned.fill(
            // A ColoredBox alone doesn't reliably stop taps from reaching
            // whatever's underneath in the Stack - AbsorbPointer makes the
            // "can't interact while busy" guarantee explicit, so a second
            // overlapping request can't be fired by a tap landing on the
            // menu/button underneath mid-request.
            child: AbsorbPointer(
              child: ColoredBox(
                color: Color(0x22000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Bottom sheet showing the raw last request and response - our on-device
/// visibility for diagnosing the exact payloads.
class _DebugSheet extends StatelessWidget {
  final List<RwExchange> history;
  final int currentClientId;
  final String currentHtmlrfid;
  final String bearerToken;
  const _DebugSheet({
    required this.history,
    required this.currentClientId,
    required this.currentHtmlrfid,
    required this.bearerToken,
  });
  @override
  Widget build(BuildContext context) {
    const json = JsonEncoder.withIndent('  ');
    // Newest first, so the most relevant exchange (whatever just happened,
    // e.g. a failed auto-retry) is right at the top without scrolling.
    final reversed = history.reversed.toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (_, controller) => Container(
        color: const Color(0xFF05070A),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
                'CURRENT SESSION (tracks latest, updated on every response)',
                style: TextStyle(
                    color: Color(0xFF61AFEF), fontWeight: FontWeight.bold)),
            SelectableText(
              'clientid: $currentClientId\nhtmlrfid: $currentHtmlrfid',
              style: const TextStyle(
                  color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 8),
            const Text(
                'BEARER TOKEN (matches the htmlrfid above - copy both together for a Postman replay)',
                style: TextStyle(
                    color: Color(0xFF61AFEF),
                    fontWeight: FontWeight.bold,
                    fontSize: 11)),
            SelectableText(
              bearerToken,
              style: const TextStyle(
                  color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 16),
            Text(
                'HISTORY (${reversed.length} exchange${reversed.length == 1 ? '' : 's'} this session, newest first)',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            const Divider(color: Colors.white24, height: 24),
            for (var i = 0; i < reversed.length; i++) ...[
              Text(
                '#${reversed.length - i} • ${reversed[i].at.hour.toString().padLeft(2, '0')}:${reversed[i].at.minute.toString().padLeft(2, '0')}:${reversed[i].at.second.toString().padLeft(2, '0')}'
                ' • ${reversed[i].elapsed.inMilliseconds}ms',
                style: TextStyle(
                    // Flagged orange past 800ms so a slow one is easy to
                    // spot while scrolling a long history, without implying
                    // any fixed "correct" threshold.
                    color: reversed[i].elapsed.inMilliseconds > 800
                        ? const Color(0xFFF5A623)
                        : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold),
              ),
              SelectableText(
                'token used: ${reversed[i].token}',
                style: const TextStyle(
                    color: Colors.white38,
                    fontFamily: 'monospace',
                    fontSize: 10),
              ),
              const SizedBox(height: 4),
              const Text('REQUEST',
                  style: TextStyle(
                      color: Color(0xFFF5A623),
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
              SelectableText(
                json.convert(reversed[i].request),
                style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 12),
              ),
              const SizedBox(height: 8),
              const Text('RESPONSE',
                  style: TextStyle(
                      color: Color(0xFF3ECF6E),
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
              SelectableText(
                json.convert(reversed[i].response),
                style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 12),
              ),
              const Divider(color: Colors.white24, height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================ VIEWS

/// Opens the camera scanner and returns the first decoded barcode's raw
/// value, or null if the operator backs out without scanning anything.
/// Rugged devices with DataWedge configured don't need this at all (the
/// hardware scanner injects keystrokes straight into the focused field) -
/// this is specifically for standard devices with only a camera.
Future<String?> _scanBarcode(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const _BarcodeScannerScreen()),
  );
}

class _BarcodeScannerScreen extends StatefulWidget {
  const _BarcodeScannerScreen();
  @override
  State<_BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<_BarcodeScannerScreen> {
  // MobileScanner can call onDetect multiple times for the same frame/code
  // before the pop below actually unwinds the route - guard so only the
  // first decoded value is ever returned.
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final value =
        capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (value == null || value.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode')),
      body: MobileScanner(
        onDetect: _onDetect,
        // Without this, a camera failure falls back to mobile_scanner's own
        // default placeholder - a bare white error icon on black, with NO
        // indication of what actually went wrong (2026-09-27, live-
        // confirmed on a Nokia C01 Plus: camera permission was granted and
        // it wasn't a mirroring artifact, yet the scanner still failed to
        // start - that bare icon gave no way to tell why). Surfacing
        // error.toString() here (MobileScannerException's own message,
        // e.g. permission/hardware/already-in-use) turns a dead end into
        // an actual diagnosis next time this happens on any device.
        // mobile_scanner 7.x dropped the third `child` param this callback
        // used to take in 5.x (2026-09-27, upgrade) - two args now.
        errorBuilder: (context, error) => ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Camera unavailable:\n$error',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Parses barcode #1 from the Multi Field Barcode - GS1 label (2026-09-27) -
/// see AppConfig.multiFieldBarcodeGs1QtyLabelMatch's doc comment for the
/// fixed AI layout this assumes. Positional, not separator-based, same
/// reasoning as the LPN+Item barcode's fixed-width parsing. Returns null if
/// the scan doesn't match this exact shape (e.g. it's some other barcode, or
/// a manually typed value) - the caller leaves anything that doesn't parse
/// untouched rather than guessing.
({String expiryYYMMDD, String count})? _parseMultiFieldBarcodeGs1Barcode1(
    String rawScan) {
  const gtinMarker = ']C102'; // ]C1 symbology prefix + AI(02) marker
  const gtinLength = 14;
  const variantMarker = '20';
  const variantLength = 2;
  const expiryMarker = '15';
  const expiryLength = 6;
  const countMarker = '37';

  if (!rawScan.startsWith(gtinMarker)) return null;
  var rest = rawScan.substring(gtinMarker.length);
  if (rest.length <= gtinLength) return null;
  rest = rest.substring(gtinLength); // skip the GTIN value itself

  if (!rest.startsWith(variantMarker) ||
      rest.length <= variantMarker.length + variantLength) {
    return null;
  }
  rest = rest.substring(variantMarker.length + variantLength);

  if (!rest.startsWith(expiryMarker) ||
      rest.length <= expiryMarker.length + expiryLength) {
    return null;
  }
  final expiry =
      rest.substring(expiryMarker.length, expiryMarker.length + expiryLength);
  rest = rest.substring(expiryMarker.length + expiryLength);

  if (!rest.startsWith(countMarker)) return null;
  final count = rest.substring(countMarker.length);
  if (count.isEmpty) return null;

  return (expiryYYMMDD: expiry, count: count);
}

/// Strips leading zeros from a scanned Count value (2026-09-27, explicit
/// customer request - "0080" on the label should read as "80" in the Qty
/// field). Guards against stripping an all-zero value down to an empty
/// string.
String _stripLeadingZeros(String digits) {
  final stripped = digits.replaceFirst(RegExp(r'^0+'), '');
  return stripped.isEmpty ? '0' : stripped;
}

/// Converts a GS1 AI(15) Best Before Date (YYMMDD) to MM/DD/YYYY (2026-09-
/// 27) - matching the format Oracle's date entry fields expect on this
/// instance (see _pickDate's doc comment for the same convention used by
/// the manual date picker elsewhere in this app). The 2-digit year always
/// means 20XX here - a warehouse expiry date is never going to land in the
/// 1900s, so no sliding-window guess is needed the way GS1's own spec
/// requires for the general case.
String? _yymmddToMmDdYyyy(String yymmdd) {
  if (yymmdd.length != 6) return null;
  final yy = int.tryParse(yymmdd.substring(0, 2));
  final mm = yymmdd.substring(2, 4);
  final dd = yymmdd.substring(4, 6);
  if (yy == null) return null;
  return '$mm/$dd/${2000 + yy}';
}

/// Whether a field's label/prompt looks like a date field - the RF API gives
/// no dedicated "type: date" signal, only free-text entry, so this matches
/// the same label-substring convention already used for Truck Temp/LPN
/// injection (see AppConfig.enh* usage below).
bool _looksLikeDateField(String labelOrMessage) =>
    labelOrMessage.toLowerCase().contains('date');

/// Shows a date picker and writes the result into [controller] as
/// MM/DD/YYYY, matching the format Oracle expects for date entry fields
/// (e.g. Expiry Date) on this instance.
Future<void> _pickDate(
    BuildContext context, TextEditingController controller) async {
  final now = DateTime.now();
  final picked = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: DateTime(now.year - 5),
    lastDate: DateTime(now.year + 5),
  );
  if (picked != null) {
    controller.text =
        '${picked.month.toString().padLeft(2, '0')}/${picked.day.toString().padLeft(2, '0')}/${picked.year}';
  }
}

class _EntryView extends StatefulWidget {
  final String message;
  final bool masked, forceCaps, allowCancel;
  final int? maxLength;
  // Pre-filled value (2026-08-15, Wooden Pallet Task's Drop Location
  // prompt - this dialog type has no page_content fields to inject into
  // like _ScreenView, so this is the only way to default it) - empty
  // means no prefill, same as before this was added.
  final String initialValue;
  final void Function(String) onSubmit;
  final VoidCallback onCancel;
  const _EntryView({
    super.key,
    required this.message,
    required this.masked,
    required this.forceCaps,
    required this.maxLength,
    required this.allowCancel,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });
  @override
  State<_EntryView> createState() => _EntryViewState();
}

class _EntryViewState extends State<_EntryView> {
  late final _c = TextEditingController(text: widget.initialValue);

  // Single submit path for both triggers below (Enter/scanner-suffix-key via
  // onSubmitted, and the visible Submit button) - both are legitimate,
  // distinct ways a user (or a DataWedge-driven scanner) completes this
  // field, so neither can be removed; routing both through one method just
  // stops them from independently re-deriving "the current text" and
  // drifting apart.
  void _submit() => widget.onSubmit(_c.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.message.trim(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        TextField(
          controller: _c,
          autofocus: true,
          obscureText: widget.masked,
          maxLength: widget.maxLength,
          textCapitalization: widget.forceCaps
              ? TextCapitalization.characters
              : TextCapitalization.none,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            // Masked fields (e.g. a PIN) get neither helper - scanning or
            // date-picking into an obscured field makes no sense.
            suffixIcon: widget.masked
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_looksLikeDateField(widget.message))
                        IconButton(
                          icon: const Icon(Icons.calendar_month),
                          tooltip: 'Pick date',
                          onPressed: () => _pickDate(context, _c),
                        ),
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'Scan barcode',
                        onPressed: () async {
                          final scanned = await _scanBarcode(context);
                          if (scanned != null) _c.text = scanned;
                        },
                      ),
                    ],
                  ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        Row(children: [
          FilledButton(onPressed: _submit, child: const Text('Submit')),
          const SizedBox(width: 8),
          if (widget.allowCancel)
            OutlinedButton(
                onPressed: widget.onCancel, child: const Text('Cancel')),
        ]),
      ]),
    );
  }
}

class _InfoView extends StatelessWidget {
  final String message;
  final VoidCallback onOk;
  const _InfoView({required this.message, required this.onOk});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onOk, child: const Text('OK')),
        ]),
      );
}

/// A genuine yes/no dialog reaching the operator (2026-08-15) - see
/// _isAutoResolvableYesNo's doc comment for why most yesno dialogs never
/// get here at all. Prefers the response's own labeled ctrl_keys (same
/// label-stripping the Actions PopupMenuButton already uses) so any real
/// yesno dialog renders correctly without per-dialog hardcoding; falls
/// back to literal "A"/"W" with generic Accept/Do not accept labels if
/// this particular response has no ctrl_keys of its own - unverified
/// against a live capture, correct if wrong (see the debug sheet).
class _YesNoView extends StatelessWidget {
  final String message;
  final List<Map<String, dynamic>> ctrlKeys;
  final void Function(String key) onAnswer;
  const _YesNoView(
      {required this.message, required this.ctrlKeys, required this.onAnswer});
  @override
  Widget build(BuildContext context) {
    final buttons = ctrlKeys.isNotEmpty
        ? ctrlKeys
            .map((k) => MapEntry(
                (k['key'] ?? '').toString(),
                ((k['value'] ?? '') as String)
                    .replaceFirst(RegExp(r'^.*?:\s*'), '')))
            .toList()
        : const [MapEntry('A', 'Accept'), MapEntry('W', 'Do not accept')];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: buttons
                .map((b) => FilledButton(
                    onPressed: () => onAnswer(b.key), child: Text(b.value)))
                .toList()),
      ]),
    );
  }
}

/// Best-effort keyword match from a menu item's name to a representative
/// icon - added 2026-07-24 for a Flexi-Pro-style icon grid (see the
/// customer-supplied installation/connection guide for the reference).
/// Oracle's mainmenu response only ever sends {index, name} - no icon data -
/// so this is entirely client-side guesswork keyed on the visible label
/// text, same as every other name-based match in this app
/// (AppConfig.truckTempPageTitleMatch etc). Checked in order, first match
/// wins - more specific phrases are
/// listed before the generic keywords they'd otherwise be shadowed by (e.g.
/// "cycle count" before the bare "count").
IconData _iconForMenuItem(String name) {
  final n = name.toLowerCase();
  const mapping = <MapEntry<String, IconData>>[
    MapEntry('proof of delivery', Icons.assignment_turned_in),
    MapEntry('cycle count', Icons.fact_check),
    MapEntry('count', Icons.fact_check),
    MapEntry('putaway', Icons.warehouse),
    MapEntry('put away', Icons.warehouse),
    MapEntry('receiv', Icons.move_to_inbox),
    MapEntry('pick', Icons.shopping_basket),
    MapEntry('pack', Icons.inventory_2),
    MapEntry('ship', Icons.local_shipping),
    MapEntry('load', Icons.local_shipping),
    MapEntry('repalletiz', Icons.autorenew),
    MapEntry('wrap', Icons.layers),
    MapEntry('pallet', Icons.view_module),
    MapEntry('carton', Icons.inventory),
    MapEntry('box', Icons.inventory),
    MapEntry('lpn', Icons.qr_code),
    MapEntry('lock', Icons.lock),
    MapEntry('adjust', Icons.tune),
    MapEntry('transfer', Icons.swap_horiz),
    MapEntry('locate', Icons.pin_drop),
    MapEntry('move', Icons.swap_horiz),
    MapEntry('return', Icons.assignment_return),
    MapEntry('consumable', Icons.category),
    MapEntry('machine', Icons.precision_manufacturing),
    MapEntry('issue', Icons.report_problem),
    MapEntry('short', Icons.report_problem),
    MapEntry('damage', Icons.report_problem),
    MapEntry('dock', Icons.garage),
    MapEntry('replenish', Icons.refresh),
    MapEntry('order', Icons.receipt_long),
    MapEntry('task', Icons.play_circle_outline),
    MapEntry('inventory', Icons.inventory_2),
  ];
  for (final e in mapping) {
    if (n.contains(e.key)) return e.value;
  }
  return Icons.touch_app;
}

class _MenuView extends StatelessWidget {
  final Map<String, dynamic> content;
  final void Function(String index, String name) onSelect;
  const _MenuView({required this.content, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final rows = (content['page_content'] ?? []) as List;
    final buttons = <Map<String, dynamic>>[];
    for (final row in rows) {
      for (final c in (row as List)) {
        if ((c as Map)['type'] == 'menu_button') {
          buttons.add(c.cast<String, dynamic>());
        }
      }
    }
    // ctrl_keys are shown from the shared AppBar "Actions" menu now (added
    // 2026-07-09, see _RuntimeScreenState.build()) rather than a
    // mainmenu-only popup here, so every screen type gets the same menu.

    // Synthetic entry (2026-07-23) - POD is a bespoke screen backed by
    // direct OCWMS lgfapi calls, not an RF transaction, so there's no real
    // server-side menu_button for it. Appended client-side after the real
    // ones so it renders identically (same ListTile, next sequential screen
    // number) but is never confused with genuine WMS menu content - detected
    // by name (see the onSelect callback below) rather than a sentinel index,
    // since the index now looks like a real one and must stay collision-safe
    // if a real environment ever legitimately has that many menu items.
    //
    // Built for one customer specifically - gated behind
    // AppConfig.currentFlags.podEnabled (2026-07-25) so customers with no
    // POD concept never see it. Off by default - see
    // FeatureSettingsScreen to turn it on.
    var maxIndex = 0;
    for (final b in buttons) {
      final n =
          int.tryParse(((b['value'] ?? {}) as Map)['index']?.toString() ?? '');
      if (n != null && n > maxIndex) maxIndex = n;
    }
    void addSynthetic(String name) {
      buttons.add({
        'value': {'index': '${++maxIndex}', 'name': name},
      });
    }

    if (AppConfig.currentFlags.podEnabled) {
      addSynthetic('POD - Proof of Delivery');
    }
    // Serial Receiving (2026-09-08) - same synthetic-entry pattern as POD:
    // a bespoke lgfapi-backed flow, not an RF transaction, detected by name
    // in the onSelect callback (see _RuntimeScreenState) and pushed on top
    // of the live RF session without touching it.
    if (AppConfig.currentFlags.serialReceivingEnabled) {
      addSynthetic('Serial Receiving');
    }
    if (AppConfig.currentFlags.combinedReceivingEnabled) {
      addSynthetic('Receiving Serial/Non Serial');
    }

    // Icon grid (2026-07-24), replacing the earlier plain numbered list -
    // matches the Flexi Pro reference's icon-per-transaction mobile layout.
    // Wider windows (desktop) get more columns rather than staying pinned
    // at 2 - same GridView, just a width-derived crossAxisCount.
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 180).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
          ),
          itemCount: buttons.length,
          itemBuilder: (context, i) {
            final v = (buttons[i]['value'] ?? {}) as Map;
            final idx = (v['index'] ?? '').toString();
            final name = (v['name'] ?? '').toString();
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelect(idx, name),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_iconForMenuItem(name),
                          size: 36,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 8),
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Generic RF screen renderer with Truck Temp injection above the LPN field.
///
/// Oracle tracks a single current-field cursor server-side on multi-field
/// screens, exactly like a physical RF terminal - confirmed live 2026-07-09
/// on a full multi-step transaction (Dock -> Shipment -> LPN -> SKU -> Qty
/// -> Batch -> Expiry -> End LPN). Only the field the server currently has
/// `"focus": true` on is genuinely editable; every other field shown is
/// read-only context (already submitted, or not yet reached - jumping ahead
/// isn't possible). [onTab] explicitly skips the current field with no
/// value - only valid on a field the server doesn't require; skipping one
/// that has an unconfirmed auto-populated SUGGESTED value (the server can
/// pre-fill e.g. Shipment/Shpmt Type after Dock is submitted) fails with a
/// "Required Field" info dialog - that value must be explicitly
/// (re-)submitted via [onSubmit] first, even though it's already showing.
class _ScreenView extends StatefulWidget {
  final Map<String, dynamic> content;
  // Name of the mainmenu item that led to this screen (see
  // _RuntimeScreenState._currentTransactionName) - used to scope the Truck
  // Temp injection to one specific transaction rather than every screen with
  // an "lpn"-labeled field.
  final String transactionName;
  // If the currently-on-screen shipment already has a Truck Temp value
  // recorded (see _RuntimeScreenState._lookupTruckTemp), it's passed here so
  // the injected field can display it read-only instead of asking the
  // operator to re-enter it.
  final String? truckTempPrefill;
  final bool truckTempLocked;
  // Pick And Allocate serial-driven enhancement (2026-09-08) - the result
  // of the lgfapi lookup fired when the injected Serial Nbr field is
  // submitted (see _RuntimeScreenState._lookupPickAllocateSerial). Non-null
  // paLookup means a successful lookup whose values pre-fill the standard
  // Locn/IBLPN/Qty/Serial fields on the following screens.
  final PaSerialLookup? paLookup;
  final bool paLookupLoading;
  final String? paLookupError;
  final Future<void> Function(String serial) onPaSerialSubmit;
  // Wooden Pallet Task (2026-08-15) - result of the trailer -> load ->
  // order lookup fired from _RuntimeScreenState when the Trailer field is
  // submitted (see AppConfig.wpEnhPageTitleMatch/wpEnhTrailerLabelMatch).
  // wpTrailerNbr doubles as "has a lookup been attempted at all this
  // transaction" - null means never attempted, so nothing renders yet.
  final WoodenPalletLoad? wpLoad;
  final List<WoodenPalletOrder> wpOrders;
  final bool wpLoading;
  final String? wpTrailerNbr;
  final String? wpError;
  // Task table step (2026-08-15) - result of tapping one order from
  // wpOrders above (see onWoodenPalletOrderTap). wpSelectedOrderNbr doubles
  // as "are we viewing the task table right now" - null means still on the
  // order table. Both this and the order table (wpLoad/wpOrders above) are
  // the last purely custom, client-only steps in this feature - once a
  // task is submitted (onWoodenPalletTaskSubmit), everything downstream is
  // the REAL RF session/screens, just with a few injected values (see
  // build()'s doc comment on onWoodenPalletOblpnScreen etc.).
  final List<WoodenPalletAllocation>? wpAllocations;
  final bool wpAllocationsLoading;
  final String? wpAllocationsError;
  final String? wpSelectedOrderNbr;
  // The task nbr genuinely submitted to the real RF session (see
  // onWoodenPalletTaskSubmit) - used to find the matching
  // WoodenPalletAllocation (Locn/SKU/Qty) once the real SKU/Qty screen is
  // reached, and to find the real OBLPN screen's own readonly display
  // field's value (see build()'s onWoodenPalletOblpnScreen).
  final String? wpSubmittedTaskNbr;
  // Fired when the injected Trailer Nbr field (see _woodenPalletTrailerField)
  // is submitted - goes straight to _RuntimeScreenState._lookupWoodenPallet,
  // NOT through onSubmit/sendInput below, since this field has no
  // corresponding real RF field to submit to (see the injection's doc
  // comment in build()).
  final Future<void> Function(String) onWoodenPalletTrailerSubmit;
  final Future<void> Function(String orderNbr) onWoodenPalletOrderTap;
  // Submits the checked task's nbr into the REAL RF session (2026-08-15
  // correction) - see _RuntimeScreenState._submitWoodenPalletTask.
  // Everything past this point (OBLPN scan, SKU/Qty, Task Ended dialog,
  // Drop Location, assign_and_load_oblpn) is driven by the real session
  // and rendered normally, not through a dedicated callback like this one.
  final Future<void> Function(String taskNbr) onWoodenPalletTaskSubmit;
  // Fired when the real OBLPN-scan field is submitted - see its wiring's
  // doc comment above (blank label means it can't be matched inside
  // onSubmit below the way every other injection's trigger field is).
  final void Function(String value) onWoodenPalletOblpnFieldSubmit;
  // Back/Tasks-in-Progress send ctrl_key "X"/"P" directly to the still-live
  // real RF session behind this screen - see _RuntimeScreenState._sendCtrlKey.
  // "Continue" reuses onTab below (TAB), same as every other screen.
  final VoidCallback onWoodenPalletBack;
  final VoidCallback onWoodenPalletTasksInProgress;
  // Mix Area Task (2026-08-21) - unlike Wooden Pallet Task, the real
  // task-list buttons stay live and get FILTERED in place by
  // maAllocations' task numbers (not replaced by a custom table) - see
  // AppConfig.maEnhPageTitleMatch. maAllocations is null before any
  // trailer has been entered (show every real task unfiltered, per spec:
  // "first we will display all the tasks"), and doubles as the Qty-prefill
  // source once a task is tapped (maSubmittedTaskNbr).
  final List<WoodenPalletAllocation>? maAllocations;
  final bool maLoading;
  final String? maTrailerNbr;
  final String? maError;
  final String? maSubmittedTaskNbr;
  final Future<void> Function(String trailerNbr) onMixAreaTrailerSubmit;
  // Same blank-label caveat as onWoodenPalletOblpnFieldSubmit - see there.
  final void Function(String value) onMixAreaOblpnFieldSubmit;
  // Full Pallet Task (2026-08-22) - see AppConfig.fpEnhPageTitleMatch
  // and _RuntimeScreenState's own "Full Pallet Task enhancement" section.
  // fpLoad/fpOrderNbr/fpCustomerName/fpTmp/fpTfp come from the trailer
  // lookup fired the moment the injected Trailer field is submitted (that
  // submit ALSO advances the real RF session - see
  // onFullPalletTrailerSubmit's doc comment below).
  final FullPalletLoad? fpLoad;
  final String? fpOrderNbr;
  final String fpCustomerName;
  final bool fpLoading;
  final String? fpTrailerNbr;
  final String? fpError;
  final int? fpTmp;
  final int? fpTfp;
  // Client-built task list (step 1, 2026-08-22 correction) - shown
  // alongside the Trailer/TMP/TFP/Customer Name row once the trailer
  // lookup succeeds, same "pick one, then Submit" shape as Wooden Pallet
  // Task's own task table (_injectedWoodenPalletTaskDetailsBlock).
  final List<WoodenPalletAllocation> fpTasks;
  // SKU/Pallet/Pick table (step 4) - populated once Full Pallet Task is
  // pressed (see onFullPalletFullPalletTask). Entirely client-built and
  // client-driven, not tied to any real page_content - confirmed by the
  // user the LPN scan step is a distinct lgfapi action call, not a real
  // RF field submission.
  final List<FullPalletSkuGroup> fpSkuGroups;
  // Already fully-picked lines for this order, shown read-only beneath
  // fpSkuGroups (2026-10-07) - see FullPalletTaskService.
  // fetchCompletedSkuGroups's doc comment.
  final List<FullPalletSkuGroup> fpCompletedSkuGroups;
  final bool fpSkuLoading;
  final String? fpSkuError;
  // How many of a group's pallets have been accounted for so far (normal
  // picks plus any substitute picks resolved to it) - see
  // _RuntimeScreenState._fpPickedCountFor's doc comment.
  final int Function(FullPalletSkuGroup) fpPickedCountFor;
  // Fired when the injected Trailer field (see _fullPalletTrailerField) is
  // submitted - purely a client-side lgfapi lookup (see
  // _RuntimeScreenState._lookupFullPalletTrailer's doc comment), same as
  // Wooden Pallet Task's own trailer field.
  final Future<void> Function(String) onFullPalletTrailerSubmit;
  // Back on the client-built task screen - sends the real "Previous
  // Screen" action (mirrors onWoodenPalletBack).
  final VoidCallback onFullPalletBack;
  // Reject on the vehicle questionnaire (step 2, if/when reached) - fires
  // the email relay before sending the given real ctrl_key. Approve/Exit
  // Screen on that same screen just reuse onCtrlKeyPressed below (no side
  // effect).
  final Future<void> Function(String ctrlKey) onFullPalletReject;
  // Mix Pallet Task / Full Pallet Task buttons on the client-built
  // Trailer/TMP/TFP/Customer + task screen (2026-08-22 correction - these
  // turned out to be OUR OWN buttons, not a separate real screen's
  // ctrl_keys) - both submit the picked task nbr into the real RF session;
  // see _RuntimeScreenState._selectMixPalletTask/_lookupFullPalletSkus.
  final Future<void> Function(String taskNbr) onFullPalletMixPalletTask;
  final Future<void> Function(String taskNbr) onFullPalletFullPalletTask;
  // LPN scan on the SKU/Pallet/Pick screen (step 4) - see
  // FullPalletTaskService.packFullLpn's doc comment on why this isn't a
  // real RF field submission. The checked SKU group is passed alongside
  // the scanned value (2026-08-22, restored 2026-10-06 after a same-day
  // removal) - the operator picks the line first, and the scan is
  // validated against it - see _RuntimeScreenState._scanFullPalletLpn.
  final Future<void> Function(String lpn, FullPalletSkuGroup group)
      onFullPalletLpnScan;
  // Renders content['ctrl_keys'] as an on-page button row (2026-08-21,
  // Mix Area Task spec) - a generic hook (not Mix-Area-specific in
  // meaning) reusing _RuntimeScreenState._sendCtrlKey, the same dispatch
  // the shared "Actions" menu already uses.
  final void Function(String key) onCtrlKeyPressed;
  // onSubmit(focusedLabel, focusedValue, injectedTruckTemp)
  final Future<void> Function(String, String, String?) onSubmit;
  final VoidCallback onTab;
  const _ScreenView(
      {required this.content,
      required this.transactionName,
      required this.truckTempPrefill,
      required this.truckTempLocked,
      required this.paLookup,
      required this.paLookupLoading,
      required this.paLookupError,
      required this.onPaSerialSubmit,
      required this.wpLoad,
      required this.wpOrders,
      required this.wpLoading,
      required this.wpTrailerNbr,
      required this.wpError,
      required this.wpAllocations,
      required this.wpAllocationsLoading,
      required this.wpAllocationsError,
      required this.wpSelectedOrderNbr,
      required this.wpSubmittedTaskNbr,
      required this.onWoodenPalletTrailerSubmit,
      required this.onWoodenPalletOrderTap,
      required this.onWoodenPalletTaskSubmit,
      required this.onWoodenPalletOblpnFieldSubmit,
      required this.onWoodenPalletBack,
      required this.onWoodenPalletTasksInProgress,
      required this.maAllocations,
      required this.maLoading,
      required this.maTrailerNbr,
      required this.maError,
      required this.maSubmittedTaskNbr,
      required this.onMixAreaTrailerSubmit,
      required this.onMixAreaOblpnFieldSubmit,
      required this.fpLoad,
      required this.fpOrderNbr,
      required this.fpCustomerName,
      required this.fpLoading,
      required this.fpTrailerNbr,
      required this.fpError,
      required this.fpTmp,
      required this.fpTfp,
      required this.fpTasks,
      required this.fpSkuGroups,
      required this.fpCompletedSkuGroups,
      required this.fpSkuLoading,
      required this.fpSkuError,
      required this.fpPickedCountFor,
      required this.onFullPalletTrailerSubmit,
      required this.onFullPalletBack,
      required this.onFullPalletReject,
      required this.onFullPalletMixPalletTask,
      required this.onFullPalletFullPalletTask,
      required this.onFullPalletLpnScan,
      required this.onCtrlKeyPressed,
      required this.onSubmit,
      required this.onTab});
  @override
  State<_ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<_ScreenView> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, FocusNode> _focusNodes = {};
  // Last value the SERVER itself reported per field label (2026-08-22) -
  // NOT what the controller currently shows - lets the sync logic below
  // tell "the server's own value genuinely changed" apart from "the
  // operator is mid-typing something new" even when a field stays current
  // across repeated submissions (e.g. Load Confirmation's OBLPN/Pallet
  // scan loop). See that sync block's doc comment for the full story.
  final Map<String, String> _lastServerFieldValue = {};
  final _truckTemp = TextEditingController();
  // Pick And Allocate serial-driven enhancement (2026-09-08) - the
  // client-only injected Serial Nbr field (not one of the server's own
  // page_content fields, same reasoning as _wpTrailer). `_paPrefilledFor`
  // maps a downstream field tag -> the paLookup.key it was last pre-filled
  // for, so a rebuild doesn't clobber operator edits but a new serial
  // lookup re-fills every field.
  final _paSerial = TextEditingController();
  final Map<String, String> _paPrefilledFor = {};
  // Wooden Pallet Task (2026-08-15) - purely client-side, not one of
  // the server's own page_content fields, so it isn't in _ctrls/_focusNodes
  // (those are keyed off real field labels and resynced from the server on
  // every response, which would fight a client-only field).
  final _wpTrailer = TextEditingController();
  // Checkbox selection on the task table - Submit (see
  // _woodenPalletActionButtons/_injectedWoodenPalletTaskDetailsBlock) is
  // only enabled once exactly one task is checked, matching how the real
  // downstream RF screens only ever deal with one task at a time.
  final Set<String> _wpSelectedTaskNbrs = {};
  // 2026-08-15 correction - which real field label each one-time prefill
  // below has already been applied for, so a rebuild doesn't clobber
  // further operator edits (same idiom as Truck Temp's prefill sync in
  // build()), but a genuinely NEW value (new OBLPN generated for a
  // different task, a different allocation's alloc_qty) still gets synced
  // in. These prefill the REAL fields' own _ctrls[label] controllers now -
  // no separate dedicated controllers needed, since every downstream step
  // (OBLPN scan, SKU/Qty, Drop Location) is the real RF screen itself.
  String? _wpOblpnFieldSyncedFor;
  String? _wpSkuFieldSyncedFor;
  String? _wpQtyFieldSyncedFor;
  bool _wpDropLocationFieldSynced = false;
  // Mix Area Task (2026-08-21) - same purely-client-side trailer
  // field pattern as _wpTrailer, kept separate rather than shared (see
  // plan quirky-shimmying-haven.md's modularity note) since each feature
  // has its own flag/state and should stay independently removable.
  final _maTrailer = TextEditingController();
  String? _maOblpnFieldSyncedFor;
  String? _maQtyFieldSyncedFor;
  // No _maDropLocationFieldSynced - unlike the entry-field injections
  // above, Drop Location for Mix Area (same as Wooden Pallet Task) is a
  // dialog_type "entry" (_EntryView), not a _ScreenView field - handled
  // in _RuntimeScreenState.build()'s dialog branch instead (see
  // isMaDropLocationPrompt).
  // Full Pallet Task (2026-08-22) - same purely-client-side field
  // pattern as _wpTrailer/_maTrailer, kept separate for the same
  // modularity reason. _fpLpn is the SKU/Pallet/Pick screen's scan field -
  // also client-side only, since that step is a distinct lgfapi action
  // call, not a real RF field (see FullPalletTaskService.packFullLpn).
  final _fpTrailer = TextEditingController();
  final _fpLpn = TextEditingController();
  // Single-select checkbox state on the client-built task table
  // (_injectedFullPalletTaskDetailsBlock) - "select the task number"
  // (singular) per the spec, unlike Wooden Pallet Task's Set-based
  // multi-checkbox (which also only ever enables Submit at exactly one).
  String? _fpSelectedTaskNbr;
  // Checked SKU line on the SKU/Pallet/Pick table (_fullPalletSkuBlock) -
  // restored 2026-10-06 (previously removed the same day, then reinstated
  // once enforcing it against the scan turned out to be the actual fix
  // needed, not removing it - see _scanFullPalletLpn's doc comment).
  FullPalletSkuGroup? _fpSelectedSku;
  // `autofocus` only ever fires once per widget lifetime, but this same
  // State persists across the whole multi-field transaction as focus moves
  // field to field - so autofocus alone stops working after the first
  // field. Track the last-focused label and explicitly request focus again
  // whenever it changes (added 2026-07-09 - previously the cursor location
  // had no visible indicator after the first field).
  String? _lastCurrentLabel;

  // Split IBLPN photo capture (2026-07-10) - captured any time on this
  // screen (not tied to any field being current), but only actually written
  // to local storage when the Move to LPN field is submitted. Held here as
  // the picked file's own temp path until then; cleared back to null once
  // persisted so a fresh capture is required for the next LPN.
  XFile? _capturedPhoto;

  Future<void> _capturePhoto() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 85);
    if (picked != null && mounted) {
      setState(() => _capturedPhoto = picked);
    }
  }

  /// Copies the captured photo into the app's own local documents storage,
  /// under AppConfig.camFolderName, named with the Move to LPN value plus a
  /// timestamp so multiple captures don't collide and each file is traceable
  /// back to the LPN it was taken for.
  Future<void> _persistCapturedPhoto(String moveToLpnValue) async {
    final photo = _capturedPhoto;
    if (photo == null) return;
    final docsDir = await getApplicationDocumentsDirectory();
    final folder = Directory('${docsDir.path}/${AppConfig.camFolderName}');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeLpn = moveToLpnValue.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final destPath = '${folder.path}/SplitIBLPN_${safeLpn}_$ts.jpg';
    await File(photo.path).copy(destPath);
    // Best-effort auto-upload (2026-07-23, see UploadService) - only
    // deletes the local copy once the receiver confirms it, so an
    // unconfigured/unreachable server just leaves it queued for Captured
    // Files' "Sync Now" to pick up later, exactly like today.
    final uploadConfig = await AppConfig.loadUploadServer();
    if (uploadConfig.isConfigured &&
        await UploadService.tryUpload(File(destPath), uploadConfig)) {
      await File(destPath).delete();
    }
    if (mounted) setState(() => _capturedPhoto = null);
  }

  /// The Wooden/Mix Area/Full Pallet Task Trailer fields are purely
  /// client-side controllers that persist for this State's whole lifetime
  /// (see their declarations' doc comments) - unlike the real RF fields in
  /// _ctrls, nothing was ever resyncing them from the corresponding reset
  /// (_resetWoodenPalletState/_resetMixAreaState/_resetFullPalletState in
  /// _RuntimeScreenState), so whatever trailer number was last typed/scanned
  /// stayed showing the next time that screen came back around - e.g. after
  /// Full Pallet Task's "Tasks Completed" returns to the Trailer entry
  /// screen (2026-09-26, reported during testing). Each reset DOES null out
  /// its own tracked xTrailerNbr, which flows down here as a prop, so
  /// clearing the matching controller when that prop goes non-null -> null
  /// catches all three the same way. A normal new-trailer lookup never
  /// passes through null on its way to the new value (it's set directly in
  /// the same setState that starts the lookup - see e.g.
  /// _lookupFullPalletTrailer), so this can't fire mid-lookup and clear
  /// what the operator just typed.
  @override
  void didUpdateWidget(covariant _ScreenView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wpTrailerNbr != null && widget.wpTrailerNbr == null) {
      _wpTrailer.clear();
    }
    if (oldWidget.maTrailerNbr != null && widget.maTrailerNbr == null) {
      _maTrailer.clear();
    }
    if (oldWidget.fpTrailerNbr != null && widget.fpTrailerNbr == null) {
      _fpTrailer.clear();
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    _truckTemp.dispose();
    _paSerial.dispose();
    _wpTrailer.dispose();
    _maTrailer.dispose();
    _fpTrailer.dispose();
    _fpLpn.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _fields() {
    final rows = (widget.content['page_content'] ?? []) as List;
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      for (final c in (row as List)) {
        out.add((c as Map).cast<String, dynamic>());
      }
    }
    return out;
  }

  String _labelOf(Map<String, dynamic> f) =>
      (f['label'] ?? f['name'] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final fields = _fields();
    final entryFields = fields.where((f) => f['type'] == 'entry').toList();

    // The field Oracle currently has the cursor on. Defaults to the first
    // entry field if none is marked (defensive - every live response so far
    // has always marked exactly one).
    Map<String, dynamic>? currentField;
    for (final f in entryFields) {
      if (f['focus'] == true) {
        currentField = f;
        break;
      }
    }
    currentField ??= entryFields.isNotEmpty ? entryFields.first : null;
    final currentLabel = currentField != null ? _labelOf(currentField) : null;
    final currentTag = (currentField?['tag'] ?? '').toString();
    // Captured BEFORE updating _lastCurrentLabel below, so the per-field
    // loop can tell "did this field just become current in this exact
    // response" apart from "has been current for a while already".
    final previousCurrentLabel = _lastCurrentLabel;

    // Pick And Allocate serial-driven enhancement (2026-09-08) - scoped by
    // the response's own page_title (every screen of this transaction
    // carries "Pick And Allocate"), NOT the mainmenu button name.
    // onPaOrderScreen = the post-order-scan screen (order-type field is
    // present) that still has the editable OBLPN field - the one place the
    // injected Serial Nbr field + details table belong.
    final onPickAllocatePage =
        AppConfig.currentFlags.pickAllocateSerialEnabled &&
            ((widget.content['headers'] ?? const {}) as Map)['page_title']
                    .toString()
                    .toLowerCase()
                    .trim() ==
                AppConfig.paEnhPageTitleMatch;
    final onPaOrderScreen = onPickAllocatePage &&
        fields.any((f) => (f['tag'] ?? '') == AppConfig.paEnhOrderTypeTag) &&
        fields.any((f) => (f['tag'] ?? '') == AppConfig.paEnhInjectBeforeTag);

    // INJECTION: Mix Area Task (2026-08-21) - "Execute Task Mix Area
    // (new)" has the SAME "Tasks:" heading + Curr Locn/Task Type shape as
    // Wooden Pallet Task's first screen, so the same
    // transactionName-alone-isn't-enough bug applies - require this
    // response to actually look like it too. Unlike Wooden Pallet Task,
    // the real content on THIS screen is NOT hidden - it's reordered (see
    // the field-reordering further below) and the real task buttons stay
    // live, just filtered/re-laid-out. Computed here (earlier than every
    // other Mix Area boolean) specifically so the autofocus guard just
    // below can use it too.
    final looksLikeMixAreaTasksScreen = fields.any((f) =>
        f['type'] == 'label' &&
        (f['value'] ?? '').toString().trim().toLowerCase() == 'tasks:');
    final onMixAreaTasksScreen = AppConfig.currentFlags.mixAreaTaskEnabled &&
        widget.transactionName
            .toLowerCase()
            .contains(AppConfig.maEnhPageTitleMatch) &&
        looksLikeMixAreaTasksScreen;

    // Full Pallet Task (2026-08-22) - live-confirmed 2026-08-22 this
    // screen's real shape is the SAME "Tasks:" heading + Curr Locn/Task
    // Type + real task buttons as Mix Area Task's own first screen (not
    // Wooden Pallet Task's hidden-content one) - reuses the same "Tasks:"
    // heading match. Computed here (before every other Full Pallet Task
    // boolean, further below) specifically so the autofocus guard just
    // below can use it too, same reason as onMixAreaTasksScreen above.
    final looksLikeFullPalletTasksScreen = fields.any((f) =>
        f['type'] == 'label' &&
        (f['value'] ?? '').toString().trim().toLowerCase() == 'tasks:');
    final onFullPalletTasksScreen =
        AppConfig.currentFlags.fullPalletTaskEnabled &&
            widget.transactionName
                .toLowerCase()
                .contains(AppConfig.fpEnhPageTitleMatch) &&
            looksLikeFullPalletTasksScreen;

    if (currentLabel != null && currentLabel != _lastCurrentLabel) {
      _lastCurrentLabel = currentLabel;
      // BUG FIX 2026-08-21 - live-confirmed focus-stealing: unlike Wooden
      // Pallet Task (which hides every real field, so none of them ever
      // had a FocusNode to steal focus with), Mix Area Task deliberately
      // keeps the real blank current field ("=>") visible and
      // interactive. This auto-focus side effect was firing for THAT
      // real field on first render regardless, silently pulling
      // keyboard/scanner input away from the injected Trailer field the
      // operator was actually typing/scanning into - whatever got typed
      // instead landed in the real field and was submitted to the real
      // RF session, which (reasonably) rejected it as "Invalid Entry".
      // _lastCurrentLabel is still updated above either way (so
      // justBecameCurrent below keeps its normal one-shot semantics) -
      // only the actual focus-grab is skipped here; the operator can
      // still tap the real field directly if they want to type a task
      // nbr into it instead.
      //
      // onFullPalletTasksScreen (2026-08-22) - same bug, same fix: this
      // screen also keeps a real visible/focusable field (the task-list
      // barcode entry) alongside the injected Trailer field, live-confirmed
      // stealing focus/input from it the same way Mix Area Task's did.
      if (!onMixAreaTasksScreen && !onFullPalletTasksScreen) {
        // Deferred to after this build/layout completes - requesting
        // focus synchronously during build can be dropped since the
        // FocusNode's target TextField isn't attached to the tree yet.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNodes[currentLabel]?.requestFocus();
        });
      }
    }

    // INJECTION: Wooden Pallet Task (2026-08-15) - the standard
    // "Execute Wooden Pallet Tasks" RF screen (Curr Locn/Task Type filters +
    // a task list) has NO trailer concept of its own - live-confirmed via
    // debug-sheet capture 2026-08-15, correcting the original plan's
    // assumption that an existing "Trailer"-labeled field could be found and
    // augmented. So this is a wholly new, purely client-side field (same
    // idea as the Split IBLPN camera button below - not tied to any real RF
    // field or submission), shown first on screen per the spec ("first we
    // should display Trailer Nbr"). Submitting it fires the lgfapi
    // load/order lookup directly - it never calls widget.onSubmit/sendInput,
    // since there's no corresponding server-side field to submit to.
    //
    // 2026-08-15 follow-up: per the reference UX (competitor's "Flexi
    // Client" - trailer field + info only, no Curr Locn/Task Type/task
    // list), the standard fields on THIS specific screen are now hidden
    // rather than shown alongside the trailer lookup - see the skip logic
    // below. This is visual only: the underlying RF session is untouched
    // and still sitting on this screen waiting for Curr Locn/Task Type, so
    // there is deliberately no way to proceed past it through this UI yet -
    // that's tomorrow's "finish the full" follow-up (an actual "Execute
    // Tasks In Progress" action, matching the reference screenshot).
    //
    // BUG FIX 2026-08-15: transactionName alone isn't enough to scope this -
    // it's only set when a mainmenu item is tapped, but ctrl_key Actions
    // (e.g. "Restrict Company", reachable from the Actions menu on ANY
    // screen) navigate to a completely different real screen WITHOUT
    // resetting it. Live-confirmed: after visiting Execute Wooden Pallet
    // Tasks then opening Actions > Restrict Company mid-transaction, this
    // screen's real content (a company picker) was being hidden too,
    // because transactionName was still "Execute Wooden Pallet Tasks" from
    // the earlier mainmenu tap. Now also requires THIS response's own
    // content to actually look like the known Tasks screen (its "Tasks:"
    // heading) - Restrict Company and any other ctrl_key detour has no such
    // heading, so real content there renders normally again.
    final looksLikeWoodenPalletTasksScreen = fields.any((f) =>
        f['type'] == 'label' &&
        (f['value'] ?? '').toString().trim().toLowerCase() == 'tasks:');
    final onWoodenPalletScreen =
        AppConfig.currentFlags.woodenPalletTaskEnabled &&
            widget.transactionName
                .toLowerCase()
                .contains(AppConfig.wpEnhPageTitleMatch) &&
            looksLikeWoodenPalletTasksScreen;

    // 2026-08-15 correction: once a task is submitted, this feature stops
    // building its own screens and starts driving the REAL RF session -
    // see plan quirky-shimmying-haven.md. These three booleans scope small
    // injections onto Oracle's own real screens/fields from here on,
    // exactly like Truck Temp's enhInsertBeforeLabel pattern - no "Tasks:"
    // heading requirement (unlike onWoodenPalletScreen above), since these
    // real screens naturally don't have one.
    final onWoodenPalletTransaction =
        AppConfig.currentFlags.woodenPalletTaskEnabled &&
            widget.transactionName
                .toLowerCase()
                .contains(AppConfig.wpEnhPageTitleMatch);
    // Matched by tag, not label - live-confirmed 2026-08-15 the real
    // field's label is blank (see AppConfig.wpEnhOblpnFieldTag's doc
    // comment).
    final onWoodenPalletOblpnScreen =
        onWoodenPalletTransaction && currentTag == AppConfig.wpEnhOblpnFieldTag;
    final currentLabelLower = (currentLabel ?? '').toLowerCase();
    final onWoodenPalletSkuField = onWoodenPalletTransaction &&
        currentLabelLower.contains(AppConfig.wpEnhSkuLabelMatch);
    final onWoodenPalletQtyScreen = onWoodenPalletTransaction &&
        currentLabelLower.contains(AppConfig.wpEnhQtyLabelMatch);
    // SKU and Qty are two separate real current fields submitted one after
    // the other on the same screen shape (2026-08-15) - both draw from the
    // same allocation, so this covers either one being current right now.
    WoodenPalletAllocation? wpCurrentAllocation;
    if (onWoodenPalletSkuField || onWoodenPalletQtyScreen) {
      for (final a
          in widget.wpAllocations ?? const <WoodenPalletAllocation>[]) {
        if (a.taskNbr == widget.wpSubmittedTaskNbr) {
          wpCurrentAllocation = a;
          break;
        }
      }
    }
    // 2026-08-15 correction: no more client-generated OBLPN - live-
    // confirmed Oracle's own real readonly "OBLPN:" display field already
    // holds the one genuinely valid OBLPN for this task (our earlier
    // separately-generated number was rejected as "Invalid OBLPN" once
    // submitted for real). Read it directly off this response's own
    // content and use it to pre-fill the real editable scan field below.
    String? wpOblpnDisplayValue;
    if (onWoodenPalletOblpnScreen) {
      for (final f in fields) {
        if (f['type'] == 'entry' &&
            (f['tag'] ?? '') == AppConfig.wpEnhOblpnDisplayFieldTag) {
          wpOblpnDisplayValue = (f['value'] ?? '').toString();
          break;
        }
      }
    }

    // Broader, transaction-name-only match for the downstream real
    // screens (OBLPN scan, SKU/Qty, Drop Location) - mirrors
    // onWoodenPalletTransaction.
    final onMixAreaTransaction = AppConfig.currentFlags.mixAreaTaskEnabled &&
        widget.transactionName
            .toLowerCase()
            .contains(AppConfig.maEnhPageTitleMatch);
    final onMixAreaOblpnScreen =
        onMixAreaTransaction && currentTag == AppConfig.maEnhOblpnFieldTag;
    final onMixAreaSkuField = onMixAreaTransaction &&
        currentLabelLower.contains(AppConfig.maEnhSkuLabelMatch);
    final onMixAreaQtyScreen = onMixAreaTransaction &&
        currentLabelLower.contains(AppConfig.maEnhQtyLabelMatch);
    // Live-confirmed 2026-10-07 (OBLPN prefill blank on a second visit to
    // the exact same task) - _ScreenView has no `key:` (see its call site),
    // so this State and its *FieldSyncedFor guards outlive any single real
    // screen, persisting for the WHOLE app session. Revisiting this same
    // task later (e.g. Previous Screen, then tapping the same task again)
    // re-sends the identical real OBLPN value, which the guard then treats
    // as "already synced" and skips - even though the text field itself is
    // actually blank again by then (a fresh _ctrls entry/cleared text).
    // Clearing the guard the moment this screen is no longer current forces
    // a genuine re-sync on the next visit, however many times that repeats.
    if (!onMixAreaOblpnScreen) _maOblpnFieldSyncedFor = null;
    if (!onMixAreaQtyScreen) _maQtyFieldSyncedFor = null;
    WoodenPalletAllocation? maCurrentAllocation;
    if (onMixAreaSkuField || onMixAreaQtyScreen) {
      for (final a
          in widget.maAllocations ?? const <WoodenPalletAllocation>[]) {
        if (a.taskNbr == widget.maSubmittedTaskNbr) {
          maCurrentAllocation = a;
          break;
        }
      }
    }
    String? maOblpnDisplayValue;
    if (onMixAreaOblpnScreen) {
      for (final f in fields) {
        if (f['type'] == 'entry' &&
            (f['tag'] ?? '') == AppConfig.maEnhOblpnDisplayFieldTag) {
          maOblpnDisplayValue = (f['value'] ?? '').toString();
          break;
        }
      }
    }

    // Full Pallet Task (2026-08-22) - see plan quirky-shimmying-haven.md.
    // onFullPalletTasksScreen itself is computed earlier (see above, before
    // the autofocus guard) - just the downstream-screen booleans live here.
    // Broader, transaction-name-only match for every downstream real
    // screen in this transaction (questionnaire, TMP/TFP/task list) -
    // mirrors onWoodenPalletTransaction/onMixAreaTransaction.
    final onFullPalletTransaction =
        AppConfig.currentFlags.fullPalletTaskEnabled &&
            widget.transactionName
                .toLowerCase()
                .contains(AppConfig.fpEnhPageTitleMatch);
    final fpCtrlKeyLabels = ((widget.content['ctrl_keys'] as List?) ?? const [])
        .map((k) => ((k as Map)['value'] ?? '').toString().toLowerCase())
        .toList();
    // Vehicle questionnaire screen (step 2) - matched by its own real
    // ctrl_keys (Approve AND Reject both present) - unverified against a
    // live capture, see AppConfig.fpEnhApproveCtrlKeyMatch's doc comment.
    final onFullPalletQuestionnaireScreen = onFullPalletTransaction &&
        fpCtrlKeyLabels
            .any((l) => l.contains(AppConfig.fpEnhApproveCtrlKeyMatch)) &&
        fpCtrlKeyLabels
            .any((l) => l.contains(AppConfig.fpEnhRejectCtrlKeyMatch));
    // SKU/Pallet/Pick/LPN screen (step 4) - entirely client-driven, gated
    // on fpSkuGroups being populated rather than any real page_content
    // shape (confirmed by the user this step isn't tied to a real field).
    // Excludes onFullPalletTasksScreen (2026-08-22 correction) - live-
    // confirmed pressing the top-left Back arrow returns to the real
    // Tasks: screen (which fpSkuGroups doesn't get cleared for, since
    // there's no other real signal that we've left the SKU step), so this
    // stale client block kept showing underneath the task table again;
    // excluding it here is a robust, no-state-reset fix since landing back
    // on the Tasks: screen is itself a reliable signal we're not on the
    // SKU step any more.
    // Includes fpSkuLoading/fpSkuError, not just fpSkuGroups.isNotEmpty
    // (2026-10-06 fix) - the real OBLPN screen was flashing visibly for the
    // duration of the fetchSkuGroups() network call: _lookupFullPalletSkus
    // submits the real task nbr (which makes Oracle respond with its OBLPN
    // screen and triggers a rebuild) before fpSkuGroups is ever populated,
    // so the old groups-only condition stayed false - and the real screen
    // stayed visible - for that whole gap. Loading/error now count as "on
    // this step" too, so the real screen is hidden from the moment the
    // operator commits to this step, not just once the fetch succeeds.
    final onFullPalletSkuScreen = onFullPalletTransaction &&
        (widget.fpSkuGroups.isNotEmpty ||
            widget.fpSkuLoading ||
            widget.fpSkuError != null) &&
        !onFullPalletTasksScreen;

    // Reorders (does NOT hide) this screen's real content: task buttons
    // are pulled out to render separately as a Wrap (see maTaskButtons
    // below), the "Tasks:" heading is dropped (matches the reference's
    // replacement-by-Trailer-field), and Curr Locn/Task Type move to the
    // END instead of their natural position near the top - per spec
    // point (a). Every OTHER screen type (including every other Mix Area
    // screen downstream) iterates `fields` completely unchanged.
    var loopFields = fields;
    List<Map<String, dynamic>> maTaskButtonFields = const [];
    if (onMixAreaTasksScreen) {
      maTaskButtonFields = fields.where((f) => f['type'] == 'button').toList();
      final deferred = fields.where((f) {
        if (f['type'] != 'entry') return false;
        final l = _labelOf(f).toLowerCase();
        return l.contains(AppConfig.maEnhCurrLocnLabelMatch) ||
            l.contains(AppConfig.maEnhTaskTypeLabelMatch);
      }).toList();
      final everythingElse = fields.where((f) {
        if (f['type'] == 'button') return false;
        if (f['type'] == 'label' &&
            (f['value'] ?? '').toString().trim().toLowerCase() == 'tasks:') {
          return false;
        }
        if (f['type'] == 'entry') {
          final l = _labelOf(f).toLowerCase();
          if (l.contains(AppConfig.maEnhCurrLocnLabelMatch) ||
              l.contains(AppConfig.maEnhTaskTypeLabelMatch)) {
            return false;
          }
        }
        return true;
      }).toList();
      loopFields = [...everythingElse, ...deferred];
    }

    final widgets = <Widget>[];
    if (onWoodenPalletScreen) {
      widgets.add(_woodenPalletTrailerField());
      // The last two purely custom, client-only steps (2026-08-15): the
      // order table (from the trailer lookup above), then - once an order
      // is tapped - the task table for it. Gated on wpSelectedOrderNbr,
      // which doubles as "has this step been reached". Submitting a task
      // from here (see _woodenPalletActionButtons' Submit button) moves to
      // the REAL RF session - see onWoodenPalletOblpnScreen etc. below.
      if (widget.wpSelectedOrderNbr == null) {
        widgets.add(_injectedWoodenPalletOrdersBlock());
      } else {
        widgets.add(_injectedWoodenPalletTaskDetailsBlock());
      }
    }
    // INJECTION: Full Pallet Task screen 1 (2026-08-22, corrected after the
    // second live test) - Trailer field, same shape as
    // _woodenPalletTrailerField (own controller/method - see plan
    // quirky-shimmying-haven.md's modularity note). Submitting it is a
    // purely client-side lgfapi lookup (see
    // _RuntimeScreenState._lookupFullPalletTrailer) - once it resolves,
    // shows a client-built Trailer/TMP/TFP/Customer Name + task list,
    // mirroring Wooden Pallet Task's own order/task tables. Only picking a
    // task and pressing Submit touches the real RF session.
    if (onFullPalletTasksScreen) {
      widgets.add(_fullPalletTrailerField());
      if (widget.fpLoading) {
        widgets.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Looking up trailer...'),
          ]),
        ));
      } else if (widget.fpError != null) {
        widgets.add(Card(
          color: const Color(0xFFFFEBEE),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.fpError!,
                style: const TextStyle(color: Colors.red)),
          ),
        ));
      } else if (widget.fpTrailerNbr != null) {
        widgets.add(_injectedFullPalletTaskDetailsBlock());
      }
    }
    // INJECTION: Full Pallet Task vehicle questionnaire (step 2) - the 9
    // real questions render normally via the generic label branch further
    // below; this only adds the Approve/Reject/Exit Screen buttons in the
    // mockup's stacked full-width style (distinct from Mix Area's small
    // Wrap row further below).
    if (onFullPalletQuestionnaireScreen) {
      widgets.add(_fullPalletQuestionnaireButtons());
    }
    // INJECTION: Full Pallet Task SKU/Pallet/Pick/LPN screen (step 4) -
    // entirely client-built, appended additively (never suppresses
    // whatever real content Oracle sends next - see onFullPalletSkuScreen's
    // doc comment above).
    if (onFullPalletSkuScreen) {
      widgets.add(_fullPalletSkuBlock());
    }
    // INJECTION: Customer Name on top of the real SKU/Qty screen - that
    // screen's own real content has no customer info at all (unlike the
    // OBLPN-scan screen just before it, which already shows a real
    // Destination field) - per spec. Shows regardless of which of SKU/Qty
    // is current right now, since both are the same screen shape.
    if (onWoodenPalletSkuField || onWoodenPalletQtyScreen) {
      String destination = '';
      for (final o in widget.wpOrders) {
        if (o.orderNbr == widget.wpSelectedOrderNbr) {
          destination = o.custName;
          break;
        }
      }
      widgets.add(_wpReadOnlyField('Customer Name', destination));
    }
    // INJECTION: Mix Area Task's Trailer field + real task buttons
    // (2026-08-21) - unlike Wooden Pallet Task, nothing is hidden here:
    // the real task buttons stay live, just moved into a Wrap ("side by
    // side, not a list") and filtered to widget.maAllocations' task
    // numbers once a trailer's been entered (null maTrailerNbr = show
    // every real task unfiltered, per spec "first we will display all
    // the tasks"). Curr Locn/Task Type render further down, deferred to
    // the end of loopFields above - same real fields, just reordered.
    if (onMixAreaTasksScreen) {
      widgets.add(_mixAreaTrailerField());
      if (widget.maLoading) {
        widgets.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Looking up trailer...'),
          ]),
        ));
      } else if (widget.maError != null) {
        widgets.add(Card(
          color: const Color(0xFFFFEBEE),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.maError!,
                style: const TextStyle(color: Colors.red)),
          ),
        ));
      }
      final allowedTaskNbrs = widget.maTrailerNbr != null
          ? (widget.maAllocations ?? const <WoodenPalletAllocation>[])
              .map((a) => a.taskNbr)
              .toSet()
          : null; // null = no trailer scanned yet, show every real task
      final visibleButtons = maTaskButtonFields.where((f) {
        if (allowedTaskNbrs == null) return true;
        final name = ((f['value'] ?? {}) as Map)['name']?.toString() ?? '';
        return allowedTaskNbrs.contains(name);
      }).toList();
      if (visibleButtons.isEmpty && allowedTaskNbrs != null) {
        widgets.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('No tasks found for this trailer.'),
        ));
      } else {
        widgets.add(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: visibleButtons.map((f) {
            final v = (f['value'] ?? {}) as Map;
            final idx = (v['index'] ?? '').toString();
            final name = (v['name'] ?? '').toString();
            return OutlinedButton(
              onPressed: () => widget.onSubmit(name, idx, null),
              child: Text('$idx) $name'),
            );
          }).toList(),
        ));
      }
    }
    for (final f in loopFields) {
      final type = f['type'] as String?;
      // Hides ALL of this screen's own real content (the "Tasks:" heading,
      // Curr Locn/Task Type, the numbered task-list buttons, AND the
      // server's own currently-focused entry field, which turned out to
      // render with a blank label - live-confirmed 2026-08-15, an earlier
      // narrower label-match filter missed it). Per the reference UX
      // (competitor's "Flexi Client" - trailer field only, nothing else),
      // this screen shows nothing from the server at all while the flag is
      // on. See the doc comment above on why this is still visual-only.
      // onFullPalletTasksScreen (2026-08-22 correction, second live test)
      // shares this same hide - reverted back to Wooden Pallet Task's
      // pattern per the user's explicit instruction, after confirming the
      // real content shouldn't be interacted with directly here either -
      // see this screen's doc comment further up. onFullPalletSkuScreen
      // (2026-08-22, third live test) hides too - live-confirmed the real
      // screen underneath the client-built SKU table has its own real
      // "OBLPN:" field (same default-prefilled shape as Wooden Pallet
      // Task's own OBLPN screen), which the user explicitly said should
      // never be shown - "we don't need to display any OBLPN by default".
      if (onWoodenPalletScreen ||
          onFullPalletTasksScreen ||
          onFullPalletSkuScreen) {
        continue;
      }
      // Note: for onMixAreaTasksScreen, loopFields (built above) already
      // excludes type=='button' items entirely - they were rendered
      // separately as a Wrap - so the button branch just below is never
      // reached on that screen; only "everythingElse" + deferred Curr
      // Locn/Task Type entries iterate here, in that order.
      if (type == 'label') {
        final text = (f['value'] ?? '').toString().trim();
        if (text.isNotEmpty) {
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child:
                Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
          ));
        }
        continue;
      }
      if (type == 'button') {
        final v = (f['value'] ?? {}) as Map;
        final idx = (v['index'] ?? '').toString();
        final name = (v['name'] ?? '').toString();
        widgets.add(Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(idx)),
            title: Text(name),
            onTap: () => widget.onSubmit(name, idx, null),
          ),
        ));
        continue;
      }

      // entry
      final label = _labelOf(f);
      final isCurrent = label == currentLabel;
      // BUG FIX 2026-08-15 - live-confirmed crash: `readonly` is normally a
      // bool, but the real "Pack NC Active Empties" screen's Order Nbr
      // field sends it as a non-bool truthy STRING instead (the task nbr,
      // apparently a server-side templating quirk) - `as bool` on that
      // throws mid-build(), which rendered as a blank screen. Treat
      // anything other than a literal `false` as readonly, matching what
      // that field is visibly meant to be (grayed, non-editable).
      final serverReadonly = (f['readonly'] ?? false) != false;
      _ctrls.putIfAbsent(label,
          () => TextEditingController(text: (f['value'] ?? '').toString()));
      _focusNodes.putIfAbsent(label, () => FocusNode());
      // A non-current field just reflects whatever the server most recently
      // reported for it (e.g. auto-populated Shipment/Shpmt Type) - only
      // resync fields the user isn't actively typing into. The one
      // exception: a field that just became current in THIS exact response
      // still needs its text synced once - fixed 2026-07-09, a field the
      // server auto-populates in the very same response that also hands it
      // focus (e.g. Shipment after submitting Dock) was previously left
      // showing its old (empty) text forever, since "it's current" was
      // wrongly treated the same as "the user is actively editing it".
      //
      // BUG FIX 2026-08-22 - live-confirmed on the standard Load
      // Confirmation screen: its "OBLPN/Pallet:" field stays the CURRENT
      // field across repeated scans (submit -> server accepts, count goes
      // up, but the SAME field remains current for the next scan) - the
      // two conditions above never covered this ("current" the whole time,
      // never "just became" current, so the stale just-scanned text was
      // left showing forever even though the server had already moved on
      // and reset this field for the next entry). A field genuinely
      // remaining current with the SERVER's own value now different from
      // what it last reported is a real new-response signal, distinct from
      // "the operator is still mid-typing something new" (which never
      // changes the server's own value at all) - track the last value the
      // SERVER itself reported per label (not what the controller
      // currently shows) so this case can be told apart and safely synced
      // too, without breaking the original mid-typing protection.
      final rawServerValue = (f['value'] ?? '').toString();
      final isNewServerValue = _lastServerFieldValue[label] != rawServerValue;
      _lastServerFieldValue[label] = rawServerValue;
      // Load Confirmation's "OBLPN/Pallet" (2026-09-26, explicit request):
      // DISPLAY always forced blank, but change-detection above still uses
      // Oracle's own RAW value (which genuinely differs scan to scan, since
      // each scan is a different OBLPN) - that's what lets isNewServerValue
      // correctly fire on every scan. Forcing serverValue itself to '' here
      // would make every scan look identical ('' -> '') to the check above,
      // so this field would stop resyncing at all after the first time and
      // the original bug would come right back.
      final isOblpnPalletField =
          label.trim().toLowerCase().startsWith('oblpn/pallet');
      final serverValue = isOblpnPalletField ? '' : rawServerValue;
      final justBecameCurrent = isCurrent && label != previousCurrentLabel;
      if (!isCurrent || justBecameCurrent || isNewServerValue) {
        if (_ctrls[label]!.text != serverValue)
          _ctrls[label]!.text = serverValue;
      }

      // INJECTION: Wooden Pallet Task, real readonly "OBLPN:" display field
      // (2026-08-15) - live-confirmed it shows Oracle's own separately-
      // reserved suggestion, which doesn't match our generated number and
      // INJECTION: Wooden Pallet Task, real OBLPN-scan screen (2026-08-15
      // correction) - pre-fill the REAL scan field with the value already
      // shown in the real readonly "OBLPN:" display field just above it
      // (wpOblpnDisplayValue, read straight off this response - see
      // build()'s doc comment on why this replaced a client-side generate
      // call). Still editable - the operator can override it.
      if (onWoodenPalletOblpnScreen &&
          isCurrent &&
          wpOblpnDisplayValue != null &&
          wpOblpnDisplayValue != _wpOblpnFieldSyncedFor) {
        _ctrls[label]!.text = wpOblpnDisplayValue;
        _wpOblpnFieldSyncedFor = wpOblpnDisplayValue;
      }

      // INJECTION: Wooden Pallet Task, real SKU field (2026-08-15) -
      // pre-fill with the selected task's item code (still editable),
      // cursor at the end - live feedback: this was missed initially, only
      // Qty was being pre-filled.
      if (onWoodenPalletSkuField &&
          isCurrent &&
          wpCurrentAllocation != null &&
          wpCurrentAllocation.itemCode != _wpSkuFieldSyncedFor) {
        _ctrls[label]!.text = wpCurrentAllocation.itemCode;
        _ctrls[label]!.selection =
            TextSelection.collapsed(offset: _ctrls[label]!.text.length);
        _wpSkuFieldSyncedFor = wpCurrentAllocation.itemCode;
      }

      // INJECTION: Wooden Pallet Task, real Qty field (2026-08-15
      // correction) - pre-fill with the selected task's alloc_qty (still
      // editable), cursor at the end once actually current, per spec.
      // Live feedback: this only fired once Qty was already the CURRENT
      // field, but on the preceding SKU-current screen Qty hasn't been
      // reached by the server at all yet (still blank) - matched here by
      // label on every field in the loop instead, so it shows proactively
      // the same way the real readonly "Qty to Pick:" field already does.
      // Excludes "Qty to Pick" itself, whose label also contains "qty".
      final isQtyField =
          label.toLowerCase().contains(AppConfig.wpEnhQtyLabelMatch) &&
              !label.toLowerCase().contains('to pick');
      if ((onWoodenPalletSkuField || onWoodenPalletQtyScreen) &&
          isQtyField &&
          wpCurrentAllocation != null) {
        // alloc_qty comes back from the allocation lookup as "1.0" - live-
        // confirmed 2026-08-15 that submitting that decimal form fails
        // real validation ("Entered qty is greater than ordered qty, over
        // pack not allowed"), unlike the real "Qty to Pick:" field (from
        // Oracle itself), which already shows the whole-number "1".
        // Stripped to match - only whole numbers are reformatted, a
        // genuinely fractional alloc_qty is left as-is.
        final qtyValue = _wpFormatQty(wpCurrentAllocation.allocQty);
        if (!isCurrent) {
          // Not yet reached/editable - reassert every build, since the
          // generic resync just above unconditionally overwrites
          // non-current fields back to the server's own (blank) value
          // every single build; safe to override unconditionally since
          // it's not editable yet either way.
          _ctrls[label]!.text = qtyValue;
        } else if (qtyValue != _wpQtyFieldSyncedFor) {
          // Now genuinely current/editable - sync once, then leave further
          // operator edits alone.
          _ctrls[label]!.text = qtyValue;
          _wpQtyFieldSyncedFor = qtyValue;
        }
        if (isCurrent && justBecameCurrent) {
          _ctrls[label]!.selection =
              TextSelection.collapsed(offset: _ctrls[label]!.text.length);
        }
      }

      // INJECTION: Wooden Pallet Task, real Drop Location screen
      // (2026-08-15 correction) - pre-fill with the literal "DROP", per
      // spec ("system won't display any location in value field, we need
      // to display DROP as value by default"). Editable - the spec only
      // asked for a default, not read-only.
      if (onWoodenPalletTransaction &&
          isCurrent &&
          !_wpDropLocationFieldSynced &&
          label.toLowerCase().contains(AppConfig.wpEnhDropLocationLabelMatch)) {
        _ctrls[label]!.text = 'DROP';
        _wpDropLocationFieldSynced = true;
      }

      // INJECTION: Mix Area Task, real OBLPN-scan field (2026-08-21) -
      // same pattern as Wooden Pallet Task's, see its own doc comment
      // above. maEnhOblpnFieldTag is unverified against a live capture of
      // THIS screen - correct it if this never fires.
      if (onMixAreaOblpnScreen &&
          isCurrent &&
          maOblpnDisplayValue != null &&
          maOblpnDisplayValue != _maOblpnFieldSyncedFor) {
        _ctrls[label]!.text = maOblpnDisplayValue;
        _maOblpnFieldSyncedFor = maOblpnDisplayValue;
      }

      // INJECTION: Mix Area Task, real Qty field (2026-08-21) - same
      // proactive-display + one-time-sync + cursor-at-end pattern as
      // Wooden Pallet Task's Qty field, and the same ".0" stripping fix.
      // No separate SKU-field prefill yet - the spec only calls out Qty
      // explicitly for this screen; add one if live testing shows a
      // separate real "SKU:" field the way Wooden Pallet Task had.
      final isMaQtyField =
          label.toLowerCase().contains(AppConfig.maEnhQtyLabelMatch) &&
              !label.toLowerCase().contains('to pick');
      if (onMixAreaQtyScreen && isMaQtyField && maCurrentAllocation != null) {
        final qtyValue = _wpFormatQty(maCurrentAllocation.allocQty);
        if (!isCurrent) {
          _ctrls[label]!.text = qtyValue;
        } else if (qtyValue != _maQtyFieldSyncedFor) {
          _ctrls[label]!.text = qtyValue;
          _maQtyFieldSyncedFor = qtyValue;
        }
        if (isCurrent && justBecameCurrent) {
          _ctrls[label]!.selection =
              TextSelection.collapsed(offset: _ctrls[label]!.text.length);
        }
      }

      // INJECTION: Truck Temp before the LPN field - only on the one
      // transaction this enhancement is scoped to
      // (AppConfig.truckTempPageTitleMatch), not every screen that happens
      // to have an "lpn"-labeled field. Built for one customer specifically
      // - also gated behind AppConfig.currentFlags.truckTempEnabled
      // (2026-07-25), off by default, same as POD above.
      final onTruckTempScreen = AppConfig.currentFlags.truckTempEnabled &&
          AppConfig.truckTempPageTitleMatch.isNotEmpty &&
          widget.transactionName
              .toLowerCase()
              .contains(AppConfig.truckTempPageTitleMatch.toLowerCase());
      if (onTruckTempScreen &&
          label.toLowerCase().contains(AppConfig.enhInsertBeforeLabel)) {
        // If this shipment already has a value on file, show it read-only
        // rather than an empty editable box - the operator shouldn't be
        // asked to re-enter (and shouldn't be able to overwrite) a value
        // that's already recorded.
        if (widget.truckTempLocked && widget.truckTempPrefill != null) {
          if (_truckTemp.text != widget.truckTempPrefill) {
            _truckTemp.text = widget.truckTempPrefill!;
          }
        }
        widgets.add(_injectedTruckTempField());
      }

      // INJECTION: photo capture, right before the "Move to LPN" field.
      // Matched on the field's `tag` ("to-lpn"), not label text - see
      // AppConfig.camInsertBeforeTag's doc comment for why (the visible
      // "Move to LPN:" caption and the actual input box are two separate
      // page_content items on this screen; the entry itself has no label of
      // its own). The camera button is always tappable here regardless of
      // which field is currently focused - capturing a photo isn't an edit
      // to any particular field.
      final isMoveToLpnField =
          (f['tag'] ?? '').toString() == AppConfig.camInsertBeforeTag;
      if (isMoveToLpnField) {
        widgets.add(_capturePhotoRow());
      }

      // INJECTION: Pick And Allocate serial-driven enhancement (2026-09-08)
      // - the Serial Nbr scan field + details table, between the item
      // description and the real OBLPN field (matched by tag `oblpn-nbr`).
      if (onPaOrderScreen &&
          (f['tag'] ?? '').toString() == AppConfig.paEnhInjectBeforeTag) {
        widgets.add(_paSerialBlock());
      }

      // Pre-fill the standard Locn / IBLPN / Qty / Serial fields on the
      // screens that follow, from the serial lookup. One-shot per lookup
      // (keyed by paLookup.key) so operator edits aren't clobbered on
      // rebuild, and only once the field is the current/editable one. The
      // operator still presses Enter on each, per spec.
      if (onPickAllocatePage && widget.paLookup != null && isCurrent) {
        final tag = (f['tag'] ?? '').toString();
        final lk = widget.paLookup!;
        String? fill;
        if (tag == AppConfig.paEnhLocnBarcodeTag) {
          fill = lk.locnBarcode;
        } else if (tag == AppConfig.paEnhIblpnTag) {
          fill = lk.iblpn;
        } else if (tag == AppConfig.paEnhQtyTag) {
          fill = '1';
        } else if (tag == AppConfig.paEnhSerialTag) {
          fill = lk.serialNbr;
        }
        if (fill != null && fill.isNotEmpty && _paPrefilledFor[tag] != lk.key) {
          _ctrls[label]!.text = fill;
          _ctrls[label]!.selection =
              TextSelection.collapsed(offset: fill.length);
          _paPrefilledFor[tag] = lk.key;
        }
      }

      void submitCurrent() {
        final injectsTruckTemp = onTruckTempScreen &&
            !widget.truckTempLocked &&
            label.toLowerCase().contains(AppConfig.enhInsertBeforeLabel) &&
            _truckTemp.text.isNotEmpty;
        // The photo is persisted right when Move to LPN itself is submitted
        // - capturing can happen anytime beforehand, but the file write is
        // keyed off the LPN value being entered here.
        if (isMoveToLpnField && _capturedPhoto != null) {
          _persistCapturedPhoto(_ctrls[label]?.text ?? '');
        }
        // Wooden Pallet Task's real OBLPN field (2026-08-15) - blank label,
        // so matched by tag/onWoodenPalletOblpnScreen (both already
        // computed above) rather than inside onSubmit below.
        if (onWoodenPalletOblpnScreen && isCurrent) {
          widget.onWoodenPalletOblpnFieldSubmit(_ctrls[label]?.text ?? '');
        }
        // Mix Area Task's real OBLPN field (2026-08-21) - same reasoning.
        if (onMixAreaOblpnScreen && isCurrent) {
          widget.onMixAreaOblpnFieldSubmit(_ctrls[label]?.text ?? '');
        }
        final submittedValue = _ctrls[label]?.text ?? '';
        widget.onSubmit(
            label, submittedValue, injectsTruckTemp ? _truckTemp.text : null);
        // Load Confirmation's "OBLPN/Pallet" field: always blank right after
        // submitting, every scan (2026-09-26, explicit request). This field
        // stays the CURRENT field across repeated scans (see the 2026-08-22
        // fix above) and Oracle's own response keeps echoing the
        // just-submitted OBLPN back as that field's value rather than
        // resetting it - so from the operator's side it always looked like
        // "the previous one is still showing". Cleared HERE, at the moment
        // of submission, rather than from render-cycle sync logic - certain
        // and immediate, and can't risk erasing an operator's in-progress
        // typing on some unrelated rebuild the way a generic per-build
        // override would. Label match is case/whitespace-tolerant since the
        // exact raw string Oracle sends (with/without a trailing colon)
        // wasn't confirmed against a live capture.
        if (label.trim().toLowerCase().startsWith('oblpn/pallet')) {
          _ctrls[label]!.text = '';
        }
      }

      // Auto-submit the real SKU field right after it's pre-filled
      // (2026-08-15, live feedback) - the operator shouldn't need to
      // manually confirm a value already known correct from the same
      // allocation lookup that seeded Qty; advances straight to the real
      // Qty field becoming current instead of requiring an extra tap.
      // `justBecameCurrent` is a one-shot signal (same guarantee the
      // autofocus-request callback above already relies on), so this
      // can't double-fire on an unrelated rebuild of the same response.
      if (onWoodenPalletSkuField &&
          isCurrent &&
          justBecameCurrent &&
          wpCurrentAllocation != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) submitCurrent();
        });
      }

      // TAB is only a bare "skip, no value" request server-side. If the
      // operator actually typed something, pressing TAB must not discard it
      // silently - submit it instead (which auto-advances on its own, per
      // the live-confirmed behavior); only send a genuine bare TAB when the
      // field is intentionally left empty. Fixed 2026-07-09 - previously
      // TAB always sent bare, so a typed value with no explicit Submit tap
      // vanished the moment focus moved on and this field resynced to the
      // server's (still-empty) value.
      void tabOrSubmit() {
        if ((_ctrls[label]?.text ?? '').isNotEmpty) {
          submitCurrent();
        } else {
          widget.onTab();
        }
      }

      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: TextField(
              controller: _ctrls[label],
              focusNode: _focusNodes[label],
              readOnly: !isCurrent || serverReadonly,
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
                filled: !isCurrent,
                fillColor: !isCurrent ? const Color(0x11000000) : null,
              ),
              onSubmitted: isCurrent ? (_) => submitCurrent() : null,
            ),
          ),
          const SizedBox(width: 4),
          // Scan/date-pick only make sense on the field the operator can
          // actually type into right now - hidden on read-only/non-current
          // fields, same gating as the Submit button below.
          if (isCurrent && !serverReadonly) ...[
            if (_looksLikeDateField(label))
              IconButton(
                icon: const Icon(Icons.calendar_month),
                tooltip: 'Pick date',
                onPressed: () => _pickDate(context, _ctrls[label]!),
              ),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan barcode',
              onPressed: () async {
                final scanned = await _scanBarcode(context);
                if (scanned != null) _ctrls[label]!.text = scanned;
              },
            ),
          ],
          IconButton(
            icon: const Icon(Icons.keyboard_tab),
            tooltip: 'TAB - submit if filled, otherwise skip this field',
            onPressed: isCurrent ? tabOrSubmit : null,
          ),
          if (isCurrent && !serverReadonly)
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              tooltip: 'Submit this field',
              onPressed: submitCurrent,
            ),
        ]),
      ));
    }

    // INJECTION: Mix Area Task's ctrl_key button row (2026-08-21) - "at
    // the bottom, display all the Action keys as buttons" per spec point
    // (a), scoped to just this first/tasks screen (the shared "Actions"
    // menu already covers every screen, including the downstream ones,
    // so this is additive, not a replacement).
    if (onMixAreaTasksScreen) {
      final ctrlKeys = (widget.content['ctrl_keys'] as List?) ?? const [];
      if (ctrlKeys.isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ctrlKeys.map((k) {
              final m = (k as Map).cast<String, dynamic>();
              final rawKey = (m['key'] ?? '').toString();
              final label = ((m['value'] ?? '') as String)
                  .replaceFirst(RegExp(r'^.*?:\s*'), '');
              return OutlinedButton(
                onPressed: () => widget.onCtrlKeyPressed(rawKey),
                child: Text(label),
              );
            }).toList(),
          ),
        ));
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: widgets),
    );
  }

  Widget _injectedTruckTempField() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _truckTemp,
            readOnly: widget.truckTempLocked,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: AppConfig.enhFieldLabel,
              border: const OutlineInputBorder(),
              filled: widget.truckTempLocked,
              fillColor:
                  widget.truckTempLocked ? const Color(0x11000000) : null,
              enabledBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.blue, width: 2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              widget.truckTempLocked
                  ? 'Already recorded for this shipment \u2022 read-only'
                  : 'Your field \u2022 saved to shipment via lgfapi',
              style: const TextStyle(color: Colors.blue, fontSize: 11),
            ),
          ),
        ]),
      );

  /// Pick And Allocate serial-driven enhancement (2026-09-08) - the
  /// injected Serial Nbr scan field plus, once a serial is looked up, a
  /// details table (Serial Nbr / Item / Location / Location Barcode /
  /// IBLPN / Batch Nbr / Lock Code). Rendered between the item description
  /// and the real OBLPN field. Submitting fires the lgfapi lookup directly
  /// (widget.onPaSerialSubmit) - it is not a real RF field.
  Widget _paSerialBlock() {
    void submit() {
      final v = _paSerial.text.trim();
      if (v.isNotEmpty) widget.onPaSerialSubmit(v);
    }

    final lk = widget.paLookup;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _paSerial,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: AppConfig.paEnhFieldLabel,
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.blue, width: 2)),
              ),
              onSubmitted: (_) => submit(),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan barcode',
            onPressed: () async {
              final scanned = await _scanBarcode(context);
              if (scanned != null) {
                _paSerial.text = scanned;
                submit();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_tab),
            tooltip: 'Look up this serial',
            onPressed: submit,
          ),
        ]),
        if (widget.paLookupLoading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Looking up serial...'),
            ]),
          )
        else if (widget.paLookupError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(widget.paLookupError!,
                style: const TextStyle(color: Colors.red)),
          )
        else if (lk != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 34,
                dataRowMinHeight: 38,
                dataRowMaxHeight: 46,
                columnSpacing: 18,
                columns: const [
                  DataColumn(label: Text('Serial Nbr')),
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Location')),
                  DataColumn(label: Text('Location Barcode')),
                  DataColumn(label: Text('IBLPN')),
                  DataColumn(label: Text('Batch Nbr')),
                  DataColumn(label: Text('Lock Code')),
                ],
                rows: [
                  DataRow(cells: [
                    DataCell(Text(lk.serialNbr)),
                    DataCell(Text(lk.item)),
                    DataCell(Text(lk.locnStr)),
                    DataCell(Text(lk.locnBarcode)),
                    DataCell(Text(lk.iblpn)),
                    DataCell(Text(lk.batchNbr)),
                    DataCell(
                        Text(lk.lockCode.isEmpty ? '\u2014' : lk.lockCode)),
                  ]),
                ],
              ),
            ),
          ),
      ]),
    );
  }

  /// Purely client-side Trailer Nbr entry, shown first on the Wooden Pallet
  /// Task screen (see build()'s doc comment on why this isn't tied to any
  /// real page_content field). Submitting fires the lgfapi lookup directly;
  /// the field stays editable afterward so the operator can look up a
  /// different trailer without leaving/re-entering the screen.
  Widget _woodenPalletTrailerField() {
    void submit() {
      final value = _wpTrailer.text.trim();
      if (value.isNotEmpty) widget.onWoodenPalletTrailerSubmit(value);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: TextField(
            controller: _wpTrailer,
            decoration: const InputDecoration(
              labelText: 'Trailer Nbr',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => submit(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: 'Scan barcode',
          onPressed: () async {
            final scanned = await _scanBarcode(context);
            if (scanned != null) {
              _wpTrailer.text = scanned;
              submit();
            }
          },
        ),
        IconButton(
          // Icon changed from check_circle_outline to keyboard_tab
          // (2026-08-22) per the Full Pallet Task spec's explicit request
          // to match this field's submit icon "like in all other
          // screens/fields... for Execute Wooden Pallet Tasks (new) as
          // well" - purely cosmetic, submit() behavior is unchanged.
          icon: const Icon(Icons.keyboard_tab),
          tooltip: 'Look up load/order for this trailer',
          onPressed: submit,
        ),
      ]),
    );
  }

  /// Mix Area Task's Trailer field (2026-08-21) - same shape as
  /// _woodenPalletTrailerField, kept as its own method/controller rather
  /// than shared (see the plan's modularity note). Submitting filters the
  /// already-visible real task buttons in place, rather than fetching a
  /// separate custom list.
  Widget _mixAreaTrailerField() {
    void submit() {
      final value = _maTrailer.text.trim();
      if (value.isNotEmpty) widget.onMixAreaTrailerSubmit(value);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: TextField(
            controller: _maTrailer,
            // Explicit autofocus (2026-08-21, live focus-stealing fix) -
            // this screen keeps the real blank current field visible
            // (unlike Wooden Pallet Task, which hides it), so grabbing
            // focus here isn't left to chance against that field's own
            // auto-focus request (now suppressed on this screen in
            // build(), but belt-and-suspenders).
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Trailer Nbr',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => submit(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: 'Scan barcode',
          onPressed: () async {
            final scanned = await _scanBarcode(context);
            if (scanned != null) {
              _maTrailer.text = scanned;
              submit();
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.check_circle_outline),
          tooltip: 'Filter tasks to this trailer',
          onPressed: submit,
        ),
      ]),
    );
  }

  /// Full Pallet Task's Trailer field (2026-08-22) - same shape as
  /// _woodenPalletTrailerField/_mixAreaTrailerField, kept as its own
  /// method/controller for the same modularity reason. Unlike those two,
  /// submitting this ALSO advances the real RF session (see
  /// _RuntimeScreenState._lookupFullPalletTrailer's doc comment), so there
  /// is no separate client-built table below it here.
  Widget _fullPalletTrailerField() {
    void submit() {
      final value = _fpTrailer.text.trim();
      if (value.isNotEmpty) widget.onFullPalletTrailerSubmit(value);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: TextField(
            controller: _fpTrailer,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Trailer Nbr',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => submit(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: 'Scan barcode',
          onPressed: () async {
            final scanned = await _scanBarcode(context);
            if (scanned != null) {
              _fpTrailer.text = scanned;
              submit();
            }
          },
        ),
        IconButton(
          // keyboard_tab, matching Wooden Pallet Task's own icon change
          // above - see that field's doc comment for why.
          icon: const Icon(Icons.keyboard_tab),
          tooltip: 'Look up load/order for this trailer',
          onPressed: submit,
        ),
      ]),
    );
  }

  /// Client-built Trailer/TMP/TFP/Customer Name + task list (step 1,
  /// 2026-08-22) - shown once the trailer lookup resolves, mirroring
  /// Wooden Pallet Task's own _injectedWoodenPalletTaskDetailsBlock
  /// (single-task-selection + Submit, same "exactly one checked" gating).
  /// Submitting sends the picked task nbr into the real RF session for
  /// real (onFullPalletTaskSubmit) - everything before this point in this
  /// screen's flow is purely client-side lgfapi lookups.
  Widget _injectedFullPalletTaskDetailsBlock() {
    final rows = <Widget>[
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Trailer')),
            DataColumn(label: Text('TMP')),
            DataColumn(label: Text('TFP')),
            DataColumn(label: Text('Customer Name')),
          ],
          rows: [
            DataRow(cells: [
              DataCell(Text(widget.fpTrailerNbr ?? '')),
              DataCell(Text((widget.fpTmp ?? 0).toString())),
              DataCell(Text((widget.fpTfp ?? 0).toString())),
              DataCell(Text(widget.fpCustomerName)),
            ]),
          ],
        ),
      ),
    ];
    if (widget.fpTasks.isEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text('No open tasks found for this trailer.'),
      ));
    } else {
      rows.add(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Task Nbr')),
            DataColumn(label: Text('Type')),
            DataColumn(label: Text('Location')),
          ],
          rows: widget.fpTasks
              .map((t) => DataRow(
                    selected: _fpSelectedTaskNbr == t.taskNbr,
                    onSelectChanged: (selected) => setState(() {
                      _fpSelectedTaskNbr =
                          (selected ?? false) ? t.taskNbr : null;
                    }),
                    cells: [
                      DataCell(Text(t.taskNbr)),
                      DataCell(Text(t.taskType)),
                      DataCell(Text(t.locnStr)),
                    ],
                  ))
              .toList(),
        ),
      ));
    }
    // Full Pallet Task / Mix Pallet Task (2026-10-08 correction) - gated by
    // the SELECTED task's own type now, not just "is something selected" -
    // fpTasks can hold both TFP and TMP tasks together (see
    // FullPalletTaskService.fetchTasks' doc comment), so picking a TMP
    // task must only enable Mix Pallet Task, and a TFP task must only
    // enable Full Pallet Task, never both at once.
    final selectedTaskType = widget.fpTasks
        .where((t) => t.taskNbr == _fpSelectedTaskNbr)
        .map((t) => t.taskType);
    final selectedType =
        selectedTaskType.isEmpty ? null : selectedTaskType.first;
    rows.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            onPressed: widget.onFullPalletBack, child: const Text('Back')),
        ElevatedButton(
          onPressed: selectedType == 'TFP'
              ? () => widget.onFullPalletFullPalletTask(_fpSelectedTaskNbr!)
              : null,
          child: const Text('Full Pallet Task'),
        ),
        ElevatedButton(
          onPressed: selectedType == 'TMP'
              ? () => widget.onFullPalletMixPalletTask(_fpSelectedTaskNbr!)
              : null,
          child: const Text('Mix Pallet Task'),
        ),
      ]),
    ));
    return Column(children: rows);
  }

  /// Vehicle questionnaire's Approve/Reject/Exit Screen buttons (step 2,
  /// 2026-08-22) - stacked full-width per the reference mockup (distinct
  /// from Mix Area Task's small Wrap-of-buttons row further below), built
  /// from this response's own real ctrl_keys rather than hardcoded keys,
  /// same label-stripping regex the Actions menu already uses. Reject
  /// routes through onFullPalletReject (fires the email relay first);
  /// every other key (Approve, Exit Screen) just uses the generic
  /// onCtrlKeyPressed.
  Widget _fullPalletQuestionnaireButtons() {
    final ctrlKeys = (widget.content['ctrl_keys'] as List?) ?? const [];
    final buttons = <Widget>[];
    for (final k in ctrlKeys) {
      final m = (k as Map).cast<String, dynamic>();
      final rawKey = (m['key'] ?? '').toString();
      final rawValue = (m['value'] ?? '').toString();
      final label = rawValue.replaceFirst(RegExp(r'^.*?:\s*'), '');
      final lower = rawValue.toLowerCase();
      final isReject = lower.contains(AppConfig.fpEnhRejectCtrlKeyMatch);
      final isApprove = lower.contains(AppConfig.fpEnhApproveCtrlKeyMatch);
      buttons.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: isReject
                ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700)
                : isApprove
                    ? null
                    : FilledButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        foregroundColor:
                            Theme.of(context).colorScheme.onSurface),
            onPressed: () => isReject
                ? widget.onFullPalletReject(rawKey)
                : widget.onCtrlKeyPressed(rawKey),
            child: Text(label),
          ),
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: buttons),
    );
  }

  /// SKU/Pallet/Pick/LPN screen (step 4, 2026-08-22) - entirely
  /// client-built, driven by widget.fpSkuGroups (see
  /// FullPalletTaskService.fetchSkuGroups). "Pallet" = each group's
  /// distinct container count; "Pick" = normal picks plus any substitute
  /// picks resolved to that group so far this transaction
  /// (widget.fpPickedCountFor).
  Widget _fullPalletSkuBlock() {
    final rows = <Widget>[];
    // Split fpSkuGroups at render time (2026-10-07) - a line that reaches
    // full completion mid-session updates its Pick count purely through
    // local tracking (widget.fpPickedCountFor), not a re-fetch of
    // fpSkuGroups itself, so without this split it would stay stuck in
    // the interactive top table showing Pick == Pallet instead of moving
    // down into the read-only Completed section where the user expects it
    // to land, same as a line that was already complete on screen entry.
    final pendingGroups = widget.fpSkuGroups
        .where((g) => widget.fpPickedCountFor(g) < g.containerNbrs.length)
        .toList();
    final justCompletedGroups = widget.fpSkuGroups
        .where((g) => widget.fpPickedCountFor(g) >= g.containerNbrs.length)
        .toList();
    // Clear a now-stale selection (2026-10-07) - if the selected group just
    // moved out of pendingGroups (its last pallet got picked), it no
    // longer has a row to show the selection on, so the LPN field should
    // revert to prompting for a fresh selection rather than silently
    // keeping a reference to a group that's no longer interactive. A
    // direct field assignment (no setState) is enough: this runs during
    // build, before the LPN field section below reads _fpSelectedSku in
    // this same pass.
    if (_fpSelectedSku != null &&
        !pendingGroups.any((g) => identical(g, _fpSelectedSku))) {
      _fpSelectedSku = null;
    }
    if (widget.fpSkuLoading) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Looking up SKU details...'),
        ]),
      ));
    } else if (widget.fpSkuError != null) {
      rows.add(Card(
        color: const Color(0xFFFFEBEE),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(widget.fpSkuError!,
              style: const TextStyle(color: Colors.red)),
        ),
      ));
    } else if (widget.fpSkuGroups.isEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text('No full-pallet SKUs found for this order.'),
      ));
    } else if (pendingGroups.isNotEmpty) {
      rows.add(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('SKU')),
            DataColumn(label: Text('Product Name')),
            DataColumn(label: Text('Exp Date')),
            DataColumn(label: Text('Pallet')),
            DataColumn(label: Text('Pick')),
            DataColumn(label: Text('StQty')),
            DataColumn(label: Text('Location')),
          ],
          // Checkbox column (2026-08-22, per the mockup; removed and
          // restored the same day, 2026-10-06 - see _scanFullPalletLpn's
          // doc comment) - "first user selects the line and scans the
          // respective LPN nbr," now actually enforced against the scan
          // instead of just tracked for display. Single select, tracked by
          // object identity (FullPalletSkuGroup instances are stable
          // within one fetch, only replaced wholesale on a fresh lookup).
          rows: pendingGroups.map((g) {
            final picked = widget.fpPickedCountFor(g);
            return DataRow(
              selected: identical(_fpSelectedSku, g),
              onSelectChanged: (selected) => setState(() {
                _fpSelectedSku = (selected ?? false) ? g : null;
              }),
              cells: [
                DataCell(Text(g.sku)),
                DataCell(Text(g.productName)),
                DataCell(Text(g.expDate)),
                DataCell(Text(g.containerNbrs.length.toString())),
                DataCell(Text(picked.toString())),
                DataCell(Text(g.stdQty)),
                DataCell(Text(g.location)),
              ],
            );
          }).toList(),
        ),
      ));
    }
    // Already-completed lines (2026-10-07) - read-only, no checkbox/
    // selection, Pick always shows the full count. Combines two sources:
    // lines that were already complete on screen entry
    // (fpCompletedSkuGroups, from fetchCompletedSkuGroups) and lines that
    // just reached completion this session (justCompletedGroups, computed
    // above) - without the latter, a line picked to completion mid-session
    // would stay stuck in the interactive table above instead of moving
    // down here. Shown only once there's something to show - a task with
    // nothing yet completed shouldn't display an empty "Completed" table.
    final completedGroups = [
      ...widget.fpCompletedSkuGroups,
      ...justCompletedGroups,
    ];
    if (completedGroups.isNotEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 4),
        child: Text('Completed',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
      ));
      rows.add(Opacity(
        opacity: 0.6,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('SKU')),
              DataColumn(label: Text('Product Name')),
              DataColumn(label: Text('Exp Date')),
              DataColumn(label: Text('Pallet')),
              DataColumn(label: Text('Pick')),
              DataColumn(label: Text('StQty')),
              DataColumn(label: Text('Location')),
            ],
            rows: completedGroups.map((g) {
              final count = g.containerNbrs.length.toString();
              return DataRow(cells: [
                DataCell(Text(g.sku)),
                DataCell(Text(g.productName)),
                DataCell(Text(g.expDate)),
                DataCell(Text(count)),
                DataCell(Text(count)),
                DataCell(Text(g.stdQty)),
                DataCell(Text(g.location)),
              ]);
            }).toList(),
          ),
        ),
      ));
    }
    // LPN scan (2026-08-22 correction, selection requirement restored
    // 2026-10-06) - no default/prefilled OBLPN shown (the real screen's
    // own OBLPN field is hidden entirely - see onFullPalletSkuScreen's
    // hide in the main loop above); the operator checks a SKU line first,
    // then scans/enters its LPN here. Tab icon added alongside scan,
    // matching the Trailer field's own icon - both just trigger the same
    // submit as pressing Enter.
    void submitLpn(String value) {
      final group = _fpSelectedSku;
      if (value.trim().isEmpty || group == null) return;
      widget.onFullPalletLpnScan(value.trim(), group);
      _fpLpn.clear();
    }

    rows.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: TextField(
            controller: _fpLpn,
            decoration: InputDecoration(
              labelText: 'LPN',
              border: const OutlineInputBorder(),
              helperText: _fpSelectedSku == null
                  ? 'Select a SKU line above first'
                  : null,
            ),
            onSubmitted: submitLpn,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          tooltip: 'Scan barcode',
          onPressed: () async {
            final scanned = await _scanBarcode(context);
            if (scanned != null) submitLpn(scanned);
          },
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_tab),
          tooltip: 'Submit',
          onPressed: () => submitLpn(_fpLpn.text),
        ),
      ]),
    ));
    return Column(children: rows);
  }

  /// Order list step (2026-08-15) - a single table (Trailer/Load
  /// Nbr/Shipment Nbr/Customer Name and Number/Order Nbr, one row per
  /// order), matching the reference "Flexi Client" screenshot rather than
  /// the earlier separate header-card-plus-list-tiles layout. The
  /// checkbox column doubles as the "button or checkbox" selector from the
  /// spec - checking a row fires the allocation lookup for it immediately.
  Widget _injectedWoodenPalletOrdersBlock() {
    if (widget.wpLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Looking up load/order...'),
        ]),
      );
    }
    // No lookup attempted yet this transaction (Trailer not yet submitted).
    if (widget.wpTrailerNbr == null) return const SizedBox.shrink();
    if (widget.wpError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Card(
          color: const Color(0xFFFFEBEE),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.wpError!,
                style: const TextStyle(color: Colors.red)),
          ),
        ),
      );
    }
    final load = widget.wpLoad;
    if (load == null) {
      return Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('No load found for trailer ${widget.wpTrailerNbr}.'),
            ),
          ),
        ),
        _woodenPalletActionButtons(),
      ]);
    }
    return Column(children: [
      if (widget.wpOrders.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('No orders found for load ${load.loadNbr}.'),
        )
      else
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Trailer')),
              DataColumn(label: Text('Load Nbr')),
              DataColumn(label: Text('Shipment Nbr')),
              DataColumn(label: Text('Customer Name and Number')),
              DataColumn(label: Text('Order Nbr')),
            ],
            rows: widget.wpOrders
                .map((o) => DataRow(
                      selected: widget.wpSelectedOrderNbr == o.orderNbr,
                      onSelectChanged: (_) =>
                          widget.onWoodenPalletOrderTap(o.orderNbr),
                      cells: [
                        DataCell(Text(widget.wpTrailerNbr ?? '')),
                        DataCell(Text(load.loadNbr)),
                        DataCell(Text(load.externallyPlannedLoadNbr)),
                        DataCell(Text('${o.custName} / ${o.custPhoneNbr}')),
                        DataCell(Text(o.orderNbr)),
                      ],
                    ))
                .toList(),
          ),
        ),
      _woodenPalletActionButtons(),
    ]);
  }

  /// Task-details step: one order's in-progress/open tasks (2026-08-15,
  /// "finish the full"), shown once that order's card is tapped above.
  Widget _injectedWoodenPalletTaskDetailsBlock() {
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('Tasks for Order ${widget.wpSelectedOrderNbr}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ];
    if (widget.wpAllocationsLoading) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Looking up tasks...'),
        ]),
      ));
    } else if (widget.wpAllocationsError != null) {
      rows.add(Card(
        color: const Color(0xFFFFEBEE),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(widget.wpAllocationsError!,
              style: const TextStyle(color: Colors.red)),
        ),
      ));
    } else {
      final allocations = widget.wpAllocations ?? const [];
      if (allocations.isEmpty) {
        rows.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('No tasks in progress for this order.'),
        ));
      } else {
        rows.add(SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Task Nbr')),
              DataColumn(label: Text('Location')),
            ],
            rows: allocations
                .map((a) => DataRow(
                      selected: _wpSelectedTaskNbrs.contains(a.taskNbr),
                      onSelectChanged: (selected) => setState(() {
                        if (selected ?? false) {
                          _wpSelectedTaskNbrs.add(a.taskNbr);
                        } else {
                          _wpSelectedTaskNbrs.remove(a.taskNbr);
                        }
                      }),
                      cells: [
                        DataCell(Text(a.taskNbr)),
                        DataCell(Text(a.locnStr)),
                      ],
                    ))
                .toList(),
          ),
        ));
      }
    }
    // Submit -> OBLPN details (2026-08-15) - only enabled with exactly one
    // task checked, since that step's display is singular (one Task Nbr).
    // Continue (real TAB, sent to the still-idle underlying RF session) was
    // dropped 2026-08-15 - live-confirmed it errors, since nothing in this
    // whole feature has ever actually submitted to that session; Submit is
    // the one real way to proceed.
    rows.add(_woodenPalletActionButtons(trailing: [
      ElevatedButton(
        onPressed: _wpSelectedTaskNbrs.length == 1
            ? () => widget.onWoodenPalletTaskSubmit(_wpSelectedTaskNbrs.first)
            : null,
        child: const Text('Submit'),
      ),
    ]));
    return Column(children: rows);
  }

  /// A field-styled but non-editable display (2026-08-15) - left-aligned,
  /// boxed the same as the real editable fields elsewhere in this renderer
  /// (matches the standard reference screenshot's OBLPN/OBLPN Type/Locn/SKU/
  /// Qty to Pick styling). InputDecorator rather than a readOnly TextField
  /// + throwaway controller, since the value here is fixed per build - no
  /// real editable state to hold.
  Widget _wpReadOnlyField(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            filled: true,
            fillColor: const Color(0x11000000),
          ),
          child: Text(value),
        ),
      );

  /// Strips a trailing ".0" (2026-08-15, live-confirmed fix) - alloc_qty
  /// comes back from the allocation lookup as e.g. "1.0", which the real
  /// Qty field's own validation rejected ("Entered qty is greater than
  /// ordered qty, over pack not allowed"). Only whole numbers are
  /// reformatted; a genuinely fractional value (e.g. "1.5") is returned
  /// unchanged, and anything unparseable is returned as-is.
  String _wpFormatQty(String raw) {
    final n = double.tryParse(raw);
    if (n == null) return raw;
    return n == n.roundToDouble() ? n.toInt().toString() : raw;
  }

  /// Back (Previous Screen) / Tasks in Progress (Ctrl-P) - sent directly to
  /// the still-live real RF session behind this screen (2026-08-15). Back
  /// was originally wired to ctrl_key "X", but that's Exit App on this
  /// screen and logged the operator straight out - corrected to reuse the
  /// same previousScreenKey action the app's own top-left back arrow sends.
  /// [trailing] appends step-specific buttons after these two - e.g. the
  /// task-details step's Submit. A real TAB "Continue" button used to sit
  /// here too, but was dropped 2026-08-15 (live-confirmed it errors - see
  /// _injectedWoodenPalletTaskDetailsBlock's doc comment).
  Widget _woodenPalletActionButtons({List<Widget> trailing = const []}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: widget.onWoodenPalletBack, child: const Text('Back')),
          OutlinedButton(
              onPressed: widget.onWoodenPalletTasksInProgress,
              child: const Text('Tasks in Progress')),
          ...trailing,
        ]),
      );

  Widget _capturePhotoRow() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            OutlinedButton.icon(
              onPressed: _capturePhoto,
              icon: const Icon(Icons.camera_alt),
              label: Text(
                  _capturedPhoto == null ? 'Capture Photo' : 'Retake Photo'),
            ),
            const SizedBox(width: 8),
            if (_capturedPhoto != null)
              const Icon(Icons.check_circle, color: Colors.green),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
                'Your field \u2022 saved locally when Move to LPN is submitted',
                style: TextStyle(color: Colors.blue, fontSize: 11)),
          ),
        ]),
      );
}
