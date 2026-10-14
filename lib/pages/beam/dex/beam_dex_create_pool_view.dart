/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: create a new, empty pool for two assets.
// 2. Primary CTA: "Create pool".
// 3. Taps from app open: wallet → Swap → Pools → "Create a pool" (4),
//    choose the second asset (5), "Create pool" (6); then the confirmation
//    (deposit warning + tick box) and the PIN. A secondary action, so the
//    4–5 tap budget is exceeded by the asset choice; the first asset is
//    pre-filled with BEAM and the fee tier with the usual 1%.
//
// Exit-intent — what could make an impatient person leave:
// * Discovering the 10 BEAM deposit late — it is stated on this screen
//   before anything is pressed, and again on the confirmation.
// * Creating a pool that exists — the screen says so and offers to open it.
// * Three fee tiers with no idea which to pick — 1% is pre-selected and
//   each tier says who it is for.
// * "#2", "#3" in the asset list — every asset is named from its on-chain
//   metadata (unverified ones keep their #id and "Not verified"), and the
//   deposit says what it is worth in the user's currency.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_service.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../widgets/beam/dex/dex_asset_icon.dart';
import '../../../widgets/beam/dex/dex_asset_picker.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/beam/dex/dex_format.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/rounded_container.dart';
import 'beam_dex_confirm_view.dart';
import 'beam_dex_pool_detail_view.dart';

/// Creates a new, empty AMM pool. Liquidity is added afterwards, from the
/// pool's own screen.
class BeamDexCreatePoolView extends StatefulWidget {
  const BeamDexCreatePoolView({
    super.key,
    required this.deps,
    this.aidA = 0,
    this.aidB,
  });

  final BeamDexDeps deps;
  final int aidA;
  final int? aidB;

  @override
  State<BeamDexCreatePoolView> createState() => _BeamDexCreatePoolViewState();
}

class _BeamDexCreatePoolViewState extends State<BeamDexCreatePoolView> {
  late int _a = widget.aidA;
  late int? _b = widget.aidB == widget.aidA ? null : widget.aidB;
  BeamPoolKind _kind = BeamPoolKind.high;
  bool _preparing = false;
  String? _problem;

  BeamDexDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_rebuild);
    unawaited(deps.pools.ensureLoaded());
  }

  @override
  void dispose() {
    deps.changes.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  BeamPool? get _existing {
    final b = _b;
    if (b == null) return null;
    for (final p in deps.pools.all ?? const <BeamPool>[]) {
      if (p.pairs(_a, b) && p.kind == _kind) return p;
    }
    return null;
  }

  List<int> get _choices {
    final lp = deps.pools.lpTokens;
    final ids = {
      ...dexTradableAssets(deps),
      for (final e in deps.balances.value.entries)
        if (!lp.contains(e.key)) e.key,
    };
    return ids.toList()..sort((x, y) => x == 0 ? -1 : (y == 0 ? 1 : x - y));
  }

  Future<void> _pick(bool first) async {
    final chosen = await showDexAssetPicker(
      context,
      deps: deps,
      title: first ? context.l10n.dexFirstAsset : context.l10n.dexSecondAsset,
      assets: _choices,
      selected: first ? _a : _b,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _problem = null;
      if (first) {
        if (chosen == _b) _b = _a;
        _a = chosen;
      } else {
        if (chosen == _a) {
          _b = null;
        } else {
          _b = chosen;
        }
      }
    });
  }

  Future<void> _create() async {
    final b = _b;
    if (b == null || _preparing) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    final BeamPreparedDexCall prepared;
    try {
      prepared = await deps.dex.prepareCreatePool(
        aidA: _a,
        aidB: b,
        kind: _kind,
      );
    } on BeamDexException catch (e) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _problem = e.code == BeamDexErrorCode.poolExists
            ? context.l10n.dexPoolExists
            : context.l10n.dexCreateRefused(e.message);
      });
      unawaited(deps.pools.refresh());
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _problem = context.l10n.dexCreateBuildFailed;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    final txId = await BeamDexConfirmView.show(
      context,
      deps: deps,
      prepared: prepared,
    );
    if (!mounted || txId == null) return;
    Navigator.of(context).pop();
  }

  ({VoidCallback? onPressed, String? reason}) _cta() {
    final l10n = context.l10n;
    if (_preparing) return (onPressed: null, reason: l10n.dexBuildingPool);
    if (!deps.canSpend) {
      return (onPressed: null, reason: l10n.dexPausedUntilSynced);
    }
    if (_b == null) {
      return (onPressed: null, reason: l10n.dexChooseSecondAsset);
    }
    if (_existing != null) return (onPressed: null, reason: null);
    final need = kDexPoolCreateDeposit + kDexPoolCreateFee;
    final beam = deps.available(0);
    if (need > beam) {
      return (
        onPressed: null,
        reason: l10n.dexCreateNotEnoughBeam(
          '${DexFormat.exact(kDexPoolCreateDeposit)} BEAM',
          '${DexFormat.exact(kDexPoolCreateFee)} BEAM',
          '${DexFormat.exact(beam)} BEAM',
        ),
      );
    }
    return (onPressed: _create, reason: null);
  }

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    return DexPage(
      deps: deps,
      title: context.l10n.dexCreatePoolTitle,
      body: _body(context),
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('dex-create-cta'),
        label: context.l10n.dexCreatePoolCta,
        reason: cta.reason,
        onPressed: cta.onPressed,
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final labelStyle = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final existing = _existing;
    // Only a real price: "(No USD price)" would add nothing here.
    final depositWorth = deps.fiat?.value?.approx(kDexPoolCreateDeposit);
    final deposit = '${DexFormat.exact(kDexPoolCreateDeposit)} BEAM';
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DexSyncBanner(deps: deps),
        DexNotice(
          key: const Key('dex-create-deposit-note'),
          kind: DexNoticeKind.warning,
          title: depositWorth == null
              ? l10n.dexCreateDepositTitle(deposit)
              : l10n.dexCreateDepositTitleWorth(deposit, depositWorth),
          detail: l10n.dexCreateDepositDetail,
        ),
        const SizedBox(height: 16),
        Text(l10n.dexAssetsLabel, style: labelStyle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: _assetButton(context, _a, first: true)),
            const SizedBox(width: 8),
            Text('/', style: STextStyles.smallMed14(context)),
            const SizedBox(width: 8),
            Expanded(child: _assetButton(context, _b, first: false)),
          ],
        ),
        const SizedBox(height: 16),
        Text(l10n.dexFeeForEverySwap, style: labelStyle),
        const SizedBox(height: 6),
        for (final k in [BeamPoolKind.high, BeamPoolKind.mid, BeamPoolKind.low])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _kindOption(context, k),
          ),
        if (existing != null) ...[
          const SizedBox(height: 4),
          DexNotice(
            key: const Key('dex-create-exists'),
            title: l10n.dexCreateExistsTitle(
              deps.pairLabel(existing),
              existing.kind.feePercent,
            ),
            detail: existing.isEmpty
                ? l10n.dexCreateExistsEmpty
                : l10n.dexCreateExistsLive,
            actionLabel: l10n.dexOpenPool,
            onAction: () => unawaited(
              showDexPage<void>(
                context,
                deps,
                (_) => BeamDexPoolDetailView(deps: deps, pool: existing),
              ),
            ),
          ),
        ],
        if (_problem != null) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('dex-create-problem'),
            sticker: BeamMoments.somethingWentWrong,
            kind: DexNoticeKind.error,
            title: _problem!,
          ),
        ],
      ],
    );
  }

  Widget _assetButton(BuildContext context, int? id, {required bool first}) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      key: Key(first ? 'dex-create-asset-a' : 'dex-create-asset-b'),
      color: colors.textFieldDefaultBG,
      onPressed: () => unawaited(_pick(first)),
      child: Row(
        children: [
          if (id != null) ...[
            DexAssetIcon(asset: deps.display(id), size: 24),
            const SizedBox(width: 8),
            Expanded(child: DexAssetName(asset: deps.display(id))),
          ] else
            Expanded(
              child: Text(
                context.l10n.dexChoose,
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ),
          Icon(Icons.expand_more_rounded, size: 18, color: colors.textDark3),
        ],
      ),
    );
  }

  Widget _kindOption(BuildContext context, BeamPoolKind k) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final selected = k == _kind;
    final l10n = context.l10n;
    final hint = switch (k) {
      BeamPoolKind.high => l10n.dexKindHigh,
      BeamPoolKind.mid => l10n.dexKindMid,
      BeamPoolKind.low => l10n.dexKindLow,
    };
    return RoundedContainer(
      key: Key('dex-create-kind-${k.wire}'),
      color: selected ? colors.textFieldActiveBG : colors.popupBG,
      borderColor: selected ? colors.accentColorBlue : colors.background,
      onPressed: () => setState(() => _kind = k),
      child: Row(
        children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 20,
            color: selected
                ? colors.radioButtonIconEnabled
                : colors.radioButtonIconBorder,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  k == BeamPoolKind.high
                      ? l10n.dexFeeTierRecommended(k.feePercent)
                      : l10n.dexFeeTier(k.feePercent),
                  style: STextStyles.smallMed14(context)
                      .copyWith(color: colors.textDark),
                ),
                Text(hint, style: STextStyles.label(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
