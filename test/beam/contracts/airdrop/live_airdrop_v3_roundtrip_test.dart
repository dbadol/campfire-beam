/*
 * This file is part of Campfire for BEAM.
 *
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 */

// LIVE, real funds (tiny): one Airdrop v3 round trip on mainnet through
// BeamAirdropV3Service, the service the airdrop screens use:
//
//   1. the creator makes a batch of TWO codes worth 0.002 BEAM each, with
//      their claim fees paid ahead;
//   2. the app checks the batch on the network (3 confirmations, then every
//      code) before it calls the codes ready to share;
//   3. a wallet holding NO BEAM claims one code (the prepaid fee pays it),
//      and a second claim of the same code is refused;
//   4. the creator takes the batch back: the unclaimed code and its prepaid
//      claim fee come back.
//
// Skipped unless BEAM_LIVE_AIRDROP_V3=1. Both wallets run in TCP mode
// (scripts/beam/live/wapi.py start <label> --tcp); labels BEAM_LIVE_CREATOR
// (default lwtest) and BEAM_LIVE_CLAIMER (default v3claim, an empty wallet).
//
// The codes are keys to the funds: never printed. They are written 0600 to
// ~/beam-campfire-test/airdrop_codes/ (outside the repo) before the batch is
// sent, so a failure never strands them.
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

import 'memory_code_store.dart';

final BigInt _value = BigInt.from(200000); // 0.002 BEAM per code
final BigInt _maxFee = BigInt.from(5000000); // 0.05 BEAM

String _b(BigInt g) => (g.toDouble() / 1e8).toStringAsFixed(8);
String _short(String s) => s.length <= 12 ? s : s.substring(0, 12);

Future<(BeamApi, TcpLineTransport)> _open(String label) async {
  final home = Platform.environment['HOME']!;
  final state = jsonDecode(
    File('$home/beam-campfire-test/run/$label.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final t = TcpLineTransport(
    port: state['port']! as int,
    aclKey: state['key']! as String,
    log: (_) {},
  );
  await t.connect();
  return (BeamApi(t), t);
}

Future<BeamTransaction> _waitDone(BeamApi api, String txId) async {
  final sw = Stopwatch()..start();
  while (true) {
    final tx = await api.txStatus(txId);
    if (tx.status == BeamTxStatus.completed ||
        tx.status == BeamTxStatus.failed ||
        tx.status == BeamTxStatus.canceled) {
      print(
        '[evidence] tx ${_short(txId)} ${tx.statusString} at height '
        '${tx.height} after ${sw.elapsed.inSeconds} s',
      );
      return tx;
    }
    if (sw.elapsed > const Duration(minutes: 20)) {
      fail('tx ${_short(txId)} not done after 20 min: ${tx.statusString}');
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
}

void main() {
  final enabled = Platform.environment['BEAM_LIVE_AIRDROP_V3'] == '1';

  test('create two prepaid codes, check them, claim one from an empty wallet, '
      'take the rest back', () async {
    final env = Platform.environment;
    final (creatorApi, creatorT) = await _open(
      env['BEAM_LIVE_CREATOR'] ?? 'lwtest',
    );
    final (claimerApi, claimerT) = await _open(
      env['BEAM_LIVE_CLAIMER'] ?? 'v3claim',
    );
    final shader = airdropV3AppShader(
      const FileShaderSource('assets/beam/shaders'),
    );
    final store = MemoryCodeStore();
    final creator = BeamAirdropV3Service(creatorApi, shader, store: store);
    final claimer = BeamAirdropV3Service(claimerApi, shader);

    for (final api in [creatorApi, claimerApi]) {
      final s = await api.walletStatus();
      expect(s.isInSync, isTrue, reason: 'never call contracts out of sync');
    }
    final empty = await claimerApi.walletStatus();
    print(
      '[evidence] claimer starts with '
      '${_b(empty.available ?? BigInt.zero)} BEAM',
    );

    // --- 1. create ---
    final create = await creator.prepareCreateBatch(
      assetId: 0,
      values: [_value, _value],
    );
    final codes = create.saved!.codes.map((c) => c.code).toList();
    final dir = Directory('${env['HOME']}/beam-campfire-test/airdrop_codes')
      ..createSync(recursive: true);
    final keep = File(
      '${dir.path}/v3-${DateTime.now().toUtc().millisecondsSinceEpoch}.txt',
    )..writeAsStringSync('${codes.join('\n')}\n');
    await Process.run('chmod', ['600', keep.path]);
    final c = create.summary;
    print(
      '[evidence] create built: pays '
      '${c.pays.map((k, v) => MapEntry(k, _b(v)))}, creation fee '
      '${_b(c.creationFee!)}, claim fees ${_b(c.claimFees)}, network fee '
      '${_b(c.networkFee)} BEAM',
    );
    expect(c.pays[0], _value * BigInt.two + c.creationFee! + c.claimFees);
    expect(c.networkFee, AirdropV3Fee.create(2));
    expect(c.networkFee <= _maxFee, isTrue);
    final createTx = await creator.execute(create);
    final created = await _waitDone(creatorApi, createTx);
    expect(created.status, BeamTxStatus.completed);

    // --- 2. checked on the network before the codes are shared ---
    final localId = create.saved!.localId;
    final sw = Stopwatch()..start();
    AirdropV3Verdict v;
    while (true) {
      v = await creator.verifyBatch(localId);
      print(
        '[evidence] check after ${sw.elapsed.inSeconds} s: ${v.state.name}'
        ', confirmations ${v.confirmations}',
      );
      if (v.state == AirdropV3BatchState.ready ||
          v.state == AirdropV3BatchState.failed) {
        break;
      }
      if (sw.elapsed > const Duration(minutes: 20)) {
        fail('the batch was not checked within 20 min: ${v.state.name}');
      }
      await Future<void>.delayed(const Duration(seconds: 20));
    }
    expect(v.state, AirdropV3BatchState.ready, reason: '${v.problem}');
    final batchId = v.batch.batchId!;

    // --- 3. claim from a wallet holding no BEAM ---
    final info = await claimer.checkVoucher(codes.first);
    expect(info, isNotNull);
    expect(info!.value, _value);
    expect(info.redeemed, isFalse);
    expect(info.gas > BigInt.zero, isTrue, reason: 'its claim fee is paid');
    final redeem = await claimer.prepareRedeem(codes.first);
    final r = redeem.summary;
    print(
      '[evidence] claim built: receives '
      '${r.receives.map((k, v) => MapEntry(k, _b(v)))}, network fee '
      '${_b(r.networkFee)} BEAM (paid by the code)',
    );
    final claimTx = await claimer.execute(redeem);
    final claimed = await _waitDone(claimerApi, claimTx);
    expect(claimed.status, BeamTxStatus.completed);
    final after = await claimer.checkVoucher(codes.first);
    expect(after!.redeemed, isTrue);
    final s2 = await claimerApi.walletStatus();
    print(
      '[evidence] claimer now has ${_b(s2.available ?? BigInt.zero)} BEAM '
      '(was ${_b(empty.available ?? BigInt.zero)})',
    );
    await expectLater(
      claimer.prepareRedeem(codes.first),
      throwsA(isA<BeamAirdropException>()),
      reason: 'a code works once',
    );
    print('[evidence] a second claim of the same code is refused');

    // --- 4. take the rest back ---
    final cancel = await creator.prepareCancelBatch(batchId);
    final k = cancel.summary;
    print(
      '[evidence] take-back built: receives '
      '${k.receives.map((key, val) => MapEntry(key, _b(val)))}, network fee '
      '${_b(k.networkFee)} BEAM',
    );
    final cancelTx = await creator.execute(cancel);
    final cancelled = await _waitDone(creatorApi, cancelTx);
    expect(cancelled.status, BeamTxStatus.completed);
    final left = await claimer.checkVoucher(codes.last);
    print(
      '[evidence] the unclaimed code now reads: '
      '${left == null ? 'gone' : (left.redeemed ? 'taken' : 'open')}',
    );
    expect(left == null || left.redeemed, isTrue);
    keep.deleteSync();
    await creatorT.close();
    await claimerT.close();
  }, skip: enabled ? null : 'set BEAM_LIVE_AIRDROP_V3=1 to run');
}
