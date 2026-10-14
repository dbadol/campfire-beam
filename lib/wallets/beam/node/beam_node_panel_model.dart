/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// What the "Node & sync" panel and the node status chip show, decided in
/// one pure place from the wallet's honest sync verdict and the private node
/// status. No Flutter here, so every state is unit-tested.
///
/// No jargon on purpose: no "explorer", "owner key",
/// "fast sync", "RPC", "wallet-api" or "beam-node".
library;

import '../../../l10n/l10n.dart';
import '../host/beam_host.dart';
import '../sync/beam_sync_messages.dart';
import '../sync/beam_sync_state.dart';
import 'beam_node_disk.dart';
import 'beam_private_node_coordinator.dart';
import 'beam_private_node_messages.dart';

/// Everything the panel needs, at one moment.
class BeamNodePanelSnapshot {
  const BeamNodePanelSnapshot({
    required this.assessment,
    this.node,
    this.privateNodeSupported = false,
    this.privateNodeEnabled = false,
    this.privateNode,
    this.disk,
    this.coreProblem,
    this.busy = false,
    this.torEnabled = false,
  });

  /// The wallet's honest sync verdict (`BeamWallet.syncAssessment`).
  final BeamSyncAssessment assessment;

  /// The node the wallet is connected to now, when connected.
  final BeamNodeEndpoint? node;

  /// This device can run a private node (desktop).
  final bool privateNodeSupported;

  /// "Use my own private node".
  final bool privateNodeEnabled;

  /// The private node's state, once its coordinator runs.
  final BeamPrivateNodeStatus? privateNode;

  /// Disk numbers for the node (from the coordinator, or measured by the
  /// panel itself before it runs).
  final BeamNodeDiskCheck? disk;

  /// Why the wallet core could not start, in plain words, when it could not.
  final String? coreProblem;

  /// An action from the panel is in progress.
  final bool busy;

  /// Campfire's Tor is on (`BeamPrivateNodePreference.torEnabled`). The
  /// private node then runs only through Tor, and only on a core that can;
  /// otherwise it is off and the panel says why.
  final bool torEnabled;

  BeamNodePanelSnapshot copyWith({
    BeamSyncAssessment? assessment,
    BeamNodeEndpoint? node,
    bool clearNode = false,
    bool? privateNodeSupported,
    bool? privateNodeEnabled,
    BeamPrivateNodeStatus? privateNode,
    bool clearPrivateNode = false,
    BeamNodeDiskCheck? disk,
    String? coreProblem,
    bool clearCoreProblem = false,
    bool? busy,
    bool? torEnabled,
  }) => BeamNodePanelSnapshot(
    assessment: assessment ?? this.assessment,
    node: clearNode ? null : node ?? this.node,
    privateNodeSupported: privateNodeSupported ?? this.privateNodeSupported,
    privateNodeEnabled: privateNodeEnabled ?? this.privateNodeEnabled,
    privateNode: clearPrivateNode ? null : privateNode ?? this.privateNode,
    disk: disk ?? this.disk,
    coreProblem: clearCoreProblem ? null : coreProblem ?? this.coreProblem,
    busy: busy ?? this.busy,
    torEnabled: torEnabled ?? this.torEnabled,
  );

  @override
  bool operator ==(Object other) =>
      other is BeamNodePanelSnapshot &&
      other.assessment == assessment &&
      other.node == node &&
      other.privateNodeSupported == privateNodeSupported &&
      other.privateNodeEnabled == privateNodeEnabled &&
      other.privateNode == privateNode &&
      other.disk == disk &&
      other.coreProblem == coreProblem &&
      other.busy == busy &&
      other.torEnabled == torEnabled;

  @override
  int get hashCode => Object.hash(
    assessment,
    node,
    privateNodeSupported,
    privateNodeEnabled,
    privateNode,
    disk,
    coreProblem,
    busy,
    torEnabled,
  );
}

/// Colour family of a line: green, yellow, red, or plain.
enum BeamNodeTone { good, busy, problem, neutral }

/// Which Beam girl moment goes with the private node's state (the UI maps
/// these to `BeamMoments`): small and secondary to the text.
enum BeamNodeMoment {
  /// Downloading or catching up.
  syncing,

  /// In use.
  ready,

  /// Back on a public node after something went wrong.
  fellBack,
}

/// The buttons the panel can show.
enum BeamNodePanelAction {
  /// Start again after a failure ([BeamPrivateNodeCoordinator.retry]).
  retry,

  /// Re-check now ([BeamPrivateNodeCoordinator.checkNow]).
  checkAgain,

  /// Start a node the user stopped ([BeamPrivateNodeCoordinator.retry]).
  start,

  /// [BeamPrivateNodeCoordinator.restart].
  restart,

  /// [BeamPrivateNodeCoordinator.stop].
  stop,

  /// Leave a private node that is not answering (stops it).
  usePublicNode,
}

/// Labels and texts for one snapshot.
class BeamNodePanelView {
  const BeamNodePanelView({
    required this.nodeTitle,
    this.nodeAddress,
    required this.syncTitle,
    this.syncDetail,
    required this.syncTone,
    this.heightLine,
    this.syncAction,
    required this.showPrivateNode,
    required this.toggleValue,
    required this.privateTitle,
    this.privateDetail,
    this.progress,
    required this.privateTone,
    this.diskLine,
    this.diskShort = false,
    this.primaryAction,
    this.secondaryActions = const [],
    this.moment,
    this.showFallbackNote = true,
    required this.chipLabel,
    required this.chipTone,
  });

  /// "Public node" or "Your private node".
  final String nodeTitle;

  /// `host:port` of a public node; null for the private one.
  final String? nodeAddress;

  final String syncTitle;
  final String? syncDetail;
  final BeamNodeTone syncTone;

  /// "Block 4,068,266" (and "of 4,068,300" while behind).
  final String? heightLine;

  /// The one fix the sync card offers, when there is one the app can do.
  final BeamNodePanelAction? syncAction;

  final bool showPrivateNode;
  final bool toggleValue;

  /// "Downloading 43%", "Catching up 1,700 blocks", "Ready — switching",
  /// "Your private node is in use", ...
  final String privateTitle;
  final String? privateDetail;

  /// 0–1 while downloading.
  final double? progress;
  final BeamNodeTone privateTone;

  /// "Needs about 8 GB · 37 GB free".
  final String? diskLine;

  /// [diskLine] says the private node cannot set up in the space there is.
  final bool diskShort;

  /// "If it ever stops: back on a public node…" fits; not while the node
  /// serves another wallet (it is not this wallet's to stop).
  final bool showFallbackNote;

  /// The panel's one primary button, when something needs doing.
  final BeamNodePanelAction? primaryAction;

  /// Quiet text buttons ("Restart", "Stop").
  final List<BeamNodePanelAction> secondaryActions;

  /// The sticker beside the private node's state, if any.
  final BeamNodeMoment? moment;

  final String chipLabel;
  final BeamNodeTone chipTone;
}

abstract final class BeamNodePanelText {
  static String get title => appL10n.nodePanelTitle;

  static String get toggleLabel => appL10n.nodePanelToggleLabel;

  /// What the private node gives, in one sentence.
  static String get toggleExplainer => appL10n.nodePanelToggleExplainer;

  /// What happens when it fails.
  static String get fallbackNote => appL10n.nodePanelFallbackNote;

  static String get notOnThisDevice => appL10n.nodePanelNotOnThisDevice;

  /// Why the private node is off while Tor is on.
  static String get offForTor => appL10n.nodePanelOffForTor;

  /// Added to the private node's state while it runs with Tor on.
  static String get runsThroughTor => appL10n.nodePanelRunsThroughTor;

  static String actionLabel(BeamNodePanelAction a) => switch (a) {
    BeamNodePanelAction.retry => appL10n.commonTryAgain,
    BeamNodePanelAction.checkAgain => appL10n.nodeActionCheckAgain,
    BeamNodePanelAction.start => appL10n.nodeActionStartPrivateNode,
    BeamNodePanelAction.restart => appL10n.nodeActionRestart,
    BeamNodePanelAction.stop => appL10n.nodeActionStop,
    BeamNodePanelAction.usePublicNode => appL10n.syncActionUsePublicNode,
  };
}

abstract final class BeamNodePanelModel {
  static BeamNodePanelView describe(BeamNodePanelSnapshot s) {
    final l = appL10n;
    final a = s.assessment;
    final onPrivate =
        (s.node?.isOwned ?? false) || a.node == BeamNodeKind.privateNode;
    final syncMessage = BeamSyncMessages.describe(a);
    final problem = s.coreProblem;

    final private = _private(s);
    final showDisk =
        s.privateNodeSupported &&
        s.privateNodeEnabled &&
        s.privateNode?.issue != BeamPrivateNodeIssue.notEnoughDisk &&
        s.privateNode?.issue != BeamPrivateNodeIssue.diskFull;
    return BeamNodePanelView(
      nodeTitle: s.node == null
          ? (problem == null ? l.nodePanelConnecting : l.nodePanelNotConnected)
          : onPrivate
          ? l.nodePanelYourPrivateNode
          : l.nodePanelPublicNode,
      nodeAddress: onPrivate ? null : s.node?.toString(),
      syncTitle: problem == null
          ? syncMessage.title
          : l.nodePanelCantStartWallet,
      syncDetail: problem ?? syncMessage.detail,
      syncTone: problem != null ? BeamNodeTone.problem : _syncTone(a),
      heightLine: _height(a),
      syncAction:
          problem == null &&
              a.action == BeamSyncAction.usePublicNode &&
              s.privateNode != null
          ? BeamNodePanelAction.usePublicNode
          : null,
      showPrivateNode: s.privateNodeSupported,
      toggleValue: s.privateNodeEnabled,
      privateTitle: private.title,
      privateDetail: private.detail,
      progress: private.progress,
      privateTone: private.tone,
      // A disk refusal already says the numbers in its message.
      diskLine: showDisk ? _diskLine(s) : null,
      diskShort: showDisk && _diskShortfall(s) > 0,
      primaryAction: private.primary,
      secondaryActions: private.secondary,
      moment: private.moment,
      showFallbackNote:
          s.privateNode?.issue != BeamPrivateNodeIssue.servingOtherWallet,
      chipLabel: _chipLabel(s, onPrivate),
      chipTone: problem != null ? BeamNodeTone.problem : _syncTone(a),
    );
  }

  static BeamNodeTone _syncTone(BeamSyncAssessment a) => switch (a) {
    BeamSynced() => BeamNodeTone.good,
    BeamSyncCatchingUp() || BeamSyncConnecting() => BeamNodeTone.busy,
    BeamSyncNotConnected() || BeamSyncStalled() => BeamNodeTone.problem,
  };

  static String? _height(BeamSyncAssessment a) {
    final h = a.walletHeight;
    if (h == null) return null;
    final n = a.networkHeight;
    final at = BeamSyncMessages.number(h);
    if (a is! BeamSynced && n != null && n > h) {
      return appL10n.nodePanelBlockHeightOf(at, BeamSyncMessages.number(n));
    }
    return appL10n.nodePanelBlockHeight(at);
  }

  /// Bytes still to free before a new private node can set up; 0 when it
  /// fits or nothing is known yet.
  static int _diskShortfall(BeamNodePanelSnapshot s) {
    final d = s.disk ?? s.privateNode?.disk;
    return d == null || !d.freshNode ? 0 : d.shortfallBytes;
  }

  static String? _diskLine(BeamNodePanelSnapshot s) {
    final d = s.disk ?? s.privateNode?.disk;
    if (d == null) {
      const policy = BeamNodeDiskPolicy();
      return _setupNeeds(policy.setupPeakBytes, policy.nodeBytes);
    }
    final short = _diskShortfall(s);
    if (short > 0) {
      // Said before the node tries, not after it fails.
      return appL10n.nodePanelDiskNotEnough(
        formatBeamDiskSize(short),
        formatBeamDiskSize(d.space.freeBytes),
      );
    }
    final free = formatBeamDiskSize(d.space.freeBytes);
    final used = formatBeamDiskSize(d.space.nodeBytes);
    if (!d.freshNode) return appL10n.nodePanelDiskUses(used, free);
    if (d.space.nodeBytes < 100 * 1024 * 1024) {
      return appL10n.nodePanelDiskNeedsWithFree(
        formatBeamDiskSize(d.setupPeakBytes),
        formatBeamDiskSize(d.nodeBytes),
        free,
      );
    }
    return appL10n.nodePanelDiskUsesSoFar(
      used,
      formatBeamDiskSize(d.setupPeakBytes),
      free,
    );
  }

  static String _setupNeeds(int peak, int settled) =>
      appL10n.nodePanelDiskNeeds(
        formatBeamDiskSize(peak),
        formatBeamDiskSize(settled),
      );

  static String _chipLabel(BeamNodePanelSnapshot s, bool onPrivate) {
    final l = appL10n;
    if (s.coreProblem != null) return l.nodeChipNotConnected;
    final a = s.assessment;
    switch (a) {
      case BeamSyncConnecting():
        return l.nodeChipConnecting;
      case BeamSyncNotConnected():
        return l.nodeChipNotConnected;
      case BeamSyncStalled():
        return l.nodeChipNotUpToDate;
      case BeamSyncCatchingUp():
        return l.nodeChipCatchingUp;
      case BeamSynced():
        if (onPrivate) return l.nodeChipPrivateNode;
        final p = s.privateNode;
        final f = p?.finishingPercent;
        if (f != null) return l.nodeChipPublicPrivatePercent(f);
        if (p?.phase == BeamPrivateNodePhase.downloading) {
          final pct = p!.percent;
          return pct == null
              ? l.nodeChipPublicPrivateDownloading
              : l.nodeChipPublicPrivatePercent(pct);
        }
        if (p?.phase == BeamPrivateNodePhase.catchingUp) {
          return l.nodeChipPublicPrivateCatchingUp;
        }
        return l.nodeChipPublicNode;
    }
  }

  static _Private _private(BeamNodePanelSnapshot s) {
    final l = appL10n;
    if (!s.privateNodeSupported) {
      return _Private(
        title: l.nodePanelNotAvailable,
        detail: BeamNodePanelText.notOnThisDevice,
        tone: BeamNodeTone.neutral,
      );
    }
    final st = s.privateNode;
    if (!s.privateNodeEnabled &&
        (st == null || st.phase == BeamPrivateNodePhase.off)) {
      return s.torEnabled
          ? _Private(
              title: l.nodePanelOffWhileTor,
              detail: BeamNodePanelText.offForTor,
              tone: BeamNodeTone.neutral,
            )
          : _Private(
              title: l.nodePanelOff,
              detail: l.nodeWalletUsesPublicNodes,
              tone: BeamNodeTone.neutral,
            );
    }
    final state = _privateState(s, st);
    if (!s.torEnabled) return state;
    // Running (or about to) with Tor on: only ever through Tor.
    final detail = state.detail;
    return state.withDetail(
      joinSentences([detail, BeamNodePanelText.runsThroughTor]),
    );
  }

  static _Private _privateState(
    BeamNodePanelSnapshot s,
    BeamPrivateNodeStatus? st,
  ) {
    final l = appL10n;
    if (st == null || st.phase == BeamPrivateNodePhase.idle) {
      return _Private(
        title: l.nodePanelStartingSoon,
        detail: s.assessment.canSpend
            ? l.nodePanelStartsInAMinute
            : l.nodePanelStartsWhenUpToDate,
        tone: BeamNodeTone.neutral,
      );
    }
    final message = BeamPrivateNodeMessages.describe(st);
    final running = <BeamNodePanelAction>[
      BeamNodePanelAction.restart,
      BeamNodePanelAction.stop,
    ];
    final publicUntilReady = l.nodePanelPublicUntilReady;
    final finishing = st.finishingPercent;
    if (finishing != null &&
        (st.phase == BeamPrivateNodePhase.downloading ||
            st.phase == BeamPrivateNodePhase.catchingUp)) {
      return _Private(
        title: l.nodePanelFinishingSetup(finishing),
        detail: joinSentences([l.nodeLastStepTakes, publicUntilReady]),
        progress: finishing.clamp(0, 100) / 100,
        tone: BeamNodeTone.busy,
        secondary: running,
        moment: BeamNodeMoment.syncing,
      );
    }
    switch (st.phase) {
      case BeamPrivateNodePhase.off:
        // Turned on in the panel, not applied yet.
        return _Private(
          title: l.nodePanelStartingSoon,
          detail: l.nodePanelStartsInAMoment,
          tone: BeamNodeTone.neutral,
        );
      case BeamPrivateNodePhase.idle:
      case BeamPrivateNodePhase.preparing:
        return _Private(
          title: l.nodePanelSettingUp,
          detail: message.detail,
          tone: BeamNodeTone.busy,
        );
      case BeamPrivateNodePhase.downloading:
        final pct = st.percent;
        return _Private(
          title: pct == null
              ? l.nodePanelDownloading
              : l.nodePanelDownloadingPercent(pct),
          detail: joinSentences([l.nodePanelFirstDownload, publicUntilReady]),
          progress: pct == null ? null : (pct.clamp(0, 100) / 100),
          tone: BeamNodeTone.busy,
          secondary: running,
          moment: BeamNodeMoment.syncing,
        );
      case BeamPrivateNodePhase.catchingUp:
        final behind = st.blocksBehind;
        return _Private(
          title: behind != null && behind > 0
              ? l.nodePanelCatchingUpBlocks(BeamSyncMessages.blockCount(behind))
              : l.nodePanelCatchingUp,
          detail: publicUntilReady,
          tone: BeamNodeTone.busy,
          secondary: running,
          moment: BeamNodeMoment.syncing,
        );
      case BeamPrivateNodePhase.switching:
        return _Private(
          title: st.waitingForWallet
              ? l.nodePanelReadySwitchingAfterPayment
              : l.nodePanelReadySwitching,
          detail: message.detail,
          tone: BeamNodeTone.busy,
        );
      case BeamPrivateNodePhase.active:
        return st.privateReceiveAvailable
            ? _Private(
                title: l.nodePanelInUse,
                detail: message.detail,
                tone: BeamNodeTone.good,
                secondary: running,
                moment: BeamNodeMoment.ready,
              )
            : _Private(
                title: message.title,
                detail: message.detail,
                tone: BeamNodeTone.busy,
                secondary: running,
              );
      case BeamPrivateNodePhase.cannotVerify:
      case BeamPrivateNodePhase.stuck:
      case BeamPrivateNodePhase.fellBehind:
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: BeamNodeTone.busy,
          primary: _actionFor(st),
          secondary: running,
          moment: st.phase == BeamPrivateNodePhase.fellBehind
              ? BeamNodeMoment.fellBack
              : null,
        );
      case BeamPrivateNodePhase.stopped:
        final byUser = st.issue == BeamPrivateNodeIssue.stoppedByUser;
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: byUser ? BeamNodeTone.neutral : BeamNodeTone.problem,
          primary: _actionFor(st),
          moment: byUser ? null : BeamNodeMoment.fellBack,
        );
      case BeamPrivateNodePhase.failed
          when st.issue == BeamPrivateNodeIssue.servingOtherWallet:
        // Nothing is wrong: the node is busy with another wallet's key.
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: BeamNodeTone.neutral,
          primary: _actionFor(st),
        );
      case BeamPrivateNodePhase.failed:
      case BeamPrivateNodePhase.ownNodeUnconfirmed:
      case BeamPrivateNodePhase.walletClosed:
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: BeamNodeTone.problem,
          primary: _actionFor(st),
          moment: BeamNodeMoment.fellBack,
        );
    }
  }

  static BeamNodePanelAction? _actionFor(BeamPrivateNodeStatus st) =>
      switch (BeamPrivateNodeMessages.actionFor(st)) {
        BeamPrivateNodeAction.none => null,
        // The switch above the card turns it on.
        BeamPrivateNodeAction.turnOn => null,
        BeamPrivateNodeAction.retry => BeamNodePanelAction.retry,
        BeamPrivateNodeAction.checkAgain => BeamNodePanelAction.checkAgain,
        BeamPrivateNodeAction.start => BeamNodePanelAction.start,
      };
}

class _Private {
  const _Private({
    required this.title,
    this.detail,
    this.progress,
    required this.tone,
    this.primary,
    this.secondary = const [],
    this.moment,
  });

  _Private withDetail(String detail) => _Private(
    title: title,
    detail: detail,
    progress: progress,
    tone: tone,
    primary: primary,
    secondary: secondary,
    moment: moment,
  );

  final String title;
  final String? detail;
  final double? progress;
  final BeamNodeTone tone;
  final BeamNodePanelAction? primary;
  final List<BeamNodePanelAction> secondary;
  final BeamNodeMoment? moment;
}
