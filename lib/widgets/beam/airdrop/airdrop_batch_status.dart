/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import 'beam_blocks.dart';

/// A status in plain words with how loudly to show it.
typedef BeamStatusText = ({String text, BeamNoticeKind kind});

/// One saved batch's state, from its codes as last checked and, when it is
/// still on chain, the contract's own counts.
BeamStatusText airdropBatchStatus(
  AirdropSavedBatch? saved,
  AirdropBatch? chain,
) {
  final l = appL10n;
  if (chain != null) {
    final claimed = chain.redeemedCount;
    final left = chain.unclaimedCount;
    if (left == 0) {
      return (
        text: l.airdropStatusAllClaimed(claimed),
        kind: BeamNoticeKind.success,
      );
    }
    return (
      text: l.airdropStatusClaimedWaiting(claimed, chain.totalCount, left),
      kind: BeamNoticeKind.info,
    );
  }
  if (saved == null) {
    return (text: l.airdropStatusNotChecked, kind: BeamNoticeKind.warning);
  }
  var available = 0, claimed = 0, gone = 0, unknown = 0;
  for (final c in saved.codes) {
    switch (c.status) {
      case AirdropCodeStatus.available:
        available++;
      case AirdropCodeStatus.claimed:
        claimed++;
      case AirdropCodeStatus.notFound:
        gone++;
      case AirdropCodeStatus.unknown:
        unknown++;
    }
  }
  final n = saved.count;
  final pending =
      saved.txStatus == AirdropBatchTxStatus.unconfirmed ||
      saved.txStatus == AirdropBatchTxStatus.broadcast;
  if (saved.txStatus == AirdropBatchTxStatus.failed &&
      available == 0 &&
      claimed == 0) {
    return (text: l.airdropStatusNotCreated, kind: BeamNoticeKind.danger);
  }
  if (claimed == n) {
    return (text: l.airdropStatusAllClaimed(n), kind: BeamNoticeKind.success);
  }
  if (available > 0) {
    return (
      text: l.airdropStatusClaimedWaiting(claimed, n, available),
      kind: BeamNoticeKind.info,
    );
  }
  if (pending && (unknown > 0 || gone == n)) {
    return (text: l.airdropStatusWaitingNetwork, kind: BeamNoticeKind.warning);
  }
  if (gone > 0 && unknown == 0) {
    return (
      text: claimed > 0
          ? l.airdropStatusClaimedCancelled(claimed, gone)
          : l.airdropStatusCancelled,
      kind: BeamNoticeKind.info,
    );
  }
  return (text: l.airdropStatusNotChecked, kind: BeamNoticeKind.warning);
}

/// One code's state, for its pill.
BeamStatusText airdropCodeStatus(
  AirdropSavedCode code,
  AirdropBatchTxStatus batch,
) => switch (code.status) {
  AirdropCodeStatus.available => (
    text: appL10n.airdropCodeStatusUnclaimed,
    kind: BeamNoticeKind.success,
  ),
  AirdropCodeStatus.claimed => (
    text: appL10n.airdropCodeStatusClaimed,
    kind: BeamNoticeKind.info,
  ),
  AirdropCodeStatus.notFound =>
    batch == AirdropBatchTxStatus.confirmed
        ? (
            text: appL10n.airdropCodeStatusCancelled,
            kind: BeamNoticeKind.danger,
          )
        : (
            text: appL10n.airdropCodeStatusNotActive,
            kind: BeamNoticeKind.warning,
          ),
  AirdropCodeStatus.unknown => (
    text: appL10n.airdropStatusNotChecked,
    kind: BeamNoticeKind.warning,
  ),
};

/// Mirrors the checks of `BeamAirdropService.forgetSavedBatch` on the
/// batch as last refreshed, so "Remove from this list" is only offered
/// when the service will allow it. The service checks the chain again.
bool airdropBatchLooksSettled(AirdropSavedBatch b, DateTime now) {
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
      now.toUtc().difference(b.createdAt) > BeamAirdropService.staleAfter;
  final settled =
      b.txStatus == AirdropBatchTxStatus.confirmed ||
      b.txStatus == AirdropBatchTxStatus.failed ||
      stale;
  return !anyAvailable && allGone && settled;
}
