/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: show exactly what this move does — every amount leaving
//    each wallet, every fee, what arrives where and when, and what is
//    public — and start it only after Campfire's PIN / password.
// 2. Primary CTA: the outcome, "Move 1,000 BEAM to Ethereum".
// 3. Taps from app open: the Move screen's button (3 on a phone), this
//    button (4), then the PIN.
//
// To Ethereum, the BEAM network fee is the one decoded from the built
// transaction. To BEAM, the Ethereum transactions are named one by one,
// the approval included ("allow the bridge to take exactly 100 USDT"),
// so no signature comes as a surprise; collecting on BEAM later costs
// 0.121 BEAM, said here, and is only automatic when ticked here.
//
// Exit-intent:
// * "Is this a scam?" — the destination is your own wallet, named with its
//   address; the contract is BEAM's official bridge, named with its id.
// * A surprise fee — every fee is its own line, in the coin and dollars,
//   and the total leaving each wallet sits with the button.
// * "Who can see this?" — said plainly: bridging is public on both chains.
// * "Can this coin be frozen?" — said for WBEAM, USDT and WBTC.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_fees.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../wallets/bridge/bridge_sides.dart';
import '../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../widgets/beam/dex/dex_widgets.dart';
import '../../widgets/rounded_container.dart';
import 'bridge_deps.dart';
import 'bridge_format.dart';
import 'bridge_widgets.dart';

enum _Phase { review, sending }

/// Pops with the new crossing's id once started, or null when the user
/// went back. Nothing is sent before the PIN.
class BridgeReviewView extends StatefulWidget {
  const BridgeReviewView({
    super.key,
    required this.deps,
    required this.controller,
    required this.prepared,
  });

  final BridgeDeps deps;
  final BridgeController controller;
  final BridgePrepared prepared;

  static Future<String?> show(
    BuildContext context, {
    required BridgeDeps deps,
    required BridgeController controller,
    required BridgePrepared prepared,
  }) => showDexPage<String>(
    context,
    deps,
    (_) => BridgeReviewView(
      deps: deps,
      controller: controller,
      prepared: prepared,
    ),
  );

  @override
  State<BridgeReviewView> createState() => _BridgeReviewViewState();
}

/// Why a coin of [r] could be stopped on Ethereum, as a notice's title
/// and text; null when it cannot.
({String title, String detail})? bridgeFreezeNote(BridgeRoute r) {
  final l = appL10n;
  return switch (r.id) {
    'beam' => (
      title: l.bridgeFreezeWbeamTitle,
      detail: l.bridgeFreezeDetail('WBEAM'),
    ),
    'usdt' => (
      title: l.bridgeFreezeUsdtTitle,
      detail: l.bridgeFreezeDetail('USDT'),
    ),
    'wbtc' => (
      title: l.bridgeFreezeWbtcTitle,
      detail: l.bridgeFreezeDetail('WBTC'),
    ),
    _ => null,
  };
}

class _BridgeReviewViewState extends State<BridgeReviewView> {
  _Phase _phase = _Phase.review;
  bool _autoClaim = false;
  String? _error;

  BridgeDeps get deps => widget.deps;
  BridgePrepared get p => widget.prepared;
  BridgeQuote get q => p.quote;
  BridgeRoute get r => q.route;
  bool get _toEth => q.toEthereum;
  int get _srcDec => r.sourceDecimals(q.direction);
  String get _srcSym => r.sourceSymbol(q.direction);
  int get _dstDec => r.destinationDecimals(q.direction);
  String get _dstSym => r.destinationSymbol(q.direction);
  BigInt get _fee => q.fee!;

  String _cta(AppLocalizations l10n) {
    final coin = BridgeFormat.coin(q.amount, _srcDec, _srcSym);
    return _toEth
        ? l10n.bridgeMoveAmountToEthereum(coin)
        : l10n.bridgeMoveAmountToBeam(coin);
  }

  Future<void> _confirm() async {
    if (_phase != _Phase.review) return;
    // Set before the first await: a second tap lands here and returns.
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    final ok = await deps.authenticate(
      context,
      reason: context.l10n.bridgeAuthMoveReason,
    );
    if (!mounted) return;
    if (ok != true) {
      setState(() {
        _phase = _Phase.review;
        _error = ok == false
            ? (deps.desktop
                  ? context.l10n.bridgeWrongPasswordNothingSent
                  : context.l10n.bridgeWrongPinNothingSent)
            : null;
      });
      return;
    }
    if (_toEth && !(deps.beamCanSpend?.value ?? true)) {
      setState(() {
        _phase = _Phase.review;
        _error = context.l10n.bridgeBeamFellBehind;
      });
      return;
    }
    try {
      final crossing = await widget.controller.start(
        p,
        autoClaim: !_toEth && _autoClaim,
      );
      if (mounted) Navigator.of(context).pop(crossing.id);
    } on BridgeReviewExpired {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.review;
        _error = context.l10n.bridgeReviewExpired;
      });
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.review;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.review;
        _error = context.l10n.bridgeStartNoAnswer;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.sending;
    final l10n = context.l10n;
    return PopScope<String>(
      canPop: !busy,
      child: DexPage(
        deps: deps,
        title: l10n.bridgeReviewTitle,
        onClose: busy ? () {} : () => Navigator.of(context).pop(),
        body: _body(context),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              DexNotice(
                key: const Key('bridge-review-error'),
                kind: DexNoticeKind.error,
                title: _error!,
              ),
              const SizedBox(height: 12),
            ],
            _total(context),
            const SizedBox(height: 12),
            DexPrimaryAction(
              deps: deps,
              buttonKey: const Key('bridge-review-cta'),
              label: _cta(l10n),
              reason: busy ? l10n.bridgeSending : null,
              onPressed: busy ? null : _confirm,
            ),
          ],
        ),
      ),
    );
  }

  /// What leaves each wallet now, in one coloured box by the button.
  Widget _total(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.titleBold12(context)
        .copyWith(color: colors.textConfirmTotalAmount);
    final valueStyle = STextStyles.itemSubtitle12(context)
        .copyWith(color: colors.textConfirmTotalAmount);
    final l10n = context.l10n;
    final String text;
    if (_toEth) {
      text = r.isBeam
          ? BridgeFormat.coin(q.amount + _fee + p.beamNetworkFee, 8, 'BEAM')
          : '${BridgeFormat.coin(q.amount + _fee, 8, _srcSym)} + '
                '${BridgeFormat.coin(p.beamNetworkFee, 8, 'BEAM')}';
    } else {
      final gas = p.ethNetworkFee ?? BigInt.zero;
      text = r.isNativeEth
          ? l10n.bridgeUpToAmount(
              BridgeFormat.coin(q.amount + _fee + gas, 18, 'ETH'),
            )
          : l10n.bridgeAmountPlusUpTo(
              BridgeFormat.coin(q.amount + _fee, _srcDec, _srcSym),
              BridgeFormat.coinShort(gas, 18, 'ETH'),
            );
    }
    return RoundedContainer(
      color: colors.snackBarBackSuccess,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _toEth ? l10n.bridgeLeavingBeamWallet : l10n.bridgeLeavingEthWallet,
            style: style,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              key: const Key('bridge-review-total'),
              textAlign: TextAlign.right,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final prices = q.prices;
    final ethAddress = q.ethAddress;
    final note = bridgeFreezeNote(r);
    final steps = p.plan?.steps ?? const <UniTxRequest>[];
    final approvals = steps.length - 1;
    final l10n = context.l10n;
    final take = BridgeFormat.coin(q.amount + _fee, _srcDec, _srcSym);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundedContainer(
          color: colors.snackBarBackInfo,
          child: Row(
            children: [
              BridgeAssetIcon(route: r, onBeam: !_toEth, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _toEth
                          ? l10n.bridgeArrivesInEthWallet
                          : l10n.bridgeArrivesInBeamWallet,
                      style: STextStyles.label(context)
                          .copyWith(color: colors.snackBarTextInfo),
                    ),
                    Text(
                      BridgeFormat.coin(q.receives, _dstDec, _dstSym),
                      key: const Key('bridge-review-receive'),
                      style: STextStyles.titleBold12(
                        context,
                      ).copyWith(color: colors.snackBarTextInfo, fontSize: 18),
                    ),
                    Text(
                      _toEth
                          ? l10n.bridgeTimeOrWhenBusy(
                              BridgeFormat.about(BridgeTiming.toEthereum),
                              BridgeFormat.upTo(_slowest),
                            )
                          : l10n.bridgeTimeThenCollect(
                              BridgeFormat.about(BridgeTiming.toBeam),
                            ),
                      key: const Key('bridge-review-time'),
                      style: STextStyles.label(context)
                          .copyWith(color: colors.snackBarTextInfo),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(
                label: l10n.bridgeYouMoveLabel,
                valueKey: const Key('bridge-review-amount'),
                value: BridgeFormat.coin(q.amount, _srcDec, _srcSym),
                note: BridgeFormat.usd(
                  prices,
                  r.coingeckoId,
                  q.amount,
                  _srcDec,
                ),
              ),
              DexDetailRow(
                label: _toEth
                    ? l10n.bridgeFeeLabel
                    : l10n.bridgeFeeOperatorLabel,
                valueKey: const Key('bridge-review-fee'),
                value: BridgeFormat.coin(_fee, _srcDec, _srcSym),
                note: BridgeFormat.usd(prices, r.coingeckoId, _fee, _srcDec),
              ),
              if (_feeWhy case final why?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    why,
                    key: const Key('bridge-review-fee-why'),
                    style: STextStyles.label(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ),
              DexDetailRow(
                label: _toEth
                    ? l10n.bridgeBeamNetworkFeeLabel
                    : l10n.bridgeBeamNetworkFeeCollectLabel,
                valueKey: const Key('bridge-review-beam-fee'),
                value: BridgeFormat.coin(p.beamNetworkFee, 8, 'BEAM'),
                note: BridgeFormat.usd(prices, 'beam', p.beamNetworkFee, 8),
              ),
              if (!_toEth)
                DexDetailRow(
                  label: approvals > 0
                      ? l10n.bridgeEthNetworkFeeForCount(approvals + 1)
                      : l10n.bridgeEthNetworkFeeLabel,
                  valueKey: const Key('bridge-review-eth-fee'),
                  value: l10n.bridgeUpToAmount(
                    BridgeFormat.coinShort(p.ethNetworkFee!, 18, 'ETH'),
                  ),
                  note: BridgeFormat.usd(
                    prices,
                    'ethereum',
                    p.ethNetworkFee!,
                    18,
                  ),
                ),
              DexDetailRow(
                address: true,
                label: _toEth ? l10n.bridgeRowTo : l10n.bridgeRowFrom,
                value: l10n.bridgeYourEthWalletAddress(
                  bridgeShortAddress(ethAddress),
                ),
              ),
              DexDetailRow(
                address: true,
                label: l10n.bridgeThroughLabel,
                value: l10n.bridgeOfficialContract(
                  _toEth
                      ? _shortId(r.beamPipeCid)
                      : bridgeShortAddress(r.ethPipe),
                ),
              ),
            ],
          ),
        ),
        if (approvals > 0) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('bridge-review-approval'),
            title: l10n.bridgeReviewSignCount(approvals + 1),
            detail: approvals > 1
                ? l10n.bridgeReviewSignResetAllowThenSend(take, approvals + 1)
                : l10n.bridgeReviewSignAllowThenSend(take),
          ),
        ],
        const SizedBox(height: 12),
        DexNotice(
          key: const Key('bridge-review-public'),
          title: l10n.bridgePublicTitle,
          detail: l10n.bridgePublicDetail,
        ),
        if (note != null) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('bridge-review-freeze'),
            kind: DexNoticeKind.warning,
            title: note.title,
            detail: note.detail,
          ),
        ],
        for (final w in q.warnings) ...[
          const SizedBox(height: 12),
          DexNotice(
            kind: DexNoticeKind.warning,
            title: w.title,
            detail: w.detail,
          ),
        ],
        if (!_toEth) ...[
          const SizedBox(height: 4),
          // Its own Material: a desktop dialog's white box would hide the
          // tile's ink.
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              key: const Key('bridge-auto-claim'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _autoClaim,
              activeColor: colors.checkboxBGChecked,
              checkColor: colors.checkboxIconChecked,
              onChanged: _phase == _Phase.review
                  ? (v) => setState(() => _autoClaim = v ?? false)
                  : null,
              title: Text(
                l10n.bridgeAutoCollectTitle,
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textDark),
              ),
              subtitle: Text(
                l10n.bridgeAutoCollectDetail(
                  BridgeFormat.coin(kBridgeClaimFeeGroth, 8, 'BEAM'),
                ),
                style: STextStyles.label(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Duration get _slowest => BridgeTiming.toEthereumSlowest(r);

  /// Going to Ethereum: why the fee is more than the bridge asks today.
  String? get _feeWhy {
    final now = q.feeNow;
    if (!_toEth || now == null) return null;
    final room = ((kBridgeFeeMargin - 1) * 100).round();
    return context.l10n.bridgeFeeWhy(
      BridgeFormat.coinShort(now, _srcDec, _srcSym),
      '$room',
    );
  }

  static String _shortId(String hex) =>
      '${hex.substring(0, 6)}…${hex.substring(hex.length - 6)}';
}
