/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The airdrop screens over the real services of both airdrop contracts
// (BeamAirdrops), on a FakeTransport whose invoke_contract is answered like
// the pinned app shaders: the old contract's
// (test/beam/contracts/airdrop/airdrop_fixtures.dart, built on the recorded
// mainnet answers) and Airdrop v3's (airdrop_v3_fixtures.dart), and whose
// wallet_status is the recorded fixture. Codes of the old contract are
// still claimed and taken back there; every new batch is made on v3. Every
// code here comes from a seeded Random in a fake contract: none of them
// unlocks anything on mainnet.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_batches_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_codes_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_create_airdrop_view.dart';
import 'package:stackwallet/utilities/beam/secret_clipboard.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';
import 'package:stackwallet/widgets/flag_secure_scope.dart';

import '../contracts/airdrop/airdrop_fixtures.dart';
import '../contracts/airdrop/airdrop_v3_fixtures.dart';
import '../contracts/airdrop/memory_code_store.dart';
import 'beam_ui_harness.dart';

/// Logs reads as well as writes, to prove the read-back happens before the
/// broadcast.
class _RecordingStore extends MemoryCodeStore {
  _RecordingStore(List<String> super.log);

  @override
  Future<List<AirdropSavedBatch>> all() {
    // `this.`: dart:math's top-level log would shadow the inherited field.
    this.log!.add('all');
    return super.all();
  }
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PrimaryButton>(find.byKey(ValueKey(key))).enabled;

void main() {
  const g = BigInt.from;
  late FakeAirdropShader shader;
  late FakeAirdropV3Shader v3Shader;
  late FakeTransport t;
  late List<String> log;
  late _RecordingStore store;
  late BeamAirdrops service;
  // What tx_status says about any transaction.
  late Map<String, Object?> txState;
  late ValueNotifier<BeamSyncAssessment> sync;
  late FakeAuth auth;
  final names = BeamAssetNames();

  String code(int seed) => AirdropVoucherCode.generate(Random(seed));

  void voucher(String c, int assetId, BigInt value, {int batch = 7}) =>
      shader.vouchers[AirdropVoucherCode.hashHex(c)] = FakeVoucher(
        BigInt.from(batch),
        assetId,
        value,
      );

  // Built inside each test body: a service made in setUp() holds
  // Futures of the real zone, whose callbacks never run under the widget
  // test's fake clock.
  void init() {
    log = [];
    txState = {'status': 3, 'confirmations': 5};
    shader = FakeAirdropShader();
    v3Shader = FakeAirdropV3Shader();
    store = _RecordingStore(log);
    t = FakeTransport({
      'invoke_contract': airdropRouter(shader, v3Shader),
      'process_invoke_data': (Map<String, Object?> p) {
        log.add('sent');
        return {'txid': 'cd' * 16};
      },
      'wallet_status': jsonDecode(
        File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
      ),
      'tx_status': (Map<String, Object?> p) => {
        'txId': p['txId'],
        'status_string': 'x',
        'tx_type': 12,
        'create_time': 1790000000,
        ...txState,
      },
    });
    final lock = AirdropFlowLock();
    final shaders = MemoryShaderSource();
    service = BeamAirdrops(
      old: BeamAirdropService(
        BeamApi(t),
        airdropAppShader(shaders),
        store: store,
        lock: lock,
        random: Random(11),
        clock: () => DateTime.utc(2026, 10, 6, 12),
      ),
      v3: BeamAirdropV3Service(
        BeamApi(t),
        airdropV3AppShader(shaders),
        store: store,
        lock: lock,
        random: Random(11),
        clock: () => DateTime.utc(2026, 10, 6, 12),
      ),
    );
    sync = ValueNotifier(synced());
    auth = FakeAuth();
  }

  Widget claimView({
    bool withNames = true,
    String? initialCode,
    ClipboardInterface? clipboard,
  }) => BeamClaimVoucherView(
    service: service,
    sync: sync,
    assetNames: withNames ? names : null,
    authorize: auth.authorizer,
    initialCode: initialCode,
    clipboard: clipboard ?? FakeClipboard(),
  );

  final field = find.byKey(const ValueKey('claim-code-field'));

  /// Every code text the node was asked about: the old contract's SHA-256
  /// keys and the codes Airdrop v3's shader derives a key from.
  bool asked(String code) {
    final n = AirdropVoucherCode.normalise(code);
    final hash = AirdropVoucherCode.hashHex(n);
    return [
      ...shader.seen,
      ...v3Shader.seen,
    ].any((a) => a.contains(hash) || RegExp('=$n(,|\$)').hasMatch(a));
  }

  group('claim a voucher', () {
    testWidgets('a full code is checked by itself; value and decoded fee '
        'show before the claim, which sends once after the PIN', (
      tester,
    ) async {
      init();
      final c = code(5);
      voucher(c, 0, g(50000000));
      await pumpBeamPage(tester, claimView());
      expect(find.text('Claim code'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isFalse);

      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);
      expect(_textOf(tester, 'claim-gets'), '0.5 BEAM');
      // Decoded from the built transaction: the shader's 1,200,000 charge.
      expect(_textOf(tester, 'claim-fee'), '0.121 BEAM');
      expect(_textOf(tester, 'claim-total'), '+0.379 BEAM');
      expect(find.byKey(const ValueKey('claim-loss-warning')), findsNothing);
      // The contract reveals the code when claiming: said before the claim.
      expect(find.byKey(const ValueKey('claim-bearer-notice')), findsOneWidget);
      expect(t.lastParams('invoke_contract')['create_tx'], isFalse);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      await expectScreen(tester, 'claim_ready');

      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      // An old-contract code: the stop first, once for both taps.
      expect(
        find.byKey(const ValueKey('claim-old-contract-stop')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('claim-old-contract-go')));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(auth.reasons, ['Claim 0.5 BEAM']);
      // Sent, not "received": that waits for the network.
      expect(_textOf(tester, 'claim-done'), 'Claim sent');
      expect(service.isBusy, isFalse);
      // An old contract's code: found there after Airdrop v3 said no.
      expect(
        v3Shader.seen.where((a) => a.contains('action=check_voucher')),
        isNotEmpty,
      );
      expect(
        shader.seen.where((a) => a.contains('action=redeem')),
        hasLength(1),
      );
      await expectScreen(tester, 'claim_done');
    });

    testWidgets('typing a code and pausing at every length short of a full '
        'code asks the node nothing (release audit 1.3.0)', (tester) async {
      init();
      final c = code(5);
      voucher(c, 0, g(50000000));
      final n = AirdropVoucherCode.normalise(c);
      await pumpBeamPage(tester, claimView());
      for (var i = 1; i < AirdropVoucherCode.length; i++) {
        await tester.enterText(field, n.substring(0, i));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(t.callsTo('invoke_contract'), isEmpty, reason: '$i symbols');
        expect(service.isBusy, isFalse);
      }
      // 15 symbols: offered, never run by itself.
      expect(find.text('Check code'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isTrue);
      expect(find.text('15 of 16 characters'), findsOneWidget);

      // The 16th: looked up at once, and only the whole code.
      await tester.enterText(field, n);
      await tester.pumpAndSettle();
      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);
      expect(asked(c), isTrue);
      for (var i = 1; i < AirdropVoucherCode.length; i++) {
        expect(asked(n.substring(0, i)), isFalse, reason: '$i symbols');
      }
    });

    testWidgets('a code that is not a full one, pasted or opened from a '
        'scan, is looked up only after a tap on Check code', (tester) async {
      init();
      // Codes made elsewhere can be shorter; this one is on the old
      // contract.
      const short = 'ABCD-EFGH-JKLM';
      voucher(short, 0, g(50000000));
      final clipboard = FakeClipboard();
      await clipboard.setData(const ClipboardData(text: short));
      await pumpBeamPage(tester, claimView(clipboard: clipboard));
      await tester.tap(find.byKey(const ValueKey('claim-paste')));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(t.callsTo('invoke_contract'), isEmpty);
      expect(find.text('Check code'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      expect(asked(short), isTrue);
      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);
      expect(t.callsTo('process_invoke_data'), isEmpty);

      // From a scan or a link: the same, nothing on open.
      await tester.pumpWidget(const SizedBox());
      init();
      voucher(short, 0, g(50000000));
      await pumpBeamPage(tester, claimView(initialCode: short));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(t.callsTo('invoke_contract'), isEmpty);
      expect(find.text('Check code'), findsOneWidget);
    });

    testWidgets('a code edited while the full one is being checked: the part '
        'left is never looked up', (tester) async {
      init();
      final c = code(5);
      voucher(c, 0, g(50000000));
      final n = AirdropVoucherCode.normalise(c);
      await pumpBeamPage(tester, claimView());
      t.latency = const Duration(milliseconds: 100);
      await tester.enterText(field, n);
      await tester.pump(); // the check starts
      expect(find.text('Checking the code…'), findsOneWidget);
      await tester.enterText(field, n.substring(0, 12));
      await tester.pumpAndSettle();
      expect(asked(n), isTrue);
      expect(asked(n.substring(0, 12)), isFalse);
      expect(find.text('Check code'), findsOneWidget);
      expect(service.isBusy, isFalse, reason: 'the stale claim is dropped');
      expect(find.byKey(const ValueKey('claim-gets')), findsNothing);
    });

    testWidgets('every claim of an old-contract code stops first and says '
        'why: Don\'t claim is the default, closing it claims nothing, and a '
        'scanned code never goes past it', (tester) async {
      init();
      // Airdrop v3 says "not found" and the old contract "found": all a
      // node that lies needs to steer a new code here.
      final c = code(5);
      voucher(c, 0, g(50000000));
      await pumpBeamPage(tester, claimView(initialCode: c));
      await tester.pumpAndSettle();
      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('claim-old-contract-stop')),
        findsNothing,
      );
      expect(auth.reasons, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);

      final stop = find.byKey(const ValueKey('claim-old-contract-stop'));
      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      expect(stop, findsOneWidget);
      expect(
        find.text('This code is from the old airdrop contract'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Codes made since 13 October 2026 never need '
          'this.',
        ),
        findsOneWidget,
      );
      expect(auth.reasons, isEmpty, reason: 'the PIN comes after the stop');
      await expectScreen(tester, 'claim_old_contract_stop');

      // "Don't claim": nothing asked, nothing sent.
      await tester.tap(find.byKey(const ValueKey('claim-old-contract-keep')));
      await tester.pumpAndSettle();
      expect(stop, findsNothing);
      expect(auth.reasons, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);

      // Closed by tapping beside it: the same.
      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(stop, findsNothing);
      expect(auth.reasons, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);

      // Only "Claim it anyway" goes on: the PIN, then the claim.
      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('claim-old-contract-go')));
      await tester.pumpAndSettle();
      expect(auth.reasons, ['Claim 0.5 BEAM']);
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(_textOf(tester, 'claim-done'), 'Claim sent');
    });

    testWidgets('a voucher worth less than its fee says how much BEAM the '
        'claim loses', (tester) async {
      init();
      final c = code(6);
      voucher(c, 0, g(5000000));
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('claim-loss-warning')), findsOneWidget);
      expect(
        find.textContaining('your balance goes down by 0.071 BEAM'),
        findsOneWidget,
      );
      expect(_textOf(tester, 'claim-total'), '−0.071 BEAM');
      expect(find.text('Claim anyway'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isTrue);
      await expectScreen(tester, 'claim_less_than_fee');
    });

    testWidgets('an unknown code explains what to check, blames nobody, and '
        'releases the service', (tester) async {
      init();
      await pumpBeamPage(tester, claimView());
      await tester.enterText(
        find.byKey(const ValueKey('claim-code-field')),
        code(99),
      );
      await tester.pumpAndSettle();

      expect(find.text('No voucher has this code'), findsOneWidget);
      expect(find.textContaining('never use I, O, 0 or 1'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(service.isBusy, isFalse);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      await expectScreen(tester, 'claim_invalid');
    });

    testWidgets('while the wallet catches up, the claim waits and says why', (
      tester,
    ) async {
      init();
      final c = code(5);
      voucher(c, 0, g(50000000));
      sync.value = catchingUp();
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(find.text('Claim 0.5 BEAM'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isFalse);
      expect(find.byKey(const ValueKey('beam-sync-notice')), findsOneWidget);
      expect(find.textContaining('Behind by 42 blocks'), findsOneWidget);
      await expectScreen(tester, 'claim_not_synced');

      sync.value = synced();
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'claim-cta'), isTrue);
    });

    testWidgets('editing the code drops the prepared claim', (tester) async {
      init();
      final c = code(5);
      voucher(c, 0, g(50000000));
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();
      expect(service.isBusy, isTrue);

      await tester.enterText(
        find.byKey(const ValueKey('claim-code-field')),
        c.substring(0, 6),
      );
      await tester.pump();
      expect(service.isBusy, isFalse);
      expect(find.text('Claim code'), findsOneWidget);
    });

    testWidgets('desktop: a token voucher, fee paid in BEAM', (tester) async {
      init();
      final c = code(7);
      voucher(c, 174, g(250000000000));
      await pumpBeamPage(tester, claimView(), desktop: true);
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(find.text('Claim 2,500 FOMO'), findsOneWidget);
      expect(_textOf(tester, 'claim-total'), '+2,500 FOMO, −0.121 BEAM');
      await expectScreen(tester, 'desktop_claim_token');
    });
  });

  group('create a batch', () {
    testWidgets('on Airdrop v3: the summary adds up with the claim fees paid '
        'ahead, a double tap builds one batch, the codes are saved and read '
        'back before the broadcast, and shown once they are checked', (
      tester,
    ) async {
      init();
      await pumpBeamPage(
        tester,
        BeamCreateAirdropView(
          service: service,
          sync: sync,
          assetNames: names,
          authorize: auth.authorizer,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('You have 667.07641121 BEAM'), findsOneWidget);
      expect(_enabled(tester, 'create-cta'), isFalse);
      expect(
        find.byKey(const ValueKey('create-bearer-warning')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('create-amount')),
        '0.1',
      );
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'create-locked'), '1 BEAM');
      expect(_textOf(tester, 'create-fee'), '0.01 BEAM');
      // "Pay the claim fee for each code" is on by default: 10 × 0.022.
      expect(_textOf(tester, 'create-gas'), '0.22 BEAM');
      // 0.001 + 10 groth × (115,000 + 30,000 × 10).
      expect(_textOf(tester, 'create-network-fee'), '0.0425 BEAM');
      expect(_textOf(tester, 'create-total'), '1.2725 BEAM');
      expect(find.text('Create 10 codes'), findsOneWidget);
      await expectScreen(tester, 'create_form');

      // Two taps in the same frame: one batch.
      txState = {'status': 1};
      await tester.tap(find.byKey(const ValueKey('create-cta')));
      await tester.tap(find.byKey(const ValueKey('create-cta')));
      await tester.pumpAndSettle();
      expect(
        v3Shader.seen.where((a) => a.contains('action=create_batch')),
        hasLength(1),
      );
      expect(
        shader.seen.where((a) => a.contains('action=create_batch')),
        isEmpty,
        reason: 'new batches go to Airdrop v3 only',
      );
      expect(log, isEmpty); // nothing saved or sent by preparing

      // The confirmation, read back from raw_data.
      expect(_textOf(tester, 'confirm-locked'), '1 BEAM');
      expect(_textOf(tester, 'confirm-creation-fee'), '0.01 BEAM');
      expect(_textOf(tester, 'confirm-gas'), '0.22 BEAM');
      expect(_textOf(tester, 'confirm-network-fee'), '0.0425 BEAM');
      expect(_textOf(tester, 'confirm-total'), '1.2725 BEAM');
      await expectScreen(tester, 'create_confirm');

      await tester.tap(find.byKey(const ValueKey('airdrop-confirm-cta')));
      await tester.tap(find.byKey(const ValueKey('airdrop-confirm-cta')));
      await tester.pumpAndSettle();

      expect(t.callsTo('process_invoke_data'), hasLength(1));
      // Written, read back, then sent; then the tx id is recorded.
      expect(log.take(4), ['put unconfirmed', 'all', 'sent', 'put broadcast']);
      var saved = (await store.all()).single;
      expect(saved.count, 10);
      expect(saved.txId, 'cd' * 16);
      expect(saved.isV3, isTrue);

      // Not mined yet: the codes are not shown until they are checked.
      expect(find.text('Your airdrop codes'), findsOneWidget);
      expect(find.byKey(const ValueKey('codes-steps')), findsOneWidget);
      expect(find.byKey(const ValueKey('code-0')), findsNothing);

      // Mined, 5 confirmations: the next look checks every code.
      v3Shader.mine(v3Shader.pending!);
      txState = {'status': 3, 'confirmations': 5};
      await tester.pump(BeamAirdropCodesView.checkEvery);
      await tester.pumpAndSettle();
      saved = (await store.all()).single;
      expect(saved.check!.ok, isTrue);
      expect(find.byKey(const ValueKey('codes-ready')), findsOneWidget);
      expect(find.byKey(const ValueKey('codes-key-warning')), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        final shown = tester.widget<Text>(find.byKey(ValueKey('code-$i'))).data;
        expect(shown, saved.codes[i].code);
      }
      // Nothing to select: a code leaves only through Copy, which takes it
      // off the clipboard again (release audit 1.3.0).
      expect(find.byType(SelectableText), findsNothing);
      await expectScreen(tester, 'codes_new');
    });

    testWidgets('more than the balance is refused before preparing', (
      tester,
    ) async {
      init();
      await pumpBeamPage(
        tester,
        BeamCreateAirdropView(service: service, sync: sync, assetNames: names),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('create-amount')), '70');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('create-funds-problem')),
        findsOneWidget,
      );
      expect(_enabled(tester, 'create-cta'), isFalse);
    });

    testWidgets('while the wallet catches up, creating waits', (tester) async {
      init();
      sync.value = catchingUp();
      await pumpBeamPage(
        tester,
        BeamCreateAirdropView(service: service, sync: sync, assetNames: names),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('create-amount')),
        '0.1',
      );
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'create-cta'), isFalse);
      expect(find.byKey(const ValueKey('beam-sync-notice')), findsOneWidget);
    });
  });

  group('my batches', () {
    late List<String> codesA;
    late List<String> codesC;

    AirdropSavedBatch saved(
      String id,
      List<String> codes,
      BigInt value,
      AirdropBatchTxStatus status,
      DateTime at,
    ) => AirdropSavedBatch(
      localId: id,
      contractId: kAirdropContractId,
      assetId: 0,
      createdAt: at,
      txId: 'ab' * 16,
      txStatus: status,
      codes: [
        for (final c in codes)
          AirdropSavedCode(
            code: c,
            hashHex: AirdropVoucherCode.hashHex(c),
            value: value,
          ),
      ],
    );

    Future<void> seed() async {
      codesA = [code(21), code(22), code(23)];
      codesC = [code(31), code(32)];
      // A: on chain, 1 of 3 claimed, codes saved here.
      shader.addBatch(g(41), 0, {
        for (final c in codesA) AirdropVoucherCode.hashHex(c): g(20000000),
      });
      shader.vouchers[AirdropVoucherCode.hashHex(codesA[0])]!.redeemed = true;
      await store.put(
        saved(
          'batch_a',
          codesA,
          g(20000000),
          AirdropBatchTxStatus.broadcast,
          DateTime.utc(2026, 10, 3),
        ),
      );
      // B: on chain, made elsewhere: no codes on this device.
      shader.addBatch(g(40), 174, {
        AirdropVoucherCode.hashHex(code(41)): g(500000000),
        AirdropVoucherCode.hashHex(code(42)): g(500000000),
      });
      // C: every code claimed; the contract no longer lists it.
      for (final c in codesC) {
        shader.vouchers[AirdropVoucherCode.hashHex(c)] = FakeVoucher(
          g(39),
          0,
          g(10000000),
          redeemed: true,
        );
      }
      await store.put(
        saved(
          'batch_c',
          codesC,
          g(10000000),
          AirdropBatchTxStatus.confirmed,
          DateTime.utc(2026, 9, 30),
        ),
      );
      log.clear();
    }

    Widget batches() => BeamAirdropBatchesView(
      service: service,
      sync: sync,
      assetNames: names,
      authorize: auth.authorizer,
      clock: () => DateTime.utc(2026, 10, 6, 12),
    );

    testWidgets('lists saved and on-chain batches with their counts; cancel '
        'shows the 0.181 BEAM fee and what comes back', (tester) async {
      init();
      await seed();
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();

      expect(find.text('1 of 3 claimed · 2 waiting'), findsOneWidget);
      expect(find.text('0 of 2 claimed · 2 waiting'), findsOneWidget);
      expect(find.text('All 2 claimed'), findsOneWidget);
      expect(
        find.textContaining('codes are not on this device'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('batch-cancel-41')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('batch-forget-batch_c')),
        findsOneWidget,
      );
      // A batch that still holds funds can never be forgotten.
      expect(find.byKey(const ValueKey('batch-forget-batch_a')), findsNothing);
      await expectScreen(tester, 'batches');

      await tester.tap(find.byKey(const ValueKey('batch-cancel-41')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'confirm-returned'), '0.4 BEAM');
      expect(_textOf(tester, 'confirm-network-fee'), '0.181 BEAM');
      expect(_textOf(tester, 'confirm-total'), '+0.219 BEAM');
      expect(find.text('Get back 0.4 BEAM'), findsOneWidget);
      await expectScreen(tester, 'cancel_confirm');

      await tester.tap(find.byKey(const ValueKey('airdrop-confirm-cta')));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(find.byKey(const ValueKey('batches-done')), findsOneWidget);
      expect(service.isBusy, isFalse);
      // Nothing was deleted along the way.
      expect(store.deletes, 0);
    });

    testWidgets('"Remove from this list" asks first and only removes a '
        'settled batch', (tester) async {
      init();
      await seed();
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-forget-batch_c')));
      await tester.pumpAndSettle();
      expect(find.text('Remove this batch from the list?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(store.deletes, 1);
      final left = await store.all();
      expect(left.map((b) => b.localId), ['batch_a']);
    });

    testWidgets('desktop layout', (tester) async {
      init();
      await seed();
      await pumpBeamPage(tester, batches(), desktop: true);
      await tester.pumpAndSettle();
      expect(find.text('All 2 claimed'), findsOneWidget);
      await expectScreen(tester, 'desktop_batches');
    });

    testWidgets('no batches: says what airdrops are and offers to create', (
      tester,
    ) async {
      init();
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('batches-empty')), findsOneWidget);
      expect(find.text('Create airdrop codes'), findsOneWidget);
      expect(_enabled(tester, 'batches-create'), isTrue);
      await expectScreen(tester, 'batches_empty');
    });
  });

  group('voucher codes stay private (issue #76)', () {
    final flags = <bool>[];
    setUp(() {
      flags.clear();
      FlagSecureScope.debugSetFlagSecure = (on) async => flags.add(on);
      FlagSecureScope.debugUserWantsSecure = () => false;
    });
    tearDown(() {
      FlagSecureScope.debugSetFlagSecure = null;
      FlagSecureScope.debugUserWantsSecure = null;
      SecretClipboard.debugDesktop = null;
    });

    testWidgets('the claim screen blocks screenshots while it is open', (
      tester,
    ) async {
      init();
      await pumpBeamPage(tester, claimView());
      expect(FlagSecureScope.activeCount, 1);
      expect(flags, [true]);
      await tester.pumpWidget(const SizedBox());
      expect(FlagSecureScope.activeCount, 0);
      expect(flags, [true, false]);
    });

    testWidgets('the codes screen blocks screenshots; Copy all says the codes '
        'leave the clipboard in a minute, and they do', (tester) async {
      init();
      SecretClipboard.debugDesktop = true;
      final c = code(21);
      await store.put(
        AirdropSavedBatch(
          localId: 'batch_76',
          contractId: kAirdropContractId,
          assetId: 0,
          createdAt: DateTime.utc(2026, 10, 13),
          codes: [
            AirdropSavedCode(
              code: c,
              hashHex: AirdropVoucherCode.hashHex(c),
              value: g(100000),
            ),
          ],
        ),
      );
      final clipboard = FakeClipboard();
      await pumpBeamPage(
        tester,
        BeamAirdropCodesView(
          service: service,
          localId: 'batch_76',
          clipboard: clipboard,
        ),
      );
      await tester.pumpAndSettle();
      expect(FlagSecureScope.activeCount, 1);
      await tester.tap(find.byKey(const ValueKey('codes-copy-all')));
      await tester.pump(const Duration(milliseconds: 100));
      expect((await clipboard.getData('text/plain'))?.text, c);
      expect(
        find.text('All 1 codes copied. It leaves the clipboard in a minute.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect((await clipboard.getData('text/plain'))?.text, '');
      await tester.pumpAndSettle();
    });
  });
}
