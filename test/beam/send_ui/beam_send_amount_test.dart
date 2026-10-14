/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Send amount field takes, on any device and in any language: "."
// is the decimal point, a comma never is. Declaring Russian in the app's
// bundle (CFBundleLocalizations) makes iOS and macOS report the device
// locale as ru_RU, whose decimal comma used to reach this field: "0,5" was
// 0.5 and a pasted "1,000" was one BEAM. Now the field and the parser are
// the app's, not the device's. Also: a desktop Scan into an open Send tab
// starts a new payment (no old amount or comment rides along).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/l10n/l10n.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_format.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';

import 'send_ui_support.dart';

const _to = Key('beamSendRecipientField');
const _amount = Key('beamSendAmountField');
const _comment = Key('beamSendCommentField');
const _send = Key('beamSendReviewButton');

String _text(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

Future<GlobalKey<BeamSendPageState>> _open(WidgetTester tester) async {
  await setScreen(tester, desktop: false);
  final page = GlobalKey<BeamSendPageState>();
  await pumpCampfire(
    tester,
    home: BeamSendPage(
      key: page,
      backend: ScriptedBackend(),
      coin: Beam(CryptoCurrencyNetwork.main),
      walletId: 'beam-test-wallet',
      walletName: 'My BEAM',
      clipboard: FakeClipboard(),
      minimumBuildTime: Duration.zero,
      routeOnSuccessName: '/',
      nameDebounce: const Duration(milliseconds: 50),
    ),
    desktop: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  return page;
}

/// One key press: [text] is the field's text after it.
Future<void> _key(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_amount), text);
  await tester.pump();
}

void main() {
  tearDown(debugResetAppL10n);

  group('BeamSendFormat.parse: "." decimals, a comma never', () {
    const g = BigInt.from;

    test('a dot is the decimal point', () {
      expect(BeamSendFormat.parse('0.5'), g(50000000));
      expect(BeamSendFormat.parse('.5'), g(50000000));
      expect(BeamSendFormat.parse('1000.5'), g(100050000000));
      expect(BeamSendFormat.parse(' 2 '), g(200000000));
      expect(BeamSendFormat.parse('0.00000001'), g(1));
    });

    test('Russian input: "0,5" is refused, never 5; "1,000" is refused, '
        'never 1', () {
      debugSetAppL10n(lookupAppLocalizations(const Locale('ru')));
      for (final t in ['0,5', '1,000', '1,5', '1.000,5', '1,000.5', ',5']) {
        expect(BeamSendFormat.parse(t), isNull, reason: t);
      }
    });

    test('nothing else that is not an amount', () {
      for (final t in ['', '0', '1 000', '0.123456789', '-1', 'abc', '1.2.3']) {
        expect(BeamSendFormat.parse(t), isNull, reason: t);
      }
    });

    test('text put back in the field is ungrouped with a dot, in Russian '
        'too', () {
      debugSetAppL10n(lookupAppLocalizations(const Locale('ru')));
      expect(BeamSendFormat.editable(g(100050000000)), '1000.5');
      expect(BeamSendFormat.editable(g(1)), '0.00000001');
    });
  });

  testWidgets('the field: the decimal key types a dot (a Russian keypad has '
      'only a comma), a pasted "1,000" or "0,5" is refused', (tester) async {
    await _open(tester);
    // "0", then the decimal key, then "5".
    await _key(tester, '0');
    await _key(tester, '0,');
    expect(_text(tester, _amount), '0.');
    await _key(tester, '0.5');
    expect(_text(tester, _amount), '0.5');

    // Pasted into the field: kept out, the field keeps what it had.
    await _key(tester, '');
    await _key(tester, '1,000');
    expect(_text(tester, _amount), '');
    await _key(tester, '0,5');
    expect(_text(tester, _amount), '');
  });

  testWidgets('the confirm screen shows what was typed, with its dot', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(find.byKey(_to), vectorAddress('regular'));
    await tester.pump();
    await _key(tester, '0');
    await _key(tester, '0,');
    await _key(tester, '0.5');
    await tester.tap(find.byKey(_send));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('beamConfirmAmount')))
          .data,
      '0.5 BEAM',
    );
  });

  testWidgets('a desktop Scan into an open Send tab starts a new payment: '
      "the link's amount or none, and no old comment", (tester) async {
    final page = await _open(tester);
    final address = vectorAddress('regular');
    await tester.enterText(find.byKey(_to), 'someone.beam');
    await _key(tester, '3');
    await tester.enterText(find.byKey(_comment), 'old note');
    await tester.pump();

    page.currentState!.fill(address, amount: '1.5');
    await tester.pump();
    expect(_text(tester, _to), address);
    expect(_text(tester, _amount), '1.5');
    expect(_text(tester, _comment), '');
    expect(page.currentState!.model.comment, '');

    await _key(tester, '7');
    await tester.enterText(find.byKey(_comment), 'another note');
    await tester.pump();
    page.currentState!.fill(address);
    await tester.pump();
    expect(_text(tester, _amount), '', reason: 'no amount in the link');
    expect(_text(tester, _comment), '');
    expect(page.currentState!.model.amountText, '');
  });
}
