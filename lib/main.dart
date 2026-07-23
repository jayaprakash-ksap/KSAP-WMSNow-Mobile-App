import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'config/app_config.dart';
import 'services/auth_service.dart';
import 'services/rwmobile_service.dart';

void main() => runApp(const JapraApp());

class JapraApp extends StatelessWidget {
  const JapraApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Japra WMS Mobile',
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

  @override
  void initState() {
    super.initState();
    _loadEnvironments();
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
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Manage Environments',
            onPressed: _openEnvironmentManager,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Faint warehouse-themed watermark behind the login form - built
          // from Flutter's own Material icon set (2026-07-11), not an
          // external image asset, so there's nothing to source/license.
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: const Alignment(0, -0.15),
                child: Opacity(
                  opacity: 0.06,
                  child: Icon(
                    Icons.warehouse,
                    size: 340,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Japra WMS Mobile',
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
                          .map((e) =>
                              DropdownMenuItem(value: e, child: Text(e.name)))
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
                          labelText: 'Password', border: OutlineInputBorder()),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _login,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                  ],
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
                            icon: const Icon(Icons.edit),
                            tooltip: 'Edit',
                            onPressed: () => _edit(i),
                          ),
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
      title: Text(
          widget.existing == null ? 'Add Environment' : 'Edit Environment'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. flow_test',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          // Added 2026-07-11 - domain is per-environment, not a shared app
          // constant (two environments can live on entirely different hosts,
          // e.g. tb2.wms.ocs.oraclecloud.com vs b2.wms.ocs.oraclecloud.com -
          // confirmed live). Previously this wasn't configurable at all and
          // silently used one fixed domain for every environment.
          TextField(
            controller: _domain,
            decoration: const InputDecoration(
                labelText: 'Domain',
                hintText: 'e.g. https://tb2.wms.ocs.oraclecloud.com',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instance,
            decoration: const InputDecoration(
                labelText: 'Instance (URL path segment)',
                hintText: 'e.g. flow_test',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientId,
            decoration: const InputDecoration(
                labelText: 'OAuth Client ID', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientSecret,
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
      actions: [
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
  // is currently on screen (e.g. "MARS Receive SKUs - FG") - added
  // 2026-07-10 so the Truck Temp injection (see AppConfig.enhPageTitleMatch)
  // can be scoped to one specific transaction instead of matching every
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

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
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
      while (_isYesNo(res) && attempt < _maxYesAttempts) {
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
        if (_isYesNo(res)) continue;
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
      if (_isYesNo(res)) {
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
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
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
          onSubmit: (v) {
            _memory[message.isEmpty ? 'input' : message] = v;
            _send(() => _rw.sendInput(_clientid, _htmlrfid, v));
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
      } else {
        // yesno dialogs are always auto-resolved inside _send() before
        // _page is ever set (see the comment there) - this branch is only a
        // defensive fallback for any other/unrecognized dialog_type.
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
          _currentTransactionName = name;
          // Fresh transaction - any shipment/Truck Temp state from whatever
          // was on screen before no longer applies.
          _truckTempShipmentId = null;
          _truckTempExistingValue = null;
          _truckTempLocked = false;
          _pendingTruckTemp = null;
          _send(() => _rw.sendInput(_clientid, _htmlrfid, index));
        },
      );
    } else {
      body = _ScreenView(
        content: content,
        transactionName: _currentTransactionName,
        truckTempPrefill: _truckTempExistingValue,
        truckTempLocked: _truckTempLocked,
        onSubmit: (label, value, injectedTemp) async {
          if (value.isNotEmpty) _memory[label] = value;
          // The Shipment field just being confirmed is the earliest reliable
          // point at which its value is final - look up whether this
          // shipment already has a Truck Temp recorded (see
          // _lookupTruckTemp's doc comment).
          if (value.isNotEmpty &&
              label.toLowerCase().contains(AppConfig.enhLookupLabelMatch)) {
            await _lookupTruckTemp(value);
          }
          if (injectedTemp != null && injectedTemp.isNotEmpty) {
            // Captured now, but NOT patched yet - see _pendingTruckTemp's
            // doc comment. The actual PATCH fires when End LPN is pressed.
            _pendingTruckTemp = injectedTemp;
          }
          await _send(() => _rw.sendInput(_clientid, _htmlrfid, value));
        },
        onTab: () => _send(() => _rw.sendTab(_clientid, _htmlrfid)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back (Previous Screen)',
          onPressed: () => _send(
              () => _rw.sendActionKey(_clientid, _htmlrfid, previousScreenKey)),
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
                if (key == 'X') {
                  await _sendAndLogout(
                      () => _rw.sendActionKey(_clientid, _htmlrfid, key));
                } else {
                  await _send(
                      () => _rw.sendActionKey(_clientid, _htmlrfid, key));
                }
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
                '#${reversed.length - i} • ${reversed[i].at.hour.toString().padLeft(2, '0')}:${reversed[i].at.minute.toString().padLeft(2, '0')}:${reversed[i].at.second.toString().padLeft(2, '0')}',
                style: const TextStyle(
                    color: Colors.white54,
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
      body: MobileScanner(onDetect: _onDetect),
    );
  }
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
  final void Function(String) onSubmit;
  final VoidCallback onCancel;
  const _EntryView({
    super.key,
    required this.message,
    required this.masked,
    required this.forceCaps,
    required this.maxLength,
    required this.allowCancel,
    required this.onSubmit,
    required this.onCancel,
  });
  @override
  State<_EntryView> createState() => _EntryViewState();
}

class _EntryViewState extends State<_EntryView> {
  final _c = TextEditingController();

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

    return ListView(
      padding: const EdgeInsets.all(12),
      children: buttons.map((b) {
        final v = (b['value'] ?? {}) as Map;
        final idx = (v['index'] ?? '').toString();
        final name = (v['name'] ?? '').toString();
        return Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(idx)),
            title: Text(name),
            onTap: () => onSelect(idx, name),
          ),
        );
      }).toList(),
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
  // onSubmit(focusedLabel, focusedValue, injectedTruckTemp)
  final Future<void> Function(String, String, String?) onSubmit;
  final VoidCallback onTab;
  const _ScreenView(
      {required this.content,
      required this.transactionName,
      required this.truckTempPrefill,
      required this.truckTempLocked,
      required this.onSubmit,
      required this.onTab});
  @override
  State<_ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<_ScreenView> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, FocusNode> _focusNodes = {};
  final _truckTemp = TextEditingController();
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
    if (mounted) setState(() => _capturedPhoto = null);
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
    // Captured BEFORE updating _lastCurrentLabel below, so the per-field
    // loop can tell "did this field just become current in this exact
    // response" apart from "has been current for a while already".
    final previousCurrentLabel = _lastCurrentLabel;

    if (currentLabel != null && currentLabel != _lastCurrentLabel) {
      _lastCurrentLabel = currentLabel;
      // Deferred to after this build/layout completes - requesting focus
      // synchronously during build can be dropped since the FocusNode's
      // target TextField isn't attached to the tree yet.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNodes[currentLabel]?.requestFocus();
      });
    }

    final widgets = <Widget>[];
    for (final f in fields) {
      final type = f['type'] as String?;
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
      final serverReadonly = (f['readonly'] ?? false) as bool;
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
      final justBecameCurrent = isCurrent && label != previousCurrentLabel;
      if (!isCurrent || justBecameCurrent) {
        final serverValue = (f['value'] ?? '').toString();
        if (_ctrls[label]!.text != serverValue)
          _ctrls[label]!.text = serverValue;
      }

      // INJECTION: Truck Temp before the LPN field - only on the one
      // transaction this enhancement is scoped to (AppConfig.enhPageTitleMatch),
      // not every screen that happens to have an "lpn"-labeled field.
      final onTruckTempScreen = widget.transactionName
          .toLowerCase()
          .contains(AppConfig.enhPageTitleMatch);
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
        widget.onSubmit(label, _ctrls[label]?.text ?? '',
            injectsTruckTemp ? _truckTemp.text : null);
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
