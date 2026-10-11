/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Transferring a name: the receiving wallet shows its name key as a QR code
// (Names → Receive a name), and Scan reads it into the key field, where it
// is checked exactly as a pasted key is. Without a reader there is no Scan
// button (the other names goldens stay as they are).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/names/beam_name_transfer_view.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/widgets/beam/scan/beam_qr_reader.dart';

import 'names_ui_harness.dart';

class _Reader implements BeamQrReader {
  _Reader(this.next);

  final String? next;
  final List<bool> desktopCalls = [];

  @override
  Future<String?> read(BuildContext context, {required bool desktop}) async {
    desktopCalls.add(desktop);
    return next;
  }
}

final _clock = BansClock(
  tipHeight: tipHeight,
  tipTime: DateTime.fromMillisecondsSinceEpoch(
    tipTimestamp * 1000,
    isUtc: true,
  ),
);

const _alice = BansDomain(
  name: 'alice',
  ownerKey: fakeMyKey,
  expireHeight: tipHeight + 12 * blocksPerDay + 300,
);

Future<void> _open(WidgetTester tester, _Reader? reader) async {
  final fake = NamesUiFake({'my_key': 'my_key', 'view_params': 'view_params'});
  final deps = makeDeps(fake, qrReader: reader);
  await pumpNames(
    tester,
    Launcher(
      open: (c) => BeamNameTransferView.show(
        c,
        deps: deps,
        domain: _alice,
        clock: _clock,
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launch')));
  await settle(tester);
}

void main() {
  testWidgets('Scan reads the key (its first line) and checks it as pasted', (
    tester,
  ) async {
    final reader = _Reader('  $beamOwnerKey\nalice wants this');
    await _open(tester, reader);
    await tester.tap(find.byKey(const Key('names-transfer-scan')));
    await settle(tester);
    expect(reader.desktopCalls, [false]);
    expect(
      textOf(tester, const Key('names-transfer-fingerprint')),
      '72e3 68c0 … 570d 51ef',
    );
  });

  testWidgets('a scanned code that is not a key says so', (tester) async {
    await _open(tester, _Reader('https://example.com'));
    await tester.tap(find.byKey(const Key('names-transfer-scan')));
    await settle(tester);
    expect(
      textOf(tester, const Key('names-transfer-key-error')),
      startsWith('That is not a name key.'),
    );
  });

  testWidgets('closing the camera leaves the field as it was', (tester) async {
    await _open(tester, _Reader(null));
    await tester.tap(find.byKey(const Key('names-transfer-scan')));
    await settle(tester);
    expect(find.byKey(const Key('names-transfer-key-error')), findsNothing);
    expect(find.byKey(const Key('names-transfer-fingerprint')), findsNothing);
  });

  testWidgets('no reader, no Scan button', (tester) async {
    await _open(tester, null);
    expect(find.byKey(const Key('names-transfer-scan')), findsNothing);
  });
}
