/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

import '../../api/beam_api.dart';
import '../../models/beam_call_results.dart';
import '../../models/beam_transaction.dart';
import '../../rpc/beam_transport.dart';
import '../common/contract_args.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'airdrop_v3_args.dart';
import 'airdrop_v3_constants.dart';
import 'airdrop_v3_keys.dart';
import 'airdrop_v3_models.dart';
import 'beam_airdrop_service.dart';
import 'voucher_code.dart';
import 'voucher_code_store.dart';

final _keyRe = RegExp(r'^[0-9a-f]{64}0[01]$');

/// The largest amount the core carries in a call's funds (signed 64-bit).
final _i64Max = (BigInt.one << 63) - BigInt.one;

/// An Airdrop v3 transaction built by the core and checked, not yet sent.
///
/// For a new batch, [saved] holds its codes, their voucher keys and the
/// creator key the build named. The codes are secret: they are shown only
/// once the check before sharing passed, and never logged.
class BeamPreparedAirdropV3Call implements AirdropPreparedCall {
  BeamPreparedAirdropV3Call._({
    required this.action,
    required this.args,
    required this.rawData,
    required this.invoke,
    required this.summary,
    this.saved,
  });

  @override
  final AirdropAction action;

  /// The shader args. For a claim they hold the normalised code: they go
  /// only to the app shader on this device, never into the transaction.
  final String args;
  final List<int> rawData;
  final BeamInvokeData invoke;
  @override
  final AirdropSummary summary;

  /// The record [BeamAirdropV3Service.execute] saves before broadcasting.
  final AirdropSavedBatch? saved;

  bool _executed = false;

  @override
  AirdropContract get contract => AirdropContract.v3;

  @override
  bool get isExecuted => _executed;

  @override
  String? get savedLocalId => saved?.localId;

  @override
  List<String> get codes =>
      saved == null ? const [] : [for (final c in saved!.codes) c.code];

  @override
  String toString() => 'BeamPreparedAirdropV3Call(${action.name})';
}

/// The result of the check before a new batch's codes are shared.
@immutable
class AirdropSquatCheck {
  const AirdropSquatCheck.ok(BigInt this.batchId)
    : problem = null,
      index = null;

  const AirdropSquatCheck.failed(AirdropCheckProblem this.problem, [this.index])
    : batchId = null;

  final BigInt? batchId;
  final AirdropCheckProblem? problem;

  /// The code (0-based) it stopped at, when it was one code.
  final int? index;

  bool get ok => problem == null;

  @override
  bool operator ==(Object other) =>
      other is AirdropSquatCheck &&
      other.batchId == batchId &&
      other.problem == problem &&
      other.index == index;

  @override
  int get hashCode => Object.hash(batchId, problem, index);

  @override
  String toString() => ok
      ? 'AirdropSquatCheck.ok($batchId)'
      : 'AirdropSquatCheck.failed(${problem!.name}, $index)';
}

/// The check before a new v3 batch's codes are shared (README "Checklist for
/// wallets" 11).
///
/// Someone who saw the pending create could copy its voucher keys into a
/// batch of their own with tiny values: the real create then fails, nobody
/// loses funds, but the codes point at the copy. So every code must be
/// found by `check_voucher` ([lookup]) with exactly the key derived on this
/// device, the asset, value and prepaid fee locked, all under one batch id,
/// and that batch must be one `view_my_batches` ([myBatches]) lists for this
/// wallet with this batch's count, asset and prepaid fee.
///
/// `view_my_batches` lists at most 200 batches. When it says `truncated`
/// and does not list the id, a missing batch proves nothing, so
/// `view_batch` ([viewBatch]) of that id must name this wallet's creator
/// key: the one the batch was built with (saved with it), and the creator
/// `view_batch` names for a batch the list does show (they are all this
/// wallet's). Every key known must match; with none known, nothing is
/// proven. Matching only a count and total is never enough.
///
/// A lookup that fails throws: that is not a verdict.
Future<AirdropSquatCheck> airdropV3SquatCheck({
  required AirdropSavedBatch batch,
  required Future<AirdropV3VoucherInfo?> Function(String code) lookup,
  required Future<AirdropV3BatchList> Function() myBatches,
  required Future<AirdropV3BatchDetail> Function(BigInt id) viewBatch,
  void Function(int done, int total)? onProgress,
}) async {
  final gas = batch.gasPerVoucher ?? BigInt.zero;
  final n = batch.codes.length;
  BigInt? batchId;
  for (var i = 0; i < n; i++) {
    final c = batch.codes[i];
    final info = await lookup(c.code);
    if (info == null) {
      return AirdropSquatCheck.failed(AirdropCheckProblem.notFound, i);
    }
    if (c.key == null || info.key != c.key) {
      return AirdropSquatCheck.failed(AirdropCheckProblem.otherKey, i);
    }
    if (info.assetId != batch.assetId ||
        info.value != c.value ||
        info.gas != gas) {
      return AirdropSquatCheck.failed(AirdropCheckProblem.otherValue, i);
    }
    if (batchId == null) {
      batchId = info.batchId;
    } else if (info.batchId != batchId) {
      return AirdropSquatCheck.failed(AirdropCheckProblem.otherBatch, i);
    }
    onProgress?.call(i + 1, n);
  }
  final id = batchId!;
  bool same(int assetId, int created, BigInt gasPerVoucher) =>
      assetId == batch.assetId && created == n && gasPerVoucher == gas;

  final mine = await myBatches();
  final row = mine.batches.where((b) => b.id == id).firstOrNull;
  if (row != null) {
    return same(row.assetId, row.created, row.gasPerVoucher)
        ? AirdropSquatCheck.ok(id)
        : const AirdropSquatCheck.failed(AirdropCheckProblem.otherBatch);
  }
  if (!mine.truncated) {
    return const AirdropSquatCheck.failed(AirdropCheckProblem.notMine);
  }
  final AirdropV3BatchDetail b;
  try {
    b = await viewBatch(id);
  } on BeamAirdropException catch (e) {
    if (e.code == AirdropErrorCode.batchNotFound) {
      return const AirdropSquatCheck.failed(AirdropCheckProblem.notMine);
    }
    rethrow;
  }
  final known = <String>[
    if (batch.creatorKey != null) batch.creatorKey!,
    if (mine.batches.isNotEmpty)
      (await viewBatch(mine.batches.first.id)).creator,
  ];
  if (known.isEmpty || known.any((k) => k != b.creator)) {
    return const AirdropSquatCheck.failed(AirdropCheckProblem.notMine);
  }
  return same(b.assetId, b.created, b.gasPerVoucher)
      ? AirdropSquatCheck.ok(id)
      : const AirdropSquatCheck.failed(AirdropCheckProblem.otherBatch);
}

/// Where a saved v3 batch stands ([BeamAirdropV3Service.verifyBatch]).
enum AirdropV3BatchState {
  /// Not a v3 batch: the old contract's codes work as soon as it confirms.
  old,

  /// Checked: every code is on the network in this wallet's batch. Ready to
  /// share. Saved, never checked again.
  ready,

  /// Checked and refused ([AirdropV3Verdict.problem]): do not share these
  /// codes; new ones are needed.
  failed,

  /// The create never went through: these codes hold nothing.
  notSent,

  /// The create is not confirmed [kAirdropV3ConfirmationsBeforeCheck] times
  /// yet.
  waiting,
}

@immutable
class AirdropV3Verdict {
  const AirdropV3Verdict(
    this.state,
    this.batch, {
    this.problem,
    this.confirmations,
    this.mined = false,
    this.onChain = false,
  });

  final AirdropV3BatchState state;

  /// The saved record, as it is now.
  final AirdropSavedBatch batch;
  final AirdropCheckProblem? problem;

  /// [AirdropV3BatchState.waiting]: confirmations so far, null when not
  /// known yet.
  final int? confirmations;

  /// [AirdropV3BatchState.failed]: the batch's own transaction was mined,
  /// so its funds are locked and can be taken back.
  final bool mined;

  /// [AirdropV3BatchState.notSent]: the network turned it down (rather than
  /// it never being sent).
  final bool onChain;
}

/// Airdrop v3 (`ac85d74b…`): claim with a code without the code ever
/// reaching the network, create batches of codes (optionally with each
/// claim's fee prepaid), check a new batch before its codes are shared,
/// and take back what nobody claimed. Over [BeamApi.invokeContract] with the
/// pinned v3 app shader.
///
/// As for the old contract, money-moving work is split in two: `prepare…`
/// builds the transaction with `create_tx: false` and checks the decoded
/// `raw_data` byte for byte against the request (one plain call to this
/// contract, the method, its BVM charge, its kernel comment, signed by
/// exactly the key it should be, nothing the core would rebuild, the exact
/// arguments, exactly the expected funds and exactly the expected network
/// fee); [execute] is the only path to `process_invoke_data`. One airdrop
/// transaction at a time, across both contracts ([lock]).
///
/// Never offered: `sponsor_gas`, the gas pool (claims pass
/// `use_gas_pool=0`), and every owner action. No call passes a fee of its
/// own: a higher fee would make a code with a prepaid claim fee need BEAM
/// its claimer may not have.
class BeamAirdropV3Service {
  BeamAirdropV3Service(
    this.api,
    this.shader, {
    this.store,
    this.timeout = const Duration(minutes: 2),
    AirdropFlowLock? lock,
    Random? random,
    DateTime Function()? clock,
  }) : lock = lock ?? AirdropFlowLock(),
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now {
    if (shader.name != kAirdropV3AppShaderName ||
        shader.sha256 != kAirdropV3AppShaderSha256) {
      throw ArgumentError.value(shader.name, 'shader', 'not the v3 app shader');
    }
  }

  final BeamApi api;

  /// The v3 app shader, pinned (see [airdropV3AppShader]).
  final PinnedShader shader;

  /// Where created codes are kept. Required to create batches.
  final VoucherCodeStore? store;

  /// Per `invoke_contract` / `process_invoke_data` call.
  final Duration timeout;

  /// Shared with the old contract's service of the same wallet.
  final AirdropFlowLock lock;

  final Random _random;
  final DateTime Function() _clock;
  Future<void> _tail = Future<void>.value();

  static const contractId = kAirdropV3ContractId;

  /// A prepare or send is in progress on either contract, or a prepared
  /// call awaits [execute] / [discard].
  bool get isBusy => lock.isBusy;

  // ------------------------------------------------------------------ views

  /// What [code] unlocks on v3, or null when v3 has no voucher for it (or
  /// could not hold it). Any other failure throws: it is never "not there".
  Future<AirdropV3VoucherInfo?> checkVoucher(String code) async {
    if (!AirdropV3Code.isV3Code(code)) return null;
    try {
      return AirdropV3VoucherInfo.fromOutput(
        await _view(
          AirdropV3Args.checkVoucher(
            normalisedCode: AirdropV3Code.normalise(code),
          ),
        ),
      );
    } on BeamAirdropException catch (e) {
      if (e.code == AirdropErrorCode.voucherNotFound ||
          e.code == AirdropErrorCode.invalidCode) {
        return null;
      }
      rethrow;
    }
  }

  /// The seed and key the shader derives for [code]; never on chain.
  Future<AirdropV3DerivedKey> voucherKey(String code) async =>
      AirdropV3DerivedKey.fromOutput(
        await _view(
          AirdropV3Args.voucherKey(
            normalisedCode: AirdropV3Code.normalisedOrThrow(code),
          ),
        ),
      );

  /// This wallet's v3 batches (at most 200; see `truncated`).
  Future<AirdropV3BatchList> myBatches() async =>
      AirdropV3BatchList.fromOutput(await _view(AirdropV3Args.viewMyBatches()));

  /// One batch, with its creator and every voucher.
  Future<AirdropV3BatchDetail> viewBatch(BigInt batchId) async =>
      AirdropV3BatchDetail.fromOutput(
        await _view(AirdropV3Args.viewBatch(batchId: batchId)),
        batchId,
      );

  // ------------------------------------------------------------ saved codes

  /// The saved v3 batches, newest first.
  Future<List<AirdropSavedBatch>> savedBatches() async {
    final all = (await _requireStore().all()).where((b) => b.isV3);
    return List.unmodifiable(
      all.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  /// Where the saved v3 batch [localId] stands, and the check before its
  /// codes are shared, run once it is due ([AirdropV3BatchState]):
  ///
  /// * waits until the batch's transaction has
  ///   [kAirdropV3ConfirmationsBeforeCheck] confirmations;
  /// * then [airdropV3SquatCheck] on every code, reporting
  ///   [onProgress]`(done, total)`;
  /// * saves the verdict once; a checked batch is never checked again.
  ///
  /// A lookup that fails throws and saves nothing: the next call tries
  /// again.
  Future<AirdropV3Verdict> verifyBatch(
    String localId, {
    void Function(int done, int total)? onProgress,
  }) async {
    final s = _requireStore();
    final rec = (await s.all()).where((b) => b.localId == localId).firstOrNull;
    if (rec == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.batchNotFound,
        'This batch is not among the codes saved on this device.',
      );
    }
    if (!rec.isV3) return AirdropV3Verdict(AirdropV3BatchState.old, rec);
    final check = rec.check;
    if (check != null) {
      return check.ok
          ? AirdropV3Verdict(AirdropV3BatchState.ready, rec)
          : AirdropV3Verdict(
              AirdropV3BatchState.failed,
              rec,
              problem: check.problem,
              mined: rec.txStatus == AirdropBatchTxStatus.confirmed,
            );
    }
    if (rec.txStatus == AirdropBatchTxStatus.failed) {
      return AirdropV3Verdict(AirdropV3BatchState.notSent, rec);
    }
    var mined = false;
    var txKnown = false;
    final txId = rec.txId;
    if (txId != null) {
      BeamTransaction? t;
      try {
        t = await api.txStatus(txId);
      } on BeamRpcException {
        // Not in this wallet's history (restored from the seed, say): the
        // codes on the network decide, and only a full pass counts.
      }
      if (t != null) {
        txKnown = true;
        final st = t.status;
        if (st == BeamTxStatus.failed || st == BeamTxStatus.canceled) {
          final failed = rec.copyWith(txStatus: AirdropBatchTxStatus.failed);
          await s.put(failed);
          return AirdropV3Verdict(
            AirdropV3BatchState.notSent,
            failed,
            onChain: st == BeamTxStatus.failed,
          );
        }
        if (st != BeamTxStatus.completed) {
          return AirdropV3Verdict(
            AirdropV3BatchState.waiting,
            rec,
            confirmations: 0,
          );
        }
        final confirmations = await _confirmations(t);
        if (confirmations < kAirdropV3ConfirmationsBeforeCheck) {
          return AirdropV3Verdict(
            AirdropV3BatchState.waiting,
            rec,
            confirmations: confirmations,
          );
        }
        mined = true;
      }
    }
    onProgress?.call(0, rec.codes.length);
    final r = await airdropV3SquatCheck(
      batch: rec,
      lookup: checkVoucher,
      myBatches: myBatches,
      viewBatch: viewBatch,
      onProgress: onProgress,
    );
    // Without a known transaction (a timeout while sending, or a history
    // that lost it), a batch nowhere to be found may still be on its way.
    if (!r.ok &&
        !mined &&
        !txKnown &&
        r.problem == AirdropCheckProblem.notFound &&
        r.index == 0) {
      return AirdropV3Verdict(AirdropV3BatchState.waiting, rec);
    }
    final next = rec.copyWith(
      txStatus: r.ok || mined ? AirdropBatchTxStatus.confirmed : null,
      batchId: r.batchId,
      check: AirdropCodeCheck(
        state: r.ok ? AirdropCheckState.ok : AirdropCheckState.failed,
        at: _clock().toUtc(),
        problem: r.problem,
        index: r.index,
      ),
      codes: r.ok
          ? [
              for (final c in rec.codes)
                c.status == AirdropCodeStatus.unknown
                    ? c.withStatus(AirdropCodeStatus.available)
                    : c,
            ]
          : null,
    );
    await s.put(next);
    return r.ok
        ? AirdropV3Verdict(AirdropV3BatchState.ready, next)
        : AirdropV3Verdict(
            AirdropV3BatchState.failed,
            next,
            problem: r.problem,
            mined: mined,
          );
  }

  /// Re-reads every code of the saved v3 batch [batch] with
  /// `check_voucher` and its transaction, and saves the result. Never
  /// removes a code, and never decides the check before sharing.
  Future<AirdropSavedBatch> refreshSavedBatch(AirdropSavedBatch batch) async {
    final s = _requireStore();
    final stored = (await s.all()).where((b) => b.localId == batch.localId);
    final current = stored.isEmpty ? batch : stored.single;
    if (!current.isV3) {
      throw ArgumentError.value(batch.localId, 'batch', 'not a v3 batch');
    }
    var status = current.txStatus;
    final tx = current.txId;
    if (tx != null &&
        (status == AirdropBatchTxStatus.unconfirmed ||
            status == AirdropBatchTxStatus.broadcast)) {
      try {
        status = switch ((await api.txStatus(tx)).status) {
          BeamTxStatus.completed => AirdropBatchTxStatus.confirmed,
          BeamTxStatus.failed ||
          BeamTxStatus.canceled => AirdropBatchTxStatus.failed,
          _ => status,
        };
      } on BeamRpcException {
        // Unknown to this wallet's history.
      }
    }
    final codes = <AirdropSavedCode>[];
    for (final c in current.codes) {
      final info = await checkVoucher(c.code);
      codes.add(
        c.withStatus(
          info == null
              ? AirdropCodeStatus.notFound
              : info.redeemed
              ? AirdropCodeStatus.claimed
              : AirdropCodeStatus.available,
        ),
      );
    }
    final updated = current.copyWith(txStatus: status, codes: codes);
    await s.put(updated);
    return updated;
  }

  /// Removes a saved v3 batch, on an explicit user request, only when it
  /// can no longer hold funds (as `BeamAirdropService.forgetSavedBatch`):
  /// every code is gone or claimed on v3 and its transaction has settled.
  Future<void> forgetSavedBatch(String localId) async {
    final s = _requireStore();
    final found = (await s.all()).where((b) => b.localId == localId);
    if (found.isEmpty) return;
    if (!(await api.walletStatus()).isInSync) {
      throw const BeamAirdropException(
        AirdropErrorCode.walletNotSynced,
        'The wallet is still catching up with the network. Try again once '
        'it is in sync.',
      );
    }
    final b = await refreshSavedBatch(found.single);
    final anyAvailable = b.codes.any(
      (c) => c.status == AirdropCodeStatus.available,
    );
    final allGone = b.codes.every(
      (c) =>
          c.status == AirdropCodeStatus.notFound ||
          c.status == AirdropCodeStatus.claimed,
    );
    final stale =
        b.txStatus == AirdropBatchTxStatus.unconfirmed &&
        _clock().toUtc().difference(b.createdAt) >
            BeamAirdropService.staleAfter;
    final settled =
        b.txStatus == AirdropBatchTxStatus.confirmed ||
        b.txStatus == AirdropBatchTxStatus.failed ||
        stale;
    if (anyAvailable || !allGone || !settled) {
      throw const BeamAirdropException(
        AirdropErrorCode.stillHoldsFunds,
        'These codes can still unlock funds, so they stay saved. Take the '
        'batch back first, or wait until its transaction settles.',
      );
    }
    await s.delete(localId);
  }

  // ---------------------------------------------------------------- prepare

  /// Builds a batch of vouchers of [assetId], one fresh 16-symbol code per
  /// entry of [values] (each in the asset's smallest unit), each with its
  /// claim fee prepaid (0.022 BEAM per code) when [prepayClaimFees].
  ///
  /// The wallet locks the values plus the 1% creation fee, and the prepaid
  /// claim fees in BEAM; the network fee is paid in BEAM. Each code's
  /// voucher key is derived on this device and the built batch must carry
  /// exactly those keys. The codes go into
  /// [BeamPreparedAirdropV3Call.saved]; [execute] stores them before it
  /// broadcasts.
  Future<BeamPreparedAirdropV3Call> prepareCreateBatch({
    required int assetId,
    required List<BigInt> values,
    bool prepayClaimFees = true,
  }) => _flowed(() async {
    if (store == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.noCodeStore,
        'This wallet has nowhere safe to keep the codes, so it cannot '
        'create a batch.',
      );
    }
    if (values.isEmpty || values.length > kAirdropV3MaxVouchersPerBatch) {
      throw ArgumentError.value(
        values.length,
        'values',
        '1 to $kAirdropV3MaxVouchersPerBatch codes',
      );
    }
    final gasPerVoucher = prepayClaimFees
        ? kAirdropV3GasPerVoucher
        : BigInt.zero;
    final n = values.length;
    final codes = <String>[];
    final hashes = <String>{};
    final keys = <String>[];
    final entries = <AirdropV3SeedEntry>[];
    while (codes.length < n) {
      final c = AirdropVoucherCode.generate(_random);
      final h = AirdropVoucherCode.hashHex(c);
      if (!hashes.add(h)) continue;
      final seed = AirdropV3Code.seed(c);
      keys.add(AirdropV3Code.keyOfSecret(AirdropV3Code.secret(seed)));
      entries.add(AirdropV3SeedEntry(seed, values[codes.length]));
      seed.fillRange(0, seed.length, 0);
      codes.add(c);
      // A key is a few milliseconds of curve arithmetic: let frames through.
      if (codes.length % 10 == 0) await Future<void>.delayed(Duration.zero);
    }
    final total = values.fold(BigInt.zero, (a, v) => a + v);
    final fee = AirdropV3Fee.creationFee(total);
    final gasTotal = gasPerVoucher * BigInt.from(n);
    if (total > _i64Max ||
        total + fee + (assetId == 0 ? gasTotal : BigInt.zero) > _i64Max) {
      throw ArgumentError.value(total, 'values', 'more than one batch holds');
    }
    final args = AirdropV3Args.createBatch(
      assetId: assetId,
      gasPerVoucher: gasPerVoucher,
      entries: entries,
    );
    final ({List<int> raw, BeamInvokeData d, Map<String, Object?> out}) built;
    try {
      built = await _build(
        args,
        method: AirdropV3Method.createBatch,
        charge: AirdropV3Charge.createBatch(n),
        comment: AirdropV3KernelComment.createBatch,
        signer: AirdropV3SigningKeys.creator(),
      );
      // Seeds go to the app shader only; the transaction carries keys.
      for (final e in entries) {
        _expect(!_contains(built.raw, e.seed), 'the batch carries a seed');
      }
    } finally {
      for (final e in entries) {
        e.seed.fillRange(0, e.seed.length, 0);
      }
    }
    final (:raw, :d, :out) = built;
    final a = d.entries.single.args;
    final creatorKey = BeamArgsReader(a).pubKey();
    _expect(_keyRe.hasMatch(creatorKey), 'no creator key');
    _expect(
      _bytesEqual(a, [
        ..._hex(creatorKey),
        ..._le(assetId, 4),
        ..._le(n, 4),
        ..._le(gasPerVoucher, 8),
        for (var i = 0; i < n; i++) ...[..._hex(keys[i]), ..._le(values[i], 8)],
      ]),
      'the batch arguments differ from the request',
    );
    for (final (k, v) in [
      ('total', total),
      ('fee', fee),
      ('gas_total', gasTotal),
    ]) {
      if (out.containsKey(k)) {
        _expect(out[k] == v, 'the shader reports another $k');
      }
    }
    _expectFunds(d, _funds(assetId, total + fee, gasTotal, 1), 'the batch');
    _expect(
      d.fee == AirdropV3Fee.create(n),
      'a network fee of ${d.fee} groth, expected ${AirdropV3Fee.create(n)}',
    );

    final now = _clock().toUtc();
    final saved = AirdropSavedBatch(
      localId:
          'batch_${now.microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}',
      contractId: contractId,
      assetId: assetId,
      createdAt: now,
      gasPerVoucher: gasPerVoucher,
      creatorKey: creatorKey,
      codes: [
        for (var i = 0; i < n; i++)
          AirdropSavedCode(
            code: codes[i],
            hashHex: AirdropVoucherCode.hashHex(codes[i]),
            value: values[i],
            key: keys[i],
          ),
      ],
    );
    return BeamPreparedAirdropV3Call._(
      action: AirdropAction.createBatch,
      args: args,
      rawData: raw,
      invoke: d,
      saved: saved,
      summary: AirdropSummary(
        action: AirdropAction.createBatch,
        contract: AirdropContract.v3,
        assetId: assetId,
        pays: d.pays,
        receives: d.receives,
        networkFee: d.fee,
        contractId: contractId,
        voucherCount: n,
        voucherValues: List.unmodifiable(values),
        creationFee: fee,
        gas: gasTotal,
        gasPerVoucher: gasPerVoucher,
      ),
    );
  });

  /// Builds the claim of the voucher [code] unlocks into this wallet. The
  /// transaction carries the voucher's key, a fresh receiving key and a
  /// signature by the code's secret, never the code: that is checked on the
  /// built bytes. A code whose creator prepaid its claim fee brings that
  /// BEAM with it, so it can be claimed from a wallet holding none.
  Future<BeamPreparedAirdropV3Call> prepareRedeem(String code) => _flowed(
    () async {
      if (!AirdropV3Code.isV3Code(code)) {
        throw const BeamAirdropException(
          AirdropErrorCode.invalidCode,
          'A code has letters and digits, like ABCD-EFGH-JKLM-NPQR.',
        );
      }
      final normalised = AirdropV3Code.normalise(code);
      final info = await checkVoucher(normalised);
      if (info == null) {
        throw const BeamAirdropException(
          AirdropErrorCode.voucherNotFound,
          'No voucher has this code. Check it letter by letter; codes '
          'never contain I, O, 0 or 1.',
        );
      }
      if (info.redeemed) {
        throw const BeamAirdropException(
          AirdropErrorCode.alreadyRedeemed,
          'This code was already claimed.',
        );
      }
      final seed = AirdropV3Code.seed(normalised);
      final secret = AirdropV3Code.secret(seed);
      final args = AirdropV3Args.redeem(normalisedCode: normalised);
      final ({List<int> raw, BeamInvokeData d, Map<String, Object?> out}) built;
      try {
        final key = AirdropV3Code.keyOfSecret(secret);
        _expect(
          info.key == key,
          'the network answered for another voucher than this code',
        );
        built = await _build(
          args,
          method: AirdropV3Method.redeem,
          charge: AirdropV3Charge.redeem,
          comment: AirdropV3KernelComment.redeem,
          signer: AirdropV3SigningKeys.claimer(key),
        );
        final r = BeamArgsReader(built.d.entries.single.args);
        _expect(
          r.remaining == 33 + 33 + 8 + 65,
          'the claim arguments have the wrong size',
        );
        _expect(r.pubKey() == key, 'the claim names another voucher');
        _expect(_keyRe.hasMatch(r.pubKey()), 'the claim has no receiving key');
        _expect(r.u64() == BigInt.zero, 'the claim asks the gas pool');
        // The code, its seed and its secret stay on this device.
        for (final b in [ascii.encode(normalised), seed, secret]) {
          _expect(!_contains(built.raw, b), 'the claim carries the code');
        }
      } finally {
        seed.fillRange(0, seed.length, 0);
        secret.fillRange(0, secret.length, 0);
      }
      final (:raw, :d, :out) = built;
      final source = out['gas_source'];
      if (source != null) {
        _expect(
          source == (info.gas > BigInt.zero ? 'voucher' : 'none'),
          'the claim takes its fee from the gas pool',
        );
      }
      _expectFunds(
        d,
        _funds(info.assetId, info.value, info.gas, -1),
        'the claim',
      );
      _expect(
        d.fee == AirdropV3Fee.claim,
        'a network fee of ${d.fee} groth, expected ${AirdropV3Fee.claim}',
      );
      return BeamPreparedAirdropV3Call._(
        action: AirdropAction.redeem,
        args: args,
        rawData: raw,
        invoke: d,
        summary: AirdropSummary(
          action: AirdropAction.redeem,
          contract: AirdropContract.v3,
          assetId: info.assetId,
          pays: d.pays,
          receives: d.receives,
          networkFee: d.fee,
          contractId: contractId,
          gas: info.gas,
        ),
      );
    },
  );

  /// Builds the take-back of every unclaimed voucher of this wallet's v3
  /// batch [batchId]: their codes stop working, their values and prepaid
  /// claim fees come back.
  ///
  /// A claim that lands while this is prepared changes what the shader
  /// lists: refused with [AirdropErrorCode.changed], nothing built to send,
  /// so the screen reads the batch again. A claim mined after this was sent
  /// makes the take-back fail on the network, with nothing moved.
  Future<BeamPreparedAirdropV3Call> prepareCancelBatch(BigInt batchId) =>
      _flowed(() async {
        final mine = await myBatches();
        var row = mine.batches.where((b) => b.id == batchId).firstOrNull;
        if (row == null && mine.truncated) {
          final b = await viewBatch(batchId);
          final open = b.vouchers.where((v) => !v.redeemed).toList();
          row = AirdropV3Batch(
            id: batchId,
            assetId: b.assetId,
            created: b.created,
            unclaimed: open.length,
            redeemed: b.vouchers.length - open.length,
            cancelled: b.created - b.vouchers.length,
            valueUnclaimed: open.fold(BigInt.zero, (s, v) => s + v.value),
            gasPerVoucher: b.gasPerVoucher,
            createdAtHeight: b.createdAtHeight,
          );
        }
        if (row == null) {
          throw const BeamAirdropException(
            AirdropErrorCode.batchNotFound,
            'This wallet has no batch with codes left under that number.',
          );
        }
        if (row.unclaimed == 0) {
          throw const BeamAirdropException(
            AirdropErrorCode.nothingToCancel,
            'Every code of this batch was already claimed or taken back.',
          );
        }
        final n = row.unclaimed;
        final gasBack = row.gasUnclaimed;
        final saved = await _savedFor(batchId);
        final args = AirdropV3Args.cancelBatch(batchId: batchId);
        final r0 = await _invoke(args);
        // How many codes the shader found unclaimed just now, before any
        // other check: a claim in between is not a fault, just news.
        final listed = _cancelCount(r0.rawData);
        if (listed != null && listed != n) {
          throw const BeamAirdropException(
            AirdropErrorCode.changed,
            'Some codes were claimed while this was being prepared. Nothing '
            'was sent. Look at the batch again, then take back what is left.',
          );
        }
        final (:raw, :d, out: _) = _checkBuilt(
          r0,
          method: AirdropV3Method.cancelBatch,
          charge: AirdropV3Charge.cancelBatch(n),
          comment: AirdropV3KernelComment.cancelBatch,
          signer: AirdropV3SigningKeys.creator(),
        );
        final r = BeamArgsReader(d.entries.single.args);
        final creator = r.pubKey();
        _expect(_keyRe.hasMatch(creator), 'no creator key');
        if (saved?.creatorKey != null) {
          _expect(creator == saved!.creatorKey, 'another creator key');
        }
        _expect(r.u64() == batchId, 'another batch');
        _expect(
          r.u32() == n && r.remaining == 33 * n,
          'the batch changed while preparing; try again',
        );
        final keys = <String>{for (var i = 0; i < n; i++) r.pubKey()};
        _expect(
          keys.length == n && keys.every(_keyRe.hasMatch),
          'repeated or broken voucher keys',
        );
        if (saved != null && saved.codes.every((c) => c.key != null)) {
          final ours = {for (final c in saved.codes) c.key};
          _expect(
            keys.every(ours.contains),
            'a voucher that is not one of this batch\'s codes',
          );
        }
        _expectFunds(
          d,
          _funds(row.assetId, row.valueUnclaimed, gasBack, -1),
          'the take-back',
        );
        _expect(
          d.fee == AirdropV3Fee.cancel(n),
          'a network fee of ${d.fee} groth, expected ${AirdropV3Fee.cancel(n)}',
        );
        return BeamPreparedAirdropV3Call._(
          action: AirdropAction.cancelBatch,
          args: args,
          rawData: raw,
          invoke: d,
          summary: AirdropSummary(
            action: AirdropAction.cancelBatch,
            contract: AirdropContract.v3,
            assetId: row.assetId,
            pays: d.pays,
            receives: d.receives,
            networkFee: d.fee,
            contractId: contractId,
            voucherCount: n,
            batchId: batchId,
            gas: gasBack,
          ),
        );
      });

  // ---------------------------------------------------------------- execute

  /// Sends [prepared] with `process_invoke_data` and returns the tx id.
  ///
  /// For a new batch, the codes (with their keys and the creator key) are
  /// written to [store] first and read back; if that fails nothing is sent
  /// ([AirdropErrorCode.codesNotSaved]). The record is never removed,
  /// whatever happens. A prepared call is sent at most once.
  Future<String> execute(BeamPreparedAirdropV3Call prepared) async {
    if (prepared._executed) {
      throw const BeamAirdropException(
        AirdropErrorCode.alreadyExecuted,
        'This transaction was already sent.',
      );
    }
    if (!identical(lock.owner, prepared)) {
      throw const BeamAirdropException(
        AirdropErrorCode.expired,
        'This confirmation is no longer current. Prepare it again.',
      );
    }
    prepared._executed = true;
    try {
      final saved = prepared.saved;
      if (saved != null) await _saveBeforeBroadcast(saved);
      final String txId;
      try {
        txId = await api.processInvokeData(prepared.rawData, timeout: timeout);
      } on BeamRpcException {
        // The core answered with a refusal: it built no transaction.
        if (saved != null) {
          await _bestEffortPut(
            saved.copyWith(txStatus: AirdropBatchTxStatus.failed),
          );
        }
        rethrow;
      }
      if (saved != null) {
        await _bestEffortPut(
          saved.copyWith(txId: txId, txStatus: AirdropBatchTxStatus.broadcast),
        );
      }
      return txId;
    } finally {
      if (identical(lock.owner, prepared)) lock.owner = null;
    }
  }

  /// Gives up [prepared] without sending it, releasing the lock.
  void discard(BeamPreparedAirdropV3Call prepared) {
    if (identical(lock.owner, prepared) && !prepared._executed) {
      lock.owner = null;
    }
  }

  // ---------------------------------------------------------------- helpers

  Future<BeamPreparedAirdropV3Call> _flowed(
    Future<BeamPreparedAirdropV3Call> Function() build,
  ) async {
    // Runs synchronously up to the first await: a second tap in the same
    // frame finds the lock taken.
    if (lock.owner != null) {
      throw const BeamAirdropException(
        AirdropErrorCode.busy,
        'Another airdrop transaction is in progress. Finish or cancel it '
        'first.',
      );
    }
    final token = Object();
    lock.owner = token;
    try {
      final p = await build();
      if (!identical(lock.owner, token)) {
        throw const BeamAirdropException(
          AirdropErrorCode.expired,
          'This confirmation is no longer current. Prepare it again.',
        );
      }
      lock.owner = p;
      return p;
    } catch (_) {
      if (identical(lock.owner, token)) lock.owner = null;
      rethrow;
    }
  }

  VoucherCodeStore _requireStore() {
    final s = store;
    if (s == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.noCodeStore,
        'This wallet has no saved airdrop codes.',
      );
    }
    return s;
  }

  /// The saved v3 record of on-chain batch [batchId], when this device has
  /// it.
  Future<AirdropSavedBatch?> _savedFor(BigInt batchId) async {
    final s = store;
    if (s == null) return null;
    try {
      return (await s.all())
          .where((b) => b.isV3 && b.batchId == batchId)
          .firstOrNull;
    } catch (_) {
      return null; // Unreadable storage: the checks without it still hold.
    }
  }

  Future<void> _saveBeforeBroadcast(AirdropSavedBatch saved) async {
    final s = _requireStore();
    try {
      await s.put(saved);
      final back = (await s.all()).where((b) => b.localId == saved.localId);
      final ok =
          back.length == 1 &&
          back.single.creatorKey == saved.creatorKey &&
          back.single.gasPerVoucher == saved.gasPerVoucher &&
          back.single.codes.length == saved.codes.length &&
          [
            for (var i = 0; i < saved.codes.length; i++)
              back.single.codes[i].code == saved.codes[i].code &&
                  back.single.codes[i].hashHex == saved.codes[i].hashHex &&
                  back.single.codes[i].key == saved.codes[i].key,
          ].every((x) => x);
      if (!ok) throw StateError('read-back mismatch');
    } catch (e) {
      throw BeamAirdropException(
        AirdropErrorCode.codesNotSaved,
        'The codes could not be saved, so nothing was sent. ($e)',
      );
    }
  }

  Future<void> _bestEffortPut(AirdropSavedBatch b) async {
    try {
      await store?.put(b);
    } catch (_) {
      // The codes were saved before sending; only the status is stale.
    }
  }

  /// Confirmations of a completed transaction: the core's own count, or
  /// the distance from its height to the wallet's tip.
  Future<int> _confirmations(BeamTransaction t) async {
    final c = t.confirmations;
    if (c != null) return c;
    final h = t.height;
    if (h == null) return 0;
    final tip = (await api.walletStatus()).currentHeight;
    return tip >= h ? tip - h + 1 : 0;
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<BeamInvokeResult> _invoke(String args) => _serial(() async {
    final bytes = await shader.load();
    return api.invokeContract(
      createTx: false,
      args: args,
      contractBytes: bytes,
      timeout: timeout,
    );
  });

  /// A read-only call. A transaction in the answer is refused.
  Future<Map<String, Object?>> _view(String args) async {
    final r = await _invoke(args);
    final out = _decodeOutput(r.output);
    if (r.rawData != null || r.txId != null) {
      throw const BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'a read-only airdrop call produced a transaction',
      );
    }
    return out;
  }

  Future<({List<int> raw, BeamInvokeData d, Map<String, Object?> out})> _build(
    String args, {
    required int method,
    required int charge,
    required String comment,
    required String signer,
  }) async => _checkBuilt(
    await _invoke(args),
    method: method,
    charge: charge,
    comment: comment,
    signer: signer,
  );

  /// The checks every v3 transaction passes: one plain call to this
  /// contract, the expected method, BVM charge and kernel comment, signed
  /// by exactly [signer] and nothing else, nothing the core would rebuild
  /// or re-run after approval, and no transaction started.
  static ({List<int> raw, BeamInvokeData d, Map<String, Object?> out})
  _checkBuilt(
    BeamInvokeResult r, {
    required int method,
    required int charge,
    required String comment,
    required String signer,
  }) {
    final out = r.output.trim().isEmpty
        ? const <String, Object?>{}
        : _decodeOutput(r.output);
    final raw = r.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'the shader built no transaction',
      );
    }
    _expect(r.txId == null, 'the core started a transaction by itself');
    final BeamInvokeData d;
    try {
      d = BeamInvokeData.decode(raw);
    } on FormatException catch (e) {
      throw BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'cannot read the prepared transaction: ${e.message}',
      );
    }
    _expect(d.entries.length == 1, 'expected one contract call');
    final e = d.entries.single;
    _expect(
      e.contractId == contractId,
      'the call targets ${e.contractId}, not Airdrop v3',
    );
    _expect(e.method == method, 'contract method ${e.method}, not $method');
    _expect(e.flags == 0, 'not a plain call (flags ${e.flags})');
    _expect(
      !d.isRebuildable &&
          d.appArgs == null &&
          d.appShader == null &&
          d.appPrivilege == null &&
          d.spendMax == null,
      'something the core would rebuild later',
    );
    _expect(e.charge == charge, 'BVM charge ${e.charge}, expected $charge');
    _expect(e.comment == comment, 'kernel comment "${e.comment}"');
    _expect(
      e.signatureCount == 1 && e.signatureKeyHashes.single == signer,
      'not signed by exactly the expected key',
    );
    return (raw: List<int>.unmodifiable(raw), d: d, out: out);
  }

  /// The count field of a built `CancelBatch` (creator 33 + batch id 8,
  /// then count), or null when the data is not one: checked in full later.
  static int? _cancelCount(List<int>? raw) {
    if (raw == null) return null;
    try {
      final d = BeamInvokeData.decode(raw);
      if (d.entries.length != 1) return null;
      final e = d.entries.single;
      if (e.contractId != contractId ||
          e.method != AirdropV3Method.cancelBatch ||
          e.args.length < 45) {
        return null;
      }
      return BeamArgsReader(e.args.sublist(41, 45)).u32();
    } on FormatException {
      return null;
    }
  }

  /// Funds for [value] of [assetId] plus [gas] BEAM, moving [sign] (1 =
  /// paid into the contract, -1 = paid out to the wallet).
  static Map<int, BigInt> _funds(
    int assetId,
    BigInt value,
    BigInt gas,
    int sign,
  ) {
    final m = <int, BigInt>{};
    void add(int k, BigInt v) {
      if (v == BigInt.zero) return;
      m[k] = (m[k] ?? BigInt.zero) + (sign < 0 ? -v : v);
    }

    add(assetId, value);
    add(0, gas);
    return m;
  }

  static void _expectFunds(
    BeamInvokeData d,
    Map<int, BigInt> expected,
    String what,
  ) {
    final s = d.spend;
    _expect(
      s.length == expected.length &&
          expected.entries.every((e) => s[e.key] == e.value),
      '$what moves $s, expected exactly $expected',
    );
  }

  static Map<String, Object?> _decodeOutput(String output) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BeamAirdropException(codeFor(e.message), _messageFor(e.message));
    }
  }

  /// The [AirdropErrorCode] for one of the v3 shader's error texts.
  static AirdropErrorCode codeFor(String shaderMessage) {
    switch (shaderMessage) {
      case 'voucher not found':
        return AirdropErrorCode.voucherNotFound;
      case 'voucher already redeemed':
        return AirdropErrorCode.alreadyRedeemed;
      case 'batch not found':
        return AirdropErrorCode.batchNotFound;
      case 'this wallet did not create the batch':
        return AirdropErrorCode.notBatchCreator;
      case 'no unclaimed vouchers in this batch':
        return AirdropErrorCode.nothingToCancel;
      case 'contract is paused: no new batches':
        return AirdropErrorCode.paused;
      case 'code has no letters or digits':
      case 'code is longer than 64 letters and digits':
        return AirdropErrorCode.invalidCode;
    }
    if (shaderMessage.startsWith('no Airdrop v3 contract at this cid') ||
        shaderMessage.startsWith('this cid is not derived from') ||
        shaderMessage == 'contract settings not found' ||
        shaderMessage == 'gas pool not found') {
      return AirdropErrorCode.contractNotFound;
    }
    return AirdropErrorCode.shaderError;
  }

  static String _messageFor(String shaderMessage) =>
      switch (codeFor(shaderMessage)) {
        AirdropErrorCode.paused =>
          'New codes cannot be made right now: the airdrop contract is '
              'paused. Claims and take-backs still work.',
        _ => shaderMessage,
      };

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BeamAirdropException(AirdropErrorCode.unexpectedTransaction, what);
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _contains(List<int> hay, List<int> needle) {
    if (needle.isEmpty) return false;
    outer:
    for (var i = 0; i + needle.length <= hay.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  static List<int> _hex(String h) => [
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];

  static List<int> _le(Object value, int n) => BeamArgsWriter.le(value, n);
}
