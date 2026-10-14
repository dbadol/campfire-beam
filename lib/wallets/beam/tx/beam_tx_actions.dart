/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../models/beam_address.dart';
import '../models/beam_call_results.dart';
import '../models/beam_transaction.dart';

/// What the transaction details screen may offer, decided exactly as the
/// core decides it, so a button never appears only to fail.
abstract final class BeamTxActions {
  /// `TxDescription::canCancel` (`wallet/core/common.cpp:946`): pending or
  /// in progress. The core can still refuse once the kernel is being
  /// registered; the UI then says so instead of showing an error code.
  static bool canCancel(BeamTransaction tx) =>
      tx.status == BeamTxStatus.pending || tx.status == BeamTxStatus.inProgress;

  /// `TxDescription::canDelete` (`common.cpp:952`): only finished ones.
  /// Deleting removes the wallet's record only; nothing changes on chain.
  static bool canDelete(BeamTransaction tx) =>
      tx.status == BeamTxStatus.completed ||
      tx.status == BeamTxStatus.failed ||
      tx.status == BeamTxStatus.canceled;

  /// A payment proof exists for a completed payment this wallet sent.
  static bool canExportProof(BeamTransaction tx) =>
      tx.status == BeamTxStatus.completed &&
      tx.income == false &&
      tx.txType == BeamTxType.simple;

  /// One line for the status chip, in plain words. Regular (SBBS)
  /// payments need both wallets online, which is the most common reason a
  /// payment seems stuck; the text says so.
  static String statusLine(BeamTransaction tx) {
    final incoming = tx.income ?? false;
    final l = appL10n;
    return switch (tx.status) {
      BeamTxStatus.pending || BeamTxStatus.inProgress when _interactive(tx) =>
        incoming ? l.txStatusWaitingForSender : l.txStatusWaitingForReceiver,
      BeamTxStatus.pending || BeamTxStatus.inProgress => l.txStatusInProgress,
      BeamTxStatus.registering => l.txStatusRegistering,
      BeamTxStatus.confirming => l.txStatusConfirming,
      BeamTxStatus.completed => incoming ? l.txStatusReceived : l.txStatusSent,
      BeamTxStatus.canceled => l.txStatusCancelled,
      BeamTxStatus.failed => _failure(tx),
      BeamTxStatus.unknown => l.txStatusUnknown,
    };
  }

  static bool _interactive(BeamTransaction tx) =>
      tx.txType == BeamTxType.simple &&
      (tx.addressType == null ||
          tx.addressType == BeamAddressType.regular ||
          tx.addressType == BeamAddressType.regularNew);

  /// What a failed transaction's status line says when the core's message
  /// is not one [failureSentence] knows. The core's own words stay behind
  /// "Copy technical details"; they are not written for people.
  static String get notCompleted => appL10n.txStatusNotCompleted;

  /// The status line of a failed transaction the core gave no reason for.
  static String get failed => appL10n.txStatusFailed;

  static String _failure(BeamTransaction tx) {
    final r = (tx.failureReason ?? '').trim();
    if (r.isEmpty) return failed;
    return failureSentence(r, interactive: _interactive(tx)) ?? notCompleted;
  }

  /// Plain words for a failure message the core really sends
  /// (`BEAM_TX_FAILURE_REASON_MAP`, wallet/core/common.h, tag
  /// beam-7.5.14493), or null when [reason] is empty or not one of them.
  /// A failed BEAM transaction never reached a block, so every sentence
  /// says that nothing was sent. [interactive] is a regular payment, where
  /// a timeout means the other wallet never answered.
  static String? failureSentence(String? reason, {required bool interactive}) {
    final r = (reason ?? '').trim().toLowerCase();
    if (r.isEmpty) return null;
    final l = appL10n;
    // Order matters: "Address is expired" must not read as a timeout.
    if (r.contains('address is expired')) return l.txFailAddressExpired;
    if (r.contains('timed out') || r.contains('expired')) {
      return interactive ? l.txFailExpiredOtherWallet : l.txFailExpiredNoBlock;
    }
    if (r.contains('inputs missing') || r.contains('spent')) {
      return l.txFailCoinsSpent;
    }
    if (r.contains('failed to register')) return l.txFailNotAccepted;
    if (r.contains('not enough inputs')) return l.txFailNotEnoughCoins;
    if (r.contains('fee is too small')) return l.txFailFeeTooLow;
    if (r.contains('fee is too large') || r.contains('fee is too big')) {
      return l.txFailFeeTooLarge;
    }
    if (r.contains('not signed by the receiver')) return l.txFailNotSigned;
    if (r.contains('transaction parameters')) return l.txFailUnreachable;
    if (r.contains('no voucher') || r.contains('cannot get vouchers')) {
      return l.txFailNoVouchers;
    }
    if (r.contains('disabled in the receiver wallet')) return l.txFailNoTokens;
    if (r.contains('aborted by the user')) return l.txStatusCancelled;
    if (r.contains('cancel')) return l.txFailCancelledByOther;
    if (r.contains('send wallet logs') ||
        r.contains('not valid') ||
        r.contains('kernel') ||
        r.contains('key keeper') ||
        r.contains('invalid state')) {
      return l.txFailWalletCouldNotComplete;
    }
    return null;
  }
}

/// A payment proof checked by the core, put into words.
class BeamProofVerdict {
  const BeamProofVerdict._(this.valid, this.sentence);

  /// [info] from `verify_payment_proof`; [describeAmount] formats the amount
  /// with its asset (the UI's formatter).
  factory BeamProofVerdict.of(
    BeamPaymentProofInfo info, {
    required String Function(BigInt amount, int assetId) describeAmount,
  }) {
    if (!info.isValid) {
      return BeamProofVerdict._(false, appL10n.txProofInvalid);
    }
    return BeamProofVerdict._(
      true,
      appL10n.txProofValid(
        describeAmount(info.amount, info.assetId),
        _short(info.sender),
        _short(info.receiver),
        _short(info.kernel),
      ),
    );
  }

  final bool valid;
  final String sentence;

  static String _short(String s) =>
      s.length <= 16 ? s : '${s.substring(0, 8)}…${s.substring(s.length - 6)}';
}
