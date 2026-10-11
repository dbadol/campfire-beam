/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM wallet home's Scan with an Ethereum code, next to a REAL
// Ethereum wallet (eth_ui_harness.dart): the Ethereum wallet's own Send
// opens (a page on a phone, a dialog on desktop) with the recipient and the
// amount filled in, ready for its own review; with two Ethereum wallets the
// person picks which pays first. No network: the wallets are never synced.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/send_view/send_view.dart';
import 'package:stackwallet/pages/wallet_view/wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send.dart';
import 'package:stackwallet/networking/http.dart';
import 'package:stackwallet/providers/global/node_service_provider.dart';
import 'package:stackwallet/providers/global/price_provider.dart';
import 'package:stackwallet/services/ethereum/ethereum_api.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/widgets/beam/scan/beam_qr_reader.dart';
import 'package:stackwallet/widgets/beam/scan/beam_scan.dart';

import '../eth_ui/eth_ui_harness.dart';
import '../wiring_ui/wiring_harness.dart';

class _Reader implements BeamQrReader {
  _Reader(this.next);

  final String? next;

  @override
  Future<String?> read(BuildContext context, {required bool desktop}) async =>
      next;
}

const _to = '0x52908400098527886E0F7030069857D2E4169EE7';

/// Opening the Ethereum wallet reads and writes Isar (real time, outside
/// the test's fake clock): waits until [what] shows, or fails.
Future<void> _until(WidgetTester tester, Finder what) async {
  for (var i = 0; i < 40 && what.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester, rounds: 2);
  expect(what, findsWidgets);
}
const _link = 'ethereum:$_to@1?value=2.014e18';

/// Made-up gas prices, in the index's shape.
const _gas = {
  'success': true,
  'result': {
    'result': {
      'FastGasPrice': '3',
      'ProposeGasPrice': '2',
      'SafeGasPrice': '1',
      'suggestBaseFee': '1',
      'LastBlock': '1',
    },
  },
};

/// Scans, picks [wallet] when Campfire asks which Ethereum wallet pays (the
/// wallets of earlier tests in this file stay registered), and waits for
/// [what].
Future<void> _scanTo(
  WidgetTester tester,
  Key button,
  String wallet,
  Finder what,
) async {
  await tester.tap(find.byKey(button));
  await settle(tester, rounds: 2);
  if (find.text('Pay from which Ethereum wallet?').evaluate().isNotEmpty) {
    await tester.tap(find.text(wallet));
  }
  await _until(tester, what);
}

int get _payingEthWallets =>
    beamScanEthWallets(Wallets.sharedInstance.wallets).length;

void main() {
  final db = WiringDb();
  setUpAll(() async {
    await db.open();
    await openNodeHive();
  });
  tearDownAll(() async {
    await closeNodeHive();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget home, bool desktop) {
    // The Ethereum Send asks Campfire's index for gas prices on open.
    EthereumAPI.client = FakeEthIndex({'gas-prices': _gas});
    addTearDown(() => EthereumAPI.client = const HTTP());
    return pumpWiring(
        tester,
        home,
        desktop: desktop,
        overrides: [
          pBeamQrReader.overrideWithValue(_Reader(_link)),
          priceAnd24hChangeNotifierProvider.overrideWithValue(NoPrices()),
          nodeServiceChangeNotifierProvider.overrideWithValue(
            testNodeService(),
          ),
        ],
      );
  }

  testWidgets('phone: the Ethereum wallet\'s Send, recipient and amount '
      'filled', (tester) async {
    if (!buildHasEthereum) return;
    Util.debugIsDesktop = false;
    addTearDown(() => Util.debugIsDesktop = null);
    final beam = await openBeamWallet(tester, db);
    final eth = await openEthWallet(tester, name: 'Savings ETH');
    await pump(tester, WalletView(walletId: beam.walletId), false);

    // The first test of the file: this is the only Ethereum wallet, so its
    // Send opens straight away (the router's own tests cover the rest).
    expect(_payingEthWallets, 1);
    await tester.tap(find.byKey(const Key('beamHomeScanButton')));
    await _until(tester, find.byType(SendView));
    final send = tester.widget<SendView>(find.byType(SendView));
    expect(send.walletId, eth.walletId);
    expect(send.autoFillData!.address, _to);
    expect(send.autoFillData!.amount, Decimal.parse('2.014'));
    expect(find.text(_to), findsWidgets);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/phone_scan_to_ethereum_send.png'),
    );
    await finish(tester);
  });

  testWidgets('two Ethereum wallets: pick one, then its Send', (tester) async {
    if (!buildHasEthereum) return;
    Util.debugIsDesktop = false;
    addTearDown(() => Util.debugIsDesktop = null);
    final beam = await openBeamWallet(tester, db);
    await openEthWallet(tester, name: 'Savings ETH');
    final daily = await openEthWallet(tester, name: 'Daily ETH');
    await pump(tester, WalletView(walletId: beam.walletId), false);

    expect(_payingEthWallets, greaterThanOrEqualTo(2));
    await tester.tap(find.byKey(const Key('beamHomeScanButton')));
    await settle(tester, rounds: 2);
    expect(find.text('Pay from which Ethereum wallet?'), findsOneWidget);
    expect(find.byType(SendView), findsNothing, reason: 'asks first');
    await tester.tap(find.text('Daily ETH'));
    await _until(tester, find.byType(SendView));
    final send = tester.widget<SendView>(find.byType(SendView));
    expect(send.walletId, daily.walletId);
    expect(send.autoFillData!.address, _to);
    await finish(tester);
  });

  testWidgets('desktop: the Ethereum wallet\'s Send in a dialog, filled', (
    tester,
  ) async {
    if (!buildHasEthereum) return;
    Util.debugIsDesktop = true;
    addTearDown(() => Util.debugIsDesktop = null);
    final beam = await openBeamWallet(tester, db);
    final eth = await openEthWallet(tester, name: 'Desk ETH');
    await pump(tester, DesktopWalletView(walletId: beam.walletId), true);

    await _scanTo(
      tester,
      const Key('beamDesktopScanButton'),
      'Desk ETH',
      find.byKey(const Key('beamScanEthereumSendDialog')),
    );
    expect(find.text('Send ETH from Desk ETH'), findsOneWidget);
    final send = tester.widget<DesktopSend>(
      find.descendant(
        of: find.byKey(const Key('beamScanEthereumSendDialog')),
        matching: find.byType(DesktopSend),
      ),
    );
    expect(send.walletId, eth.walletId);
    expect(send.autoFillData!.address, _to);
    expect(send.autoFillData!.amount, Decimal.parse('2.014'));
    await finish(tester);
  });
}
