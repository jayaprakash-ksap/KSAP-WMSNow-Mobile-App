import 'dart:io';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Sends captured photos/signatures to the local receiver
/// (tools/captured_files_receiver.py) - see that script's header comment
/// for the protocol. Deliberately separate from RwmobileService: this talks
/// to a small local dev-machine tool, not Oracle WMS, and has nothing to do
/// with the RF session/bearer token.
class UploadService {
  static const _timeout = Duration(seconds: 4);

  /// Uploads one file. Returns false (never throws) on any failure -
  /// receiver not running, wrong WiFi, timeout, etc. are all routine,
  /// expected outcomes here, not exceptional ones; the caller's job is just
  /// to leave the file queued locally when this returns false.
  static Future<bool> tryUpload(File file, UploadServerConfig config) async {
    if (!config.isConfigured) return false;
    try {
      final uri = Uri.parse('${config.baseUrl}/upload');
      final bytes = await file.readAsBytes();
      final res = await http
          .post(
            uri,
            headers: {
              'X-Filename': file.path.split(Platform.pathSeparator).last,
              'X-Auth-Token': config.token,
              'Content-Type': 'application/octet-stream',
            },
            body: bytes,
          )
          .timeout(_timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Attempts every file still queued in [folder], deleting each one
  /// locally only once its upload is confirmed. Returns how many synced.
  /// The folder itself IS the pending-upload queue - a file present there
  /// means "not yet uploaded", nothing else to track.
  static Future<int> syncPending(Directory folder, UploadServerConfig config) async {
    if (!config.isConfigured || !await folder.exists()) return 0;
    var synced = 0;
    final entries = await folder.list().toList();
    for (final entry in entries.whereType<File>()) {
      if (await tryUpload(entry, config)) {
        await entry.delete();
        synced++;
      }
    }
    return synced;
  }
}
