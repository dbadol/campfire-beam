/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Plain-language wording for [BeamPrivateNodeStatus], kept apart from the
/// state machine so the UI layer can replace it with localized strings.
///
/// No jargon on purpose: no "owner key", "explorer", "fast sync", "RPC" or
/// "own_node". Every message that is not good news says what the wallet is
/// doing instead and, where the user can help, names the next step.
library;

import '../../../l10n/l10n.dart';
import '../sync/beam_sync_messages.dart';
import '../sync/beam_sync_state.dart' show beamMainnetHf6Height;
import 'beam_node_disk.dart';
import 'beam_private_node_coordinator.dart';

/// What the user can press, per status.
enum BeamPrivateNodeAction {
  none,

  /// [BeamPrivateNodeCoordinator.retry].
  retry,

  /// [BeamPrivateNodeCoordinator.checkNow].
  checkAgain,

  /// Turn the setting on and call [BeamPrivateNodeCoordinator.applySetting].
  turnOn,

  /// Start a node the user stopped ([BeamPrivateNodeCoordinator.retry]).
  start,
}

abstract final class BeamPrivateNodeMessages {
  static String get _publicNodes => appL10n.nodeWalletUsesPublicNodes;
  static String get _private => appL10n.nodePrivateNeededForOfflinePayments;
  static String get _autoSwitch => appL10n.nodePrivateAutoSwitch;

  /// The action the UI should offer for [s].
  static BeamPrivateNodeAction actionFor(BeamPrivateNodeStatus s) =>
      switch (s.phase) {
        BeamPrivateNodePhase.off => BeamPrivateNodeAction.turnOn,
        BeamPrivateNodePhase.cannotVerify => BeamPrivateNodeAction.checkAgain,
        BeamPrivateNodePhase.stopped
            when s.issue == BeamPrivateNodeIssue.stoppedByUser =>
          BeamPrivateNodeAction.start,
        // Nothing to try: it takes the node by itself once it is free.
        BeamPrivateNodePhase.failed
            when s.issue == BeamPrivateNodeIssue.servingOtherWallet =>
          BeamPrivateNodeAction.none,
        BeamPrivateNodePhase.failed ||
        BeamPrivateNodePhase.stopped ||
        BeamPrivateNodePhase.ownNodeUnconfirmed ||
        BeamPrivateNodePhase.walletClosed => BeamPrivateNodeAction.retry,
        BeamPrivateNodePhase.stuck =>
          s.issue == BeamPrivateNodeIssue.belowHardFork
              ? BeamPrivateNodeAction.none
              : BeamPrivateNodeAction.retry,
        _ => BeamPrivateNodeAction.none,
      };

  static String? actionLabel(BeamPrivateNodeAction a) => switch (a) {
    BeamPrivateNodeAction.none => null,
    BeamPrivateNodeAction.retry => appL10n.commonTryAgain,
    BeamPrivateNodeAction.checkAgain => appL10n.nodeActionCheckAgain,
    BeamPrivateNodeAction.turnOn => appL10n.nodeActionTurnOnPrivateNode,
    BeamPrivateNodeAction.start => appL10n.nodeActionStartPrivateNode,
  };

  static BeamSyncMessage describe(BeamPrivateNodeStatus s) {
    final m = _describe(s);
    if (!s.waitingForWallet || s.phase == BeamPrivateNodePhase.switching) {
      return m;
    }
    return BeamSyncMessage(
      title: m.title,
      detail: joinSentences([m.detail, _waitsForPayment]),
      actionLabel: m.actionLabel,
    );
  }

  static String get _waitsForPayment =>
      appL10n.nodePrivateSwitchWaitsForPayment;

  static BeamSyncMessage _describe(BeamPrivateNodeStatus s) {
    final l = appL10n;
    final label = actionLabel(actionFor(s));
    switch (s.phase) {
      case BeamPrivateNodePhase.off:
        return BeamSyncMessage(
          title: l.nodePrivateOffTitle,
          detail: joinSentences([_publicNodes, _private]),
          actionLabel: label,
        );
      case BeamPrivateNodePhase.idle:
        return BeamSyncMessage(title: l.nodePrivateNotStartedTitle);
      case BeamPrivateNodePhase.preparing:
        return BeamSyncMessage(
          title: l.nodePrivateSettingUpTitle,
          detail: l.nodePrivateKeepsWorkingWhileStarting,
        );
      case BeamPrivateNodePhase.downloading when s.finishingPercent != null:
        return BeamSyncMessage(
          title: l.nodePrivatePublicNowFinishingSetup(s.finishingPercent!),
          detail: joinSentences([l.nodeLastStepTakes, _autoSwitch]),
        );
      case BeamPrivateNodePhase.downloading:
        final pct = s.percent;
        return BeamSyncMessage(
          title: pct == null
              ? l.nodePrivatePublicNowDownloading
              : l.nodePrivatePublicNowDownloadingPercent(pct),
          detail: _autoSwitch,
        );
      case BeamPrivateNodePhase.catchingUp:
        final finishing = s.finishingPercent;
        if (finishing != null) {
          return BeamSyncMessage(
            title: l.nodePrivatePublicNowFinishingSetup(finishing),
            detail: joinSentences([l.nodeLastStepTakes, _autoSwitch]),
          );
        }
        return BeamSyncMessage(
          title: l.nodePrivatePublicNowCatchingUp,
          detail: joinSentences([_behind(s), _autoSwitch]),
        );
      case BeamPrivateNodePhase.cannotVerify:
        return BeamSyncMessage(
          title: l.nodePrivatePublicNowLooksReady,
          detail: l.nodePrivateCannotVerifyDetail,
          actionLabel: label,
        );
      case BeamPrivateNodePhase.stuck:
        if (s.issue == BeamPrivateNodeIssue.belowHardFork) {
          final at = s.nodeHeight;
          final fork = BeamSyncMessages.number(beamMainnetHf6Height);
          return BeamSyncMessage(
            title: l.nodePrivateStuckOldVersionTitle,
            detail: joinSentences([
              at == null
                  ? l.syncUpgradedAtBlock(fork)
                  : l.nodePrivateUpgradedYourNodeStoppedAt(
                      fork,
                      BeamSyncMessages.number(at),
                    ),
              l.nodePrivateStaysOnPublicNode,
            ]),
            actionLabel: label,
          );
        }
        return BeamSyncMessage(
          title: l.nodePrivateStoppedReceivingBlocksTitle,
          detail: joinSentences([_behind(s), l.nodePrivateStaysOnPublicNode]),
          actionLabel: label,
        );
      case BeamPrivateNodePhase.switching:
        return s.waitingForWallet
            ? BeamSyncMessage(
                title: l.nodePrivateReadyTitle,
                detail: l.nodePrivateSwitchesAfterPayment,
              )
            : BeamSyncMessage(
                title: l.nodePrivateSwitchingTitle,
                detail: l.nodePrivateTakesFewSeconds,
              );
      case BeamPrivateNodePhase.active:
        return s.privateReceiveAvailable
            ? BeamSyncMessage(
                title: l.nodePrivateSwitchedTitle,
                detail: l.nodePrivateOfflinePaymentsCanReachYou,
              )
            : BeamSyncMessage(
                title: l.nodePrivateReconnectingTitle,
                detail: l.nodePrivateOfflinePaymentsPaused,
              );
      case BeamPrivateNodePhase.ownNodeUnconfirmed:
        return BeamSyncMessage(
          title: l.nodePrivateUnconfirmedTitle,
          detail: l.nodePrivateUnconfirmedDetail,
          actionLabel: label,
        );
      case BeamPrivateNodePhase.failed:
        if (s.issue == BeamPrivateNodeIssue.notEnoughDisk ||
            s.issue == BeamPrivateNodeIssue.diskFull) {
          return _disk(s, label);
        }
        return BeamSyncMessage(
          title: _failedTitle(s.issue),
          detail: _failedDetail(s.issue),
          actionLabel: label,
        );
      case BeamPrivateNodePhase.stopped:
        if (s.issue == BeamPrivateNodeIssue.stoppedByUser) {
          return BeamSyncMessage(
            title: l.nodePrivateStoppedByUserTitle,
            detail: l.nodePrivateStoppedByUserDetail,
            actionLabel: label,
          );
        }
        return BeamSyncMessage(
          title: l.nodePrivateStoppedTitle,
          detail: joinSentences([l.nodePrivateWalletKeepsWorking, _private]),
          actionLabel: label,
        );
      case BeamPrivateNodePhase.fellBehind:
        if (s.issue == BeamPrivateNodeIssue.notServingWallet) {
          return BeamSyncMessage(
            title: l.nodePrivateNotReadyTitle,
            detail: l.nodePrivateNotReadyDetail,
          );
        }
        return BeamSyncMessage(
          title: l.nodePrivateFellBehindTitle,
          detail: joinSentences([
            _behind(s),
            l.nodePrivateSwitchesBackWhenCaughtUp,
          ]),
        );
      case BeamPrivateNodePhase.walletClosed:
        return BeamSyncMessage(
          title: l.nodePrivateReopenFailedTitle,
          detail: l.nodePrivateReopenFailedDetail,
          actionLabel: label,
        );
    }
  }

  /// Not enough room: say how much is needed, how much there is, and that
  /// the wallet keeps working. Never asks the user to guess a number.
  static BeamSyncMessage _disk(BeamPrivateNodeStatus s, String? label) {
    final l = appL10n;
    final d = s.disk;
    if (s.issue == BeamPrivateNodeIssue.diskFull) {
      return BeamSyncMessage(
        title: l.nodeDiskFullTitle,
        detail: joinSentences([
          l.nodeDiskStoppedBeforeFull,
          if (d != null)
            l.nodeDiskOnlyFree(formatBeamDiskSize(d.space.freeBytes)),
          l.nodeDiskFreeUpBackOnPublic,
        ]),
        actionLabel: label,
      );
    }
    if (d == null) {
      const policy = BeamNodeDiskPolicy();
      return BeamSyncMessage(
        title: _setupTitle(policy.setupPeakBytes, policy.nodeBytes),
        detail: l.nodeDiskFreeUpKeepsWorking,
        actionLabel: label,
      );
    }
    final title = d.freshNode
        ? _setupTitle(d.setupPeakBytes, d.nodeBytes)
        : l.nodeDiskNotEnoughTitle;
    return BeamSyncMessage(
      title: title,
      detail: l.nodeDiskNotEnoughDetail(
        formatBeamDiskSize(d.space.freeBytes),
        formatBeamDiskSize(d.reserveBytes),
        formatBeamDiskSize(d.shortfallBytes),
      ),
      actionLabel: label,
    );
  }

  /// "Your private node needs about 12 GB free while it sets up (it
  /// shrinks to about 8 GB)".
  static String _setupTitle(int peak, int settled) =>
      appL10n.nodeDiskSetupTitle(
        formatBeamDiskSize(peak),
        formatBeamDiskSize(settled),
      );

  static String _failedTitle(BeamPrivateNodeIssue? issue) => switch (issue) {
    BeamPrivateNodeIssue.keyRejected => appL10n.nodeFailedKeyRejectedTitle,
    BeamPrivateNodeIssue.nodeInUse => appL10n.nodeFailedInUseTitle,
    BeamPrivateNodeIssue.servingOtherWallet =>
      appL10n.nodeFailedServingOtherWalletTitle,
    BeamPrivateNodeIssue.binaryProblem => appL10n.nodeFailedSafetyCheckTitle,
    _ => appL10n.nodeFailedStartTitle,
  };

  static String _failedDetail(BeamPrivateNodeIssue? issue) => switch (issue) {
    BeamPrivateNodeIssue.keyRejected => appL10n.nodeFailedKeyRejectedDetail,
    BeamPrivateNodeIssue.nodeInUse => appL10n.nodeFailedInUseDetail,
    BeamPrivateNodeIssue.servingOtherWallet =>
      appL10n.nodeFailedServingOtherWalletDetail,
    BeamPrivateNodeIssue.binaryProblem => appL10n.nodeFailedSafetyCheckDetail,
    _ => joinSentences([appL10n.nodePrivateWalletKeepsWorking, _private]),
  };

  /// "Behind by 42 blocks — about 42 minutes.", or null when not behind.
  static String? _behind(BeamPrivateNodeStatus s) {
    final behind = s.blocksBehind;
    if (behind == null || behind <= 0) return null;
    return appL10n.syncBehindBySentence(
      BeamSyncMessages.blockCount(behind),
      BeamSyncMessages.approxDuration(const Duration(seconds: 60) * behind),
    );
  }
}
