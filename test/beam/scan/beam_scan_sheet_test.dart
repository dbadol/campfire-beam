/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The scan sheet on its own (beam_scan.dart): one primary button at most,
// "Copy address" copies the address and not the whole link, the button
// that goes on hands back where to go, and Close hands back nothing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/scan_recognize.dart';
import 'package:stackwallet/utilities/beam/scan_route.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/widgets/beam/scan/beam_scan.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import '../send_ui/send_ui_support.dart';

const _eth = '0x52908400098527886E0F7030069857D2E4169EE7';

ScanStopped _stopped(String text, {List<ScanEthWallet> eth = const []}) =>
    scanDestination(
          recognizeScan(text),
          text: text,
          from: ScanFrom.beamSend,
          ethWallets: eth,
        )
        as ScanStopped;

/// Opens the sheet for [stopped] and returns a future of its choice.
Future<Future<BeamScanSheetChoice?>> _show(
  WidgetTester tester,
  ScanStopped stopped, {
  required bool desktop,
  ClipboardInterface? clipboard,
}) async {
  await setScreen(tester, desktop: desktop);
  late BuildContext host;
  await pumpCampfire(
    tester,
    home: Builder(
      builder: (context) {
        host = context;
        return const SizedBox(height: 10);
      },
    ),
    desktop: desktop,
  );
  final choice = showBeamScanSheet(
    host,
    stopped,
    desktop: desktop,
    walletName: (_) => 'Savings ETH',
    clipboard: clipboard ?? FakeClipboard(),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return choice;
}

int _primaries(WidgetTester tester) => find
    .descendant(
      of: find.byKey(const Key('beamScanSheet')),
      matching: find.byType(PrimaryButton),
    )
    .evaluate()
    .length;

void main() {
  for (final desktop in [false, true]) {
    final where = desktop ? 'desktop' : 'phone';

    testWidgets('$where: an Ethereum address in BEAM Send offers that '
        "wallet's Send, which the button hands back", (tester) async {
      final stopped = _stopped(
        'ethereum:$_eth?value=1e18',
        eth: const [ScanEthWallet('eth-a', 'Savings ETH')],
      );
      final choice = await _show(tester, stopped, desktop: desktop);
      expect(find.text('An Ethereum address'), findsOneWidget);
      expect(_primaries(tester), 1);
      expect(find.text('Pay from Savings ETH'), findsOneWidget);
      await tester.tap(find.byKey(const Key('beamScanSheetAction')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await choice, BeamScanSheetChoice.onward);
      expect(
        stopped.onward,
        const ScanToEthereumSend(
          'eth-a',
          _eth,
          valueWei: '1000000000000000000',
        ),
      );
    });

    testWidgets('$where: Close hands back nothing', (tester) async {
      final choice = await _show(
        tester,
        _stopped('https://example.com'),
        desktop: desktop,
      );
      expect(_primaries(tester), 1, reason: 'Close is the one button');
      expect(find.byKey(const Key('beamScanSheetCopy')), findsNothing);
      await tester.tap(find.byKey(const Key('beamScanSheetClose')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await choice, isNull);
      expect(find.byKey(const Key('beamScanSheet')), findsNothing);
    });
  }

  testWidgets('"Copy address" copies the address, not the whole link', (
    tester,
  ) async {
    final clipboard = FakeClipboard();
    final stopped = scanDestination(
      recognizeScan('ethereum:$_eth?value=1e18'),
      text: 'ethereum:$_eth?value=1e18',
    ) as ScanStopped;
    expect(stopped.reason, ScanStop.noEthereumWallet);
    await _show(tester, stopped, desktop: false, clipboard: clipboard);
    await tester.tap(find.byKey(const Key('beamScanSheetCopy')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final copied = await clipboard.getData(Clipboard.kTextPlain);
    expect(copied?.text, _eth);
  });
}
