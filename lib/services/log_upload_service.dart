import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';

/// Sends session activity log files (LogService) to the Admin Build UI's
/// /upload-log route (tools/admin_build_ui/app.py) so they're browsable
/// from an admin's PC instead of only living in a local folder on
/// whatever device ran the app. Deliberately separate from RwmobileService
/// and UploadService, same reasoning as EmailRelayService: this talks to a
/// small local relay, not Oracle WMS.
class LogUploadService {
  static const _timeout = Duration(seconds: 6);

  /// Uploads one file. Returns false (never throws) on any failure -
  /// relay not running, wrong WiFi, timeout, etc. are routine here, not
  /// exceptional (same contract as UploadService.tryUpload).
  static Future<bool> tryUpload(File file, LogServerConfig config) async {
    if (!config.isConfigured) return false;
    try {
      final uri = Uri.parse('${config.baseUrl}/upload-log');
      final bytes = await file.readAsBytes();
      final res = await http
          .post(
            uri,
            headers: {
              'X-Filename': file.path.split(Platform.pathSeparator).last,
              'X-Auth-Token': config.token,
              'Content-Type': 'text/plain',
            },
            body: bytes,
          )
          .timeout(_timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Uploads every .log file in [folder]. Unlike UploadService.syncPending,
  /// local files are NEVER deleted afterward - logs are meant to keep
  /// accumulating locally too (LogsScreen's "Delete all" is a separate,
  /// explicit action), and the whole file is re-sent every time rather
  /// than tracked as "already synced" - simplest correct way to keep an
  /// in-progress (still-growing) session's file up to date on the relay,
  /// which just overwrites its own copy on each upload. Returns how many
  /// files were successfully synced this call.
  static Future<int> syncAll(Directory folder, LogServerConfig config) async {
    if (!config.isConfigured || !await folder.exists()) return 0;
    var synced = 0;
    final entries = await folder.list().toList();
    for (final entry in entries.whereType<File>()) {
      if (!entry.path.endsWith('.log')) continue;
      if (await tryUpload(entry, config)) synced++;
    }
    return synced;
  }

  /// Automatic, silent version of what LogsScreen's sync button does
  /// (2026-09-26) - previously the ONLY way any log ever reached the
  /// server was an operator manually opening Activity Logs, which most
  /// floor operators never do, so logs effectively never made it off the
  /// device. Resolves the same folder/config LogsScreen uses and syncs
  /// everything pending; a no-op (never throws) if the Log Server isn't
  /// configured on this build. Callers fire this without awaiting it -
  /// it must never add visible latency to login or logout.
  static Future<void> syncPendingInBackground() async {
    try {
      final config = await AppConfig.loadLogServer();
      if (!config.isConfigured) return;
      final docsDir = await getApplicationDocumentsDirectory();
      final folder = Directory('${docsDir.path}/${AppConfig.logFolderName}');
      await syncAll(folder, config);
    } catch (_) {
      // Best-effort only - a normal sync from LogsScreen (or the next
      // automatic trigger) will pick up anything missed here.
    }
  }
}
