import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/update/update_checker.dart';

void main() {
  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('0.2.0', '0.2.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
    });

    test('newer detection', () {
      expect(compareVersions('0.3.0', '0.2.0'), greaterThan(0));
      expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareVersions('0.2.10', '0.2.9'), greaterThan(0));
    });

    test('older detection', () {
      expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
      expect(compareVersions('0.2.9', '0.2.10'), lessThan(0));
    });

    test('malformed segments treated as zero', () {
      expect(compareVersions('x.y', '0.0.0'), 0);
      expect(compareVersions('1.x', '1.0.0'), 0);
    });
  });

  group('parseChecksumHex', () {
    test('extracts digest from sha256sum output', () {
      const content =
          'a3f5b7c9d2e4f6081a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081  ZemoteS-v1.2.3-arm64.apk\n';
      expect(parseChecksumHex(content),
          'a3f5b7c9d2e4f6081a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081');
    });

    test('uppercase digests are lowercased', () {
      const content =
          'A3F5B7C9D2E4F6081A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F7081  x.apk';
      expect(parseChecksumHex(content),
          'a3f5b7c9d2e4f6081a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081');
    });

    test('returns null when no 64-hex digest present', () {
      expect(parseChecksumHex('not a checksum'), isNull);
      expect(parseChecksumHex(''), isNull);
      // 63 hex chars is not a SHA-256 digest.
      expect(parseChecksumHex('a' * 63), isNull);
    });
  });
}
