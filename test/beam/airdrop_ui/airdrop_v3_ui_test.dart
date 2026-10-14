/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The airdrop screens on Airdrop v3: a code whose maker paid its fee
// claimed from an empty wallet ("No BEAM needed"), a claim followed until
// the network decides, a new batch's codes held back until the check before
// sharing passed (and what a failed check says), and take-backs with their
// prepaid claim fees, including a claim that lands first. Over the real
// services and a fake v3 app shader (airdrop_v3_fixtures.dart). Every code
// here is made up: none unlocks anything on mainnet.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_batches_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_airdrop_codes_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_create_airdrop_view.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/airdrop/airdrop_text.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';
import 'package:stackwallet/widgets/flag_secure_scope.dart';

import '../contracts/airdrop/airdrop_fixtures.dart';
import '../contracts/airdrop/airdrop_v3_fixtures.dart';
import '../contracts/airdrop/memory_code_store.dart';
import 'beam_ui_harness.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PrimaryButton>(find.byKey(ValueKey(key))).enabled;

/// The recorded wallet_status with these available balances instead.
Map<String, Object?> _walletStatus(Map<int, int> available) {
  final env = jsonDecode(
    File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final r = (env['result']! as Map).cast<String, Object?>();
  final template = ((r['totals']! as List).first as Map)
      .cast<String, Object?>();
  r['available'] = available[0] ?? 0;
  r['totals'] = [
    for (final e in available.entries)
      {
        ...template,
        'asset_id': e.key,
        'available': e.value,
        'available_str': '${e.value}',
        'available_regular': e.value,
        'available_regular_str': '${e.value}',
      },
  ];
  return {...env, 'result': r};
}

void main() {
  const g = BigInt.from;
  final gas = kAirdropV3GasPerVoucher;
  late FakeAirdropShader oldShader;
  late FakeAirdropV3Shader shader;
  late FakeTransport t;
  late MemoryCodeStore store;
  late BeamAirdrops service;
  late ValueNotifier<BeamSyncAssessment> sync;
  late FakeAuth auth;
  late Map<String, Object?> txState;
  final names = BeamAssetNames();

  /// Built inside each test body (see airdrop_ui_test.dart).
  void init({Map<int, int> balances = const {0: 66707641121}}) {
    txState = {'status': 1};
    oldShader = FakeAirdropShader();
    shader = FakeAirdropV3Shader();
    store = MemoryCodeStore();
    t = FakeTransport({
      'invoke_contract': airdropRouter(oldShader, shader),
      'process_invoke_data': (Map<String, Object?> p) => {'txid': 'cd' * 16},
      'wallet_status': _walletStatus(balances),
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
        random: Random(5),
      ),
      v3: BeamAirdropV3Service(
        BeamApi(t),
        airdropV3AppShader(shaders),
        store: store,
        lock: lock,
        random: Random(7),
        clock: () => DateTime.utc(2026, 10, 14, 12),
      ),
    );
    sync = ValueNotifier(synced());
    auth = FakeAuth();
  }

  String code(int seed) => AirdropVoucherCode.generate(Random(seed));

  Widget claimView() => BeamClaimVoucherView(
    service: service,
    sync: sync,
    assetNames: names,
    authorize: auth.authorizer,
  );

  group('claim', () {
    testWidgets('a code whose maker paid its fee: "No BEAM needed" and a '
        'claim from an empty wallet; sent, then received once the network '
        'confirms it', (tester) async {
      init(balances: const {0: 0});
      final c = code(61);
      shader.addBatch([c], 36, g(500000000), gas: gas, by: v3Other);
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('claim-no-beam-needed')),
        findsOneWidget,
      );
      expect(_textOf(tester, 'claim-gets'), '5 bETH');
      expect(_textOf(tester, 'claim-fee'), '0.021 BEAM');
      expect(find.text('Paid by the code'), findsOneWidget);
      expect(_textOf(tester, 'claim-total'), '+5 bETH, +0.001 BEAM');
      expect(find.text(AirdropBearerText.claimMessageV3), findsOneWidget);
      expect(find.byKey(const ValueKey('claim-short-of-beam')), findsNothing);
      expect(find.text('Claim 5 bETH'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isTrue);
      await expectScreen(tester, 'v3_claim_no_beam_needed');

      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();
      // A v3 claim never shows the code: no stop before the PIN.
      expect(
        find.byKey(const ValueKey('claim-old-contract-stop')),
        findsNothing,
      );
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(auth.reasons, ['Claim 5 bETH']);
      expect(_textOf(tester, 'claim-done'), 'Claim sent');
      await expectScreen(tester, 'v3_claim_sent');

      txState = {'status': 3, 'confirmations': 1};
      await tester.pump(BeamClaimVoucherView.pollEvery);
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'claim-done'), '5 bETH received');
      await expectScreen(tester, 'v3_claim_received');
    });

    testWidgets('a code without a prepaid fee, on an empty wallet: says how '
        'much BEAM the claim needs and does not offer it', (tester) async {
      init(balances: const {0: 0});
      final c = code(62);
      shader.addBatch([c], 36, g(500000000), by: v3Other);
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('claim-no-beam-needed')), findsNothing);
      expect(find.text('Paid from your BEAM'), findsOneWidget);
      expect(_textOf(tester, 'claim-total'), '+5 bETH, −0.021 BEAM');
      expect(find.byKey(const ValueKey('claim-short-of-beam')), findsOneWidget);
      expect(find.textContaining('Claiming needs 0.021 BEAM'), findsOneWidget);
      expect(_enabled(tester, 'claim-cta'), isFalse);
      await expectScreen(tester, 'v3_claim_needs_beam');
    });

    testWidgets('a claim the network turns down: nothing left the wallet; '
        'checking the code again says why', (tester) async {
      init(balances: const {0: 0});
      final c = code(63);
      shader.addBatch([c], 0, g(3000000), gas: gas, by: v3Other);
      await pumpBeamPage(tester, claimView());
      await tester.enterText(find.byKey(const ValueKey('claim-code-field')), c);
      await tester.pumpAndSettle();
      // A BEAM code with its fee paid: +0.03 + 0.022 - 0.021.
      expect(_textOf(tester, 'claim-total'), '+0.031 BEAM');
      await tester.tap(find.byKey(const ValueKey('claim-cta')));
      await tester.pumpAndSettle();

      // Someone else's claim of the same code was mined first.
      shader.vouchers[AirdropV3Code.voucherKey(c)]!.redeemed = true;
      txState = {'status': 4};
      await tester.pump(BeamClaimVoucherView.pollEvery);
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'claim-done'), 'The claim did not go through');
      expect(
        _textOf(tester, 'claim-done-message'),
        startsWith('Nothing left your wallet.'),
      );
      await expectScreen(tester, 'v3_claim_failed');

      await tester.tap(find.byKey(const ValueKey('claim-done-again')));
      await tester.pumpAndSettle();
      expect(find.text('This voucher was already claimed'), findsOneWidget);
    });
  });

  group('a new batch', () {
    Future<void> openCodes(
      WidgetTester tester,
      String localId, {
      bool desktop = false,
      bool justCreated = true,
    }) => pumpBeamPage(
      tester,
      BeamAirdropCodesView(
        service: service,
        localId: localId,
        assetNames: names,
        justCreated: justCreated,
        sync: sync,
        authorize: auth.authorizer,
      ),
      desktop: desktop,
    );

    Future<AirdropSavedBatch> sent({
      int assetId = 36,
      int n = 3,
      int value = 20000000,
      bool prepay = true,
    }) async {
      // The fake wallet answers at once: no real I/O under the fake clock.
      final p = await service.prepareCreateBatch(
        assetId: assetId,
        values: List.filled(n, g(value)),
        prepayClaimFees: prepay,
      );
      await service.execute(p);
      return (await store.all()).single;
    }

    testWidgets('a bETH batch with claim fees paid: the form adds every fee '
        'up; turning the fees off takes them out', (tester) async {
      init(balances: const {0: 66707641121, 36: 1000000000});
      await pumpBeamPage(
        tester,
        BeamCreateAirdropView(
          service: service,
          sync: sync,
          assetNames: names,
          authorize: auth.authorizer,
          initialAssetId: 36,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('create-amount')),
        '0.2',
      );
      await tester.enterText(find.byKey(const ValueKey('create-count')), '3');
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'create-locked'), '0.6 bETH');
      expect(_textOf(tester, 'create-fee'), '0.006 bETH');
      expect(_textOf(tester, 'create-gas'), '0.066 BEAM');
      expect(_textOf(tester, 'create-network-fee'), '0.0215 BEAM');
      expect(_textOf(tester, 'create-total'), '0.606 bETH + 0.0875 BEAM');
      expect(find.text(AirdropBearerText.createMessageV3), findsOneWidget);
      await expectScreen(tester, 'v3_create_form_beth');

      await tester.tap(find.byKey(const ValueKey('create-prepay-box')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-gas')), findsNothing);
      expect(_textOf(tester, 'create-total'), '0.606 bETH + 0.0215 BEAM');

      // 101 codes is more than a batch holds.
      await tester.enterText(find.byKey(const ValueKey('create-count')), '101');
      await tester.pumpAndSettle();
      expect(find.text('Choose 1 to 100 codes'), findsOneWidget);
      expect(_enabled(tester, 'create-cta'), isFalse);
      await tester.enterText(find.byKey(const ValueKey('create-count')), '100');
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'create-network-fee'), '0.3125 BEAM');
    });

    testWidgets('its codes stay hidden until the batch is confirmed and every '
        'code checked; then they are ready to share', (tester) async {
      init();
      FlagSecureScope.debugSetFlagSecure = (_) async {};
      FlagSecureScope.debugUserWantsSecure = () => false;
      addTearDown(() {
        FlagSecureScope.debugSetFlagSecure = null;
        FlagSecureScope.debugUserWantsSecure = null;
      });
      final b = await sent();
      await openCodes(tester, b.localId);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('codes-sent')), findsOneWidget);
      expect(find.byKey(const ValueKey('codes-steps')), findsOneWidget);
      expect(_textOf(tester, 'codes-step-1-note'), '0 of 3');
      expect(find.byKey(const ValueKey('code-0')), findsNothing);
      expect(find.byKey(const ValueKey('codes-copy-all')), findsNothing);
      expect(FlagSecureScope.activeCount, 0);
      await expectScreen(tester, 'v3_codes_waiting');

      shader.mine(shader.pending!);
      txState = {'status': 3, 'confirmations': 1};
      await tester.pump(BeamAirdropCodesView.checkEvery);
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'codes-step-1-note'), '1 of 3');
      expect(find.byKey(const ValueKey('code-0')), findsNothing);

      txState = {'status': 3, 'confirmations': 3};
      await tester.pump(BeamAirdropCodesView.checkEvery);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('codes-ready')), findsOneWidget);
      expect(find.byKey(const ValueKey('codes-copy-all')), findsOneWidget);
      expect(FlagSecureScope.activeCount, 1);
      final saved = (await store.all()).single;
      expect(saved.check!.ok, isTrue);
      for (var i = 0; i < 3; i++) {
        expect(
          tester.widget<Text>(find.byKey(ValueKey('code-$i'))).data,
          saved.codes[i].code,
        );
      }
      await expectScreen(tester, 'v3_codes_ready');
    });

    testWidgets('desktop: waiting for the network', (tester) async {
      init();
      final b = await sent();
      shader.mine(shader.pending!);
      txState = {'status': 3, 'confirmations': 2};
      await openCodes(tester, b.localId, desktop: true);
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'codes-step-1-note'), '2 of 3');
      await expectScreen(tester, 'desktop_v3_codes_waiting');
    });

    testWidgets('a copied batch: "Do not share these codes", the funds are '
        'safe, new codes for the same airdrop in one tap', (tester) async {
      init(balances: const {0: 66707641121, 36: 1000000000});
      final b = await sent();
      // Someone copied the keys into their own batch with 1 groth each,
      // and it was mined; ours too.
      final p = shader.pending!;
      shader.mine((
        creator: v3Other,
        assetId: p.assetId,
        gas: BigInt.zero,
        entries: [for (final e in p.entries) (key: e.key, value: BigInt.one)],
      ));
      txState = {'status': 3, 'confirmations': 9};
      await openCodes(tester, b.localId, justCreated: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('codes-check-failed')), findsOneWidget);
      expect(find.text('Do not share these codes'), findsOneWidget);
      expect(
        find.textContaining(
          'A code holds a different amount than this batch locked.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('take this batch back'), findsOneWidget);
      expect(find.byKey(const ValueKey('code-0')), findsNothing);
      expect(find.text('Take the batch back'), findsOneWidget);
      await expectScreen(tester, 'v3_codes_check_failed');

      await tester.tap(find.byKey(const ValueKey('codes-make-new')));
      await tester.pumpAndSettle();
      expect(find.byType(BeamCreateAirdropView), findsOneWidget);
      expect(_textOf(tester, 'create-locked'), '0.6 bETH');
      expect(_textOf(tester, 'create-gas'), '0.066 BEAM');
    });

    testWidgets('a copied batch whose own transaction this wallet does not '
        'know: never "nothing was locked", it points to My batches (release '
        'audit 1.3.0)', (tester) async {
      init(balances: const {0: 66707641121, 36: 1000000000});
      final b = await sent();
      final p = shader.pending!;
      shader.mine((
        creator: v3Other,
        assetId: p.assetId,
        gas: BigInt.zero,
        entries: [for (final e in p.entries) (key: e.key, value: BigInt.one)],
      ));
      // The history lost it (restored from the seed, say): whether ours
      // went into a block is not known.
      t.reply(
        'tx_status',
        const BeamRpcException(-32001, 'Transaction not found'),
      );
      await openCodes(tester, b.localId, justCreated: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('codes-check-failed')), findsOneWidget);
      expect(
        find.textContaining('Your funds are safe: nothing was locked.'),
        findsNothing,
      );
      expect(
        find.textContaining('if this batch is in My batches, take it back'),
        findsOneWidget,
      );
      expect(find.text('My batches'), findsOneWidget);
      expect(find.text('Take the batch back'), findsNothing);
      await expectScreen(tester, 'v3_codes_check_failed_unknown_tx');

      // Known never to have gone into a block: then it says so.
      await tester.pumpWidget(const SizedBox());
      final saved = (await store.all()).single;
      expect(saved.check!.ok, isFalse);
      await store.put(saved.copyWith(txStatus: AirdropBatchTxStatus.failed));
      await openCodes(tester, b.localId, justCreated: false);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your funds are safe: nothing was locked.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('if this batch is in My batches'),
        findsNothing,
      );
    });

    testWidgets('a create the network turned down: these codes hold nothing', (
      tester,
    ) async {
      init();
      final b = await sent();
      txState = {'status': 4};
      await openCodes(tester, b.localId, justCreated: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('codes-not-sent')), findsOneWidget);
      expect(find.textContaining('The network turned it down'), findsOneWidget);
      expect(find.byKey(const ValueKey('code-0')), findsNothing);
      await expectScreen(tester, 'v3_codes_not_sent');
    });
  });

  group('my batches', () {
    Widget batches() => BeamAirdropBatchesView(
      service: service,
      sync: sync,
      assetNames: names,
      authorize: auth.authorizer,
      clock: () => DateTime.utc(2026, 10, 14, 12),
    );

    Future<List<String>> v3Batch() async {
      final codes = [code(71), code(72), code(73)];
      final id = shader.addBatch(codes, 36, g(20000000), gas: gas);
      shader.vouchers[AirdropV3Code.voucherKey(codes.first)]!.redeemed = true;
      await store.put(
        AirdropSavedBatch(
          localId: 'batch_v3',
          contractId: kAirdropV3ContractId,
          assetId: 36,
          createdAt: DateTime.utc(2026, 10, 14),
          txId: 'ab' * 16,
          txStatus: AirdropBatchTxStatus.confirmed,
          gasPerVoucher: gas,
          creatorKey: v3Creator,
          batchId: id,
          check: AirdropCodeCheck(
            state: AirdropCheckState.ok,
            at: DateTime.utc(2026, 10, 14, 0, 5),
          ),
          codes: [
            for (final c in codes)
              AirdropSavedCode(
                code: c,
                hashHex: AirdropVoucherCode.hashHex(c),
                value: g(20000000),
                key: AirdropV3Code.voucherKey(c),
                status: AirdropCodeStatus.available,
              ),
          ],
        ),
      );
      return codes;
    }

    testWidgets('a v3 batch with its claim fees paid: counts from the '
        'contract; taking back returns the values and the fees', (
      tester,
    ) async {
      init();
      txState = {'status': 3, 'confirmations': 9};
      await v3Batch();
      // And one made elsewhere, before checking: matched by nothing here.
      shader.addBatch([code(74)], 0, g(10000000));
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();
      expect(find.text('1 of 3 claimed · 2 waiting'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-gas-1')), findsOneWidget);
      expect(
        _textOf(tester, 'batch-fee-v3-1'),
        'Network fee to take back: 0.011 BEAM',
      );
      expect(
        find.byKey(const ValueKey('batch-codes-batch_v3')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('batch-cancel-v3-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-cancel-v3-2')), findsOneWidget);
      await expectScreen(tester, 'v3_batches');

      await tester.tap(find.byKey(const ValueKey('batch-cancel-v3-1')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'confirm-returned'), '0.4 bETH + 0.044 BEAM');
      expect(_textOf(tester, 'confirm-network-fee'), '0.011 BEAM');
      expect(_textOf(tester, 'confirm-total'), '+0.4 bETH, +0.033 BEAM');
      expect(find.text('Get back 0.4 bETH + 0.044 BEAM'), findsOneWidget);
      await expectScreen(tester, 'v3_cancel_confirm');

      txState = {'status': 1};
      await tester.tap(find.byKey(const ValueKey('airdrop-confirm-cta')));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(find.text('Take-back sent'), findsOneWidget);
      expect(service.isBusy, isFalse);

      // A code was claimed before the take-back was mined: it fails.
      txState = {'status': 4};
      await tester.pump(BeamAirdropBatchesView.pollEvery);
      await tester.pumpAndSettle();
      expect(find.text('The take-back did not go through'), findsOneWidget);
      expect(find.textContaining('take back what is left now'), findsOneWidget);
      await expectScreen(tester, 'v3_batches_takeback_failed');
    });

    testWidgets('a v3 batch that was never created can be removed from the '
        'list once its codes are checked; a live one never', (tester) async {
      init();
      await v3Batch();
      final c = code(81);
      await store.put(
        AirdropSavedBatch(
          localId: 'batch_v3_failed',
          contractId: kAirdropV3ContractId,
          assetId: 0,
          createdAt: DateTime.utc(2026, 10, 13),
          txStatus: AirdropBatchTxStatus.failed,
          gasPerVoucher: gas,
          creatorKey: v3Creator,
          codes: [
            AirdropSavedCode(
              code: c,
              hashHex: AirdropVoucherCode.hashHex(c),
              value: g(1000000),
              key: AirdropV3Code.voucherKey(c),
            ),
          ],
        ),
      );
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();
      expect(find.text('Not created — nothing was locked'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('batch-forget-batch_v3_failed')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('batch-forget-batch_v3')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('batch-forget-batch_v3_failed')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect((await store.all()).map((b) => b.localId), ['batch_v3']);
    });

    testWidgets('a code claimed while the take-back is prepared: nothing is '
        'sent, the batch is read again', (tester) async {
      init();
      final codes = await v3Batch();
      await pumpBeamPage(tester, batches());
      await tester.pumpAndSettle();
      shader.beforeAnswer = (a) {
        if (a['action'] == 'cancel_batch') {
          shader.vouchers[AirdropV3Code.voucherKey(codes[1])]!.redeemed = true;
        }
      };
      await tester.tap(find.byKey(const ValueKey('batch-cancel-v3-1')));
      await tester.pumpAndSettle();
      shader.beforeAnswer = null;
      expect(find.byType(BeamAirdropBatchesView), findsOneWidget);
      expect(find.text('Some codes were just claimed'), findsOneWidget);
      expect(
        find.text('Take back 1 unclaimed', findRichText: true),
        findsOneWidget,
      );
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(service.isBusy, isFalse);
    });
  });
}
