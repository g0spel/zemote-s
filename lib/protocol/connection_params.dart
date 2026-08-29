/// Parses a ZCode web-remote connection URL, e.g.
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...
///
/// Mirrors `zC()` in the web client bundle. Only `https`/`wss` sources are
/// accepted: a cleartext source would downgrade the relay link to `ws://`,
/// exposing the whole session (including RPC traffic) to a network MITM.
class ZflowConnectionParams {
  final String deviceSid;
  final String passHash;
  final int timestamp;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final String? theme;
  final Uri source;

  const ZflowConnectionParams({
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    required this.source,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.theme,
  });

  static String? _get(Uri uri, String key) {
    final v = uri.queryParameters[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static ZflowConnectionParams? parse(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'wss') return null;
    final sid = _get(uri, 'sid');
    final hash = _get(uri, 'hash');
    final t = int.tryParse(_get(uri, 't') ?? '');
    if (sid == null || hash == null || t == null) return null;
    return ZflowConnectionParams(
      deviceSid: sid,
      passHash: hash,
      timestamp: t,
      deviceMid: _get(uri, 'mid'),
      deviceName: _get(uri, 'name'),
      appVersion: _get(uri, 'app_version'),
      theme: _get(uri, 'theme'),
      source: uri,
    );
  }

  /// Relay websocket URL. Mirrors `Jc()` / `pen.connect()`:
  /// `wss://<host>/ws` plus `?mid=` when present. Always TLS — cleartext
  /// `ws://` sessions can be read and rewritten by a network attacker.
  Uri get relayWsUri {
    final base = Uri(
      scheme: 'wss',
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }

  /// Whether the source points at the official ZCode relay host. Devices on
  /// other hosts receive every message the user sends, so the UI warns
  /// before saving them (see `device_management_page.dart`).
  bool get isOfficialHost => source.host.toLowerCase() == 'zcode.z.ai';
}
