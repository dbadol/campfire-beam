/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What a recipient brought in from outside the field (its Scan, paste and
// address book; the home's Scan) does to the rest of the Send form
// (release audit 1.3.0; the rule is written at BeamSendFormState._applyText):
//
//   * a `beam:` link starts a new payment: asset back to BEAM (a link's
//     amount is BEAM: with bETH chosen, "amount=0.5" was "Send 0.5 bETH",
//     about 126,000 BEAM), the link's amount or none, no comment, and a
//     word when the link's amount could not be read;
//   * a plain address or name keeps the asset, the comment and an amount
//     the person typed, but never an amount another link brought, which
//     also goes when another asset is chosen.
//
// Runs the real form over send_ui_support.dart's scripted backend.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/scan_recognize.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';
import 'package:stackwallet/widgets/icon_widgets/addressbook_icon.dart';
import 'package:stackwallet/widgets/icon_widgets/qrcode_icon.dart';

import 'send_ui_support.dart';

const _to = Key('beamSendRecipientField');
const _amount = Key('beamSendAmountField');
const _comment = Key('beamSendCommentField');
const _unread = Key('beamSendLinkAmountUnread');
const _bEth = 36;

const _unreadText =
    "This link asks for an amount Campfire couldn't read, so none was "
    'filled in. Type the amount to send.';

String _text(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

/// The form, holding BEAM and bETH. [scanned] is what its Scan reads,
/// [picked] what its address book returns.
class _Form {
  _Form(this.tester, this.page, this.clipboard);

  final WidgetTester tester;
  final GlobalKey<BeamSendPageState> page;
  final FakeClipboard clipboard;
  String? scanned;
  String? picked;

  BeamSendPageState get state => page.currentState!;
  int get assetId => state.model.assetId;
  String get to => _text(tester, _to);
  String get amount => _text(tester, _amount);
  String get comment => _text(tester, _comment);

  Future<void> type(Key field, String text) async {
    await tester.enterText(find.byKey(field), text);
    await tester.pump();
  }

  /// A draft for someone else: bETH, 3 of it, a comment.
  Future<void> draftBEth() async {
    await pickAsset(_bEth);
    await type(_amount, '3');
    await type(_comment, 'old note');
    expect(assetId, _bEth);
  }

  /// Taps [target], scrolled into view first (the draft's comment field
  /// sits below the fold on a phone).
  Future<void> tap(Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
  }

  Future<void> clearRecipient() async {
    await tap(find.byKey(const Key('beamSendClearRecipient')));
    await tester.pump();
  }

  Future<void> scan(String text) async {
    scanned = text;
    await tap(find.byType(QrCodeIcon));
    await _settle();
  }

  Future<void> paste(String text) async {
    await clipboard.setData(ClipboardData(text: text));
    await tap(find.byKey(const Key('beamSendPasteRecipient')));
    await _settle();
  }

  Future<void> addressBook(String address) async {
    picked = address;
    await tap(find.byType(AddressBookIcon));
    await _settle();
  }

  Future<void> pickAsset(int id) async {
    await tap(find.byKey(const Key('beamSendAssetSelector')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(Key('beamAssetChoice_$id')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> _settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Form> _open(WidgetTester tester, {bool desktop = false}) async {
  await setScreen(tester, desktop: desktop);
  final page = GlobalKey<BeamSendPageState>();
  final clipboard = FakeClipboard();
  late final _Form form;
  await pumpCampfire(
    tester,
    home: BeamSendPage(
      key: page,
      backend: ScriptedBackend(balances: {0: g(2), _bEth: g(1)}),
      coin: Beam(CryptoCurrencyNetwork.main),
      walletId: 'beam-test-wallet',
      walletName: 'My BEAM',
      clipboard: clipboard,
      minimumBuildTime: Duration.zero,
      routeOnSuccessName: '/',
      nameDebounce: const Duration(milliseconds: 50),
      onScanQr: (_) async => form.scanned,
      onAddressBook: (_) async => form.picked,
    ),
    desktop: desktop,
  );
  await tester.pump(const Duration(milliseconds: 50));
  form = _Form(tester, page, clipboard);
  return form;
}

void main() {
  final address = vectorAddress('regular');
  final other = vectorAddress('regular_new');

  group('scanIsBeamLink / scanBeamLinkAmountText', () {
    test('a beam: link, in any case, whatever it points to', () {
      expect(scanIsBeamLink('beam:$address'), isTrue);
      expect(scanIsBeamLink('BEAM:$address?amount=1'), isTrue);
      expect(scanIsBeamLink('beam:alice.beam'), isTrue);
      expect(scanIsBeamLink('  beam:alice\nlabel'), isTrue);
      expect(scanIsBeamLink(address), isFalse);
      expect(scanIsBeamLink('alice.beam'), isFalse);
      expect(
        scanIsBeamLink('ethereum:0x52908400098527886E0F7030069857D2E4169EE7'),
        isFalse,
      );
      expect(scanIsBeamLink(null), isFalse);
    });

    test("the amount as the link writes it, even one the rules refuse", () {
      expect(scanBeamLinkAmountText('beam:$address?amount=1.5'), '1.5');
      expect(scanBeamLinkAmountText('beam:$address?amount=1,000'), '1,000');
      expect(scanBeamLinkAmountText('beam:$address?tx_amount=2'), '2');
      expect(scanBeamLinkAmountText('beam:alice.beam?amount=5'), '5');
      expect(scanBeamLinkAmountText('beam:$address'), isNull);
      expect(scanBeamLinkAmountText('$address?amount=1'), isNull);
      // The rules keep only the valid one.
      expect(recognizeScan('beam:$address?amount=1,000').amount, isNull);
    });
  });

  group('a beam: link starts a new payment', () {
    testWidgets('scanned with bETH chosen: BEAM, the link\'s amount, no old '
        'comment; never "Send 0.5 bETH"', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.scan('beam:$address?amount=0.5');
      expect(f.to, address);
      expect(f.assetId, 0, reason: "a link's amount is BEAM");
      expect(f.amount, '0.5');
      expect(f.state.model.amount, g(0.5));
      expect(f.comment, '');
      expect(f.state.model.comment, '');
      expect(find.byKey(_unread), findsNothing);
    });

    testWidgets('scanned with no amount: the old amount does not ride '
        'along', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.scan('beam:$address');
      expect(f.to, address);
      expect(f.assetId, 0);
      expect(f.amount, '');
      expect(f.state.model.amountText, '');
      expect(f.comment, '');
      expect(find.byKey(_unread), findsNothing, reason: 'it asked for none');
    });

    testWidgets("a link's amount that cannot be read is said, and goes "
        'once an amount is typed', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.scan('beam:$address?amount=1,000');
      expect(f.to, address);
      expect(f.assetId, 0);
      expect(f.amount, '', reason: 'never 1, never the old 3');
      expect(find.byKey(_unread), findsOneWidget);
      expect(find.text(_unreadText), findsOneWidget);
      await f.type(_amount, '2');
      expect(find.byKey(_unread), findsNothing);
    });

    testWidgets('pasted: the same as scanned', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.paste('beam:$address?amount=0,5');
      expect(f.to, address);
      expect(f.assetId, 0);
      expect(f.amount, '');
      expect(f.comment, '');
      expect(find.byKey(_unread), findsOneWidget);

      await f.clearRecipient();
      expect(find.byKey(_unread), findsNothing, reason: 'the link is gone');
      await f.paste('beam:$address?tx_amount=1.25');
      expect(f.amount, '1.25');
      expect(find.byKey(_unread), findsNothing);
    });

    testWidgets("a name's link: the name, and its amount is said to be "
        'unread, not dropped silently', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.scan('beam:alice.beam?amount=5');
      expect(f.to, 'alice.beam');
      expect(f.assetId, 0);
      expect(f.amount, '');
      expect(find.byKey(_unread), findsOneWidget);
    });
  });

  group('a plain address or name says only who', () {
    testWidgets('from the address book: the asset, the typed amount and the '
        'comment stay', (tester) async {
      final f = await _open(tester, desktop: true);
      await f.draftBEth();
      await f.addressBook(address);
      expect(f.to, address);
      expect(f.assetId, _bEth);
      expect(f.amount, '3');
      expect(f.state.model.amount, g(3));
      expect(f.comment, 'old note');
    });

    testWidgets('scanned or pasted: the same', (tester) async {
      final f = await _open(tester);
      await f.draftBEth();
      await f.scan(address);
      expect((f.assetId, f.amount, f.comment), (_bEth, '3', 'old note'));
      await f.clearRecipient();
      await f.paste('alice.beam');
      expect(f.to, 'alice.beam');
      expect((f.assetId, f.amount, f.comment), (_bEth, '3', 'old note'));
    });

    testWidgets("but a link's amount never goes to another recipient", (
      tester,
    ) async {
      final f = await _open(tester, desktop: true);
      await f.scan('beam:$address?amount=1.5');
      expect(f.amount, '1.5');
      await f.clearRecipient();
      expect(f.amount, '', reason: "it was that link's");
      await f.addressBook(other);
      expect(f.to, other);
      expect(f.amount, '');
      expect(f.state.model.amount, isNull);

      // Typed over the field by hand: the same.
      await f.clearRecipient();
      await f.scan('beam:$address?amount=1.5');
      await f.type(_to, other);
      expect(f.amount, '');
    });

    testWidgets('an amount the person typed after a link is theirs: it '
        'stays', (tester) async {
      final f = await _open(tester, desktop: true);
      await f.scan('beam:$address?amount=1.5');
      await f.type(_amount, '0.7');
      await f.clearRecipient();
      await f.addressBook(other);
      expect(f.amount, '0.7');
    });
  });

  testWidgets("another asset never takes a link's BEAM amount", (tester) async {
    final f = await _open(tester);
    await f.scan('beam:$address?amount=0.5');
    expect((f.assetId, f.amount), (0, '0.5'));
    await f.pickAsset(_bEth);
    expect(f.assetId, _bEth);
    expect(f.amount, '', reason: 'never 0.5 bETH');
    expect(f.state.model.amount, isNull);

    // A typed amount follows the asset as before.
    await f.type(_amount, '0.25');
    await f.pickAsset(0);
    expect((f.assetId, f.amount), (0, '0.25'));
  });

  testWidgets("the home's Scan (fill) is a link too: its amount is that "
      "recipient's", (tester) async {
    final f = await _open(tester, desktop: true);
    await f.draftBEth();
    f.state.fill(address, amount: '1.5');
    await tester.pump();
    expect((f.assetId, f.amount, f.comment), (0, '1.5', ''));
    await f.clearRecipient();
    await f.addressBook(other);
    expect(f.amount, '');
  });
}
