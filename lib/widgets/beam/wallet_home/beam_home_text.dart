/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Every sentence the BEAM wallet home shows, as pure functions of the
/// wallet's state. The widgets only lay these out, so the wording is tested
/// without pumping anything.
///
/// Rules: no jargon ("explorer",
/// "UTXO", "shader", "vault"), numbers with units, a problem always names
/// the next step and never blames the user, and anything that stops the
/// user from sending says so.
library;

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/node/beam_private_node_coordinator.dart';
import '../../../wallets/beam/price/beam_asset_pricer.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_balance_mapper.dart';
import '../../../wallets/beam/wallet/beam_sync_tracker.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';

final BigInt _grothPerBeam = BigInt.from(100000000);

/// How loud a banner is.
enum BeamBannerTone {
  /// Things are moving and will finish by themselves.
  progress,

  /// Something is off; the wallet keeps trying.
  warning,

  /// The user (or a reinstall) has to do something.
  problem,
}

/// Which Beam girl sticker a banner carries.
enum BeamBannerMood {
  /// Catching up, connecting, scanning.
  syncing,

  /// Behind, stuck or unreachable.
  behind,

  /// The wallet core itself cannot run.
  broken,
}

/// What a banner's button does. The screen decides how.
enum BeamHomeAction {
  none,

  /// Campfire's node settings for this wallet ("Try another node").
  nodeSettings,

  /// Ask the wallet to reconnect / re-read (`wallet.refresh()`).
  retry,
}

/// One sync banner.
class BeamBannerContent {
  const BeamBannerContent({
    required this.title,
    required this.tone,
    this.detail,
    this.actionLabel,
    this.action = BeamHomeAction.none,
    this.progress,
    this.urgent = false,
    this.mood = BeamBannerMood.syncing,
  });

  final String title;
  final String? detail;
  final String? actionLabel;
  final BeamHomeAction action;
  final BeamBannerTone tone;

  /// 0..1 for a thin progress bar, or null for none.
  final double? progress;

  /// Shown at once. Non-urgent banners wait a few seconds first, so the
  /// second or two of "connecting" on every open stays invisible (R11).
  final bool urgent;

  final BeamBannerMood mood;

  @override
  bool operator ==(Object other) =>
      other is BeamBannerContent &&
      other.mood == mood &&
      other.title == title &&
      other.detail == detail &&
      other.actionLabel == actionLabel &&
      other.action == action &&
      other.tone == tone &&
      other.progress == progress &&
      other.urgent == urgent;

  @override
  int get hashCode => Object.hash(
    title,
    detail,
    actionLabel,
    action,
    tone,
    progress,
    urgent,
    mood,
  );

  @override
  String toString() =>
      '$title${detail == null ? '' : ' | $detail'}'
      '${actionLabel == null ? '' : ' [$actionLabel]'}';
}

/// "Sent to your name alice.beam" + "2.5 BEAM + 1,000 FOMO".
class BeamNamePaymentsText {
  const BeamNamePaymentsText(this.lead, this.amounts);

  final String lead;
  final String amounts;

  String get line => appL10n.homeNamePaymentsLine(lead, amounts);

  /// [lead] with the separator that comes before the amounts.
  String get label => appL10n.homeNamePaymentsLead(lead);

  @override
  String toString() => line;
}

/// The portfolio lines under the balance. Both are null when the wallet
/// holds nothing but BEAM.
class BeamPortfolioText {
  const BeamPortfolioText({this.total, this.note});

  /// "With assets ≈ 15.2 BEAM (estimate)" or "Plus 3 assets".
  final String? total;

  /// "2 assets have no price". Never folded into the total as zero.
  final String? note;
}

/// What the claim sheet says.
class BeamClaimText {
  const BeamClaimText({
    required this.headline,
    required this.receive,
    required this.fee,
    required this.balanceChange,
    required this.cta,
    this.from,
    this.feeNote,
    this.warning,
    this.blocker,
    this.batches,
    this.privacyNote,
  });

  final String headline;

  /// One entry per asset, exact.
  final List<String> receive;

  /// "alice.beam, bob.beam", or null when only sale proceeds wait.
  final String? from;

  /// "0.011 BEAM".
  final String fee;

  /// What the balance actually gains once the claim confirms, the fee
  /// taken out: "+2.489 BEAM", or "+1,000 FOMO, −0.011 BEAM".
  final String balanceChange;

  /// Where the fee comes from.
  final String? feeNote;

  /// Shown, not enforced: the claim costs at least what it returns.
  final String? warning;

  /// Why the claim button is off, or null when it is on.
  final String? blocker;

  /// More than one claim transaction is needed.
  final String? batches;

  /// A payment to a name and its claim can be linked on-chain; null when
  /// only sale proceeds wait.
  final String? privacyNote;

  /// The primary button: the outcome, not the mechanism.
  final String cta;
}

abstract final class BeamHomeText {
  // ------------------------------------------------------------ amounts

  /// 250000000 -> "2.5"; 100000000000 -> "1,000". Exact: every BEAM asset
  /// is on the 10^8 scale. [maxDecimals] < 8 rounds down, never up.
  static String amount(BigInt groth, {int maxDecimals = 8}) {
    final negative = groth.isNegative;
    var v = groth.abs();
    if (maxDecimals < 8) {
      final unit = BigInt.from(10).pow(8 - maxDecimals);
      v = v ~/ unit * unit;
    }
    final whole = v ~/ _grothPerBeam;
    final frac = v
        .remainder(_grothPerBeam)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    final sign = negative ? '-' : '';
    return '$sign${_group(whole.toString())}${frac.isEmpty ? '' : '.$frac'}';
  }

  /// An estimate, rounded down to what people read: 2 decimals from 1 up,
  /// 4 below that.
  static String estimate(BigInt groth) =>
      amount(groth, maxDecimals: groth >= _grothPerBeam ? 2 : 4);

  /// The ticker of [assetId]; "#205" for an asset Campfire does not vouch
  /// for (its on-chain name is attacker text, so the home never shows it).
  static String symbol(int assetId) =>
      BeamAssetCatalog.display(assetId, null).symbol;

  static String withUnit(int assetId, BigInt groth) =>
      '${amount(groth)} ${symbol(assetId)}';

  /// "2.5 BEAM + 1,000 FOMO": BEAM first, then by asset id.
  static String amounts(Map<int, BigInt> totals) {
    final ids = totals.keys.toList()
      ..sort((a, b) => a == 0 ? -1 : (b == 0 ? 1 : a.compareTo(b)));
    return ids.map((id) => withUnit(id, totals[id]!)).join(' + ');
  }

  static String _group(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  // ------------------------------------------------------------ balance

  /// "+ 0.5 BEAM arriving", or null when nothing is on its way.
  static String? arriving(String formattedPending, BigInt pendingGroth) =>
      pendingGroth > BigInt.zero
      ? appL10n.homeArriving(formattedPending)
      : null;

  /// How far a restore scan is, in whole percent (rounded down, so it never
  /// says 100% before the end), or null when the core reports no progress.
  static int? scanPercent(BeamScanProgress? scan) {
    final f = scan?.fraction;
    return f == null ? null : (f * 100).floor();
  }

  /// "Scanning for your coins… 43%": the banner's title during a restore
  /// scan.
  static String scanning(BeamScanProgress? scan) {
    final p = scanPercent(scan);
    return p == null
        ? appL10n.homeScanningCoins
        : appL10n.homeScanningCoinsPercent(p);
  }

  /// The headline in place of the balance while a restored wallet has found
  /// nothing yet: never a bare 0, which would look like a loss.
  static String scanningHeadline(BeamScanProgress? scan) {
    final p = scanPercent(scan);
    return p == null
        ? appL10n.homeScanningHeadline
        : appL10n.homeScanningHeadlinePercent(p);
  }

  /// Under the amount while the scan still runs: more may turn up.
  static String get foundSoFar => appL10n.homeFoundSoFar;

  /// The portfolio lines from the cached per-asset totals and, once it is
  /// known, the DEX pricer. [fiat] formats a BEAM amount in the user's
  /// currency, or is null when prices are off. Assets the user [hidden]
  /// (spam, dust) are neither counted nor valued, as in the asset list.
  static BeamPortfolioText? portfolio({
    required Map<int, BeamCachedAssetTotals> totals,
    BeamAssetPricer? pricer,
    String? Function(BigInt groth)? fiat,
    Set<int> hidden = const {},
  }) {
    final held = <int, BigInt>{
      for (final e in totals.entries)
        if (e.key != 0 &&
            !hidden.contains(e.key) &&
            e.value.total > BigInt.zero)
          e.key: e.value.total,
    };
    if (held.isEmpty) return null;
    final n = held.length;
    if (pricer == null) {
      return BeamPortfolioText(total: appL10n.homePortfolioPlusAssets(n));
    }
    final beam = totals[0]?.total ?? BigInt.zero;
    final value = pricer.portfolio({0: beam, ...held});
    final unpriced = value.unpriced.where((id) => id != 0).length;
    final priced = n - unpriced;
    final note = unpriced == 0 ? null : appL10n.homePortfolioUnpriced(unpriced);
    if (priced == 0) {
      return BeamPortfolioText(
        total: appL10n.homePortfolioPlusAssets(n),
        note: note,
      );
    }
    final money = fiat?.call(value.totalGroth);
    final inBeam = '${estimate(value.totalGroth)} BEAM';
    return BeamPortfolioText(
      total: money == null
          ? appL10n.homePortfolioEstimate(inBeam)
          : appL10n.homePortfolioEstimateFiat(inBeam, money),
      note: note,
    );
  }

  // ------------------------------------------------------- name payments

  /// The line under the balance, or null when nothing waits or this core
  /// cannot see the inbox (the home stays quiet about that; it is logged).
  static BeamNamePaymentsText? namePayments(BansPendingSummary? s) {
    if (s == null ||
        s.visibility != BansInboxVisibility.visible ||
        s.isEmpty ||
        s.totalsByAsset.isEmpty) {
      return null;
    }
    final names = _displayNames(s.names);
    final String lead;
    if (s.names.length == 1 && names.length == 1) {
      lead = appL10n.homeNamePaymentsOneName(names.single);
    } else if (s.names.isNotEmpty) {
      lead = appL10n.homeNamePaymentsNames;
    } else {
      lead = appL10n.homeNamePaymentsSold;
    }
    return BeamNamePaymentsText(lead, amounts(s.totalsByAsset));
  }

  /// Only names the contract could have issued are shown; anything else
  /// (it comes out of a decryption) is left out rather than displayed.
  static List<String> _displayNames(List<String> raw) => [
    for (final n in raw)
      if (BansName.tryParse(n) case final name?) name.display,
  ];

  /// The claim sheet, from the summary on screen and the claim advice, and
  /// once the core has built the claim, from that transaction ([built]).
  static BeamClaimText claim({
    required BansPendingSummary summary,
    required BansClaimAdvice advice,
    required bool canSpend,
    BansSummary? built,
  }) {
    final receiveTotals = built == null
        ? summary.totalsByAsset
        : <int, BigInt>{for (final a in built.youReceive) a.assetId: a.amount};
    final ids = receiveTotals.keys.toList()
      ..sort((a, b) => a == 0 ? -1 : (b == 0 ? 1 : a.compareTo(b)));
    final receive = [for (final id in ids) withUnit(id, receiveTotals[id]!)];

    final l = appL10n;
    final feeGroth = built?.fee ?? kBansClaimFeeGroth;
    final fee = withUnit(0, feeGroth);
    final beamWaiting = summary.totalsByAsset[0] ?? BigInt.zero;

    // The fee comes out of BEAM, so the BEAM line is net; gains first.
    final beamNet = (receiveTotals[0] ?? BigInt.zero) - feeGroth;
    final change = [
      if (beamNet > BigInt.zero) '+${withUnit(0, beamNet)}',
      for (final id in ids)
        if (id != 0) '+${withUnit(id, receiveTotals[id]!)}',
      if (beamNet.isNegative) '−${withUnit(0, -beamNet)}',
    ];

    String? feeNote;
    if (beamWaiting >= feeGroth) {
      feeNote = l.homeClaimFeeOwn;
    } else if (beamWaiting > BigInt.zero) {
      feeNote = l.homeClaimFeePartly;
    } else {
      feeNote = l.homeClaimFeeFromWallet;
    }

    String? warning;
    if (advice.beamCostsMoreThanItReturns) {
      warning = l.homeClaimCostsMore(fee, withUnit(0, beamWaiting));
    }

    String? blocker;
    if (!canSpend) {
      blocker = l.homeClaimPausedSync;
    } else if (advice.reason == BansClaimBlocker.needsBeamForFee) {
      blocker = l.homeClaimNeedBeam(fee);
    } else if (advice.reason == BansClaimBlocker.needsCampfireCore) {
      blocker = l.homeClaimNeedsCampfireCore;
    }

    String? batches;
    if (advice.transactions > 1) {
      batches = joinSentences([
        l.homeClaimBatchesWaiting(summary.entryCount),
        l.homeClaimBatchesPerClaim(
          advice.transactions,
          kBansClaimsPerTransaction,
          fee,
        ),
        l.homeClaimBatchesAgain,
      ]);
    }

    final names = _displayNames(summary.names);
    return BeamClaimText(
      headline: names.length == 1 && summary.names.length == 1
          ? l.homeClaimHeadlineOneName(names.single)
          : summary.names.isEmpty
          ? l.homeClaimHeadlineSold
          : l.homeClaimHeadlineNames,
      receive: receive,
      from: names.isEmpty ? null : names.join(', '),
      fee: fee,
      balanceChange: change.isEmpty
          ? withUnit(0, BigInt.zero)
          : change.join(', '),
      feeNote: feeNote,
      warning: warning,
      blocker: blocker,
      batches: batches,
      privacyNote: summary.names.isEmpty ? null : l.homeClaimPrivacyNote,
      cta: receive.length == 1
          ? l.homeClaimCta(receive.single)
          : l.homeClaimAllCta,
    );
  }

  // --------------------------------------------------------------- sync

  /// The one banner for the wallet's state, or null when everything is up
  /// to date. Most important first: a broken core, then a stuck or
  /// unreachable node, then a restore scan, then catching up, then
  /// connecting.
  static BeamBannerContent? syncBanner({
    required BeamSyncAssessment assessment,
    bool scanning = false,
    BeamScanProgress? scan,
    BeamWalletException? problem,
    int maxBlocksBehind = 0,
  }) {
    if (problem != null) return _problemBanner(problem);

    final described = BeamSyncMessages.describe(assessment);
    switch (assessment) {
      case BeamSyncStalled():
        return BeamBannerContent(
          title: described.title,
          detail: described.detail,
          actionLabel: described.actionLabel,
          action: _action(assessment.action),
          tone: BeamBannerTone.problem,
          mood: BeamBannerMood.behind,
          urgent: true,
        );
      case BeamSyncNotConnected():
        return BeamBannerContent(
          title: described.title,
          detail: described.detail,
          actionLabel: described.actionLabel,
          action: _action(assessment.action),
          tone: BeamBannerTone.warning,
          mood: BeamBannerMood.behind,
        );
      default:
        break;
    }

    if (scanning) {
      return BeamBannerContent(
        title: scanningBannerTitle(scan),
        detail: appL10n.homeScanBannerDetail,
        tone: BeamBannerTone.progress,
        progress: scan?.fraction,
        urgent: true,
      );
    }

    switch (assessment) {
      case BeamSyncCatchingUp(:final blocksBehind):
        final behind = blocksBehind != null && blocksBehind > 0
            ? blocksBehind
            : null;
        final eta = assessment.eta;
        final String title;
        if (behind == null) {
          title = described.title;
        } else {
          final blocks = BeamSyncMessages.blockCount(behind);
          final lag = BeamSyncMessages.approxDuration(
            assessment.blockInterval * behind,
          );
          title = assessment.node == BeamNodeKind.privateNode
              ? appL10n.homeCatchingUpPrivateBehind(blocks, lag)
              : appL10n.homeCatchingUpBehind(blocks, lag);
        }
        return BeamBannerContent(
          title: title,
          detail: joinSentences([
            if (eta != null) BeamSyncMessages.timeLeft(eta),
            appL10n.homeSendingPausedUntilDone,
          ]),
          tone: BeamBannerTone.progress,
          progress: behind != null && maxBlocksBehind > 0
              ? (1 - behind / maxBlocksBehind).clamp(0.0, 1.0)
              : null,
        );
      case BeamSyncConnecting():
        return BeamBannerContent(
          title: described.title,
          detail: joinSentences([
            described.detail,
            appL10n.homeSendingPausedUntilDone,
          ]),
          tone: BeamBannerTone.progress,
        );
      case BeamSynced():
      case BeamSyncStalled():
      case BeamSyncNotConnected():
        return null;
    }
  }

  static String scanningBannerTitle(BeamScanProgress? scan) => scanning(scan);

  static BeamBannerContent _problemBanner(BeamWalletException p) {
    final (title, detail) = _split(p.message);
    // Not a failure: the wallet connects by itself as soon as Tor does.
    if (p.problem == BeamWalletProblem.waitingForTor) {
      return BeamBannerContent(
        title: title,
        detail: detail,
        tone: BeamBannerTone.progress,
      );
    }
    final BeamHomeAction action;
    final String? label;
    switch (p.problem) {
      case BeamWalletProblem.nodeUnreachable:
        action = BeamHomeAction.nodeSettings;
        label = appL10n.syncActionTryAnotherNode;
      case BeamWalletProblem.notOpen ||
          BeamWalletProblem.walletInUse ||
          BeamWalletProblem.other:
        action = BeamHomeAction.retry;
        label = appL10n.commonTryAgain;
      default:
        action = BeamHomeAction.none;
        label = null;
    }
    return BeamBannerContent(
      title: title,
      detail: detail,
      actionLabel: label,
      action: action,
      tone: BeamBannerTone.problem,
      mood: action == BeamHomeAction.none
          ? BeamBannerMood.broken
          : BeamBannerMood.behind,
      urgent: true,
    );
  }

  /// First sentence as the title, the rest as the detail.
  static (String, String?) _split(String message) {
    // The first sentence is the title: it ends at ". " (English, Russian)
    // or at "。" (Chinese, Japanese, which put no space after it).
    final dot = message.indexOf('. ');
    final cjk = message.indexOf('。');
    final i = dot < 0 ? cjk : (cjk < 0 || dot < cjk ? dot : cjk);
    if (i < 0 || i + (i == dot ? 2 : 1) >= message.length) {
      final t = message.endsWith('.') || message.endsWith('。')
          ? message.substring(0, message.length - 1)
          : message;
      return (t, null);
    }
    return (message.substring(0, i), message.substring(i + (i == dot ? 2 : 1)));
  }

  static BeamHomeAction _action(BeamSyncAction a) => switch (a) {
    BeamSyncAction.tryAnotherNode ||
    BeamSyncAction.usePublicNode => BeamHomeAction.nodeSettings,
    BeamSyncAction.checkInternet ||
    BeamSyncAction.reconnect ||
    BeamSyncAction.fixDeviceClock => BeamHomeAction.retry,
    BeamSyncAction.none || BeamSyncAction.wait => BeamHomeAction.none,
  };

  /// Why Send is off right now, for the disabled Send button. Null when
  /// sending is allowed.
  static String? sendPaused({
    required BeamSyncAssessment assessment,
    BeamWalletException? problem,
  }) {
    if (problem != null) {
      return appL10n.homeSendingOff(_split(problem.message).$1);
    }
    if (assessment.canSpend) return null;
    return switch (assessment) {
      BeamSyncConnecting() => appL10n.homeSendingPausedConnecting,
      BeamSyncCatchingUp(:final blocksBehind) =>
        blocksBehind != null && blocksBehind > 0
            ? appL10n.homeSendingPausedCatchingUpBlocks(
                BeamSyncMessages.blockCount(blocksBehind),
              )
            : appL10n.homeSendingPausedCatchingUp,
      BeamSyncStalled() || BeamSyncNotConnected() => appL10n.homeSendingOff(
        BeamSyncMessages.describe(assessment).title,
      ),
      BeamSynced() => null,
    };
  }

  // --------------------------------------------------------------- node

  /// The small node chip: which node the wallet uses right now.
  static String nodeChip(BeamPrivateNodeStatus? s) {
    final l = appL10n;
    if (s == null) return l.homeNodePublic;
    if (s.onPrivateNode || s.phase == BeamPrivateNodePhase.active) {
      return l.homeNodePrivate;
    }
    final percent = s.percent;
    return switch (s.phase) {
      BeamPrivateNodePhase.downloading =>
        percent == null
            ? l.homeNodePrivateSyncing
            : l.homeNodePrivateSyncingPercent(percent),
      BeamPrivateNodePhase.catchingUp => l.homeNodePrivateCatchingUp,
      BeamPrivateNodePhase.preparing ||
      BeamPrivateNodePhase.switching => l.homeNodePrivateStarting,
      _ => l.homeNodePublic,
    };
  }

  /// True while the wallet runs on its own node.
  static bool onPrivateNode(BeamPrivateNodeStatus? s) =>
      s != null && (s.onPrivateNode || s.phase == BeamPrivateNodePhase.active);
}
