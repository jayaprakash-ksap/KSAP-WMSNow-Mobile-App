import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Sends the Trailer Eligibility Form "Reject" notification to the local
/// relay (tools/trailer_reject_email_receiver.py) - see that script's
/// header comment for the protocol. Deliberately separate from
/// RwmobileService, same reasoning as UploadService: this talks to a small
/// local dev-machine tool, not Oracle WMS, and mail credentials must never
/// live inside the distributed app (see EmailServerConfig's doc comment).
class EmailRelayService {
  static const _timeout = Duration(seconds: 6);

  /// Returns false (never throws) on any failure - relay not running,
  /// wrong WiFi, timeout, etc. are routine here, not exceptional - a
  /// failed email must never block the operator from actually rejecting
  /// the trailer in the real RF session.
  static Future<bool> sendRejectNotice({
    required EmailServerConfig config,
    required String trailer,
    required String shipment,
    required String username,
  }) async {
    if (!config.isConfigured) return false;
    try {
      final uri = Uri.parse('${config.baseUrl}/reject-email');
      final res = await http
          .post(
            uri,
            headers: {
              'X-Auth-Token': config.token,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'trailer': trailer,
              'shipment': shipment,
              'status': 'Reject',
              'timestamp': DateTime.now().toIso8601String(),
              'username': username,
            }),
          )
          .timeout(_timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
