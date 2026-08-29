import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/protocol/connection_params.dart';

void main() {
  group('scheme enforcement', () {
    test('https URL parses', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1'),
        isNotNull,
      );
    });

    test('wss URL parses', () {
      expect(
        ZemoteConnectionParams.parse(
            'wss://zcode.z.ai/remote/v4?sid=s&hash=h&t=1'),
        isNotNull,
      );
    });

    test('http URL is rejected (cleartext downgrade)', () {
      expect(
        ZemoteConnectionParams.parse(
            'http://zcode.z.ai/remote/v4?sid=s&hash=h&t=1'),
        isNull,
      );
    });

    test('localhost http URL is rejected', () {
      expect(
        ZemoteConnectionParams.parse(
            'http://localhost:3000/remote/v4?sid=s&hash=h&t=1'),
        isNull,
      );
    });

    test('ws URL is rejected', () {
      expect(
        ZemoteConnectionParams.parse('ws://zcode.z.ai/ws?sid=s&hash=h&t=1'),
        isNull,
      );
    });

    test('non-http scheme is rejected', () {
      expect(
        ZemoteConnectionParams.parse(
            'ftp://bad.example.com/remote/v4?sid=s&hash=h&t=1'),
        isNull,
      );
      expect(
        ZemoteConnectionParams.parse('file:///etc/passwd?sid=s&hash=h&t=1'),
        isNull,
      );
    });

    test('scheme check is case-insensitive', () {
      expect(
        ZemoteConnectionParams.parse(
            'HTTPS://zcode.z.ai/remote/v4?sid=s&hash=h&t=1'),
        isNotNull,
      );
    });
  });

  group('isOfficialHost', () {
    test('official host', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.isOfficialHost, isTrue);
    });

    test('other host', () {
      final params = ZemoteConnectionParams.parse(
        'https://evil.example.com/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.isOfficialHost, isFalse);
    });
  });

  group('relayWsUri', () {
    test('https → wss', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws?mid=m');
    });

    test('wss source stays wss', () {
      final params = ZemoteConnectionParams.parse(
        'wss://relay.example.com/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://relay.example.com/ws');
    });

    test('port is preserved', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai:8443/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai:8443/ws');
    });

    test('no mid → no query params', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws');
    });
  });

  group('parse edge cases', () {
    test('missing sid returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?hash=h&t=1'),
        isNull,
      );
    });

    test('missing hash returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&t=1'),
        isNull,
      );
    });

    test('missing t returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h'),
        isNull,
      );
    });

    test('invalid timestamp returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=abc'),
        isNull,
      );
    });

    test('trimmed query values', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid= SID &hash= HASH &t=1',
      );
      expect(params, isNotNull);
      expect(params!.deviceSid, 'SID');
      expect(params.passHash, 'HASH');
    });

    test('empty optional fields are null', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=&name=',
      );
      expect(params!.deviceMid, isNull);
      expect(params.deviceName, isNull);
    });

    test('theme is parsed', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&theme=dark',
      );
      expect(params!.theme, 'dark');
    });
  });
}
