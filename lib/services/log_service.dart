import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';

/// Per-login-session activity log - every RF protocol exchange, lgfapi/api
/// call, and key user action, written to AppConfig.logFolderName so the
/// whole history for a shift survives after the app closes (unlike
/// RwmobileService.history, which is in-memory only, capped, and feeds just
/// the debug sheet's RF-protocol view - it doesn't cover lgfapi/api calls at
/// all, a gap found while diagnosing Mix Area Task's print failure). Static,
/// matching AppConfig's own static-field idiom - one process only ever has
/// one active login session, so there's no reason to thread an instance
/// through every service/screen.
class LogService {
  static File? _file;
  static Future<void> _writeQueue = Future.value();
  static int _seq = 0;

  static final RegExp _unsafe = RegExp(r'[^A-Za-z0-9_-]+');
  static String _sanitize(String s) {
    final cleaned = s.trim().replaceAll(_unsafe, '_');
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  /// Starts a new session log file - call once per login ATTEMPT (see
  /// LoginScreen._login), before the actual login call, so a failed login
  /// is still captured (instance/username are both known pre-login; the
  /// attempt's own success/failure is logged separately by AuthService.login
  /// once it completes). Filename: instance_username_sessionid_date_time_seq
  /// per the requested naming pattern - sessionId is a base-36 microsecond
  /// timestamp (no new UUID dependency needed), seq a simple in-memory
  /// counter (starts at 1, increments per session this app run) that exists
  /// only to satisfy that naming pattern, since sessionId+date+time already
  /// make collisions practically impossible.
  static Future<void> startSession({
    required String instance,
    required String username,
  }) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final folder = Directory('${docsDir.path}/${AppConfig.logFolderName}');
    if (!await folder.exists()) await folder.create(recursive: true);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${now.year}${two(now.month)}${two(now.day)}';
    final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final sessionId = now.microsecondsSinceEpoch.toRadixString(36);
    _seq++;
    final name = '${_sanitize(instance)}_${_sanitize(username)}_'
        '${sessionId}_${date}_${time}_$_seq.log';
    _file = File('${folder.path}/$name');
    _writeQueue = Future.value();
    log('SESSION',
        {'event': 'start', 'instance': instance, 'username': username});
  }

  // Values under any of these keys (at any nesting depth) are replaced
  // before a line is ever written - matches this codebase's existing
  // secret-hygiene practice (see AuthService.login/refresh, the only
  // places these actually originate). Applied unconditionally inside log()
  // itself so every call site is protected automatically; callers never
  // need to remember to redact.
  static const _secretKeys = {
    'password',
    'client_secret',
    'client_id',
    'access_token',
    'refresh_token',
    'authorization',
  };

  static dynamic _redactValue(dynamic v) {
    if (v is Map) {
      final out = <String, dynamic>{};
      v.forEach((k, val) {
        final key = k.toString();
        out[key] = _secretKeys.contains(key.toLowerCase())
            ? '<redacted>'
            : _redactValue(val);
      });
      return out;
    }
    if (v is List) return v.map(_redactValue).toList();
    return v;
  }

  /// Appends one redacted, timestamped line. Fire-and-forget from the
  /// caller's side (never awaited at call sites, so logging can't add
  /// latency to a real network call or UI action) - internally chained
  /// through _writeQueue so concurrent calls (e.g. Mix Area Task's
  /// Future.wait per-order allocation fetches) append safely without
  /// interleaving/corrupting each other. A no-op before the first
  /// startSession() call (e.g. the pre-login screen itself).
  static void log(String category, Map<String, dynamic> details) {
    final file = _file;
    if (file == null) return;
    final redacted = _redactValue(details);
    final line =
        '${DateTime.now().toIso8601String()} | $category | ${jsonEncode(redacted)}';
    _writeQueue = _writeQueue.then((_) async {
      try {
        await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {
        // Logging must never take the app down - silently drop on failure
        // (e.g. storage full, permission revoked mid-session).
      }
    });
  }
}
