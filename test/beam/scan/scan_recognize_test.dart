/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What a scanned code is (lib/utilities/beam/scan_recognize.dart), against
// the cases both apps share (scan_vectors.json beside this file, also read
// by the web wallet's pwa/test/unit/scan_recognize.test.mjs), plus the
// places where Dart's own string functions would read a text differently
// from JavaScript's.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/scan_recognize.dart';

const _hex =
    '2d37efaaf8e80a576d3dabb9bb2799dfe1b40b5bd29c6436ccd729744c806a7355e';

void main() {
  group('the shared cases', () {
    final file = jsonDecode(
      File('test/beam/scan/scan_vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final vectors = (file['vectors']! as List).cast<Map<String, Object?>>();

    test('there are at least 20', () {
      expect(vectors.length, greaterThanOrEqualTo(20));
    });

    for (final v in vectors) {
      final input = v['in']! as String;
      test(jsonEncode(input), () {
        final out = (v['out']! as Map).cast<String, Object?>();
        expect(recognizeScan(input).toJson(), out);
      });
    }
  });

  group('wei', () {
    test('whole numbers only, scientific notation as EIP-681 writes it', () {
      expect(scanWeiOf('1000'), '1000');
      expect(scanWeiOf('2.014e18'), '2014000000000000000');
      expect(scanWeiOf('1.5'), isNull);
      expect(scanWeiOf('1.50e1'), '15');
      expect(scanWeiOf('0'), isNull);
      expect(scanWeiOf('-1'), isNull);
      expect(scanWeiOf(''), isNull);
      expect(scanWeiOf(null), isNull);
      // More decimals than the exponent, all zeros: still whole.
      expect(scanWeiOf('1.2000e1'), '12');
      expect(scanWeiOf('1e3'), '1000');
    });
  });

  group('beam: links', () {
    test('the amount is read as typed: spaces, a plus sign; never a comma',
        () {
      for (final (q, amount) in [
        // A comma is a thousands separator or a decimal comma, a
        // thousandfold apart: refused, never 1 or 1.25.
        ('amount=1,000', null),
        ('amount=1,25', null),
        ('amount=0,5', null),
        ('amount=1%2C000', null),
        ('amount=1,000.5', null),
        ('amount=1+000', '1000'),
        ('amount=.5', '0.5'),
        ('amount=1.00000000', '1'),
        ('tx_amount=2', '2'),
        ('amount=0', null),
        ('amount=1.123456789', null), // more than 8 decimals
        ('amount=abc', null),
        ('amount=1.2.3', null),
        ('amount=90071992.54740992', null), // over Number.MAX_SAFE_INTEGER
        ('amount=', null),
      ]) {
        final r = recognizeScan('beam:$_hex?$q');
        expect(r.kind, ScanKind.beam, reason: q);
        expect(r.address, _hex, reason: q);
        expect(r.amount, amount, reason: q);
      }
    });

    test('the first amount wins, as URLSearchParams.get', () {
      expect(recognizeScan('beam:$_hex?amount=1&amount=2').amount, '1');
      // An empty amount is there, so tx_amount is not looked at.
      expect(recognizeScan('beam:$_hex?amount=&tx_amount=3').amount, isNull);
    });

    test('escapes in the path are decoded; a broken one is kept', () {
      expect(
        recognizeScan('beam:alice%2Ebeam'),
        const ScanRecognition.name('alice'),
      );
      expect(recognizeScan('beam:alice%2beam').kind, ScanKind.unknown);
      expect(recognizeScan('beam:%E0%A4%A').kind, ScanKind.unknown);
    });
  });

  group('where Dart and JavaScript differ', () {
    test('U+0085 is not white space to JavaScript', () {
      expect(recognizeScan('\u0085alice.beam').kind, ScanKind.unknown);
      expect(recognizeScan(' alice.beam　').kind, ScanKind.name);
    });

    test('the Kelvin sign lowers to k; a dotted capital I does not to i', () {
      expect(
        recognizeScan('Kelvin.beam'),
        const ScanRecognition.name('kelvin'),
      );
      expect(recognizeScan('İce.beam').kind, ScanKind.unknown);
    });

    test('a byte order mark in an escape is kept, then dropped as space', () {
      expect(
        recognizeScan('beam:%EF%BB%BF$_hex'),
        const ScanRecognition.beam(_hex),
      );
    });
  });

  test('scanFirstLine: trimmed, first line only', () {
    expect(scanFirstLine('  abc \r\n def'), 'abc');
    expect(scanFirstLine(null), '');
  });
}
