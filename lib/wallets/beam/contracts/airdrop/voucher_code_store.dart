/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'airdrop_v3_constants.dart';
import 'voucher_code.dart';

/// Where a created batch's codes live. The app implements it on Campfire's
/// secure storage (encrypted, included in the wallet backup), never in a
/// cache, a log or plain preferences.
///
/// The codes are the only key to the locked funds: redeeming needs a code,
/// and handing the airdrop out needs all of them. LightWallet kept them in
/// browser storage and once wrote them only after broadcasting, so a crash
/// in between stranded funds for good. The rules here:
///
/// * `BeamAirdropService` calls [put] with every code **before** it
///   broadcasts the batch, and does not broadcast if [put] throws.
/// * Nothing in this module ever calls [delete] on its own. The service
///   offers `forgetSavedBatch` only for batches that can no longer hold
///   funds, and only on an explicit user request.
abstract class VoucherCodeStore {
  /// Inserts or replaces [batch] by [AirdropSavedBatch.localId]. Completes
  /// only once the write is durable (flushed to disk): the service
  /// broadcasts right after.
  Future<void> put(AirdropSavedBatch batch);

  /// Every saved batch, any order.
  Future<List<AirdropSavedBatch>> all();

  /// Removes one batch. Only for `BeamAirdropService.forgetSavedBatch`.
  Future<void> delete(String localId);
}

/// Where a saved batch's transaction stands.
enum AirdropBatchTxStatus {
  /// Codes saved; the transaction was not sent, or sending it failed in a
  /// way that does not prove it never reached the network (a timeout, a
  /// lost connection). Never treat this as "nothing happened" without
  /// checking the contract: the codes may lock real funds.
  unconfirmed,

  /// Sent; [AirdropSavedBatch.txId] is known; not yet confirmed.
  broadcast,

  /// The transaction completed: the vouchers exist on chain.
  confirmed,

  /// The core reports the transaction failed or was cancelled: no funds
  /// were locked by it.
  failed,
}

/// What is known about one code, from `check_voucher`.
enum AirdropCodeStatus {
  /// Not checked yet (or the batch is not confirmed).
  unknown,

  /// On chain and unclaimed.
  available,

  /// Redeemed by someone.
  claimed,

  /// The contract has no voucher for it: never created, or cancelled.
  notFound,
}

/// One saved code.
@immutable
class AirdropSavedCode {
  const AirdropSavedCode({
    required this.code,
    required this.hashHex,
    required this.value,
    this.status = AirdropCodeStatus.unknown,
    this.key,
  });

  factory AirdropSavedCode.fromJson(Map<String, Object?> json) {
    final code = json['code'];
    final hash = json['hash'];
    final value = json['value'];
    final status = json['status'];
    final key = json['key'];
    if (code is! String || hash is! String || value is! String) {
      throw const FormatException('saved code: missing field');
    }
    // A v3 voucher key that is not a key: the record is unreadable (kept,
    // never shown as if it were fine).
    if (key != null && (key is! String || !_pubKey.hasMatch(key))) {
      throw const FormatException('saved code: bad voucher key');
    }
    final parsed = BigInt.tryParse(value);
    if (parsed == null || parsed <= BigInt.zero) {
      throw const FormatException('saved code: bad value');
    }
    if (AirdropVoucherCode.normalise(code).isEmpty ||
        AirdropVoucherCode.hashHex(code) != hash) {
      throw const FormatException('saved code: hash does not match code');
    }
    return AirdropSavedCode(
      code: AirdropVoucherCode.format(code),
      hashHex: hash,
      value: parsed,
      status: AirdropCodeStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => AirdropCodeStatus.unknown,
      ),
      key: key as String?,
    );
  }

  /// Formatted, `XXXX-XXXX-XXXX-XXXX`. Secret.
  final String code;

  /// SHA-256 of the normalised code: the old contract's key for it, and
  /// this record's identifier for every code.
  final String hashHex;
  final BigInt value;
  final AirdropCodeStatus status;

  /// Airdrop v3 only: the voucher's public key, derived on this device when
  /// the batch was built (`AirdropV3Code.voucherKey`). Public on chain.
  final String? key;

  AirdropSavedCode withStatus(AirdropCodeStatus s) => AirdropSavedCode(
    code: code,
    hashHex: hashHex,
    value: value,
    status: s,
    key: key,
  );

  /// Amounts as decimal strings: JSON numbers lose precision above 2^53.
  Map<String, Object?> toJson() => {
    'code': code,
    'hash': hashHex,
    'value': value.toString(),
    'status': status.name,
    'key': ?key,
  };

  @override
  String toString() => 'AirdropSavedCode(<secret>, $hashHex, $value)';
}

/// A batch this wallet created or tried to create, with its codes.
@immutable
class AirdropSavedBatch {
  AirdropSavedBatch({
    required this.localId,
    required this.contractId,
    required this.assetId,
    required List<AirdropSavedCode> codes,
    required this.createdAt,
    this.txId,
    this.txStatus = AirdropBatchTxStatus.unconfirmed,
    this.gasPerVoucher,
    this.creatorKey,
    this.batchId,
    this.check,
  }) : codes = List.unmodifiable(codes) {
    if (codes.isEmpty) throw ArgumentError.value(codes, 'codes', 'empty');
  }

  factory AirdropSavedBatch.fromJson(Map<String, Object?> json) {
    final id = json['localId'];
    final cid = json['contractId'];
    final aid = json['assetId'];
    final created = json['createdAt'];
    final tx = json['txId'];
    final status = json['txStatus'];
    final codes = json['codes'];
    final gas = json['gasPerVoucher'];
    final creator = json['creatorKey'];
    final batchId = json['batchId'];
    if (id is! String ||
        cid is! String ||
        aid is! int ||
        created is! String ||
        codes is! List) {
      throw const FormatException('saved batch: missing field');
    }
    BigInt? amount(Object? v, String what) {
      if (v == null) return null;
      final b = v is String ? BigInt.tryParse(v) : null;
      if (b == null || b.isNegative) {
        throw FormatException('saved batch: bad $what');
      }
      return b;
    }

    if (creator != null && (creator is! String || !_pubKey.hasMatch(creator))) {
      throw const FormatException('saved batch: bad creator key');
    }
    return AirdropSavedBatch(
      localId: id,
      contractId: cid,
      assetId: aid,
      createdAt: DateTime.parse(created).toUtc(),
      txId: tx is String ? tx : null,
      txStatus: AirdropBatchTxStatus.values.firstWhere(
        (s) => s.name == status,
        // An unreadable status must not look settled.
        orElse: () => AirdropBatchTxStatus.unconfirmed,
      ),
      codes: [
        for (final c in codes)
          AirdropSavedCode.fromJson(
            c is Map ? c.cast<String, Object?>() : const {},
          ),
      ],
      gasPerVoucher: amount(gas, 'prepaid claim fee'),
      creatorKey: creator as String?,
      batchId: amount(batchId, 'batch id'),
      check: AirdropCodeCheck.tryFromJson(json['check']),
    );
  }

  /// This wallet's id for the record (not the on-chain batch id, which is
  /// only known after confirmation).
  final String localId;
  final String contractId;
  final int assetId;
  final List<AirdropSavedCode> codes;
  final DateTime createdAt;
  final String? txId;
  final AirdropBatchTxStatus txStatus;

  /// Airdrop v3 only: BEAM (groth) prepaid per code for its claim's network
  /// fee: 0, or 0.022 BEAM.
  final BigInt? gasPerVoucher;

  /// Airdrop v3 only: the creator key the built batch named (this wallet's
  /// `CreatorID`), saved before signing. Public on chain.
  final String? creatorKey;

  /// Airdrop v3 only: the on-chain batch id, known once the check before
  /// sharing found every code in it.
  final BigInt? batchId;

  /// Airdrop v3 only: the check before sharing, once it has a verdict.
  /// Null until then: the codes are not ready to share.
  final AirdropCodeCheck? check;

  /// A batch on the Airdrop v3 contract.
  bool get isV3 => contractId == kAirdropV3ContractId;

  int get count => codes.length;

  BigInt get total => codes.fold(BigInt.zero, (s, c) => s + c.value);

  AirdropSavedBatch copyWith({
    String? txId,
    AirdropBatchTxStatus? txStatus,
    List<AirdropSavedCode>? codes,
    String? creatorKey,
    BigInt? batchId,
    AirdropCodeCheck? check,
  }) => AirdropSavedBatch(
    localId: localId,
    contractId: contractId,
    assetId: assetId,
    codes: codes ?? this.codes,
    createdAt: createdAt,
    txId: txId ?? this.txId,
    txStatus: txStatus ?? this.txStatus,
    gasPerVoucher: gasPerVoucher,
    creatorKey: creatorKey ?? this.creatorKey,
    batchId: batchId ?? this.batchId,
    check: check ?? this.check,
  );

  Map<String, Object?> toJson() => {
    'localId': localId,
    'contractId': contractId,
    'assetId': assetId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'txId': txId,
    'txStatus': txStatus.name,
    'codes': [for (final c in codes) c.toJson()],
    if (gasPerVoucher != null) 'gasPerVoucher': gasPerVoucher.toString(),
    'creatorKey': ?creatorKey,
    if (batchId != null) 'batchId': batchId.toString(),
    if (check != null) 'check': check!.toJson(),
  };

  @override
  String toString() =>
      'AirdropSavedBatch($localId, asset $assetId, $count codes, '
      '${txStatus.name})';
}

/// The check before a new v3 batch's codes are shared (README "Checklist
/// for wallets" 11): passed, or failed with why.
enum AirdropCheckState { ok, failed }

/// Why a v3 batch's codes failed the check before sharing.
enum AirdropCheckProblem {
  /// A code is not on the network.
  notFound,

  /// A code's voucher has another key than the one derived here.
  otherKey,

  /// A code holds another asset, amount or prepaid fee than was locked.
  otherValue,

  /// A code belongs to another batch than the one this wallet made.
  otherBatch,

  /// The codes' batch was made by another wallet.
  notMine,
}

/// A saved verdict of the check before sharing.
@immutable
class AirdropCodeCheck {
  const AirdropCodeCheck({
    required this.state,
    required this.at,
    this.problem,
    this.index,
  });

  /// A verdict that does not read is no verdict: the batch is checked
  /// again, never shown as ready.
  static AirdropCodeCheck? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final state = AirdropCheckState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    final at = json['at'] is String
        ? DateTime.tryParse(json['at'] as String)
        : null;
    if (state == null || at == null) return null;
    final problem = AirdropCheckProblem.values
        .where((p) => p.name == json['problem'])
        .firstOrNull;
    if (state == AirdropCheckState.failed && problem == null) return null;
    final index = json['index'];
    return AirdropCodeCheck(
      state: state,
      at: at.toUtc(),
      problem: state == AirdropCheckState.ok ? null : problem,
      index: index is int ? index : null,
    );
  }

  final AirdropCheckState state;
  final DateTime at;
  final AirdropCheckProblem? problem;

  /// The code (0-based) the check stopped at, when it was one code.
  final int? index;

  bool get ok => state == AirdropCheckState.ok;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'at': at.toUtc().toIso8601String(),
    'problem': ?problem?.name,
    'index': ?index,
  };
}

final _pubKey = RegExp(r'^[0-9a-f]{64}0[01]$');

/// CSV export of a batch's codes, columns `Number,Code,Value,Asset,Status`
/// as in LightWallet.
abstract final class AirdropCsv {
  static const header = 'Number,Code,Value,Asset,Status';

  /// [formatValue] renders an amount with the asset's own decimals;
  /// [assetLabel] is its ticker. Both can come from untrusted asset
  /// metadata, so every cell is quoted when needed and a cell that a
  /// spreadsheet would run as a formula (`=`, `+`, `-`, `@`, tab, CR) is
  /// prefixed with `'`.
  static String export(
    AirdropSavedBatch batch, {
    required String Function(BigInt amount) formatValue,
    required String assetLabel,
  }) {
    final out = StringBuffer('$header\r\n');
    for (var i = 0; i < batch.codes.length; i++) {
      final c = batch.codes[i];
      out
        ..write(
          [
            '${i + 1}',
            c.code,
            formatValue(c.value),
            assetLabel,
            c.status.name,
          ].map(cell).join(','),
        )
        ..write('\r\n');
    }
    return out.toString();
  }

  /// One RFC 4180 cell, defused against spreadsheet formula injection.
  static String cell(String value) {
    var v = value;
    if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
    if (v.contains(RegExp('[",\r\n]'))) {
      v = '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
}
