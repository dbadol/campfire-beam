/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../../l10n/l10n.dart';

/// Every failure the BANS module reports on purpose. [message] is plain
/// words that never blame the user and name what to do next, so the UI can
/// show it as is (in the app's language: names* keys in lib/l10n).
sealed class BansException implements Exception {
  const BansException();

  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// What is wrong with a name.
enum BansNameProblem { empty, tooShort, tooLong, invalidCharacter }

/// The text is not a name the contract accepts (`app.cpp:252-272`,
/// `contract.h:41-51`). Checked before anything is sent.
final class BansInvalidName extends BansException {
  const BansInvalidName(this.input, this.problem, this.message);

  final String input;
  final BansNameProblem problem;

  @override
  final String message;
}

/// A value that is not a 33-byte BVM public key (66 hex characters, the last
/// byte 00 or 01).
final class BansInvalidKey extends BansException {
  const BansInvalidKey(this.input);

  final String input;

  @override
  String get message => appL10n.namesErrorInvalidKey;
}

/// Why the app shader refused a request. The wire strings are the ones
/// `app.cpp` and `vault_anon/app_impl.h` pass to `OnError`.
enum BansRefusal {
  nameInvalid('name is invalid'),
  nameTooShort('name too short'),
  nameTooLong('name too long'),
  nameMissing('name not specified'),
  notRegistered('not registered'),
  ownedByOther('owned by other'),
  alreadyMine('already owned by me'),
  periodTooLong('validity period too long'),
  priceFeedUnavailable('price feed unavailable'),
  domainExpired('domain expired'),
  amountMissing('amount not specified'),
  notForSale('not for sale'),
  noChange('no change'),
  newOwnerMissing('new owner not set'),
  nothingToClaim('nothing to withdraw'),
  noFunds('no funds'),
  insufficientFunds('insufficient funds'),
  paymentNotFound('not detected'),
  contractStateMissing('state not found'),
  invalidAccountKey('invalid account key'),
  unknown('');

  const BansRefusal(this.wire);

  /// The exact text the shader writes into `{"error": ...}`.
  final String wire;

  static BansRefusal fromWire(String text) => values.firstWhere(
    (r) => r != unknown && r.wire == text,
    orElse: () => unknown,
  );
}

/// The app shader refused the request and said why ([refusal], with the
/// shader's own text in [shaderText]).
final class BansShaderRefused extends BansException {
  BansShaderRefused(this.shaderText)
    : refusal = BansRefusal.fromWire(shaderText);

  final BansRefusal refusal;
  final String shaderText;

  @override
  String get message => _messageFor(refusal, shaderText);

  static String _messageFor(BansRefusal r, String text) {
    final l = appL10n;
    return switch (r) {
      BansRefusal.nameInvalid => l.namesRefusedNameInvalid,
      BansRefusal.nameTooShort => l.namesProblemTooShort,
      BansRefusal.nameTooLong => l.namesProblemTooLong,
      BansRefusal.nameMissing => l.namesRefusedNameMissing,
      BansRefusal.notRegistered => l.namesRefusedNotRegistered,
      BansRefusal.ownedByOther => l.namesRefusedOwnedByOther,
      BansRefusal.alreadyMine => l.namesRefusedAlreadyMine,
      BansRefusal.periodTooLong => l.namesRefusedPeriodTooLong,
      BansRefusal.priceFeedUnavailable => l.namesRefusedPriceFeed,
      BansRefusal.domainExpired => l.namesRefusedExpired,
      BansRefusal.amountMissing => l.namesRefusedAmountMissing,
      BansRefusal.notForSale => l.namesRefusedNotForSale,
      BansRefusal.noChange => l.namesRefusedNoChange,
      BansRefusal.newOwnerMissing => l.namesRefusedNewOwnerMissing,
      BansRefusal.nothingToClaim => l.namesRefusedNothingToClaim,
      BansRefusal.noFunds => l.namesRefusedNothingToClaim,
      BansRefusal.insufficientFunds => l.namesRefusedInsufficientFunds,
      BansRefusal.paymentNotFound => l.namesRefusedPaymentNotFound,
      BansRefusal.contractStateMissing ||
      BansRefusal.invalidAccountKey ||
      BansRefusal.unknown => l.namesRefusedOther(text),
    };
  }
}

/// Claiming name payments (`role=user,action=view` / `receive_all`, or a
/// `receive` with a one-time key) runs the shader at privilege 1, which
/// stock wallet-api refuses: the call fails in `get_PkEx`
/// (research/05 §B.7). Raised instead of the raw core error.
final class BansClaimUnsupported extends BansException {
  const BansClaimUnsupported([this.coreDetail]);

  /// The core's error data, for logs. Contains no secrets.
  final Object? coreDetail;

  @override
  String get message => appL10n.namesErrorClaimUnsupported;
}

/// The name changed owner between the moment it was shown to the user and
/// the moment the payment was built or about to be signed. Nothing was sent.
final class BansOwnerChanged extends BansException {
  BansOwnerChanged(this.name, this.expectedKey, this.currentKey);

  final String name;
  final String expectedKey;

  /// Null when the name is no longer registered at all.
  final String? currentKey;

  @override
  String get message => appL10n.namesErrorOwnerChanged('$name.beam');
}

/// The node gave a vault for payments to a name that is not BEAM's own
/// (`kBansVaultCid`). Every payment to a name goes there, and the node
/// answers this without proof, so nothing is built or sent (audit D-1).
final class BansWrongVault extends BansException {
  const BansWrongVault(this.vaultCid);

  final String vaultCid;

  @override
  String get message => appL10n.namesErrorWrongVault;
}

/// The name has another owner than when this wallet last paid it, and the
/// person has not chosen to pay the new one. A name changes owner when it is
/// sold, transferred or lapses, or when the node lies about it (audit D-1),
/// so the change is never taken silently. Nothing was built or sent.
final class BansOwnerChangedSincePaid extends BansException {
  BansOwnerChangedSincePaid(this.name, this.paidKey, this.currentKey);

  final String name;

  /// The owner key this wallet paid before.
  final String paidKey;

  final String currentKey;

  @override
  String get message => appL10n.namesErrorOwnerChangedSincePaid('$name.beam');
}

/// This wallet's record of whom it paid by name could not be read, so a
/// change of owner cannot be checked (audit D-1 review). The record is left
/// as it is, never overwritten; each payment then asks the person to compare
/// the owner key with the recipient first.
final class BansPinsUnreadable extends BansException {
  const BansPinsUnreadable();

  @override
  String get message => appL10n.namesErrorPinsUnreadable;
}

/// The transaction the core built does not match what was asked for (wrong
/// contract, method, name, amount or asset). Nothing was sent. This should
/// never happen with the pinned shader; it stops a mismatch from being
/// signed if it does.
final class BansUnexpectedTransaction extends BansException {
  const BansUnexpectedTransaction(this.detail);

  final String detail;

  @override
  String get message => appL10n.namesErrorUnexpectedTx;
}

/// The bundled app shader is not the pinned build. Nothing is run with it.
final class BansShaderMismatch extends BansException {
  const BansShaderMismatch(this.actualSha256, this.actualSize);

  final String actualSha256;
  final int actualSize;

  @override
  String get message => appL10n.namesErrorShaderMismatch;
}
