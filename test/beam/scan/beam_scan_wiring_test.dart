/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The wallet home's Scan on Campfire's real wallet screens (WalletView on a
// 375 × 667 phone, DesktopWalletView in the 1280 × 800 window) for a REAL
// BeamWallet (wiring_harness.dart), with the camera replaced by a reader
// that returns a fixed text: each kind of code lands where it belongs, with
// what it said filled in, and nothing is ever sent. Plus BEAM Send's own
// scan button, which now knows an Ethereum address when it sees one.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/scan

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/wallet_view/wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/widgets/beam/scan/beam_qr_reader.dart';
import 'package:stackwallet/widgets/beam/scan/beam_scan.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';
import 'package:stackwallet/widgets/icon_widgets/qrcode_icon.dart';
import 'package:stackwallet/widgets/wallet_navigation_bar/components/wallet_navigation_bar_item.dart';

import '../wiring_ui/wiring_harness.dart';

/// The camera, replaced: returns [next] and records each call.
class _Reader implements BeamQrReader {
  String? next;
  final List<bool> desktopCalls = [];

  @override
  Future<String?> read(BuildContext context, {required bool desktop}) async {
    desktopCalls.add(desktop);
    return next;
  }
}

/// A regular BEAM address (public BEAM core test vector).
final String _address =
    ((jsonDecode(
                  File(
                    'test/beam/fixtures/beam_core_address_vectors.json',
                  ).readAsStringSync(),
                )
                as Map)['valid']
            as List)
        .cast<Map<String, Object?>>()
        .firstWhere((v) => v['type'] == 'regular')['address']!
    as String;

const _eth = '0x52908400098527886E0F7030069857D2E4169EE7';

String _field(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

const _to = Key('beamSendRecipientField');
const _amount = Key('beamSendAmountField');

Future<_Reader> _pump(WidgetTester tester, Widget home, bool desktop) async {
  final reader = _Reader();
  await pumpWiring(
    tester,
    home,
    desktop: desktop,
    overrides: [pBeamQrReader.overrideWithValue(reader)],
  );
  return reader;
}

Future<void> _scan(WidgetTester tester, Key button) async {
  await tester.tap(find.byKey(button));
  await settle(tester, rounds: 2);
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  group('phone', () {
    testWidgets('Scan sits in the top bar, on screen at 375 px; a beam: '
        'link opens BEAM Send with address and amount filled', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      final button = find.byKey(const Key('beamHomeScanButton'));
      expect(button, findsOneWidget);
      final r = tester.getRect(button);
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(phone.width));
      expect(r.bottom, lessThanOrEqualTo(80), reason: 'in the top bar');
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/phone_wallet_scan_button.png'),
      );

      reader.next = 'beam:$_address?amount=1.5';
      await _scan(tester, const Key('beamHomeScanButton'));
      expect(reader.desktopCalls, [false]);
      expect(find.byType(BeamSendScreen), findsOneWidget);
      expect(_field(tester, _to), _address);
      expect(_field(tester, _amount), '1.5');
      await finish(tester);
    });

    testWidgets('a web link: the sheet says it is never opened, shows the '
        'text, and Close closes it', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      reader.next = 'https://example.com/pay?to=me';
      await _scan(tester, const Key('beamHomeScanButton'));
      expect(find.byKey(const Key('beamScanSheet')), findsOneWidget);
      expect(find.text('A web link'), findsOneWidget);
      expect(find.textContaining('never opens links'), findsOneWidget);
      expect(find.text('https://example.com/pay?to=me'), findsOneWidget);
      expect(find.byKey(const Key('beamScanSheetAction')), findsNothing);
      // The whole sheet, Close included, fits the phone.
      final close = tester.getRect(
        find.byKey(const Key('beamScanSheetClose')),
      );
      expect(close.bottom, lessThanOrEqualTo(phone.height));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/phone_scan_sheet_link.png'),
      );
      await tester.tap(find.byKey(const Key('beamScanSheetClose')));
      await settle(tester, rounds: 2);
      expect(find.byKey(const Key('beamScanSheet')), findsNothing);
      expect(find.byType(WalletView), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an Ethereum address with no Ethereum wallet: says how to '
        'add one', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      reader.next = 'ethereum:$_eth?value=1e18';
      await _scan(tester, const Key('beamHomeScanButton'));
      expect(find.text('An Ethereum address'), findsOneWidget);
      expect(
        find.textContaining('add an Ethereum wallet to Campfire'),
        findsOneWidget,
      );
      expect(find.text('Add an Ethereum wallet'), findsOneWidget);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/phone_scan_sheet_ethereum.png'),
      );
      await finish(tester);
    });

    testWidgets('an airdrop code opens Claim with the code filled in', (
      tester,
    ) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      reader.next = 'abcd efgh jklm npqr';
      await _scan(tester, const Key('beamHomeScanButton'));
      expect(find.byType(BeamClaimVoucherView), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(BeamClaimVoucherView),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, 'ABCD-EFGH-JKLM-NPQR');
      await finish(tester);
    });

    testWidgets('closing the camera does nothing', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      reader.next = null;
      await _scan(tester, const Key('beamHomeScanButton'));
      expect(reader.desktopCalls, [false]);
      expect(find.byKey(const Key('beamScanSheet')), findsNothing);
      expect(find.byType(BeamSendScreen), findsNothing);
      await finish(tester);
    });

    testWidgets("BEAM Send's own scan: an Ethereum address gets the sheet, "
        'the field stays empty; a BEAM address fills it', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        WalletView(walletId: wallet.walletId),
        false,
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(WalletNavigationBarItem),
              matching: find.text('Send'),
            )
            .first,
      );
      await settle(tester, rounds: 2);
      expect(find.byType(BeamSendScreen), findsOneWidget);

      reader.next = _eth;
      await tester.tap(find.byType(QrCodeIcon));
      await settle(tester, rounds: 2);
      expect(find.text('An Ethereum address'), findsOneWidget);
      expect(
        find.textContaining("BEAM can't be sent to an Ethereum address"),
        findsOneWidget,
      );
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/phone_send_scan_ethereum.png'),
      );
      await tester.tap(find.byKey(const Key('beamScanSheetClose')));
      await settle(tester, rounds: 2);
      expect(_field(tester, _to), isEmpty);

      reader.next = _address;
      await tester.tap(find.byType(QrCodeIcon));
      await settle(tester, rounds: 2);
      expect(_field(tester, _to), _address);
      await finish(tester);
    });
  });

  group('desktop', () {
    testWidgets('"Scan QR code" sits in the top bar; a beam: link brings '
        'the Send tab forward, filled', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        DesktopWalletView(walletId: wallet.walletId),
        true,
      );
      final button = find.byKey(const Key('beamDesktopScanButton'));
      expect(button, findsOneWidget);
      expect(find.text('Scan QR code'), findsOneWidget);
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(90));
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/desktop_wallet_scan_button.png'),
      );

      // From another tab: Send comes forward with the code's numbers.
      await tester.tap(find.text('Receive').first);
      await settle(tester, rounds: 2);
      expect(find.byKey(_to), findsNothing);
      reader.next = 'beam:$_address?amount=2';
      await _scan(tester, const Key('beamDesktopScanButton'));
      await settle(tester, rounds: 1);
      expect(reader.desktopCalls, [true]);
      expect(_field(tester, _to), _address);
      expect(_field(tester, _amount), '2');

      // With Send already showing, a second scan fills it again.
      reader.next = 'alice.beam';
      await _scan(tester, const Key('beamDesktopScanButton'));
      expect(_field(tester, _to), 'alice.beam');
      expect(_field(tester, _amount), '2', reason: 'no amount: kept');
      await finish(tester);
    });

    testWidgets('a payment for another coin: the dialog says so', (
      tester,
    ) async {
      final wallet = await openBeamWallet(tester, db);
      final reader = await _pump(
        tester,
        DesktopWalletView(walletId: wallet.walletId),
        true,
      );
      reader.next = 'bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq';
      await _scan(tester, const Key('beamDesktopScanButton'));
      expect(find.text('A payment for another coin'), findsOneWidget);
      expect(find.textContaining('It starts with "bitcoin:"'), findsOneWidget);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/desktop_scan_sheet_coin.png'),
      );
      await tester.tap(find.byKey(const Key('beamScanSheetClose')));
      await settle(tester, rounds: 2);
      expect(find.byKey(const Key('beamScanSheet')), findsNothing);
      await finish(tester);
    });
  });

  test('the Ethereum wallets that can pay: none here', () {
    expect(beamScanEthWallets(const []), isEmpty);
  });
}
