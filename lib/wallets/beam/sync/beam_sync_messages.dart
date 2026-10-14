/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Plain-language wording for [BeamSyncAssessment]s, kept apart from the
/// rules so the UI layer can replace it with localized strings.
///
/// No jargon on purpose: no "explorer", "header", "is_in_sync" or "RPC".
/// Every message that blocks sending says so and names the next step.
library;

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';
import 'beam_sync_state.dart';

/// What to show for one assessment.
class BeamSyncMessage {
  const BeamSyncMessage({required this.title, this.detail, this.actionLabel});

  /// One line, suitable for a banner or badge.
  final String title;

  /// Supporting sentence(s), or null when the title says it all.
  final String? detail;

  /// Label for the button that performs [BeamSyncAssessment.action], or null
  /// when there is nothing to press.
  final String? actionLabel;

  @override
  String toString() =>
      '$title${detail == null ? '' : ' | $detail'}'
      '${actionLabel == null ? '' : ' [$actionLabel]'}';
}

abstract final class BeamSyncMessages {
  /// The degraded "synced" state ([BeamSynced.verified] false): the node is
  /// connected and current, but no second source could confirm the height.
  static String get unverifiedDetail => appL10n.syncUnverifiedDetail;

  static BeamSyncMessage describe(BeamSyncAssessment a) {
    final l = appL10n;
    final private = a.node == BeamNodeKind.privateNode;
    final label = actionLabel(a.action);
    return switch (a) {
      BeamSyncConnecting() => BeamSyncMessage(
        title: private ? l.syncConnectingPrivate : l.syncConnectingPublic,
        detail: l.syncConnectingDetail,
        actionLabel: label,
      ),
      BeamSyncNotConnected(:final networkReachable) => BeamSyncMessage(
        title: private ? l.syncCantReachPrivate : l.syncCantReachNetwork,
        detail: private
            ? l.syncPrivateNotAnsweringDetail
            : networkReachable
            ? l.syncNodeNotAnsweringDetail
            : l.syncCheckInternetDetail,
        actionLabel: label,
      ),
      BeamSyncCatchingUp() => BeamSyncMessage(
        title: private ? l.syncCatchingUpPrivate : l.syncCatchingUpPublic,
        detail: _catchingUpDetail(a),
        actionLabel: label,
      ),
      BeamSyncStalled() => _stalled(a, private, label),
      BeamSynced(:final verified) => BeamSyncMessage(
        title: l.syncUpToDate,
        detail: verified ? null : unverifiedDetail,
        actionLabel: label,
      ),
    };
  }

  /// Button text per action; null when the user has nothing to press.
  static String? actionLabel(BeamSyncAction action) => switch (action) {
    BeamSyncAction.none || BeamSyncAction.wait => null,
    BeamSyncAction.tryAnotherNode => appL10n.syncActionTryAnotherNode,
    BeamSyncAction.usePublicNode => appL10n.syncActionUsePublicNode,
    BeamSyncAction.checkInternet => appL10n.syncActionTryAgain,
    BeamSyncAction.reconnect => appL10n.syncActionReconnect,
    BeamSyncAction.fixDeviceClock => appL10n.syncActionCheckAgain,
  };

  static String _catchingUpDetail(BeamSyncCatchingUp a) {
    final l = appL10n;
    if (a.walletHeight == null && a.blocksBehind == null) {
      return l.syncReadingFromStartDetail;
    }
    final behind = a.blocksBehind;
    final eta = a.eta;
    return joinSentences([
      behind != null && behind > 0
          ? l.syncBehindBySentence(
              blockCount(behind),
              approxDuration(a.blockInterval * behind),
            )
          : l.syncGettingLatestBlocks,
      if (eta != null) timeLeft(eta),
      l.syncSendingPaused,
    ]);
  }

  static BeamSyncMessage _stalled(
    BeamSyncStalled a,
    bool private,
    String? label,
  ) {
    final l = appL10n;
    final node = private ? 'private' : 'other';
    final behind = a.blocksBehind;
    final behindSentence = behind != null && behind > 0
        ? l.syncBehindBySentence(
            blockCount(behind),
            approxDuration(a.blockInterval * behind),
          )
        : null;
    switch (a.reason) {
      case BeamStallReason.stuckBelowHardFork:
        final at = a.walletHeight;
        return BeamSyncMessage(
          title: l.syncStuckOldVersionTitle(node),
          detail: joinSentences([
            at == null
                ? l.syncUpgradedAtBlock(number(a.forkHeight))
                : l.syncUpgradedAtBlockStoppedAt(
                    number(a.forkHeight),
                    number(at),
                  ),
            behindSentence,
            l.syncOutOfDateSendingOff,
          ]),
          actionLabel: label,
        );
      case BeamStallReason.tipTooOld:
        final age = a.tipAge;
        return BeamSyncMessage(
          title: l.syncNoNewBlocksTitle(node),
          detail: joinSentences([
            age == null
                ? l.syncNewestBlockOld
                : l.syncNewestBlockAge(approxDuration(age)),
            behindSentence,
            l.syncMayBeOutOfDateSendingOff,
          ]),
          actionLabel: label,
        );
      case BeamStallReason.headerAheadOfProcessed:
        final lag = a.headerLag;
        return BeamSyncMessage(
          title: l.syncNotProcessingTitle,
          detail: joinSentences([
            lag == null
                ? l.syncKnowsNewerBlocks
                : l.syncKnowsUnprocessedBlocks(lag, number(lag)),
            l.syncMayBeOutOfDateSendingOff,
          ]),
          actionLabel: label,
        );
      case BeamStallReason.behindNetwork:
        return BeamSyncMessage(
          title: l.syncDisagreesTitle(node),
          detail: joinSentences([
            l.syncLooksUpToDateButBehind,
            behindSentence,
            l.syncSendingOff,
          ]),
          actionLabel: label,
        );
      case BeamStallReason.deviceClockWrong:
        final offset = a.deviceClockOffset;
        return BeamSyncMessage(
          title: l.syncClockWrongTitle,
          detail: offset == null
              ? l.syncClockWrongDetail
              : offset.isNegative
              ? l.syncClockBehindDetail(approxDuration(offset.abs()))
              : l.syncClockAheadDetail(approxDuration(offset.abs())),
          actionLabel: label,
        );
    }
  }

  /// "Behind by 42 blocks — about 42 minutes".
  static String behindBy(int blocks, Duration blockInterval) => appL10n
      .syncBehindBy(blockCount(blocks), approxDuration(blockInterval * blocks));

  /// "1 block", "42 blocks", "139,235 blocks".
  static String blockCount(int n) => appL10n.syncBlockCount(n, number(n));

  /// "less than a minute", "about 1 minute", "about 42 minutes",
  /// "about 1 hour", "about 3 hours", "about 97 days".
  static String approxDuration(Duration d) {
    final l = appL10n;
    final minutes = d.inSeconds.abs() / 60;
    if (minutes < 1) return l.syncAboutLessThanMinute;
    if (minutes.round() < 60) {
      final n = minutes.round();
      return l.syncAboutMinutes(n, number(n));
    }
    final hours = minutes / 60;
    if (hours.round() < 36) {
      final n = hours.round();
      return l.syncAboutHours(n, number(n));
    }
    final n = (hours / 24).round();
    return l.syncAboutDays(n, number(n));
  }

  /// The sentence for time still to go: "Less than a minute left.",
  /// "About 42 minutes left.", "About 3 hours left.", "About 2 days left.".
  static String timeLeft(Duration d) {
    final l = appL10n;
    final minutes = d.inSeconds.abs() / 60;
    if (minutes < 1) return l.syncLeftLessThanMinute;
    if (minutes.round() < 60) {
      final n = minutes.round();
      return l.syncLeftMinutes(n, number(n));
    }
    final hours = minutes / 60;
    if (hours.round() < 36) {
      final n = hours.round();
      return l.syncLeftHours(n, number(n));
    }
    final n = (hours / 24).round();
    return l.syncLeftDays(n, number(n));
  }

  /// 139235 -> "139,235" ("139 235" in Russian), grouped like amounts.
  static String number(int n) => groupThousands(n.toString());
}
