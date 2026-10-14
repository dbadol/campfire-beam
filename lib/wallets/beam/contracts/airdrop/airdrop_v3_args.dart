/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'airdrop_v3_constants.dart';

final _u64Max = (BigInt.one << 64) - BigInt.one;

/// One voucher of a new batch as `create_batch` takes it: its code's seed
/// (`AirdropV3Code.seed`, secret) and its value in the asset's smallest
/// unit.
@immutable
class AirdropV3SeedEntry {
  AirdropV3SeedEntry(List<int> seed, this.value)
    : seed = Uint8List.fromList(seed) {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'a seed is 32 bytes');
    }
    if (value <= BigInt.zero || value > _u64Max) {
      throw ArgumentError.value(value, 'value', 'must be 1..2^64-1');
    }
  }

  final Uint8List seed;
  final BigInt value;

  @override
  String toString() => 'AirdropV3SeedEntry(<seed>, $value)';
}

/// `args` strings for the pinned Airdrop v3 app shader. Pure functions;
/// every input is validated so nothing the shader would misread is sent.
///
/// Every action names its contract and every argument it needs (the shader
/// builds nothing from a default). There is deliberately no builder for
/// `sponsor_gas`, `view_gas` or any owner (`role=manager`) action: the gas
/// pool is off and the app never offers them (README "Checklist for
/// wallets" 6 and 8). A claim always passes `use_gas_pool=0`, and no
/// action ever passes a fee: the wallet pays what the declared charge sets,
/// which prepaid claim fees cover exactly.
abstract final class AirdropV3Args {
  static final _code = RegExp(r'^[A-Z0-9]{1,64}$');

  /// `create_batch`: lock the [entries]' values (plus the 1% creation fee)
  /// of [assetId], and [gasPerVoucher] BEAM per voucher (0, or exactly
  /// `kAirdropV3GasPerVoucher`). `seeds` is hex: each entry's 32-byte seed
  /// then its 8-byte little-endian value.
  static String createBatch({
    required int assetId,
    required BigInt gasPerVoucher,
    required List<AirdropV3SeedEntry> entries,
  }) => _join('create_batch', {
    'asset_id': _assetId(assetId),
    'count': '${entries.length}',
    'gas_per_voucher': gas(gasPerVoucher).toString(),
    'seeds': _hex(seedsBlob(entries)),
  });

  /// `redeem`: claim with the **normalised** code. The shader turns it into
  /// the voucher's key and signs the claim; neither the code nor its secret
  /// goes into the transaction. The gas pool is never asked.
  static String redeem({required String normalisedCode}) =>
      _join('redeem', {'code': _codeArg(normalisedCode), 'use_gas_pool': '0'});

  /// `check_voucher`: what the code's voucher holds, by the code (the
  /// shader derives the key). `{"voucher": {key, batch_id, asset_id, value,
  /// gas, redeemed, redeemed_at?, pool_gas?, claim_fee?}}`, or the error
  /// `voucher not found`.
  static String checkVoucher({required String normalisedCode}) =>
      _join('check_voucher', {'code': _codeArg(normalisedCode)});

  /// `voucher_key`: the seed and key the shader derives for a code
  /// (`{"seed": hex, "key": hex}`); for checking this module against it.
  static String voucherKey({required String normalisedCode}) =>
      _join('voucher_key', {'code': _codeArg(normalisedCode)});

  /// `view_my_batches`: this wallet's batches, at most 200 (`truncated`).
  static String viewMyBatches() => _join('view_my_batches', const {});

  /// `view_batch`: one batch with its creator and every voucher.
  static String viewBatch({required BigInt batchId}) =>
      _join('view_batch', {'batch_id': _u64(batchId, 'batchId')});

  /// `cancel_batch`: take back every unclaimed voucher of [batchId]; the
  /// shader lists them from chain state.
  static String cancelBatch({required BigInt batchId}) =>
      _join('cancel_batch', {'batch_id': _u64(batchId, 'batchId')});

  /// 0, or exactly 0.022 BEAM: the only prepaid claim fees the app offers.
  static BigInt gas(BigInt gasPerVoucher) {
    if (gasPerVoucher != BigInt.zero &&
        gasPerVoucher != kAirdropV3GasPerVoucher) {
      throw ArgumentError.value(
        gasPerVoucher,
        'gasPerVoucher',
        'the prepaid claim fee is 0 or 0.022 BEAM',
      );
    }
    return gasPerVoucher;
  }

  /// The `seeds=` bytes: 1 to 100 entries, no seed twice.
  static Uint8List seedsBlob(List<AirdropV3SeedEntry> entries) {
    if (entries.isEmpty || entries.length > kAirdropV3MaxVouchersPerBatch) {
      throw ArgumentError.value(
        entries.length,
        'entries',
        'a batch holds 1 to $kAirdropV3MaxVouchersPerBatch codes',
      );
    }
    final out = Uint8List(40 * entries.length);
    final seen = <String>{};
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (!seen.add(_hex(e.seed))) {
        throw ArgumentError.value(i, 'entries', 'the same code twice');
      }
      out.setRange(40 * i, 40 * i + 32, e.seed);
      var v = e.value;
      for (var j = 0; j < 8; j++) {
        out[40 * i + 32 + j] = (v & BigInt.from(0xff)).toInt();
        v >>= 8;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- helpers

  static String _join(String action, Map<String, String> p) => [
    'role=user',
    'action=$action',
    'cid=$kAirdropV3ContractId',
    for (final e in p.entries) '${e.key}=${e.value}',
  ].join(',');

  /// 1 to 64 of A-Z and 0-9: no `,`, `=` or quote can reach the args.
  static String _codeArg(String normalised) {
    if (!_code.hasMatch(normalised)) {
      throw ArgumentError.value(
        '<${normalised.length} chars>',
        'normalisedCode',
        '1 to 64 of A-Z and 0-9 (normalise it first)',
      );
    }
    return normalised;
  }

  static String _assetId(int id) {
    if (id < 0 || id > 0xffffffff) {
      throw ArgumentError.value(id, 'assetId', 'asset ids are 0..2^32-1');
    }
    return '$id';
  }

  static String _u64(BigInt v, String name) {
    if (v.isNegative || v > _u64Max) {
      throw ArgumentError.value(v, name, 'not a 64-bit unsigned number');
    }
    return v.toString();
  }

  static String _hex(List<int> b) =>
      [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}
