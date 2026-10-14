/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Buy BEAM screens say: dollars and BEAM the way people read
// them, how long a buy usually takes, the smallest buy in the coin being
// paid with, and every way buybeam.my can say no, in plain words, never
// the user's fault, each with the one thing that fixes it. The words are
// in lib/l10n (buy* keys), in the language the app speaks.

import 'dart:math' as math;

import '../../../l10n/amount_text.dart';
import '../../../l10n/l10n.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_order.dart';
import '../../eth/uniswap/uniswap_format.dart';

/// The one thing that fixes a problem.
enum BuyFix {
  /// Put the smallest buy in the amount field.
  useMinimum,

  /// Change the amount.
  editAmount,

  /// Pick another coin.
  pickCoin,

  /// Change the refund address.
  editRefund,

  /// Ask again.
  tryAgain,

  /// Open buybeam.my's support.
  contactSupport,
}

class BuyProblem {
  const BuyProblem({
    required this.title,
    this.detail,
    this.fix,
    this.fixLabel,
    this.serious = false,
  });

  final String title;
  final String? detail;
  final BuyFix? fix;
  final String? fixLabel;

  /// An error colour rather than a warning one.
  final bool serious;
}

abstract final class BuyBeamWords {
  /// "$1,000", "$1,497.27", "$5".
  static String usd(double v) {
    final whole = v >= 1000 || v == v.roundToDouble();
    final cents = (v * 100).round();
    final dollars = whole ? (v.round()) : cents ~/ 100;
    final g = UniFormat.exact(BigInt.from(dollars), 0);
    if (whole) return '\$$g';
    return '\$$g.${(cents % 100).toString().padLeft(2, '0')}';
  }

  /// "166,888.69 BEAM" from groth.
  static String beam(BigInt groth) => '${UniFormat.compact(groth, 8)} BEAM';

  /// "166,888.69123456 BEAM" from groth: every digit, as received.
  static String beamExact(BigInt groth) => '${formatAmountUnits(groth)} BEAM';

  /// "111,326 BEAM": whole BEAM from a thousand up, for a list.
  static String beamShort(double beam) => beam >= 1000
      ? '${UniFormat.exact(BigInt.from(beam.floor()), 0)} BEAM'
      : BuyBeamWords.beam(groth(beam));

  /// The estimate buybeam.my gave, in groth.
  static BigInt groth(double beam) => BigInt.from((beam * 1e8).round());

  /// "0.0123 BTC" exactly as it must be sent.
  static String coin(String amount, String symbol) => '$amount $symbol';

  /// "Usually done in about 14 minutes" (rounded up; "a few minutes"
  /// under three).
  static String eta(int seconds) {
    final minutes = (seconds / 60).ceil();
    if (minutes < 3) return appL10n.buyEtaFewMinutes;
    if (minutes < 90) return appL10n.buyEtaMinutes(minutes);
    final hours = (minutes / 60).ceil();
    return appL10n.buyEtaHours(hours);
  }

  /// The amount of [asset] worth at least [minimumUsd] (a little over, so
  /// a moving price does not put it back under), rounded up to three
  /// significant digits; null without a price.
  static String? minimumAmount(
    double minimumUsd,
    BuyBeamAsset asset, {
    double? priceUsd,
  }) {
    final price = priceUsd ?? asset.priceUsd;
    if (price == null || price <= 0 || minimumUsd <= 0) return null;
    final value = minimumUsd * 1.005 / price;
    final exponent = (math.log(value) / math.ln10).floor();
    final maxPlaces = BuyBeamAmount.maxFractionDigits(asset.decimals);
    var places = math.max(0, 2 - exponent);
    if (places > maxPlaces) places = maxPlaces;
    final step = math.pow(10, -places).toDouble();
    var units = (value / step).ceil();
    for (var i = 0; i < 20; i++, units++) {
      final text = (units * step).toStringAsFixed(places);
      final a = BuyBeamAmount.parse(text, decimals: asset.decimals).amount;
      if (a != null && a.isPositive && a.exact) return a.text;
    }
    return null;
  }

  /// [e] as the form shows it. [minimum]: the smallest buy in the coin
  /// ("0.0122"), when it could be worked out.
  static BuyProblem problem(
    BuyBeamError e, {
    required BuyBeamAsset coin,
    String? minimum,
    bool tor = false,
  }) {
    final sym = coin.symbol;
    final l = appL10n;
    switch (e.code) {
      case BuyBeamErrorCode.amountBelowUpstreamMinimum:
      case BuyBeamErrorCode.amountBelowOurMinimum:
        final usdText = e.minimumUsd == null ? null : usd(e.minimumUsd!);
        if (minimum != null) {
          final amount = BuyBeamWords.coin(minimum, sym);
          return BuyProblem(
            title: usdText == null
                ? l.buyProblemAtLeast(amount)
                : l.buyProblemAtLeastUsd(amount, usdText),
            detail: l.buyProblemSmallestDetail,
            fix: BuyFix.useMinimum,
            fixLabel: l.buyFixUseAmount(amount),
          );
        }
        return BuyProblem(
          title: usdText == null
              ? l.buyProblemUnderSmallest
              : l.buyProblemAtLeastUsdOf(usdText, sym),
          detail: l.buyProblemSmallestDetail,
          fix: BuyFix.editAmount,
          fixLabel: l.buyFixChangeAmount,
        );
      case BuyBeamErrorCode.badAmount:
      case BuyBeamErrorCode.amountTooSmall:
        return BuyProblem(
          title: l.buyProblemCantUseAmount(sym),
          detail: l.buyProblemTooSmallDetail,
          fix: BuyFix.editAmount,
          fixLabel: l.buyFixChangeAmount,
        );
      case BuyBeamErrorCode.unknownAsset:
        return BuyProblem(
          title: l.buyProblemNoLongerTakes(sym, coin.chainName),
          detail: l.buyProblemPickCoinDetail,
          fix: BuyFix.pickCoin,
          fixLabel: l.buyFixPickCoin,
        );
      case BuyBeamErrorCode.assetUnavailable:
        return BuyProblem(
          title: l.buyProblemPaused(sym, coin.chainName),
          detail: l.buyProblemPausedDetail,
          fix: BuyFix.pickCoin,
          fixLabel: l.buyFixPickCoin,
        );
      case BuyBeamErrorCode.noLiquidity:
        return BuyProblem(
          title: l.buyProblemTooMuch(sym),
          detail: l.buyProblemTooMuchDetail,
          fix: BuyFix.editAmount,
          fixLabel: l.buyFixChangeAmount,
        );
      case BuyBeamErrorCode.refundAddressRequired:
        return BuyProblem(
          title: l.buyProblemAddRefund(coin.chainName),
          detail: l.buyProblemAddRefundDetail(sym),
          fix: BuyFix.editRefund,
          fixLabel: l.buyFixAddAddress,
        );
      case BuyBeamErrorCode.beamWalletRequired:
      case BuyBeamErrorCode.beamWalletTooShort:
      case BuyBeamErrorCode.beamWalletTooLong:
      case BuyBeamErrorCode.beamWalletInvalid:
        return BuyProblem(
          title: l.buyProblemBeamAddress,
          detail: l.buyProblemBeamAddressDetail,
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
      case BuyBeamErrorCode.assetIdRequired:
      case BuyBeamErrorCode.badBody:
        return BuyProblem(
          title: l.buyProblemBadRequest,
          detail: l.buyNotYourFault,
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
      case BuyBeamErrorCode.orderNotFound:
        return BuyProblem(
          title: l.buyProblemNotFound,
          detail: l.buyProblemNotFoundDetail,
          fix: BuyFix.contactSupport,
          fixLabel: l.buyContactSupport,
          serious: true,
        );
      case BuyBeamErrorCode.priceUnavailable:
      case BuyBeamErrorCode.upstreamAbsent:
      case BuyBeamErrorCode.upstreamUnavailable:
      case BuyBeamErrorCode.quoteFailed:
        return BuyProblem(
          title: l.buyProblemNoPrice,
          detail: joinSentences([
            l.buyProblemNoPriceDetail,
            _later(e.retryAfter),
          ], l),
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
      case BuyBeamErrorCode.noDepositAddress:
        return BuyProblem(
          title: l.buyProblemNoDeposit,
          detail: l.buyProblemNoDepositDetail,
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
      case BuyBeamErrorCode.blocked:
      case BuyBeamErrorCode.network:
        final server = (e.httpStatus ?? 0) >= 500;
        return BuyProblem(
          title: l.buyCantReach,
          detail: joinSentences([
            l.buyNothingSent,
            if (server && !coin.isEvm) l.buyCheckRefundAddress(coin.chainName),
            if (tor) l.buyTorHint,
          ], l),
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
      case BuyBeamErrorCode.wrongDepositAddress:
        return BuyProblem(
          title: l.buyProblemWrongDeposit(coin.chainName),
          detail: l.buyProblemWrongDepositDetail(sym),
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
          serious: true,
        );
      case BuyBeamErrorCode.unexpectedAnswer:
        return BuyProblem(
          title: l.buyProblemUnexpected,
          detail: l.buyProblemUnexpectedDetail,
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
          serious: true,
        );
      case BuyBeamErrorCode.unknown:
        return BuyProblem(
          title: l.buyProblemUnknown,
          detail: l.buyProblemUnknownDetail,
          fix: BuyFix.tryAgain,
          fixLabel: l.commonTryAgain,
        );
    }
  }

  static String _later(Duration? after) {
    if (after == null || after.inSeconds < 5) return appL10n.buyRetrySoon;
    if (after.inSeconds < 90) {
      return appL10n.buyRetrySeconds(after.inSeconds);
    }
    return appL10n.buyRetryMinutes((after.inSeconds / 60).ceil());
  }

  /// One line for a buy in a list: where it is, in plain words.
  static String stateLine(BuyBeamOrder o) => switch (o.lastState) {
    null || BuyBeamState.awaitingDeposit => appL10n.buyStateWaiting,
    BuyBeamState.depositDetected => appL10n.buyStateReceived,
    BuyBeamState.sending => appL10n.buyStateSending,
    BuyBeamState.delivered => appL10n.buyStateSent,
    BuyBeamState.refunded => appL10n.buyStateRefunded,
    BuyBeamState.expired => appL10n.buyStateExpired,
    BuyBeamState.failed => appL10n.buyStateFailed,
    BuyBeamState.attention => appL10n.buyStateChecking,
    BuyBeamState.swapping ||
    BuyBeamState.buying ||
    BuyBeamState.processing ||
    BuyBeamState.inProgress => appL10n.buyStateBuying,
  };
}
