/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamAirdropV3Service and BeamAirdrops over a fake wallet-api whose
// invoke_contract is answered like the pinned app shaders of both airdrop
// contracts (airdrop_v3_fixtures.dart, airdrop_fixtures.dart). Every built
// transaction is checked byte for byte; a tampered build is never sent.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'airdrop_fixtures.dart';
import 'airdrop_v3_fixtures.dart';
import 'invoke_data_writer.dart';
import 'memory_code_store.dart';

Matcher _code(AirdropErrorCode c) =>
    throwsA(isA<BeamAirdropException>().having((e) => e.code, 'code', c));

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  const g = BigInt.from;
  final gas = kAirdropV3GasPerVoucher;
  late FakeAirdropShader oldShader;
  late FakeAirdropV3Shader shader;
  late FakeTransport t;
  late List<String> log;
  late MemoryCodeStore store;
  late AirdropFlowLock lock;
  late BeamAirdropV3Service v3;
  late BeamAirdropService old;
  late BeamAirdrops both;
  late Map<String, Object?> txStatus;
  late Object? sendReply;

  setUp(() {
    log = [];
    oldShader = FakeAirdropShader();
    shader = FakeAirdropV3Shader();
    store = MemoryCodeStore(log);
    txStatus = {'status': 1};
    sendReply = null;
    t = FakeTransport({
      'invoke_contract': airdropRouter(oldShader, shader),
      'process_invoke_data': (Map<String, Object?> p) {
        log.add('sent');
        final r = sendReply;
        if (r is Exception) throw r;
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
        ...txStatus,
      },
    });
    lock = AirdropFlowLock();
    v3 = BeamAirdropV3Service(
      BeamApi(t),
      airdropV3AppShader(const FileShaderSource('assets/beam/shaders')),
      store: store,
      lock: lock,
      random: Random(3),
      clock: () => DateTime.utc(2026, 10, 14, 12),
    );
    old = BeamAirdropService(
      BeamApi(t),
      airdropAppShader(const FileShaderSource('assets/beam/shaders')),
      store: store,
      lock: lock,
      random: Random(4),
    );
    both = BeamAirdrops(old: old, v3: v3);
  });

  Future<AirdropSavedBatch> savedOne() async => (await store.all()).single;

  group('create', () {
    test('v3 only: keys derived here equal the built ones, prepaid claim '
        'fees locked, codes saved first with their keys and the creator '
        'key', () async {
      final p = await both.prepareCreateBatch(
        assetId: 36,
        values: [g(100000), g(100000), g(100000)],
      ) as BeamPreparedAirdropV3Call;
      expect(p.contract, AirdropContract.v3);
      final s = p.summary;
      expect(s.contract, AirdropContract.v3);
      expect(s.pays, {36: g(303000), 0: g(6600000)});
      expect(s.receives, isEmpty);
      expect(s.creationFee, g(3000));
      expect(s.claimFees, g(6600000));
      expect(s.gasPerVoucher, gas);
      expect(s.networkFee, AirdropV3Fee.create(3));
      expect(s.networkFee, g(2150000));
      expect(s.beamOut, g(6600000 + 2150000));
      expect(p.invoke.entries.single.contractId, kAirdropV3ContractId);
      // Nothing saved or sent by preparing.
      expect(log, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      final saved = p.saved!;
      expect(saved.creatorKey, v3Creator);
      expect(saved.gasPerVoucher, gas);
      for (final c in saved.codes) {
        expect(
          RegExp(r'^([A-HJ-NP-Z2-9]{4}-){3}[A-HJ-NP-Z2-9]{4}$')
              .hasMatch(c.code),
          isTrue,
        );
        expect(c.key, AirdropV3Code.voucherKey(c.code));
        expect(c.hashHex, AirdropVoucherCode.hashHex(c.code));
      }
      // The shader got seeds, never codes; the transaction carries keys,
      // never seeds or codes.
      final args = shader.seen.last;
      for (final c in saved.codes) {
        final norm = AirdropV3Code.normalise(c.code);
        expect(args, isNot(contains(norm)));
        expect(args, contains(_hex(AirdropV3Code.seed(c.code))));
        expect(_contains(p.rawData, AirdropV3Code.seed(c.code)), isFalse);
        expect(_contains(p.rawData, ascii.encode(norm)), isFalse);
        expect(_hex(p.rawData), contains(c.key));
      }
      // Execute: written, read back, then sent; then the tx id.
      final tx = await both.execute(p);
      expect(tx, 'cd' * 16);
      expect(log, ['put unconfirmed', 'sent', 'put broadcast']);
      final rec = await savedOne();
      expect(rec.isV3, isTrue);
      expect(rec.creatorKey, v3Creator);
      expect(rec.txId, 'cd' * 16);
      expect(rec.check, isNull);
      expect(both.isBusy, isFalse);
    });

    test('without prepaid fees no BEAM is locked for a token; a BEAM batch '
        'locks one sum; 1 to 100 codes', () async {
      final off = await v3.prepareCreateBatch(
        assetId: 36,
        values: [g(5)],
        prepayClaimFees: false,
      );
      expect(off.summary.pays, {36: g(6)});
      expect(off.summary.claimFees, BigInt.zero);
      expect(shader.seen.last, contains(',gas_per_voucher=0,'));
      v3.discard(off);
      final beam = await v3.prepareCreateBatch(
        assetId: 0,
        values: [g(1000000), g(1000000)],
      );
      expect(beam.summary.pays, {0: g(2000000 + 20000 + 4400000)});
      v3.discard(beam);
      final hundred = await v3.prepareCreateBatch(
        assetId: 36,
        values: List.filled(100, BigInt.one),
      );
      expect(hundred.saved!.codes, hasLength(100));
      expect({for (final c in hundred.saved!.codes) c.key}, hasLength(100));
      expect(hundred.summary.networkFee, g(31250000));
      v3.discard(hundred);
      await expectLater(
        v3.prepareCreateBatch(
          assetId: 36,
          values: List.filled(101, BigInt.one),
        ),
        throwsArgumentError,
      );
      await expectLater(
        v3.prepareCreateBatch(assetId: 36, values: []),
        throwsArgumentError,
      );
      await expectLater(
        v3.prepareCreateBatch(
          assetId: 0,
          values: [(BigInt.one << 63) - BigInt.one],
        ),
        throwsArgumentError,
      );
      expect(v3.isBusy, isFalse);
    });

    test('a build that differs from the request in any way is never sent, '
        'and nothing is saved', () async {
      const keyAt = 49; // creator 33 + asset 4 + count 4 + gas 8
      final other = InvokeDataWriter.hexBytes(v3Other);
      final cases = <String, FakeInvokeEntry Function(FakeInvokeEntry)>{
        'another contract': (e) => changed(e, cid: 'ee' * 32),
        'the old contract': (e) => changed(e, cid: kAirdropContractId),
        'another method': (e) => changed(e, method: 3),
        'another voucher key': (e) => withArgs(e, [
          ...e.args.sublist(0, keyAt),
          ...other,
          ...e.args.sublist(keyAt + 33),
        ]),
        'another value': (e) => withArgs(e, [
          ...e.args.sublist(0, keyAt + 33),
          ...InvokeDataWriter.le(g(100001), 8),
          ...e.args.sublist(keyAt + 41),
        ]),
        'no prepaid fee in the args': (e) => withArgs(e, [
          ...e.args.sublist(0, 41),
          ...InvokeDataWriter.le(BigInt.zero, 8),
          ...e.args.sublist(49),
        ]),
        'another asset in the args': (e) => withArgs(e, [
          ...e.args.sublist(0, 33),
          ...InvokeDataWriter.le(g(37), 4),
          ...e.args.sublist(37),
        ]),
        'more locked': (e) => changed(
          e,
          funds: {for (final f in e.funds.entries) f.key: f.value + BigInt.one},
        ),
        'the prepaid fees not locked': (e) => changed(
          e,
          funds: {
            for (final f in e.funds.entries)
              if (f.key != 0) f.key: f.value,
          },
        ),
        'another asset as well': (e) =>
            changed(e, funds: {...e.funds, 7: BigInt.one}),
        'a different BVM charge': (e) => changed(e, charge: e.charge + 1),
        'the old contract\'s charge': (e) => changed(e, charge: 1200000),
        'another kernel comment': (e) =>
            changed(e, comment: 'Redeem airdrop voucher'),
        'two signing keys': (e) =>
            changed(e, sigs: [e.sigs.first, e.sigs.first]),
        'another signing key': (e) => changed(
          e,
          sigs: [
            InvokeDataWriter.hexBytes(AirdropV3SigningKeys.claimer(v3Other)),
          ],
        ),
      };
      for (final entry in cases.entries) {
        shader = FakeAirdropV3Shader();
        t.reply('invoke_contract', airdropRouter(oldShader, shader));
        shader.tamper = entry.value;
        await expectLater(
          v3.prepareCreateBatch(assetId: 36, values: [g(100000), g(100000)]),
          _code(AirdropErrorCode.unexpectedTransaction),
          reason: entry.key,
        );
        expect(v3.isBusy, isFalse, reason: entry.key);
      }
      // The shader reports other totals than the request.
      shader = FakeAirdropV3Shader()
        ..outputTamper = (o) => {...o, 'gas_total': 0};
      t.reply('invoke_contract', airdropRouter(oldShader, shader));
      await expectLater(
        v3.prepareCreateBatch(assetId: 36, values: [g(100000)]),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(await store.all(), isEmpty);
    });

    test('codes that cannot be saved are never sent; a refusal by the core '
        'marks them never sent; a timeout leaves them unconfirmed', () async {
      var p = await v3.prepareCreateBatch(assetId: 36, values: [g(1)]);
      store.failNextPut = StateError('disk full');
      await expectLater(v3.execute(p), _code(AirdropErrorCode.codesNotSaved));
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(v3.isBusy, isFalse);

      p = await v3.prepareCreateBatch(assetId: 36, values: [g(1)]);
      sendReply = const BeamRpcException(-32603, 'Missing 0.0155 BEAM');
      await expectLater(v3.execute(p), throwsA(isA<BeamRpcException>()));
      var rec = (await store.all()).firstWhere(
        (b) => b.localId == p.saved!.localId,
      );
      expect(rec.txStatus, AirdropBatchTxStatus.failed);

      p = await v3.prepareCreateBatch(assetId: 36, values: [g(1)]);
      sendReply = const SocketException('timed out');
      await expectLater(v3.execute(p), throwsA(isA<SocketException>()));
      rec = (await store.all()).firstWhere(
        (b) => b.localId == p.saved!.localId,
      );
      expect(rec.txStatus, AirdropBatchTxStatus.unconfirmed);
      expect(rec.txId, isNull);
      // A prepared call is sent at most once.
      await expectLater(v3.execute(p), _code(AirdropErrorCode.alreadyExecuted));
    });
  });

  group('the check before sharing, through the service', () {
    Future<AirdropSavedBatch> created({
      int assetId = 36,
      List<int> values = const [100000, 100000],
      bool prepay = true,
    }) async {
      final p = await v3.prepareCreateBatch(
        assetId: assetId,
        values: [for (final v in values) g(v)],
        prepayClaimFees: prepay,
      );
      await v3.execute(p);
      return (await store.all()).firstWhere(
        (b) => b.localId == p.saved!.localId,
      );
    }

    test('waits for 3 confirmations, then checks every code and saves the '
        'verdict once', () async {
      final b = await created();
      expect(
        (await v3.verifyBatch(b.localId)).state,
        AirdropV3BatchState.waiting,
      );
      shader.mine(shader.pending!);
      txStatus = {'status': 3, 'confirmations': 2};
      final w = await v3.verifyBatch(b.localId);
      expect((w.state, w.confirmations), (AirdropV3BatchState.waiting, 2));
      expect(shader.seen.where((a) => a.contains('check_voucher')), isEmpty);
      txStatus = {'status': 3, 'confirmations': 3};
      final progress = <String>[];
      final r = await v3.verifyBatch(
        b.localId,
        onProgress: (d, n) => progress.add('$d/$n'),
      );
      expect(r.state, AirdropV3BatchState.ready);
      expect(progress, ['0/2', '1/2', '2/2']);
      expect(
        shader.seen.where((a) => a.contains('check_voucher')),
        hasLength(2),
      );
      final saved = await savedOne();
      expect(saved.check!.ok, isTrue);
      expect(saved.batchId, BigInt.one);
      expect(saved.txStatus, AirdropBatchTxStatus.confirmed);
      expect(
        saved.codes.every((c) => c.status == AirdropCodeStatus.available),
        isTrue,
      );
      final n = shader.seen.length;
      expect(
        (await v3.verifyBatch(b.localId)).state,
        AirdropV3BatchState.ready,
      );
      expect(shader.seen.length, n, reason: 'a checked batch is not re-run');
    });

    test(
      'confirmations from the tip when the core gives none, counted as '
      'the core counts them: tip - proof height (release audit 1.3.0)',
      () async {
        final b = await created();
        shader.mine(shader.pending!);
        txStatus = {'status': 3, 'height': 3677099}; // the tip itself: 0
        expect((await v3.verifyBatch(b.localId)).confirmations, 0);
        txStatus = {'status': 3, 'height': 3677098}; // tip 3677099: 1
        expect((await v3.verifyBatch(b.localId)).confirmations, 1);
        txStatus = {'status': 3, 'height': 3677097};
        final w = await v3.verifyBatch(b.localId);
        expect((w.state, w.confirmations), (AirdropV3BatchState.waiting, 2));
        txStatus = {'status': 3, 'height': 3677096};
        expect(
          (await v3.verifyBatch(b.localId)).state,
          AirdropV3BatchState.ready,
        );
        expect(airdropV3Confirmations(blockHeight: 10, tip: 9), 0);
        expect(airdropV3Confirmations(blockHeight: 10, tip: 10), 0);
        expect(airdropV3Confirmations(blockHeight: 10, tip: 13), 3);
      },
    );

    test(
      'a create the network turned down holds nothing; a squatted batch '
      'fails the check and stays failed; another creator is notMine',
      () async {
        var b = await created(values: [100000]);
        txStatus = {'status': 4};
        var r = await v3.verifyBatch(b.localId);
        expect((r.state, r.onChain), (AirdropV3BatchState.notSent, true));
        expect((await savedOne()).txStatus, AirdropBatchTxStatus.failed);

        await store.delete(b.localId);
        txStatus = {'status': 3, 'confirmations': 5};
        b = await created();
        // The copycat's batch, made of our keys with 1 groth each, was mined
        // first; say our own was mined too (a node that lies about it).
        final p = shader.pending!;
        shader.mine((
          creator: v3Other,
          assetId: p.assetId,
          gas: BigInt.zero,
          entries: [for (final e in p.entries) (key: e.key, value: BigInt.one)],
        ));
        r = await v3.verifyBatch(b.localId);
        expect(r.state, AirdropV3BatchState.failed);
        expect(r.problem, AirdropCheckProblem.otherValue);
        expect(r.mined, isTrue);
        final saved = (await store.all()).firstWhere(
          (x) => x.localId == b.localId,
        );
        expect(saved.check!.state, AirdropCheckState.failed);
        expect(saved.check!.problem, AirdropCheckProblem.otherValue);
        expect(
          (await v3.verifyBatch(b.localId)).state,
          AirdropV3BatchState.failed,
          reason: 'never shown as ready afterwards',
        );

        // The copy with the right values and fee but another creator.
        shader = FakeAirdropV3Shader();
        t.reply('invoke_contract', airdropRouter(oldShader, shader));
        final c = await created(values: [100000]);
        final q = shader.pending!;
        shader.mine((
          creator: v3Other,
          assetId: q.assetId,
          gas: q.gas,
          entries: q.entries,
        ));
        expect(
          (await v3.verifyBatch(c.localId)).problem,
          AirdropCheckProblem.notMine,
        );
      },
    );

    test('a lookup that fails saves nothing and can be tried again; '
        'without a tx id, not found yet means waiting', () async {
      txStatus = {'status': 3, 'confirmations': 9};
      final b = await created(values: [100000]);
      shader.mine(shader.pending!);
      t.reply('invoke_contract', (Map<String, Object?> p) {
        if ((p['args']! as String).contains('check_voucher')) {
          throw const SocketException('node down');
        }
        return airdropRouter(oldShader, shader)(p);
      });
      await expectLater(v3.verifyBatch(b.localId), throwsA(anything));
      expect((await savedOne()).check, isNull);
      t.reply('invoke_contract', airdropRouter(oldShader, shader));
      expect(
        (await v3.verifyBatch(b.localId)).state,
        AirdropV3BatchState.ready,
      );

      // A record whose send timed out: no tx id. Not on the network yet is
      // not a verdict.
      await store.delete(b.localId);
      final p = await v3.prepareCreateBatch(assetId: 36, values: [g(5)]);
      sendReply = const SocketException('timed out');
      await expectLater(v3.execute(p), throwsA(anything));
      final rec = await savedOne();
      expect(rec.txId, isNull);
      expect(
        (await v3.verifyBatch(rec.localId)).state,
        AirdropV3BatchState.waiting,
      );
      expect((await savedOne()).check, isNull);
      // Once it shows up, it still waits its 3 confirmations, counted from
      // the block that holds it: the fake records created_at 4080000, the
      // height a contract reads in block 4080001 (release audit 1.3.0).
      shader.mine(shader.pending!);
      final status = Map<String, Object?>.of(
        (jsonDecode(
              File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
            ) as Map<String, Object?>)['result']!
            as Map<String, Object?>,
      );
      var tip = 4080001;
      t.reply(
        'wallet_status',
        (Map<String, Object?> _) => {...status, 'current_height': tip},
      );
      Future<(AirdropV3BatchState, int?)> verdict() async {
        final v = await v3.verifyBatch(rec.localId);
        return (v.state, v.confirmations);
      }

      expect(await verdict(), (AirdropV3BatchState.waiting, 0));
      tip = 4080001 + kAirdropV3ConfirmationsBeforeCheck - 1;
      expect(await verdict(), (
        AirdropV3BatchState.waiting,
        kAirdropV3ConfirmationsBeforeCheck - 1,
      ));
      expect((await savedOne()).check, isNull, reason: 'nothing saved');
      tip = 4080001 + kAirdropV3ConfirmationsBeforeCheck;
      expect((await verdict()).$1, AirdropV3BatchState.ready);
      expect((await savedOne()).check!.ok, isTrue);

      // The same when the core no longer knows the tx id it was sent with.
      await store.delete(rec.localId);
      sendReply = null;
      final q = await v3.prepareCreateBatch(assetId: 36, values: [g(6)]);
      await v3.execute(q);
      shader.mine(shader.pending!);
      t.reply(
        'tx_status',
        const BeamRpcException(-32001, 'Transaction not found'),
      );
      tip = 4080001;
      final lost = await savedOne();
      expect(lost.txId, isNotNull);
      final w = await v3.verifyBatch(lost.localId);
      expect((w.state, w.confirmations), (AirdropV3BatchState.waiting, 0));
      expect((await savedOne()).check, isNull);
    });

    test('an old-contract batch is not checked', () async {
      final p = await old.prepareCreateBatch(assetId: 0, values: [g(100000)]);
      await old.execute(p);
      expect(
        (await v3.verifyBatch(p.saved!.localId)).state,
        AirdropV3BatchState.old,
      );
    });
  });

  group('claim', () {
    const code = 'WXYZ-2345-6789-ABCD';

    test('the voucher key, a receiving key and a signature: never the code, '
        'its seed or its secret; the exact funds and the 0.021 fee; no fee '
        'passed, the pool never asked', () async {
      shader.addBatch([code], 36, g(500000000), gas: gas, by: v3Other);
      final p = await both.prepareRedeem(
        'wxyz 2345 6789 abcd',
      ) as BeamPreparedAirdropV3Call;
      expect(p.contract, AirdropContract.v3);
      final s = p.summary;
      expect(s.receives, {36: g(500000000), 0: gas});
      expect(s.pays, isEmpty);
      expect(s.networkFee, AirdropV3Fee.claim);
      expect(s.codePaysFee, isTrue);
      expect(s.beamNeeded, BigInt.zero);
      expect(s.assetAmount, g(500000000));
      final args = shader.seen.last;
      expect(args, endsWith(',code=WXYZ23456789ABCD,use_gas_pool=0'));
      expect(args, isNot(contains('fee')));
      expect(t.lastParams('invoke_contract').containsKey('fee'), isFalse);
      expect(_contains(p.rawData, ascii.encode('WXYZ23456789ABCD')), isFalse);
      final seed = AirdropV3Code.seed(code);
      expect(_contains(p.rawData, seed), isFalse);
      expect(_contains(p.rawData, AirdropV3Code.secret(seed)), isFalse);
      expect(
        p.invoke.entries.single.signatureKeyHashes.single,
        AirdropV3SigningKeys.claimer(AirdropV3Code.voucherKey(code)),
      );
      expect(await both.execute(p), 'cd' * 16);
      expect(await store.all(), isEmpty, reason: 'a claim saves nothing');

      shader.vouchers[AirdropV3Code.voucherKey(code)]!.redeemed = true;
      await expectLater(
        both.prepareRedeem(code),
        _code(AirdropErrorCode.alreadyRedeemed),
      );
      await expectLater(
        both.prepareRedeem('ZZZZ-ZZZZ-ZZZZ-ZZZZ'),
        _code(AirdropErrorCode.voucherNotFound),
      );
      await expectLater(
        both.prepareRedeem('----'),
        _code(AirdropErrorCode.invalidCode),
      );
      expect(both.isBusy, isFalse);
    });

    test('a token code without a prepaid fee needs 0.021 BEAM; a BEAM code '
        'worth more than the fee pays its own', () async {
      shader.addBatch([code], 36, g(100000));
      final p = await both.prepareRedeem(code);
      expect(p.summary.codePaysFee, isFalse);
      expect(p.summary.beamNeeded, g(2100000));
      expect(p.summary.receives, {36: g(100000)});
      both.discard(p);
      const beam = 'BEAM-BEAM-BEAM-BEAM';
      shader.addBatch([beam], 0, g(50000000));
      final q = await both.prepareRedeem(beam);
      expect(q.summary.beamNeeded, BigInt.zero);
      expect(q.summary.beamChange, g(50000000 - 2100000));
      both.discard(q);
    });

    test('a build that asks the pool, names another voucher, carries the '
        'code or moves other funds is never sent', () async {
      final codeBytes = ascii.encode('WXYZ23456789ABCD');
      final cases = <String, void Function(FakeAirdropV3Shader)>{
        'pool gas': (s) => s.pool = g(2500000),
        'another voucher key': (s) => s.tamper = (e) => withArgs(e, [
          ...InvokeDataWriter.hexBytes(v3Other),
          ...e.args.sublist(33),
        ]),
        'the code in the args': (s) => s.tamper = (e) => withArgs(e, [
          ...e.args.sublist(0, 74),
          ...codeBytes,
          ...e.args.sublist(74 + codeBytes.length),
        ]),
        'longer args': (s) => s.tamper = (e) => withArgs(e, [...e.args, 0]),
        'more paid out': (s) => s.tamper = (e) => changed(
          e,
          funds: {for (final f in e.funds.entries) f.key: f.value - BigInt.one},
        ),
        'the prepaid fee kept back': (s) => s.tamper = (e) => changed(
          e,
          funds: {
            for (final f in e.funds.entries)
              if (f.key != 0) f.key: f.value,
          },
        ),
        'the pool charge': (s) => s.tamper = (e) => changed(e, charge: 240000),
        'the old contract': (s) =>
            s.tamper = (e) => changed(e, cid: kAirdropContractId),
        'the creator key signs': (s) => s.tamper = (e) => changed(
          e,
          sigs: [InvokeDataWriter.hexBytes(AirdropV3SigningKeys.creator())],
        ),
      };
      for (final entry in cases.entries) {
        shader = FakeAirdropV3Shader();
        t.reply('invoke_contract', airdropRouter(oldShader, shader));
        shader.addBatch([code], 36, g(500000000), gas: gas, by: v3Other);
        entry.value(shader);
        await expectLater(
          both.prepareRedeem(code),
          _code(AirdropErrorCode.unexpectedTransaction),
          reason: entry.key,
        );
        expect(both.isBusy, isFalse, reason: entry.key);
      }
      // The node answers for another voucher than this code's: refused
      // before anything is built.
      shader = FakeAirdropV3Shader();
      t.reply('invoke_contract', airdropRouter(oldShader, shader));
      shader.addBatch([code], 36, g(1));
      final real = AirdropV3Code.voucherKey(code);
      shader.checkOverride = (c) => {
        'voucher': {
          'key': v3Other,
          'batch_id': 1,
          'asset_id': 36,
          'value': 1,
          'gas': 0,
          'redeemed': 0,
        },
      };
      expect(shader.vouchers.containsKey(real), isTrue);
      await expectLater(
        v3.prepareRedeem(code),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
      expect(shader.seen.where((a) => a.contains('action=redeem')), isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });
  });

  group('take back', () {
    test('exactly the unclaimed codes, their values and prepaid fees back, '
        'the fee for that many; a claim landing meanwhile is "changed"; '
        'tampered builds refused', () async {
      txStatus = {'status': 3, 'confirmations': 9};
      final p = await v3.prepareCreateBatch(
        assetId: 36,
        values: [g(100000), g(100000), g(100000)],
      );
      await v3.execute(p);
      final id = shader.mine(shader.pending!);
      final b = await savedOne();
      await v3.verifyBatch(b.localId);
      shader.vouchers[b.codes[0].key]!.redeemed = true;

      final c = await both.prepareCancelBatch(
        AirdropContract.v3,
        id,
      ) as BeamPreparedAirdropV3Call;
      expect(c.summary.voucherCount, 2);
      expect(c.summary.receives, {36: g(200000), 0: g(4400000)});
      expect(c.summary.claimFees, g(4400000));
      expect(c.summary.assetAmount, g(200000));
      expect(c.summary.networkFee, AirdropV3Fee.cancel(2));
      expect(c.summary.batchId, id);
      both.discard(c);

      // A claim lands while it is prepared: one code fewer than read.
      shader.beforeAnswer = (a) {
        if (a['action'] == 'cancel_batch') {
          shader.vouchers[b.codes[1].key]!.redeemed = true;
        }
      };
      await expectLater(
        both.prepareCancelBatch(AirdropContract.v3, id),
        _code(AirdropErrorCode.changed),
      );
      expect(both.isBusy, isFalse);
      shader.beforeAnswer = null;
      shader.vouchers[b.codes[1].key]!.redeemed = false;

      final other = InvokeDataWriter.hexBytes(v3Other);
      for (final tamper in <FakeInvokeEntry Function(FakeInvokeEntry)>[
        // Another creator key than the batch was built with.
        (e) => withArgs(e, [...other, ...e.args.sublist(33)]),
        // A voucher that is not one of this batch's codes.
        (e) => withArgs(e, [
          ...e.args.sublist(0, 45),
          ...other,
          ...e.args.sublist(78),
        ]),
        // The prepaid fees must come back too.
        (e) => changed(e, funds: {36: g(-200000)}),
        (e) => changed(e, charge: AirdropV3Charge.cancelBatch(3)),
        (e) => changed(
          e,
          sigs: [
            InvokeDataWriter.hexBytes(AirdropV3SigningKeys.claimer(v3Other)),
          ],
        ),
      ]) {
        shader.tamper = tamper;
        await expectLater(
          both.prepareCancelBatch(AirdropContract.v3, id),
          _code(AirdropErrorCode.unexpectedTransaction),
        );
      }
      shader.tamper = null;
      await expectLater(
        both.prepareCancelBatch(AirdropContract.v3, g(99)),
        _code(AirdropErrorCode.batchNotFound),
      );
      for (final x in b.codes) {
        shader.vouchers[x.key]!.redeemed = true;
      }
      await expectLater(
        both.prepareCancelBatch(AirdropContract.v3, id),
        _code(AirdropErrorCode.nothingToCancel),
      );
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(await store.all(), hasLength(1));
    });

    test('a truncated list: the batch is read with view_batch', () async {
      final id = shader.addBatch(
        ['AAAA-AAAA-AAAA-AAAA'],
        0,
        g(300000),
        gas: gas,
      );
      shader
        ..truncated = true
        ..listed = {};
      final c = await v3.prepareCancelBatch(id);
      expect(c.summary.receives, {0: g(300000) + gas});
      expect(shader.seen.any((a) => a.contains('action=view_batch')), isTrue);
      v3.discard(c);
    });

    test('the old contract\'s batches are taken back on it', () async {
      final h = AirdropVoucherCode.hashHex('OLDC-ODEO-LDCO-DEAA');
      oldShader.addBatch(g(41), 0, {h: g(20000000)});
      final c = await both.prepareCancelBatch(AirdropContract.v2, g(41));
      expect(c.contract, AirdropContract.v2);
      expect(c.summary.networkFee, kAirdropCancelFee);
      both.discard(c);
    });
  });

  group('both contracts', () {
    test('a code is looked up on v3 first, then the old contract; an error '
        'on v3 is never taken for "not there"', () async {
      const v3Code = 'VVVV-3333-VVVV-3333';
      const oldCode = 'OLDC-ODEO-LDCO-DEAA';
      shader.addBatch([v3Code], 36, g(5), gas: gas);
      oldShader.vouchers[AirdropVoucherCode.hashHex(oldCode)] = FakeVoucher(
        g(2),
        36,
        g(7),
      );
      final a = await both.checkVoucher(v3Code);
      expect((a!.contract, a.gas), (AirdropContract.v3, gas));
      expect(oldShader.seen, isEmpty, reason: 'found on v3: old not asked');
      final b = await both.checkVoucher(oldCode);
      expect(
        (b!.contract, b.gas, b.value),
        (AirdropContract.v2, BigInt.zero, g(7)),
      );
      expect(shader.seen.last, contains('check_voucher'));
      expect(oldShader.seen.last, contains('check_voucher'));
      expect(await both.checkVoucher('NOWH-EREN-OWHE-RE22'), isNull);

      // Claims go where the code is.
      final p = await both.prepareRedeem(oldCode);
      expect(p.contract, AirdropContract.v2);
      both.discard(p);
      final q = await both.prepareRedeem(v3Code);
      expect(q.contract, AirdropContract.v3);
      both.discard(q);

      // v3 cannot be reached: an error, never the old contract's answer.
      final asked = oldShader.seen.length;
      t.reply('invoke_contract', (Map<String, Object?> p) {
        final args = p['args']! as String;
        if (args.contains('cid=$kAirdropV3ContractId')) {
          return {
            'output': jsonEncode({
              'error':
                  'no Airdrop v3 contract at this cid (shader ID does not '
                  'match)',
            }),
          };
        }
        return oldShader(p);
      });
      await expectLater(
        both.checkVoucher(oldCode),
        _code(AirdropErrorCode.contractNotFound),
      );
      await expectLater(
        both.prepareRedeem(oldCode),
        _code(AirdropErrorCode.contractNotFound),
      );
      expect(oldShader.seen.length, asked);
      // A code longer than 64 letters is not a v3 code: v3 is not asked.
      t.reply('invoke_contract', airdropRouter(oldShader, shader));
      final n = shader.seen.length;
      expect(await both.checkVoucher('A' * 65), isNull);
      expect(shader.seen.length, n);
    });

    test('one airdrop transaction at a time, across both contracts', () async {
      final p = await both.prepareCreateBatch(assetId: 36, values: [g(1)]);
      expect(both.isBusy, isTrue);
      await expectLater(
        both.prepareRedeem('ABCD-EFGH-JKLM-NPQR'),
        _code(AirdropErrorCode.busy),
      );
      await expectLater(
        old.prepareRedeem('ABCD-EFGH-JKLM-NPQR'),
        _code(AirdropErrorCode.busy),
      );
      await expectLater(
        both.prepareCancelBatch(AirdropContract.v2, g(1)),
        _code(AirdropErrorCode.busy),
      );
      both.discard(p);
      expect(both.isBusy, isFalse);
      // A second create in the same frame finds the lock taken.
      final first = both.prepareCreateBatch(assetId: 36, values: [g(1)]);
      await expectLater(
        both.prepareCreateBatch(assetId: 36, values: [g(1)]),
        _code(AirdropErrorCode.busy),
      );
      both.discard(await first);
      expect(
        () => BeamAirdrops(
          old: old,
          v3: BeamAirdropV3Service(
            BeamApi(t),
            airdropV3AppShader(const FileShaderSource('assets/beam/shaders')),
            store: store,
          ),
        ),
        throwsArgumentError,
        reason: 'the two services must share one lock',
      );
      expect(
        () => BeamAirdropV3Service(
          BeamApi(t),
          airdropAppShader(const FileShaderSource('assets/beam/shaders')),
        ),
        throwsArgumentError,
        reason: 'only the v3 shader',
      );
    });

    test('saved batches of both contracts are listed; each is forgotten '
        'only when it holds nothing', () async {
      final o = await old.prepareCreateBatch(assetId: 0, values: [g(100000)]);
      await old.execute(o);
      final n = await v3.prepareCreateBatch(assetId: 36, values: [g(1)]);
      await v3.execute(n);
      final all = await both.savedBatches();
      expect(all.map((b) => b.isV3).toSet(), {true, false});
      // A v3 batch whose code is on the network cannot be forgotten.
      shader.mine(shader.pending!);
      txStatus = {'status': 3, 'confirmations': 9};
      final rec = all.firstWhere((b) => b.isV3);
      await expectLater(
        both.forgetSavedBatch(rec),
        _code(AirdropErrorCode.stillHoldsFunds),
      );
      // Claimed: settled, can go.
      shader.vouchers[rec.codes.single.key]!.redeemed = true;
      await both.forgetSavedBatch(rec);
      expect((await both.savedBatches()).where((b) => b.isV3), isEmpty);
    });
  });
}
