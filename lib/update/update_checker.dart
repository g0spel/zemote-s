import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';

/// Release repository this fork checks for updates against.
const updateRepo = 'g0spel/zflow';

/// Result of an update check against the GitHub latest release.
class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;
  final String? body;
  final String? apkUrl;
  /// SHA-256 checksum file asset (published by CI next to the APK). The
  /// installer flow refuses to install without a matching checksum.
  final String? checksumUrl;
  final bool isNewer;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    this.body,
    this.apkUrl,
    this.checksumUrl,
    required this.isNewer,
  });
}

/// Queries `https://api.github.com/repos/g0spel/zflow/releases/latest`
/// and compares the release tag with [currentVersion]. The release tag is
/// `vX.Y.Z`; the CI (`build-apk.yml`) uploads `Zflow-vX.Y.Z-arm64.apk` and
/// its `.sha256` as assets.
Future<UpdateInfo> checkForUpdates({
  String currentVersion = appVersion,
}) async {
  final res = await http
      .get(Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'))
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw UpdateCheckException(
        'GitHub API ${res.statusCode}: ${res.body.isEmpty ? res.reasonPhrase : res.body}');
  }
  final data = jsonDecode(res.body);
  if (data is! Map) {
    throw const UpdateCheckException('invalid GitHub response');
  }
  final tag = '${data['tag_name'] ?? ''}';
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final releaseUrl =
      '${data['html_url'] ?? 'https://github.com/$updateRepo/releases'}';
  final body = data['body'] as String?;
  final assets = data['assets'];
  String? apkUrl;
  String? checksumUrl;
  if (assets is List) {
    for (final a in assets.whereType<Map>()) {
      final name = '${a['name'] ?? ''}';
      final url = '${a['browser_download_url'] ?? ''}';
      if (url.isEmpty) continue;
      if (name.endsWith('.apk')) {
        apkUrl ??= url;
      } else if (name.endsWith('.sha256')) {
        checksumUrl ??= url;
      }
    }
  }
  return UpdateInfo(
    latestVersion: version.isEmpty ? tag : version,
    releaseUrl: releaseUrl,
    body: body,
    apkUrl: apkUrl,
    checksumUrl: checksumUrl,
    isNewer: version.isNotEmpty &&
        compareVersions(version, currentVersion) > 0,
  );
}

class UpdateCheckException implements Exception {
  final String message;
  const UpdateCheckException(this.message);

  @override
  String toString() => 'UpdateCheckException: $message';
}

/// Extracts the hex digest from a `sha256sum` checksum file
/// (`<64 hex chars>  <apk file name>`). Returns null when no valid digest
/// is present.
String? parseChecksumHex(String content) {
  final m = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(content);
  return m?.group(0)?.toLowerCase();
}

/// Semantic version compare on the first three numeric segments
/// (`major.minor.patch`). Handles `1.2` vs `1.2.0` as equal.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final x = pa.length > i ? pa[i] : 0;
    final y = pb.length > i ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
