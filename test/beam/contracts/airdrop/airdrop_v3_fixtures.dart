/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A fake Airdrop v3 app shader: answers `invoke_contract` the way the pinned
// v3 app shader (contracts/v3/app.cpp) does, from an in-memory contract, so
// the v3 service and the airdrop screens run end to end. Its voucher keys
// are derived with AirdropV3Code, which airdrop_v3_test.dart checks against
// keys the real shader printed on mainnet. Every code here is made up: none
// unlocks anything on mainnet.

import 'dart:convert';

import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';

import 'airdrop_fixtures.dart';
import 'invoke_data_writer.dart';

/// This wallet's v3 creator key in the fake (synthetic).
const v3Creator =
    '7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c01';

/// Another wallet's creator key.
const v3Other =
    '5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b00';

/// The receiving key the fake's claims name.
const v3Redeemer =
    '3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d00';

class FakeV3Voucher {
  FakeV3Voucher(
    this.batchId,
    this.assetId,
    this.value,
    this.gas, {
    this.redeemed = false,
  });

  final BigInt batchId;
  final int assetId;
  final BigInt value;
  final BigInt gas;
  bool redeemed;
}

class FakeV3Batch {
  FakeV3Batch(this.creator, this.assetId, this.created, this.gas);

  final String creator;
  final int assetId;
  final int created;
  final BigInt gas;
}

/// A built `create_batch` not mined yet.
typedef FakeV3Pending = ({
  String creator,
  int assetId,
  BigInt gas,
  List<({String key, BigInt value})> entries,
});

class FakeAirdropV3Shader {
  FakeAirdropV3Shader({this.creator = v3Creator});

  /// This wallet's creator key.
  final String creator;

  /// Vouchers by key.
  final vouchers = <String, FakeV3Voucher>{};
  final batches = <BigInt, FakeV3Batch>{};
  BigInt _next = BigInt.one;

  /// Every `args` seen.
  final seen = <String>[];

  /// The last built create, until [mine] makes it real.
  FakeV3Pending? pending;

  /// Applied to each built entry before it is serialized.
  FakeInvokeEntry Function(FakeInvokeEntry e)? tamper;

  /// Applied to a create's output (`total`, `fee`, `gas_total`).
  Map<String, Object?> Function(Map<String, Object?> out)? outputTamper;

  /// Pool gas a built claim asks for (the app must refuse anything but 0).
  BigInt pool = BigInt.zero;

  /// `view_my_batches` says `truncated` and lists only [listed] when set.
  bool truncated = false;
  Set<BigInt>? listed;

  /// Runs before each answer: a test can change the contract in between
  /// (a claim landing while a take-back is prepared).
  void Function(Map<String, String> args)? beforeAnswer;

  /// Overrides `check_voucher` (a node that answers for another voucher).
  Map<String, Object?>? Function(String code)? checkOverride;

  /// Makes a create real: its vouchers exist under a new batch.
  BigInt mine(FakeV3Pending p) {
    final id = _next;
    _next += BigInt.one;
    batches[id] = FakeV3Batch(p.creator, p.assetId, p.entries.length, p.gas);
    for (final e in p.entries) {
      vouchers[e.key] = FakeV3Voucher(id, p.assetId, e.value, p.gas);
    }
    return id;
  }

  /// A batch of [codes] (each worth [value]) made by [by], mined.
  BigInt addBatch(
    List<String> codes,
    int assetId,
    BigInt value, {
    BigInt? gas,
    String? by,
  }) => mine((
    creator: by ?? creator,
    assetId: assetId,
    gas: gas ?? BigInt.zero,
    entries: [
      for (final c in codes) (key: AirdropV3Code.voucherKey(c), value: value),
    ],
  ));

  Map<String, Object?> call(Map<String, Object?> params) {
    if (params['create_tx'] != false) {
      throw StateError('create_tx must be false');
    }
    final contract = params['contract'];
    if (contract is! List || contract.length != kAirdropV3AppShaderSize) {
      throw StateError('not the v3 app shader');
    }
    final raw = params['args']! as String;
    seen.add(raw);
    final a = parseArgs(raw);
    beforeAnswer?.call(a);
    if (a['cid'] != kAirdropV3ContractId) {
      return _out({
        'error':
            'no Airdrop v3 contract at this cid (shader ID does not match)',
      });
    }
    switch ((a['role'], a['action'])) {
      case ('user', 'check_voucher'):
        final o = checkOverride?.call(a['code']!);
        if (o != null) return _out(o);
        final key = AirdropV3Code.voucherKey(a['code']!);
        final v = vouchers[key];
        if (v == null) return _out({'error': 'voucher not found'});
        return _out({'voucher': _voucherJson(key, v)});
      case ('user', 'voucher_key'):
        final seed = AirdropV3Code.seed(a['code']!);
        return _out({
          'seed': _hex(seed),
          'key': AirdropV3Code.voucherKey(a['code']!),
        });
      case ('user', 'view_my_batches'):
        final rows = [
          for (final e in batches.entries)
            if (e.value.creator == creator &&
                (listed == null || listed!.contains(e.key)))
              _batchRow(e.key, e.value),
        ];
        return _out({'batches': rows, 'truncated': truncated ? 1 : 0});
      case ('user', 'view_batch'):
        final id = BigInt.parse(a['batch_id']!);
        final b = batches[id];
        if (b == null) return _out({'error': 'batch not found'});
        return _out({
          'batch': {
            'creator': b.creator,
            'asset_id': b.assetId,
            'created': b.created,
            'gas_per_voucher': b.gas.toInt(),
            'created_at': 4080000,
            'vouchers': [
              for (final e in vouchers.entries)
                if (e.value.batchId == id) _voucherJson(e.key, e.value),
            ],
          },
        });
      case ('user', 'create_batch'):
        return _create(a);
      case ('user', 'redeem'):
        return _redeem(a);
      case ('user', 'cancel_batch'):
        return _cancel(a);
    }
    return _out({'error': 'unknown role or action'});
  }

  Map<String, Object?> _create(Map<String, String> a) {
    final aid = int.parse(a['asset_id']!);
    final n = int.parse(a['count']!);
    final gas = BigInt.parse(a['gas_per_voucher']!);
    if (gas != BigInt.zero && gas < BigInt.from(2100000)) {
      return _out({
        'error': 'gas_per_voucher must be 0 or at least the claim fee',
      });
    }
    final blob = InvokeDataWriter.hexBytes(a['seeds']!);
    if (blob.length != 40 * n) {
      return _out({
        'error': 'missing or invalid argument',
        'argument': 'seeds',
      });
    }
    final entries = <({String key, BigInt value})>[];
    for (var i = 0; i < n; i++) {
      final seed = blob.sublist(40 * i, 40 * i + 32);
      var v = BigInt.zero;
      for (var j = 7; j >= 0; j--) {
        v = (v << 8) | BigInt.from(blob[40 * i + 32 + j]);
      }
      entries.add((
        key: AirdropV3Code.keyOfSecret(AirdropV3Code.secret(seed)),
        value: v,
      ));
    }
    final total = entries.fold(BigInt.zero, (s, e) => s + e.value);
    final fee = AirdropV3Fee.creationFee(total);
    pending = (creator: creator, assetId: aid, gas: gas, entries: entries);
    var out = <String, Object?>{
      'total': total.toInt(),
      'fee': fee.toInt(),
      'gas_total': (gas * BigInt.from(n)).toInt(),
    };
    if (outputTamper != null) out = outputTamper!(out);
    return _built(
      out,
      AirdropV3Method.createBatch,
      [
        ...InvokeDataWriter.hexBytes(creator),
        ...InvokeDataWriter.le(BigInt.from(aid), 4),
        ...InvokeDataWriter.le(BigInt.from(n), 4),
        ...InvokeDataWriter.le(gas, 8),
        for (final e in entries) ...[
          ...InvokeDataWriter.hexBytes(e.key),
          ...InvokeDataWriter.le(e.value, 8),
        ],
      ],
      _funds(aid, total + fee, gas * BigInt.from(n), 1),
      AirdropV3KernelComment.createBatch,
      AirdropV3Charge.createBatch(n),
      AirdropV3SigningKeys.creator(),
    );
  }

  Map<String, Object?> _redeem(Map<String, String> a) {
    if (a['use_gas_pool'] != '0' && a['use_gas_pool'] != '1') {
      return _out({
        'error': 'missing or invalid argument',
        'argument': 'use_gas_pool',
      });
    }
    final key = AirdropV3Code.voucherKey(a['code']!);
    final v = vouchers[key];
    if (v == null) return _out({'error': 'voucher not found'});
    if (v.redeemed) return _out({'error': 'voucher already redeemed'});
    return _built(
      {
        'asset_id': v.assetId,
        'value': v.value.toInt(),
        'gas': v.gas.toInt(),
        'gas_source': v.gas > BigInt.zero ? 'voucher' : 'none',
      },
      AirdropV3Method.redeem,
      [
        ...InvokeDataWriter.hexBytes(key),
        ...InvokeDataWriter.hexBytes(v3Redeemer),
        ...InvokeDataWriter.le(pool, 8),
        ...List.filled(65, 0x42),
      ],
      _funds(v.assetId, v.value, v.gas, -1),
      AirdropV3KernelComment.redeem,
      AirdropV3Charge.redeem,
      AirdropV3SigningKeys.claimer(key),
    );
  }

  Map<String, Object?> _cancel(Map<String, String> a) {
    final id = BigInt.parse(a['batch_id']!);
    final b = batches[id];
    if (b == null) return _out({'error': 'batch not found'});
    if (b.creator != creator) {
      return _out({'error': 'this wallet did not create the batch'});
    }
    final open = [
      for (final e in vouchers.entries)
        if (e.value.batchId == id && !e.value.redeemed) e,
    ];
    if (open.isEmpty) {
      return _out({'error': 'no unclaimed vouchers in this batch'});
    }
    final value = open.fold(BigInt.zero, (s, e) => s + e.value.value);
    final gas = open.fold(BigInt.zero, (s, e) => s + e.value.gas);
    return _built(
      {'cancelled': open.length, 'value': value.toInt(), 'gas': gas.toInt()},
      AirdropV3Method.cancelBatch,
      [
        ...InvokeDataWriter.hexBytes(creator),
        ...InvokeDataWriter.le(id, 8),
        ...InvokeDataWriter.le(BigInt.from(open.length), 4),
        for (final e in open) ...InvokeDataWriter.hexBytes(e.key),
      ],
      _funds(b.assetId, value, gas, -1),
      AirdropV3KernelComment.cancelBatch,
      AirdropV3Charge.cancelBatch(open.length),
      AirdropV3SigningKeys.creator(),
    );
  }

  Map<String, Object?> _batchRow(BigInt id, FakeV3Batch b) {
    final of = [
      for (final v in vouchers.values)
        if (v.batchId == id) v,
    ];
    final open = of.where((v) => !v.redeemed).toList();
    final redeemed = of.length - open.length;
    return {
      'id': id.toInt(),
      'asset_id': b.assetId,
      'created': b.created,
      'unclaimed': open.length,
      'redeemed': redeemed,
      'cancelled': b.created - open.length - redeemed,
      'value_unclaimed': open.fold(BigInt.zero, (s, v) => s + v.value).toInt(),
      'gas_per_voucher': b.gas.toInt(),
      'created_at': 4080000,
    };
  }

  static Map<String, Object?> _voucherJson(String key, FakeV3Voucher v) => {
    'key': key,
    'batch_id': v.batchId.toInt(),
    'asset_id': v.assetId,
    'value': v.value.toInt(),
    'gas': v.gas.toInt(),
    'redeemed': v.redeemed ? 1 : 0,
    if (v.redeemed) 'redeemed_at': 4080001,
    if (!v.redeemed) 'pool_gas': 0,
    if (!v.redeemed) 'claim_fee': 2100000,
  };

  static Map<int, BigInt> _funds(int aid, BigInt value, BigInt gas, int sign) {
    final m = <int, BigInt>{};
    void add(int k, BigInt v) {
      if (v == BigInt.zero) return;
      m[k] = (m[k] ?? BigInt.zero) + (sign < 0 ? -v : v);
    }

    add(aid, value);
    add(0, gas);
    return m;
  }

  /// The cancel taking keys out of the contract, as a mined take-back does.
  void removeVouchers(Iterable<String> keys) {
    for (final k in keys) {
      vouchers.remove(k);
    }
  }

  Map<String, Object?> _out(Map<String, Object?> json) => {
    'output': jsonEncode(json),
  };

  Map<String, Object?> _built(
    Map<String, Object?> output,
    int method,
    List<int> args,
    Map<int, BigInt> funds,
    String comment,
    int charge,
    String signer,
  ) {
    var e = FakeInvokeEntry(
      method: method,
      cid: kAirdropV3ContractId,
      args: args,
      funds: funds,
      comment: comment,
      charge: charge,
      sigs: [InvokeDataWriter.hexBytes(signer)],
    );
    final t = tamper;
    if (t != null) e = t(e);
    return {
      'output': jsonEncode(output),
      'raw_data': InvokeDataWriter.write([e]),
      'txid': '00000000000000000000000000000000',
    };
  }

  static String _hex(List<int> b) =>
      [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}

/// One `invoke_contract` for both airdrop contracts: each fake answers the
/// calls naming its contract.
Map<String, Object?> Function(Map<String, Object?>) airdropRouter(
  FakeAirdropShader old,
  FakeAirdropV3Shader v3,
) => (p) {
  final args = p['args'];
  return args is String && args.contains('cid=$kAirdropV3ContractId')
      ? v3(p)
      : old(p);
};

/// A copy of [e] with [args] in place of its arguments.
FakeInvokeEntry withArgs(FakeInvokeEntry e, List<int> args) => FakeInvokeEntry(
  method: e.method,
  cid: e.cid,
  args: args,
  funds: e.funds,
  comment: e.comment,
  charge: e.charge,
  sigs: e.sigs,
);

/// A copy of [e] with some fields replaced.
FakeInvokeEntry changed(
  FakeInvokeEntry e, {
  int? method,
  String? cid,
  Map<int, BigInt>? funds,
  String? comment,
  int? charge,
  List<List<int>>? sigs,
}) => FakeInvokeEntry(
  method: method ?? e.method,
  cid: cid ?? e.cid,
  args: e.args,
  funds: funds ?? e.funds,
  comment: comment ?? e.comment,
  charge: charge ?? e.charge,
  sigs: sigs ?? e.sigs,
);
