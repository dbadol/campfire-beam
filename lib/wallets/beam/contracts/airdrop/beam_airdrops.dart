/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../../api/beam_api.dart';
import 'airdrop_models.dart';
import 'airdrop_v3_keys.dart';
import 'airdrop_v3_models.dart';
import 'beam_airdrop_service.dart';
import 'beam_airdrop_v3_service.dart';
import 'voucher_code.dart';
import 'voucher_code_store.dart';

/// A voucher as the claim screen needs it, on whichever contract holds it.
@immutable
class AirdropFoundVoucher {
  const AirdropFoundVoucher({
    required this.contract,
    required this.assetId,
    required this.value,
    required this.gas,
    required this.redeemed,
  });

  final AirdropContract contract;
  final int assetId;
  final BigInt value;

  /// BEAM its creator prepaid for the claim's fee (v3 only; 0 otherwise).
  final BigInt gas;
  final bool redeemed;
}

/// The airdrop as the screens see it: both contracts of one wallet, sharing
/// one airdrop transaction at a time.
///
/// * **New codes are made on Airdrop v3 only.**
/// * A code is looked up on v3 first, then on the old contract (README
///   "Migration"), and claimed where it was found. An error on v3 is never
///   taken for "not there".
/// * Saved batches of both are listed, and each is taken back on its own
///   contract.
class BeamAirdrops {
  BeamAirdrops({required this.old, required this.v3}) {
    if (!identical(old.lock, v3.lock)) {
      throw ArgumentError.value(v3, 'v3', 'must share the old service\'s lock');
    }
    if (!identical(old.store, v3.store)) {
      throw ArgumentError.value(
        v3,
        'v3',
        'must share the old service\'s store',
      );
    }
  }

  /// The old contract `8737e0d3…`: existing codes and batches.
  final BeamAirdropService old;

  /// Airdrop v3 `ac85d74b…`: every new batch, and its codes.
  final BeamAirdropV3Service v3;

  BeamApi get api => v3.api;

  VoucherCodeStore? get store => v3.store;

  /// An airdrop transaction is being prepared, awaits confirmation or is
  /// being sent, on either contract.
  bool get isBusy => v3.lock.isBusy;

  /// v3 first, then the old contract: what [code] unlocks, or null when
  /// neither has it.
  Future<AirdropFoundVoucher?> checkVoucher(String code) async {
    _requireLetters(code);
    final a = await v3.checkVoucher(code);
    if (a != null) {
      return AirdropFoundVoucher(
        contract: AirdropContract.v3,
        assetId: a.assetId,
        value: a.value,
        gas: a.gas,
        redeemed: a.redeemed,
      );
    }
    final b = await old.checkVoucher(code);
    return b == null
        ? null
        : AirdropFoundVoucher(
            contract: AirdropContract.v2,
            assetId: b.assetId,
            value: b.value,
            gas: BigInt.zero,
            redeemed: b.redeemed,
          );
  }

  /// Builds the claim of [code] on whichever contract holds it.
  Future<AirdropPreparedCall> prepareRedeem(String code) async {
    if (isBusy) throw _busy;
    _requireLetters(code);
    if (AirdropV3Code.isV3Code(code) && await v3.checkVoucher(code) != null) {
      return v3.prepareRedeem(code);
    }
    return old.prepareRedeem(code);
  }

  /// Builds a new batch: always on Airdrop v3.
  Future<AirdropPreparedCall> prepareCreateBatch({
    required int assetId,
    required List<BigInt> values,
    bool prepayClaimFees = true,
  }) => v3.prepareCreateBatch(
    assetId: assetId,
    values: values,
    prepayClaimFees: prepayClaimFees,
  );

  /// Builds the take-back of a batch, on its own contract.
  Future<AirdropPreparedCall> prepareCancelBatch(
    AirdropContract contract,
    BigInt batchId,
  ) => contract == AirdropContract.v3
      ? v3.prepareCancelBatch(batchId)
      : old.prepareCancelBatch(batchId);

  /// Sends [prepared] with the service that built it.
  Future<String> execute(AirdropPreparedCall prepared) => switch (prepared) {
    final BeamPreparedAirdropV3Call p => v3.execute(p),
    final BeamPreparedAirdropCall p => old.execute(p),
    _ => throw ArgumentError.value(prepared, 'prepared', 'unknown call'),
  };

  /// Gives up [prepared] without sending it.
  void discard(AirdropPreparedCall prepared) {
    switch (prepared) {
      case final BeamPreparedAirdropV3Call p:
        v3.discard(p);
      case final BeamPreparedAirdropCall p:
        old.discard(p);
    }
  }

  // ------------------------------------------------------------ saved codes

  /// Every saved batch of both contracts, newest first.
  Future<List<AirdropSavedBatch>> savedBatches() async {
    final s = store;
    if (s == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.noCodeStore,
        'This wallet has no saved airdrop codes.',
      );
    }
    final all = (await s.all()).where(
      (b) => b.contractId == old.contractId || b.isV3,
    );
    return List.unmodifiable(
      all.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  /// Re-reads a saved batch's codes on its own contract.
  Future<AirdropSavedBatch> refreshSavedBatch(AirdropSavedBatch batch) =>
      batch.isV3 ? v3.refreshSavedBatch(batch) : old.refreshSavedBatch(batch);

  /// Removes a saved batch that can no longer hold funds (see each
  /// service's `forgetSavedBatch`).
  Future<void> forgetSavedBatch(AirdropSavedBatch batch) => batch.isV3
      ? v3.forgetSavedBatch(batch.localId)
      : old.forgetSavedBatch(batch.localId);

  /// Where a saved v3 batch stands, and its check before sharing.
  Future<AirdropV3Verdict> verifyBatch(
    String localId, {
    void Function(int done, int total)? onProgress,
  }) => v3.verifyBatch(localId, onProgress: onProgress);

  // ---------------------------------------------------------------- chain

  /// This wallet's batches on the old contract.
  Future<List<AirdropBatch>> oldBatches() => old.myBatches();

  /// Every voucher of one of this wallet's old-contract batches.
  Future<List<AirdropBatchVoucher>> oldBatchVouchers(BigInt id) =>
      old.batchVouchers(id);

  /// This wallet's v3 batches.
  Future<AirdropV3BatchList> v3Batches() => v3.myBatches();

  /// One v3 batch with its vouchers' keys.
  Future<AirdropV3BatchDetail> v3Batch(BigInt id) => v3.viewBatch(id);

  static const _busy = BeamAirdropException(
    AirdropErrorCode.busy,
    'Another airdrop transaction is in progress. Finish or cancel it first.',
  );

  static void _requireLetters(String code) {
    if (AirdropVoucherCode.normalise(code).isEmpty) {
      throw const BeamAirdropException(
        AirdropErrorCode.invalidCode,
        'A code has letters and digits, like ABCD-EFGH-JKLM-NPQR.',
      );
    }
  }
}
