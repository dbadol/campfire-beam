/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A name's sale price as typed: commas were stripped, so a Russian "0,5"
// listed the name for 5 BEAM and "1,5" for 15. Now the Airdrop and Minter
// fields' rules: a lone comma is the decimal point, commas before a "." are
// thousands groups, and "1,000" (a thousand, or one?) is refused.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';

void main() {
  const g = BigInt.from;

  test('a comma is never dropped: "0,5" is 0.5, never 5', () {
    expect(NamesFormat.parse('0,5'), g(50000000));
    expect(NamesFormat.parse('1,5'), g(150000000));
  });

  test('"1,000" is refused, never 1 or 1000; grouped with a dot it is '
      'clear', () {
    expect(NamesFormat.parse('1,000'), isNull);
    expect(NamesFormat.parse('1,000.5'), g(100050000000));
    expect(NamesFormat.parse('1.000,5'), isNull);
  });

  test('plain amounts as before', () {
    expect(NamesFormat.parse('0.25'), g(25000000));
    expect(NamesFormat.parse('12'), g(1200000000));
    expect(NamesFormat.parse('0'), isNull);
    expect(NamesFormat.parse(''), isNull);
    expect(NamesFormat.parse('0.123456789'), isNull);
  });
}
