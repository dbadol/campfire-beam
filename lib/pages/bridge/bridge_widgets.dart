/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pieces shared by the bridge screens: a coin's icon on either chain, the
// From / To wallet cards, what a crossing's state means in plain words,
// and its steps.
//
// Words: the screens never say relayer, pipe,
// message, b2e or e2b. "The bridge" is BeamMW's official bridge; its fee
// is "the bridge fee, paid to the bridge operator"; claiming on BEAM is
// "collecting".

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_crossing.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../widgets/beam/dex/dex_asset_icon.dart';
import '../../widgets/beam/dex/dex_widgets.dart';
import '../../widgets/rounded_white_container.dart';
import '../eth/uniswap/uniswap_deps.dart';
import '../eth/uniswap/uniswap_format.dart';
import '../eth/uniswap/uniswap_widgets.dart';
import 'bridge_deps.dart';
import 'bridge_format.dart';

/// The Ethereum side's token of [r], as the Uniswap screens know it.
UniToken bridgeEthToken(BridgeRoute r) {
  if (r.isNativeEth) return UniToken.eth;
  for (final t in kUniVerifiedTokens) {
    if (t.address == r.ethToken) return t;
  }
  return UniToken(
    address: r.ethToken!,
    symbol: r.ethSymbol,
    decimals: r.ethDecimals,
    name: r.name,
  );
}

/// [r]'s coin on BEAM ([onBeam]) or on Ethereum, round.
class BridgeAssetIcon extends StatelessWidget {
  const BridgeAssetIcon({
    super.key,
    required this.route,
    required this.onBeam,
    this.size = 20,
  });

  final BridgeRoute route;
  final bool onBeam;
  final double size;

  @override
  Widget build(BuildContext context) => onBeam
      ? DexAssetIcon(
          asset: BeamAssetCatalog.display(route.beamAssetId, null),
          size: size,
        )
      : UniTokenIcon(token: bridgeEthToken(route), size: size);
}

/// The coin on the amount field's button: icon and ticker, fixed.
class BridgeCoinLabel extends StatelessWidget {
  const BridgeCoinLabel({super.key, required this.route, required this.onBeam});

  final BridgeRoute route;
  final bool onBeam;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BridgeAssetIcon(route: route, onBeam: onBeam),
        const SizedBox(width: 6),
        Text(
          onBeam ? route.beamSymbol : route.ethSymbol,
          style: STextStyles.smallMed14(context)
              .copyWith(color: colors.textDark),
        ),
      ],
    );
  }
}

/// "0x7a3e…91c4" (draw it with [kAddressFontFeatures]).
String bridgeShortAddress(String a) => UniFormat.short(a);

/// One of the two wallets of a crossing: which side, which wallet, and a
/// line under it (a balance, what arrives). A tap picks another wallet
/// when there are several.
class BridgeWalletCard extends StatelessWidget {
  const BridgeWalletCard({
    super.key,
    required this.title,
    required this.noWallet,
    required this.wallet,
    this.trailing,
    this.note,
    this.onTap,
    this.chainIcon,
  });

  /// Which side and chain: "From · your BEAM wallet".
  final String title;

  /// In place of the wallet's name when there is none: "No BEAM wallet".
  final String noWallet;
  final BridgeWalletOption? wallet;
  final Widget? chainIcon;

  /// On the right of the wallet's line (a balance).
  final Widget? trailing;

  /// Under it.
  final Widget? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final w = wallet;
    final address = w?.address;
    return DexCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                title,
                style: STextStyles.label(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(
                  Icons.unfold_more_rounded,
                  size: 16,
                  color: colors.textSubtitle1,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (chainIcon != null) ...[chainIcon!, const SizedBox(width: 8)],
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: w?.name ?? noWallet),
                      if (address != null)
                        TextSpan(
                          text: '  ${bridgeShortAddress(address)}',
                          style: STextStyles.label(context).copyWith(
                            color: colors.textSubtitle1,
                            fontFeatures: kAddressFontFeatures,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.smallMed14(context)
                      .copyWith(color: colors.textDark),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          if (note != null) ...[const SizedBox(height: 6), note!],
        ],
      ),
    );
  }
}

/// Picks one of [options]; returns its id.
Future<String?> showBridgeWalletPicker(
  BuildContext context, {
  required BridgeDeps deps,
  required String title,
  required List<BridgeWalletOption> options,
  required String? selected,
}) => showDexPage<String>(
  context,
  deps,
  (context) => DexPage(
    deps: deps,
    title: title,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in options) ...[
          DexCard(
            key: Key('bridge-wallet-${w.id}'),
            onTap: () => Navigator.of(context).pop(w.id),
            child: Row(
              children: [
                Icon(
                  w.id == selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .radioButtonIconEnabled,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    w.address == null
                        ? w.name
                        : '${w.name}  ${bridgeShortAddress(w.address!)}',
                    style: STextStyles.smallMed14(context)
                        .copyWith(fontFeatures: kAddressFontFeatures),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ),
  ),
);

// -------------------------------------------------------------- the words

enum BridgeMood { progress, success, warning, error }

/// What a crossing's state means, in plain words.
class BridgeWords {
  const BridgeWords(this.title, this.detail, this.short, this.mood);

  /// What a crossing of [c] is doing; [blocksLeft] from the controller.
  factory BridgeWords.of(BridgeCrossing c, {int? blocksLeft, DateTime? now}) {
    final r = c.route;
    final out = BridgeFormat.coin(
      c.amount,
      r.sourceDecimals(c.direction),
      r.sourceSymbol(c.direction),
    );
    final arrives = BridgeFormat.coin(
      c.receives,
      r.destinationDecimals(c.direction),
      r.destinationSymbol(c.direction),
    );
    final err = c.lastError;
    String withError(String s) => err == null ? s : '$s\n$err';
    final l = appL10n;
    switch (c.state) {
      case BridgeCrossingState.quoted:
      case BridgeCrossingState.sending:
        return BridgeWords(
          l.bridgeWordsSendingTitle(out),
          l.bridgeWordsSendingDetail,
          l.bridgeShortSending,
          BridgeMood.progress,
        );
      case BridgeCrossingState.sent:
        return BridgeWords(
          l.bridgeWordsSentTitle,
          l.bridgeWordsSentDetail,
          l.bridgeShortSending,
          BridgeMood.progress,
        );
      case BridgeCrossingState.confirmed:
        if (blocksLeft == null) {
          return BridgeWords(
            l.bridgeWordsToEthereumTitle,
            l.bridgeWordsToEthereumDetail,
            l.bridgeShortOnItsWay,
            BridgeMood.progress,
          );
        }
        if (blocksLeft > 0) {
          return BridgeWords(
            l.bridgeWordsBlocksToGoTitle(blocksLeft),
            l.bridgeWordsBlocksToGoDetail,
            l.bridgeShortBlocksToGo(blocksLeft),
            BridgeMood.progress,
          );
        }
        return BridgeWords(
          l.bridgeWordsDueTitle,
          l.bridgeWordsDueDetail,
          l.bridgeShortDue,
          BridgeMood.progress,
        );
      case BridgeCrossingState.waitingForGas:
        return BridgeWords(
          l.bridgeWordsGasTitle,
          l.bridgeWordsGasDetail,
          l.bridgeShortWaitingForGas,
          // Nothing for the user to do: told calmly, not as an alarm.
          BridgeMood.progress,
        );
      case BridgeCrossingState.paid:
        return BridgeWords(
          l.bridgeWordsPaidTitle(arrives),
          null,
          l.bridgeShortArrived,
          BridgeMood.success,
        );
      case BridgeCrossingState.failed:
        return BridgeWords(
          l.bridgeWordsFailedTitle,
          withError(l.bridgeWordsFailedDetail),
          l.bridgeShortFailed,
          BridgeMood.error,
        );
      case BridgeCrossingState.approving:
        final take = BridgeFormat.coin(
          c.amount + c.relayerFee,
          r.ethDecimals,
          r.ethSymbol,
        );
        return BridgeWords(
          l.bridgeWordsApprovingTitle(r.ethSymbol),
          l.bridgeWordsApprovingDetail(take),
          l.bridgeShortStarting,
          BridgeMood.progress,
        );
      case BridgeCrossingState.locking:
        return BridgeWords(
          l.bridgeWordsLockingTitle(out),
          l.bridgeWordsLockingDetail,
          l.bridgeShortSending,
          BridgeMood.progress,
        );
      case BridgeCrossingState.locked:
        return BridgeWords(
          l.bridgeWordsToBeamTitle,
          l.bridgeWordsToBeamDetail,
          l.bridgeShortOnItsWay,
          BridgeMood.progress,
        );
      case BridgeCrossingState.notDeliveredYet:
        final since = c.lockedAt;
        final when = since == null || now == null
            ? l.bridgeAgoOver30Minutes
            : BridgeFormat.ago(since, now);
        return BridgeWords(
          l.bridgeWordsSlowTitle,
          l.bridgeWordsSlowDetail(when),
          l.bridgeShortSlow,
          BridgeMood.warning,
        );
      case BridgeCrossingState.delivered:
        final auto = c.autoClaim && err == null;
        return BridgeWords(
          auto ? l.bridgeWordsCollectingTitle : l.bridgeWordsCollectTitle,
          withError(
            l.bridgeWordsCollectDetail(
              BridgeFormat.coin(c.beamNetworkFee, 8, 'BEAM'),
            ),
          ),
          auto ? l.bridgeShortCollecting : l.bridgeShortCollect,
          err == null ? BridgeMood.progress : BridgeMood.warning,
        );
      case BridgeCrossingState.claiming:
        return BridgeWords(
          l.bridgeWordsClaimingTitle(arrives),
          l.bridgeWordsClaimingDetail,
          l.bridgeShortCollecting,
          BridgeMood.progress,
        );
      case BridgeCrossingState.claimed:
        return BridgeWords(
          l.bridgeWordsClaimedTitle(arrives),
          err,
          l.bridgeShortArrived,
          BridgeMood.success,
        );
      case BridgeCrossingState.lockFailed:
        return BridgeWords(
          l.bridgeWordsLockFailedTitle,
          err ?? l.bridgeWordsLockFailedDetail(r.ethSymbol),
          l.bridgeShortNotSent,
          BridgeMood.error,
        );
      case BridgeCrossingState.unknown:
        return BridgeWords(
          l.bridgeWordsUnknownTitle,
          withError(
            c.toEthereum
                ? l.bridgeWordsUnknownToEthereumDetail
                : l.bridgeWordsUnknownToBeamDetail,
          ),
          l.bridgeShortChecking,
          BridgeMood.warning,
        );
    }
  }

  final String title;
  final String? detail;

  /// For a list row: "34 blocks to go", "Arrived".
  final String short;
  final BridgeMood mood;

  /// It waits for the user (Collect), not for a chain.
  bool get needsYou => short == appL10n.bridgeShortCollect;

  /// The colour of [short] in a list: Campfire's red when it waits for
  /// the user, green when done; waiting text stays dark (the theme's
  /// orange is too light to read on white; the hourglass beside it is
  /// orange, as the BEAM history's waiting transactions are).
  Color color(StackColors c) => needsYou
      ? c.accentColorBlue
      : switch (mood) {
          BridgeMood.progress => c.textDark,
          BridgeMood.warning => c.warningForeground,
          BridgeMood.success => c.accentColorGreen,
          BridgeMood.error => c.textError,
        };

  DexNoticeKind get kind => switch (mood) {
    BridgeMood.progress => DexNoticeKind.info,
    BridgeMood.success => DexNoticeKind.success,
    BridgeMood.warning => DexNoticeKind.warning,
    BridgeMood.error => DexNoticeKind.error,
  };
}

/// "1,000 BEAM → Ethereum".
String bridgeHeadline(BridgeCrossing c) {
  final r = c.route;
  final out = BridgeFormat.coin(
    c.amount,
    r.sourceDecimals(c.direction),
    r.sourceSymbol(c.direction),
  );
  return '$out → ${c.toEthereum ? 'Ethereum' : 'BEAM'}';
}

// -------------------------------------------------------------- the steps

enum BridgeStepStatus { done, active, waiting, failed }

class BridgeStep {
  const BridgeStep(this.label, this.status, [this.note]);

  final String label;
  final BridgeStepStatus status;
  final String? note;
}

/// The steps of [c], each done, under way, still to come, or failed.
List<BridgeStep> bridgeSteps(
  BridgeCrossing c, {
  int? blocksLeft,
  required DateTime now,
}) {
  const done = BridgeStepStatus.done;
  const active = BridgeStepStatus.active;
  const waiting = BridgeStepStatus.waiting;
  const failed = BridgeStepStatus.failed;
  final s = c.state;
  final at = BridgeFormat.ago(c.createdAt, now);
  final l = appL10n;
  if (c.toEthereum) {
    final mined = c.msgId != null;
    final due = mined && (blocksLeft ?? 1) == 0;
    final paid = s == BridgeCrossingState.paid;
    return [
      BridgeStep(l.bridgeStepSentFromBeam, switch (s) {
        BridgeCrossingState.failed => failed,
        BridgeCrossingState.sending ||
        BridgeCrossingState.unknown when !mined => active,
        _ => done,
      }, at),
      BridgeStep(
        mined
            ? l.bridgeStepInBeamBlock(
                UniFormat.exact(BigInt.from(c.height!), 0),
              )
            : l.bridgeStepInABeamBlock,
        mined
            ? done
            : s == BridgeCrossingState.sent
            ? active
            : waiting,
      ),
      BridgeStep(
        l.bridgeStep61Blocks,
        paid || due || s == BridgeCrossingState.waitingForGas
            ? done
            : mined
            ? active
            : waiting,
        mined && !due && !paid && blocksLeft != null
            ? l.bridgeStepBlocksToGo(blocksLeft)
            : null,
      ),
      BridgeStep(
        l.bridgeStepPaidToEth,
        paid
            ? done
            : due || s == BridgeCrossingState.waitingForGas
            ? active
            : waiting,
        s == BridgeCrossingState.waitingForGas
            ? l.bridgeShortWaitingForGas
            : null,
      ),
    ];
  }
  final locked = c.msgId != null;
  final onBeam = const {
    BridgeCrossingState.delivered,
    BridgeCrossingState.claiming,
    BridgeCrossingState.claimed,
  }.contains(s);
  return [
    BridgeStep(
      l.bridgeStepSentToBridge,
      s == BridgeCrossingState.lockFailed
          ? failed
          : locked || onBeam
          ? done
          : active,
      at,
    ),
    BridgeStep(
      l.bridgeStepBroughtToBeam,
      onBeam
          ? done
          : locked
          ? active
          : waiting,
    ),
    BridgeStep(
      l.bridgeStepCollected,
      s == BridgeCrossingState.claimed
          ? done
          : onBeam
          ? active
          : waiting,
    ),
  ];
}

/// The steps as a list with a mark for each.
class BridgeStepList extends StatelessWidget {
  const BridgeStepList({super.key, required this.steps});

  final List<BridgeStep> steps;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                children: [
                  _mark(colors, steps[i].status),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      steps[i].label,
                      key: Key('bridge-step-$i'),
                      style: STextStyles.smallMed14(context).copyWith(
                        color: steps[i].status == BridgeStepStatus.waiting
                            ? colors.textSubtitle1
                            : colors.textDark,
                      ),
                    ),
                  ),
                  if (steps[i].note != null)
                    Text(
                      steps[i].note!,
                      style: STextStyles.label(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _mark(StackColors colors, BridgeStepStatus s) => switch (s) {
    BridgeStepStatus.done => Icon(
      Icons.check_circle_rounded,
      size: 20,
      color: colors.accentColorGreen,
    ),
    BridgeStepStatus.active => Icon(
      Icons.hourglass_top_rounded,
      size: 20,
      color: colors.accentColorOrange,
    ),
    BridgeStepStatus.waiting => Icon(
      Icons.radio_button_unchecked_rounded,
      size: 20,
      color: colors.textSubtitle2,
    ),
    BridgeStepStatus.failed => Icon(
      Icons.cancel_rounded,
      size: 20,
      color: colors.accentColorRed,
    ),
  };
}

/// What the bridge fee for [r] going [d] is, said before anything is
/// typed; null while unknown.
String? bridgeLimitsText(
  BridgeRoute r,
  BridgeDirection d,
  BridgeConditions? cond,
) {
  final fee = cond?.fee;
  final sym = r.sourceSymbol(d);
  final dec = r.sourceDecimals(d);
  final l = appL10n;
  if (d == BridgeDirection.toEthereum) {
    final feeText = fee == null ? null : BridgeFormat.coinShort(fee, dec, sym);
    final maxText = r.maxGroth == null
        ? null
        : BridgeFormat.coinShort(r.maxGroth!, dec, sym);
    return switch ((feeText, maxText)) {
      (final f?, final m?) => l.bridgeLimitsFeeAndMax(f, m),
      (final f?, null) => l.bridgeLimitsFee(f),
      (null, final m?) => l.bridgeLimitsMax(m),
      (null, null) => null,
    };
  }
  return l.bridgeLimitsToBeam(
    BridgeFormat.coin(kBridgeClaimFeeGroth, 8, 'BEAM'),
  );
}
