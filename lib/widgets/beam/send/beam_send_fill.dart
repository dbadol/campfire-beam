/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A recipient for a wallet's BEAM Send to take in, from the home's Scan on
// desktop, where Send is a tab of the wallet page rather than a screen of
// its own: the tabs bring Send forward (beam_desktop_wallet_tabs.dart) and
// the Send screen fills its field (beam_send_screen.dart), then clears it.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// [recipient] (an address, or a name as "alice.beam") and, when the code
/// carried one, [amount] in BEAM ("1.5"). [serial] tells two scans of the
/// same code apart.
@immutable
class BeamSendFill {
  const BeamSendFill(
    this.recipient, {
    this.amount,
    this.amountUnread = false,
    required this.serial,
  });

  /// A new fill, told apart from every earlier one.
  factory BeamSendFill.next(
    String recipient, {
    String? amount,
    bool amountUnread = false,
  }) => BeamSendFill(
    recipient,
    amount: amount,
    amountUnread: amountUnread,
    serial: ++_serial,
  );

  final String recipient;
  final String? amount;

  /// The code was a link asking for an amount that could not be read
  /// (ScanToBeamSend.amountUnread): Send says so under the amount.
  final bool amountUnread;
  final int serial;
}

int _serial = 0;

/// The fill waiting for wallet `walletId`'s Send, or null.
final pBeamSendFill = StateProvider.family<BeamSendFill?, String>(
  (ref, walletId) => null,
);
