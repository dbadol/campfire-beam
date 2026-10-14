/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: send exactly this much of this coin to this address; then
//    see the buy go through until the BEAM is in the wallet.
// 2. Primary CTA: "Copy address" while the payment is awaited; after it,
//    the one next step: back to the wallet, "See it in your wallet" once
//    the wallet has the BEAM, "Start a new buy" when no payment came,
//    "Contact buybeam.my support" when buybeam.my needs a look.
// 3. Taps: it opens by itself from "Get a … deposit address"; later, Buy →
//    "Your buys" → the buy.
//
// Exit-intent:
// * "Which network? How much exactly?" — the coin and its network are
//   said above the address, the exact amount has its own copy button.
// * "Did it work?" — four steps, each ticked as it happens; the screen
//   updates by itself. "Arrived" is said only once this wallet has the
//   BEAM transaction, received at this buy's own address, and then with
//   the amount the wallet actually got; until then it says buybeam.my
//   sent it.
// * "Can I close this?" — said: the buy keeps going; Campfire must be
//   opened again within 12 hours for the BEAM to arrive (a regular BEAM
//   address needs the wallet online).
// * "It went wrong" — what happened, where the coins are (sent back, or
//   never taken), and the one next step.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../wallets/beam/buy/buybeam_order.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../eth/uniswap/uniswap_format.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_routes.dart';
import 'buy_beam_view.dart';
import 'buy_beam_widgets.dart';
import 'buy_beam_words.dart';

class BuyBeamOrderView extends StatefulWidget {
  const BuyBeamOrderView({
    super.key,
    required this.deps,
    required this.depositAddress,
    this.now,
  });

  final BuyBeamDeps deps;

  /// The buy's only handle.
  final String depositAddress;

  /// "today" is counted from this (tests); the clock when null.
  final DateTime Function()? now;

  static Future<void> show(
    BuildContext context,
    BuyBeamDeps deps,
    String depositAddress,
  ) => showBuyBeamPage<void>(
    context,
    deps,
    (_) => BuyBeamOrderView(deps: deps, depositAddress: depositAddress),
  );

  @override
  State<BuyBeamOrderView> createState() => _BuyBeamOrderViewState();
}

class _BuyBeamOrderViewState extends State<BuyBeamOrderView> {
  bool _copied = false;
  bool _amountCopied = false;

  /// What this wallet received at the buy's address in buybeam.my's BEAM
  /// transaction (null until it has).
  BigInt? _received;
  bool get _arrived => _received != null;
  Timer? _arrival;

  BuyBeamDeps get deps => widget.deps;
  BuyBeamController get c => deps.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    unawaited(() async {
      await c.resumeAll();
      // Where it is now, not where it was when the app last looked.
      if (c.order(widget.depositAddress)?.isOpen ?? false) {
        await c.poll(widget.depositAddress);
      }
      if (mounted) _watchArrival();
    }());
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    _arrival?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) return;
    setState(() {});
    _watchArrival();
  }

  /// Once buybeam.my has sent the BEAM, looks for it in the wallet until
  /// it is there.
  void _watchArrival() {
    final o = c.order(widget.depositAddress);
    final tx = o?.beamTxId;
    final check = deps.receivedInWallet;
    if (_arrived ||
        _arrival != null ||
        check == null ||
        tx == null ||
        o?.lastState != BuyBeamState.delivered) {
      return;
    }
    Future<void> look() async {
      BuyBeamReceipt? got;
      try {
        got = await check(tx);
      } catch (_) {
        got = null;
      }
      // buybeam.my names the transaction; only BEAM this wallet received
      // at the buy's own address makes it "arrived".
      if (!mounted || got == null || !got.isFor(o!.beamAddress)) return;
      _arrival?.cancel();
      setState(() => _received = got!.groth);
    }

    _arrival = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(look()),
    );
    unawaited(look());
  }

  Future<void> _copy(String text, {bool amount = false}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => amount ? _amountCopied = true : _copied = true);
  }

  void _back() => Navigator.of(context).pop();

  void _newBuy() => unawaited(
    Navigator.of(context).pushReplacement(
      buyBeamRoute<void>(context, deps, (_) => BuyBeamView(deps: deps)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final o = c.order(widget.depositAddress);
    final l10n = context.l10n;
    if (o == null) {
      return DexPage(
        deps: deps,
        title: l10n.buyYourBuy,
        body: Text(l10n.buyLoadingYourBuy, style: STextStyles.label(context)),
      );
    }
    final s = o.lastState ?? BuyBeamState.awaitingDeposit;
    final String label;
    final VoidCallback action;
    switch (s) {
      case BuyBeamState.awaitingDeposit:
        label = _copied ? l10n.buyAddressCopied : l10n.buyCopyAddress;
        action = () => unawaited(_copy(o.depositAddress));
      case BuyBeamState.delivered when _arrived:
        label = l10n.buySeeInWallet;
        action = () => unawaited(
          deps.onOpenTransaction?.call(context, o.beamTxId) ??
              Future.sync(_back),
        );
      case BuyBeamState.delivered:
        label = l10n.buyBackToWallet;
        action = _back;
      case BuyBeamState.expired:
        label = l10n.buyStartNew;
        action = _newBuy;
      case BuyBeamState.failed:
      case BuyBeamState.attention:
        label = l10n.buyContactSupport;
        action = () => deps.onOpenSupport?.call();
      case BuyBeamState.refunded:
      case BuyBeamState.depositDetected:
      case BuyBeamState.swapping:
      case BuyBeamState.buying:
      case BuyBeamState.processing:
      case BuyBeamState.sending:
      case BuyBeamState.inProgress:
        label = l10n.buyBackToWallet;
        action = _back;
    }
    return DexPage(
      deps: deps,
      title: s == BuyBeamState.awaitingDeposit
          ? l10n.buyOrderSendTitle(BuyBeamWords.coin(o.sendAmount, o.symbol))
          : l10n.buyTitle,
      body: _body(context, o, s),
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('buy-order-cta'),
        label: label,
        onPressed: action,
      ),
    );
  }

  Widget _body(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final quiet = STextStyles.label(context)
        .copyWith(color: colors.textSubtitle1);
    final waiting = s == BuyBeamState.awaitingDeposit;
    final pollError = c.pollError(o.depositAddress);
    final notice = _notice(context, o, s);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (o.sandbox) ...[
          DexNotice(key: const Key('buy-sandbox'), title: l10n.buySandbox),
          const SizedBox(height: 12),
        ],
        if (notice != null) ...[notice, const SizedBox(height: 12)],
        if (waiting) ..._payment(context, o),
        BuyStepList(steps: buyBeamSteps(s, arrived: _arrived)),
        const SizedBox(height: 12),
        _details(context, o, s),
        if (o.isOpen) ...[
          const SizedBox(height: 12),
          Text(l10n.buyKeepOpen, key: const Key('buy-keep-open'), style: quiet),
          const SizedBox(height: 4),
          Text(l10n.buyCanLeave, key: const Key('buy-can-leave'), style: quiet),
        ],
        if (pollError != null && o.isOpen) ...[
          const SizedBox(height: 4),
          Text(
            pollError.code.unreachable
                ? l10n.buyPollUnreachable
                : l10n.buyPollBadAnswer,
            key: const Key('buy-poll-error'),
            style: quiet,
          ),
        ],
      ],
    );
  }

  List<Widget> _payment(BuildContext context, BuyBeamOrder o) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final deadline = o.deadline?.toLocal();
    return [
      RoundedContainer(
        color: colors.warningBackground,
        child: Text(
          l10n.buyNetworkWarning(o.symbol, o.chainName),
          key: const Key('buy-network-warning'),
          style: STextStyles.smallMed12(context)
              .copyWith(color: colors.warningForeground),
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(8),
          child: QrImageView(
            key: const Key('buy-qr'),
            data: o.depositAddress,
            size: 150,
            backgroundColor: Colors.white,
          ),
        ),
      ),
      const SizedBox(height: 10),
      DexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BuyCoinIcon(assetId: o.assetId, symbol: o.symbol, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.buyDepositAddressLabel(o.chainName),
                    style: STextStyles.label(context),
                  ),
                ),
                CustomTextButton(
                  key: const Key('buy-copy-address'),
                  text: _copied ? l10n.commonCopied : l10n.commonCopy,
                  onTap: () => unawaited(_copy(o.depositAddress)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              o.depositAddress,
              key: const Key('buy-deposit-address'),
              style: STextStyles.smallMed14(context).copyWith(
                color: colors.textDark,
                fontFeatures: kAddressFontFeatures,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      DexCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.buySendExactly, style: STextStyles.label(context)),
                  Text(
                    '${o.sendAmount} ${o.symbol}',
                    key: const Key('buy-exact-amount'),
                    style: STextStyles.titleBold12(context)
                        .copyWith(color: colors.textDark, fontSize: 16),
                  ),
                ],
              ),
            ),
            CustomTextButton(
              key: const Key('buy-copy-amount'),
              text: _amountCopied ? l10n.commonCopied : l10n.commonCopy,
              onTap: () => unawaited(_copy(o.sendAmount, amount: true)),
            ),
          ],
        ),
      ),
      if (deadline != null) ...[
        const SizedBox(height: 8),
        Text(
          _until(deadline),
          key: const Key('buy-deadline'),
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
      ],
      const SizedBox(height: 12),
    ];
  }

  /// "This address works until 14:05 today." / "… until 14:05 on 15 Jan."
  String _until(DateTime t) {
    final now = (widget.now?.call() ?? DateTime.now()).toLocal();
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final today =
        t.year == now.year && t.month == now.month && t.day == now.day;
    if (today) return context.l10n.buyDeadlineToday(hm);
    // The month as a case of the message (jan … dec), not as a word.
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    return context.l10n.buyDeadlineOnDay(hm, t.day, months[t.month - 1]);
  }

  Widget _details(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    final estimate = o.beamEstimate == null
        ? null
        : BuyBeamWords.beam(BuyBeamWords.groth(o.beamEstimate!));
    // Paid once buybeam.my has seen the payment.
    final paid = !const {
      BuyBeamState.awaitingDeposit,
      BuyBeamState.expired,
      BuyBeamState.failed,
    }.contains(s);
    final l10n = context.l10n;
    return DexCard(
      child: Column(
        children: [
          DexDetailRow(
            label: paid ? l10n.buyYouPaid : l10n.buyYouPay,
            value: '${o.sendAmount} ${o.symbol}',
          ),
          if (_received case final got?)
            DexDetailRow(
              label: l10n.buyYouGot,
              valueKey: const Key('buy-order-received'),
              value: BuyBeamWords.beamExact(got),
            )
          else if (estimate != null)
            DexDetailRow(
              label: l10n.buyYouGet,
              valueKey: const Key('buy-order-estimate'),
              value: '≈ $estimate',
            ),
          DexDetailRow(label: l10n.buyArrivesInLabel, value: deps.walletName),
          DexDetailRow(
            address: true,
            label: l10n.buyRefundsGoTo,
            value: UniFormat.shortAny(o.refundAddress),
          ),
          // The order's handle, for buybeam.my's support.
          if (s != BuyBeamState.awaitingDeposit)
            DexDetailRow(
              address: true,
              label: l10n.buyOrderLabel,
              valueKey: const Key('buy-order-address'),
              value: UniFormat.shortAny(o.depositAddress),
              trailing: CustomTextButton(
                key: const Key('buy-copy-order'),
                text: _copied ? l10n.commonCopied : l10n.commonCopy,
                onTap: () => unawaited(_copy(o.depositAddress)),
              ),
            ),
          if (o.beamTxId != null)
            DexDetailRow(
              address: true,
              label: l10n.buyBeamTransaction,
              valueKey: const Key('buy-beam-tx'),
              value: UniFormat.shortAny(o.beamTxId!),
            ),
        ],
      ),
    );
  }

  Widget? _notice(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    final l10n = context.l10n;
    switch (s) {
      case BuyBeamState.delivered:
        final got = o.beamEstimate == null
            ? null
            : '≈ ${BuyBeamWords.beam(BuyBeamWords.groth(o.beamEstimate!))}';
        if (_received case final received?) {
          return DexNotice(
            key: const Key('buy-arrived'),
            kind: DexNoticeKind.success,
            title: l10n.buyArrived,
            // What the wallet got, every digit: not buybeam.my's estimate.
            detail: l10n.buyArrivedDetail(
              BuyBeamWords.beamExact(received),
              deps.walletName,
            ),
          );
        }
        return DexNotice(
          key: const Key('buy-delivered'),
          title: l10n.buyDeliveredTitle,
          detail: got == null
              ? l10n.buyDeliveredDetailNoAmount(deps.walletName)
              : l10n.buyDeliveredDetail(got, deps.walletName),
        );
      case BuyBeamState.refunded:
        return DexNotice(
          key: const Key('buy-refunded'),
          kind: DexNoticeKind.warning,
          title: l10n.buyRefundedTitle(UniFormat.shortAny(o.refundAddress)),
          detail: l10n.buyRefundedDetail(o.symbol, o.chainName),
        );
      case BuyBeamState.expired:
        return DexNotice(
          key: const Key('buy-expired'),
          kind: DexNoticeKind.warning,
          title: l10n.buyExpiredTitle,
          detail: l10n.buyExpiredDetail,
        );
      case BuyBeamState.failed:
        return DexNotice(
          key: const Key('buy-failed'),
          kind: DexNoticeKind.error,
          title: l10n.buyStateFailed,
          detail: l10n.buyFailedDetail,
        );
      case BuyBeamState.attention:
        return DexNotice(
          key: const Key('buy-attention'),
          kind: DexNoticeKind.warning,
          title: l10n.buyAttentionTitle,
          detail: l10n.buyAttentionDetail,
        );
      case BuyBeamState.awaitingDeposit:
      case BuyBeamState.depositDetected:
      case BuyBeamState.swapping:
      case BuyBeamState.buying:
      case BuyBeamState.processing:
      case BuyBeamState.sending:
      case BuyBeamState.inProgress:
        return null;
    }
  }
}
