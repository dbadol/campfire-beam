/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../common/shader_output.dart';

final _key = RegExp(r'^[0-9a-f]{64}0[01]$');
final _hex32 = RegExp(r'^[0-9a-f]{64}$');

/// A 33-byte public key as the shader prints it (66 hex, last byte 00/01).
String _pubKey(Map<String, Object?> json, String key) {
  final v = ShaderOutput.string(json, key);
  if (!_key.hasMatch(v)) throw FormatException('$key: not a public key');
  return v;
}

bool _flag(Map<String, Object?> json, String key) {
  final v = ShaderOutput.uint32(json, key);
  if (v > 1) throw FormatException('$key: expected 0 or 1');
  return v == 1;
}

/// A v3 voucher as `check_voucher` prints it.
@immutable
class AirdropV3VoucherInfo {
  const AirdropV3VoucherInfo({
    required this.key,
    required this.batchId,
    required this.assetId,
    required this.value,
    required this.gas,
    required this.redeemed,
    this.redeemedAtHeight,
  });

  /// `{"voucher": {key, batch_id, asset_id, value, gas, redeemed,
  /// redeemed_at?, pool_gas?, claim_fee?}}`.
  factory AirdropV3VoucherInfo.fromOutput(Map<String, Object?> out) =>
      AirdropV3VoucherInfo.fromJson(
        ShaderOutput.map(out['voucher'], 'voucher'),
      );

  factory AirdropV3VoucherInfo.fromJson(Map<String, Object?> v) {
    final redeemed = _flag(v, 'redeemed');
    return AirdropV3VoucherInfo(
      key: _pubKey(v, 'key'),
      batchId: ShaderOutput.amount(v, 'batch_id'),
      assetId: ShaderOutput.uint32(v, 'asset_id'),
      value: ShaderOutput.amount(v, 'value'),
      gas: ShaderOutput.amount(v, 'gas'),
      redeemed: redeemed,
      redeemedAtHeight: redeemed ? ShaderOutput.amount(v, 'redeemed_at') : null,
    );
  }

  /// The voucher's public key: the only thing about the code on chain.
  final String key;
  final BigInt batchId;
  final int assetId;

  /// In the asset's smallest unit.
  final BigInt value;

  /// BEAM (groth) its creator prepaid for the claim's network fee; released
  /// to whoever claims it. 0 = the claimer pays the fee.
  final BigInt gas;
  final bool redeemed;

  /// The height the contract recorded: one below the block that holds the
  /// claim's kernel.
  final BigInt? redeemedAtHeight;
}

/// One of this wallet's v3 batches (`view_my_batches`).
@immutable
class AirdropV3Batch {
  const AirdropV3Batch({
    required this.id,
    required this.assetId,
    required this.created,
    required this.unclaimed,
    required this.redeemed,
    required this.cancelled,
    required this.valueUnclaimed,
    required this.gasPerVoucher,
    required this.createdAtHeight,
  });

  factory AirdropV3Batch.fromJson(Map<String, Object?> json) {
    final created = ShaderOutput.uint32(json, 'created');
    final unclaimed = ShaderOutput.uint32(json, 'unclaimed');
    final redeemed = ShaderOutput.uint32(json, 'redeemed');
    final cancelled = ShaderOutput.uint32(json, 'cancelled');
    // The shader computes `cancelled` in 32 bits: a wrap shows up here.
    if (unclaimed + redeemed + cancelled != created) {
      throw const FormatException('batch: counts do not add up');
    }
    return AirdropV3Batch(
      id: ShaderOutput.amount(json, 'id'),
      assetId: ShaderOutput.uint32(json, 'asset_id'),
      created: created,
      unclaimed: unclaimed,
      redeemed: redeemed,
      cancelled: cancelled,
      valueUnclaimed: ShaderOutput.amount(json, 'value_unclaimed'),
      gasPerVoucher: ShaderOutput.amount(json, 'gas_per_voucher'),
      createdAtHeight: ShaderOutput.amount(json, 'created_at'),
    );
  }

  /// The same counts made from one batch read whole (`view_batch`), for a
  /// batch `view_my_batches` does not list (it stops at 200). A voucher
  /// taken back is no longer in the batch.
  factory AirdropV3Batch.fromDetail(AirdropV3BatchDetail b) {
    final open = b.vouchers.where((v) => !v.redeemed).toList();
    final cancelled = b.created - b.vouchers.length;
    if (cancelled < 0) {
      throw const FormatException('batch: more vouchers than it created');
    }
    return AirdropV3Batch(
      id: b.id,
      assetId: b.assetId,
      created: b.created,
      unclaimed: open.length,
      redeemed: b.vouchers.length - open.length,
      cancelled: cancelled,
      valueUnclaimed: open.fold(BigInt.zero, (s, v) => s + v.value),
      gasPerVoucher: b.gasPerVoucher,
      createdAtHeight: b.createdAtHeight,
    );
  }

  final BigInt id;
  final int assetId;

  /// Vouchers the batch was created with.
  final int created;
  final int unclaimed;
  final int redeemed;

  /// Taken back by the creator.
  final int cancelled;

  /// The unclaimed vouchers' total value, in the asset's smallest unit.
  final BigInt valueUnclaimed;
  final BigInt gasPerVoucher;
  final BigInt createdAtHeight;

  /// Prepaid claim fees that come back with the unclaimed vouchers.
  BigInt get gasUnclaimed => gasPerVoucher * BigInt.from(unclaimed);
}

/// `view_my_batches`: at most 200 batches; [truncated] when there are more.
@immutable
class AirdropV3BatchList {
  const AirdropV3BatchList(this.batches, {required this.truncated});

  /// `{"batches": [...], "truncated": 0|1}`.
  factory AirdropV3BatchList.fromOutput(Map<String, Object?> out) =>
      AirdropV3BatchList(
        List.unmodifiable([
          for (final row in ShaderOutput.list(out['batches'], 'batches'))
            AirdropV3Batch.fromJson(ShaderOutput.map(row, 'batches[]')),
        ]),
        truncated: _flag(out, 'truncated'),
      );

  final List<AirdropV3Batch> batches;
  final bool truncated;
}

/// One voucher of a batch, as `view_batch` lists it.
@immutable
class AirdropV3BatchVoucher {
  const AirdropV3BatchVoucher({
    required this.key,
    required this.value,
    required this.gas,
    required this.redeemed,
  });

  final String key;
  final BigInt value;
  final BigInt gas;
  final bool redeemed;
}

/// One batch (`view_batch`), whoever created it.
@immutable
class AirdropV3BatchDetail {
  const AirdropV3BatchDetail({
    required this.id,
    required this.creator,
    required this.assetId,
    required this.created,
    required this.gasPerVoucher,
    required this.createdAtHeight,
    required this.vouchers,
  });

  /// `{"batch": {creator, asset_id, created, gas_per_voucher, created_at,
  /// vouchers: [{key, batch_id, asset_id, value, gas, redeemed, ...}]}}`.
  factory AirdropV3BatchDetail.fromOutput(Map<String, Object?> out, BigInt id) {
    final b = ShaderOutput.map(out['batch'], 'batch');
    return AirdropV3BatchDetail(
      id: id,
      creator: _pubKey(b, 'creator'),
      assetId: ShaderOutput.uint32(b, 'asset_id'),
      created: ShaderOutput.uint32(b, 'created'),
      gasPerVoucher: ShaderOutput.amount(b, 'gas_per_voucher'),
      createdAtHeight: ShaderOutput.amount(b, 'created_at'),
      vouchers: List.unmodifiable([
        for (final row in ShaderOutput.list(b['vouchers'], 'vouchers'))
          () {
            final v = AirdropV3VoucherInfo.fromJson(
              ShaderOutput.map(row, 'vouchers[]'),
            );
            if (v.batchId != id) {
              throw const FormatException('vouchers[]: another batch');
            }
            return AirdropV3BatchVoucher(
              key: v.key,
              value: v.value,
              gas: v.gas,
              redeemed: v.redeemed,
            );
          }(),
      ]),
    );
  }

  final BigInt id;

  /// The key that created it (`CreatorID{cid, 0}` of its wallet). Public.
  final String creator;
  final int assetId;
  final int created;
  final BigInt gasPerVoucher;
  final BigInt createdAtHeight;
  final List<AirdropV3BatchVoucher> vouchers;
}

/// `voucher_key`: the seed and key the shader derives for a code.
@immutable
class AirdropV3DerivedKey {
  const AirdropV3DerivedKey({required this.seedHex, required this.key});

  factory AirdropV3DerivedKey.fromOutput(Map<String, Object?> out) {
    final seed = ShaderOutput.string(out, 'seed');
    if (!_hex32.hasMatch(seed)) {
      throw const FormatException('seed: not 32 bytes');
    }
    return AirdropV3DerivedKey(seedHex: seed, key: _pubKey(out, 'key'));
  }

  /// Secret, like the code.
  final String seedHex;
  final String key;

  @override
  String toString() => 'AirdropV3DerivedKey(<seed>, $key)';
}
