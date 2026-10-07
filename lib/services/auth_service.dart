import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'log_service.dart';

/// Holds the OAuth session. username + envName are needed for the rwmobile
/// request envelope ({username, env_name, htmlrfid, input}).
class Session {
  String accessToken;
  String refreshToken;
  final String username;
  Session({
    required this.accessToken,
    required this.refreshToken,
    required this.username,
  });
}

class AuthService {
  Session? session;

  // Persistent client - see the same note in RwmobileService. Login is only
  // one or two calls, but refresh() can fire mid-session, and reusing the
  // connection avoids a fresh TLS handshake there too.
  final http.Client _client = http.Client();

  bool get isLoggedIn => session != null;
  String get username => session?.username ?? '';
  String get envName => AppConfig.instance;

  Future<void> login(String username, String password) async {
    final basic = base64Encode(
      utf8.encode('${AppConfig.clientId}:${AppConfig.clientSecret}'),
    );
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(AppConfig.tokenUrl),
      headers: {
        'Authorization': 'Basic $basic',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'password',
        'username': username,
        'password': password,
      },
    );
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (res.statusCode != 200) {
      LogService.log('AUTH', {
        'event': 'login',
        'username': username,
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        'ok': false,
      });
      throw Exception(_describeLoginFailure(res));
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    session = Session(
      accessToken: data['access_token'] as String,
      refreshToken: (data['refresh_token'] ?? '') as String,
      username: username,
    );
    LogService.log('AUTH', {
      'event': 'login',
      'username': username,
      'status': res.statusCode,
      'elapsed_ms': elapsedMs,
      'ok': true,
    });
  }

  /// Builds a message from whatever the token endpoint actually returned,
  /// rather than a bare status code - added 2026-07-11 after a real case
  /// where a misconfigured environment (wrong/hashed client_secret, or the
  /// instance path not reaching Oracle's OAuth layer at all) returned a raw
  /// HTML gateway error page instead of a proper OAuth JSON error, for EVERY
  /// username tried - previously this silently fell back to a generic
  /// "Login failed (403)" with no way to tell a real bad-password rejection
  /// apart from an environment/credential misconfiguration.
  String _describeLoginFailure(http.Response res) {
    final body = _safeJson(res.body);
    if (body.isNotEmpty) {
      final msg = body['error_description'] ?? body['error'];
      if (msg != null) return '$msg (HTTP ${res.statusCode})';
    }
    final htmlSummary = _extractHtmlSummary(res.body);
    if (htmlSummary != null) {
      return '$htmlSummary (HTTP ${res.statusCode}) - the server returned a '
          'generic error page instead of a proper login response. This '
          'usually means the environment\'s Client ID/Secret or instance '
          'name is misconfigured, not a wrong username/password - check '
          'those in Manage Environments.';
    }
    return 'Login failed (HTTP ${res.statusCode})';
  }

  /// Scrapes a short human-readable summary out of an HTML error page (e.g.
  /// an Apache/OHS-style "403 Forbidden" or "404 Not Found" gateway
  /// response) - combines <title> and <h1> text when both are present and
  /// differ, since Oracle's gateway pages often have a generic title
  /// ("404 Not Found") alongside a more specific <h1> ("Forbidden").
  String? _extractHtmlSummary(String html) {
    final title =
        RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true)
            .firstMatch(html);
    final h1 =
        RegExp(r'<h1[^>]*>(.*?)</h1>', caseSensitive: false, dotAll: true)
            .firstMatch(html);
    final parts = <String>[];
    final titleText = title?.group(1)?.trim();
    final h1Text = h1?.group(1)?.trim();
    if (titleText != null && titleText.isNotEmpty) parts.add(titleText);
    if (h1Text != null && h1Text.isNotEmpty && h1Text != titleText)
      parts.add(h1Text);
    if (parts.isEmpty) return null;
    return parts.join(' — ');
  }

  /// Returns true if refresh succeeded.
  Future<bool> refresh() async {
    if (session == null) return false;
    final basic = base64Encode(
      utf8.encode('${AppConfig.clientId}:${AppConfig.clientSecret}'),
    );
    final started = DateTime.now();
    final res = await _client.post(
      Uri.parse(AppConfig.tokenUrl),
      headers: {
        'Authorization': 'Basic $basic',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': session!.refreshToken,
      },
    );
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (res.statusCode != 200) {
      LogService.log('AUTH', {
        'event': 'refresh',
        'status': res.statusCode,
        'elapsed_ms': elapsedMs,
        'ok': false,
      });
      return false;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    session!.accessToken = data['access_token'] as String;
    if (data['refresh_token'] != null) {
      session!.refreshToken = data['refresh_token'] as String;
    }
    LogService.log('AUTH', {
      'event': 'refresh',
      'status': res.statusCode,
      'elapsed_ms': elapsedMs,
      'ok': true,
    });
    return true;
  }

  Map<String, dynamic> _safeJson(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
