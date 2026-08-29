// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img_lib;
import 'package:flutter_test/flutter_test.dart';
import 'package:zxing2/qrcode.dart';
import 'package:zflow/ui/qr_scan_page.dart';

String? tryDecode(LuminanceSource source, DecodeHints? hints) {
  try {
    return QRCodeReader()
        .decode(BinaryBitmap(HybridBinarizer(source)), hints: hints)
        .text;
  } catch (_) {
    return null;
  }
}

void main() {
  test('decode variants on generated QR', () {
    for (final path in [
      'test/fixtures/qr/test-qr.png',
      'test/fixtures/qr/test-qr-rgb.png',
      'test/fixtures/qr/test-qr-alpha.png',
    ]) {
      final bytes = File(path).readAsBytesSync();
      final image = img_lib.decodeImage(bytes)!;
      print('$path -> ${image.width}x${image.height} format=${image.format}');
      print('  decoded: ${decodeQrFromImageBytes(Uint8List.fromList(bytes))}');
    }
  });
}
