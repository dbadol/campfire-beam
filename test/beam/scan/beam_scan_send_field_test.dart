/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM Send's recipient field reads scanned and pasted text by the scan
// rules (scan_recognize.dart): a beam: link fills address and amount, a
// name goes in as "name.beam", and an Ethereum address or a link of another
// coin or the web is named in plain words, never looked up as a BEAM name.
// Runs the real form over send_ui_support.dart's scripted backend.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';
import 'package:stackwallet/widgets/icon_widgets/qrcode_icon.dart';

import '../send_ui/send_ui_support.dart';

const _to = Key('beamSendRecipientField');
const _amount = Key('beamSendAmountField');
const _eth = '0x52908400098527886E0F7030069857D2E4169EE7';

String _text(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

Future<ScriptedBackend> _open(
  WidgetTester tester, {
  String? scanned,
  ClipboardInterface? clipboard,
}) async {
  await setScreen(tester, desktop: false);
  final b = ScriptedBackend();
  await pumpCampfire(
    tester,
    home: BeamSendPage(
      backend: b,
      coin: Beam(CryptoCurrencyNetwork.main),
      walletId: 'beam-test-wallet',
      walletName: 'My BEAM',
      locale: 'en_US',
      clipboard: clipboard ?? FakeClipboard(),
      minimumBuildTime: Duration.zero,
      routeOnSuccessName: '/',
      nameDebounce: const Duration(milliseconds: 50),
      onScanQr: (_) async => scanned,
    ),
    desktop: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  return b;
}

Future<void> _tapScan(WidgetTester tester) async {
  await tester.tap(find.byType(QrCodeIcon));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final address = vectorAddress('regular');

  testWidgets('a scanned beam: link fills the address and the amount', (
    tester,
  ) async {
    await _open(tester, scanned: 'beam:$address?amount=1.5\nfor lunch');
    await _tapScan(tester);
    expect(_text(tester, _to), address);
    expect(_text(tester, _amount), '1.5');
  });

  testWidgets('a scanned "Alice.BEAM" goes in as the name alice.beam', (
    tester,
  ) async {
    final b = await _open(tester, scanned: 'Alice.BEAM');
    await _tapScan(tester);
    expect(_text(tester, _to), 'alice.beam');
    await settleLookup(tester);
    expect(b.core.actions, isNotEmpty, reason: 'the name is looked up');
  });

  testWidgets('"beam:alice" still means the name alice in this field', (
    tester,
  ) async {
    await _open(tester, scanned: 'beam:alice');
    await _tapScan(tester);
    expect(_text(tester, _to), 'alice');
  });

  testWidgets('an Ethereum address says so, and is never looked up as a '
      'name', (tester) async {
    final clipboard = FakeClipboard();
    await clipboard.setData(const ClipboardData(text: _eth));
    final b = await _open(tester, clipboard: clipboard);
    await tester.tap(find.byKey(const Key('beamSendPasteRecipient')));
    await tester.pump();
    await settleLookup(tester);
    expect(_text(tester, _to), _eth);
    expect(
      find.text(
        "That's an Ethereum address. BEAM can't be sent to it: pay it from "
        'an Ethereum wallet.',
      ),
      findsOneWidget,
    );
    expect(b.core.actions, isEmpty, reason: 'no name lookup');
  });

  testWidgets('a web link typed in is named, not looked up', (tester) async {
    final b = await _open(tester);
    await tester.enterText(find.byKey(_to), 'https://example.com/pay');
    await tester.pump();
    await settleLookup(tester);
    expect(
      find.text(
        "That's a web link, not a BEAM address. Campfire doesn't open links.",
      ),
      findsOneWidget,
    );
    expect(b.core.actions, isEmpty);
  });
}
