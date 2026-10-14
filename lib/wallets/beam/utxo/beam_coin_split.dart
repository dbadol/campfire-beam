/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../models/beam_utxo.dart';
import 'beam_coins.dart';

/// A split on its review screen: checked against the wallet's coins a
/// moment ago, holding the wallet's node switch (`BeamWallet.prepareSplit`)
/// until it is sent or [discard]ed.
///
/// A prepared split reaches the core at most once: once handed over, its tx
/// id is kept ([handedOff]) and any later confirm only looks it up.
class BeamPreparedSplit {
  BeamPreparedSplit({
    required this.plan,
    required this.before,
    required this.beamAvailable,
    this._onDiscard,
  });

  final BeamSplitPlan plan;

  /// The asset's coins when the split was prepared.
  final BeamCoinSummary before;

  /// Spendable BEAM, which pays the fee.
  final BigInt beamAvailable;

  final void Function()? _onDiscard;

  /// The tx id the core was given, once it was; null again when the core
  /// plainly refused it (nothing started, so it may be tried again).
  String? handedOff;

  bool _discarded = false;

  bool get isDiscarded => _discarded;

  /// Lets the node switch go. Harmless twice.
  void discard() {
    if (_discarded) return;
    _discarded = true;
    _onDiscard?.call();
  }
}

/// Why a split cannot start now and what happens next, in plain words.
abstract final class BeamSplitMessages {
  /// What the wallet's open money flows are, from their gate reasons.
  static String busy(Iterable<String> reasons) {
    final r = reasons.toSet();
    final l = appL10n;
    final String what;
    if (r.any((x) => x.contains('swap'))) {
      what = l.txSplitBusySwap;
    } else if (r.any((x) => x.contains('claim'))) {
      what = l.txSplitBusyClaim;
    } else if (r.any((x) => x.contains('dApp'))) {
      what = l.txSplitBusyDapp;
    } else if (r.any((x) => x.contains('split'))) {
      what = l.txSplitBusySplit;
    } else {
      what = l.txSplitBusyPayment;
    }
    return joinSentences([what, l.txSplitResumesSoon]);
  }

  static String get scanning => appL10n.txSplitScanning;

  static String get poolShare => appL10n.txSplitPoolShare;

  static String get notPrepared => appL10n.txSplitNotPrepared;

  static String get tooLittle => appL10n.txSplitTooLittle;

  static String changed() => appL10n.txSplitChanged;

  static String needBeamForFee(BigInt fee, BigInt beam) =>
      appL10n.txSplitNeedBeam(_beam(fee), _beam(beam), _beam(fee - beam));

  static String get outcomeUnknown => appL10n.txSplitOutcomeUnknown;

  static String get alreadyHandedOff => appL10n.txSplitAlreadyHandedOff;

  /// "0.005 BEAM": trailing zeros dropped, at least one decimal place.
  static String _beam(BigInt groth) {
    final unit = BigInt.from(10).pow(8);
    final whole = groth ~/ unit;
    var frac = (groth % unit).toString().padLeft(8, '0');
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    if (frac.isEmpty) frac = '0';
    return '$whole.$frac BEAM';
  }
}

/// Reads every `get_utxo` page (the core returns spent coins too, so a
/// long-lived wallet can have thousands) through [page], [pageSize] coins at
/// a time, without counting a coin twice if the list moves under the read.
Future<List<BeamUtxo>> beamReadAllCoins(
  Future<List<BeamUtxo>> Function(int skip, int count) page, {
  int pageSize = 500,
  int maxPages = 200,
}) async {
  final seen = <String>{};
  final out = <BeamUtxo>[];
  for (var i = 0; i < maxPages; i++) {
    final batch = await page(i * pageSize, pageSize);
    for (final u in batch) {
      if (seen.add('${u.type}:${u.id}')) out.add(u);
    }
    if (batch.length < pageSize) break;
  }
  return out;
}
