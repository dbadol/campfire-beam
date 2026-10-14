/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import '../../../l10n/l10n.dart';
import '../host/beam_host_exception.dart';
import '../rpc/beam_connection_exception.dart';
import '../rpc/beam_transport.dart';

/// Why a BEAM wallet operation could not be done.
enum BeamWalletProblem {
  /// This build has no usable BEAM core for this computer: the binaries are
  /// missing, not pinned for this platform, or the BEAM flag is off.
  coreNotInstalled,

  /// A BEAM core binary is present but failed its pinned-hash or consensus
  /// check, so it is not run.
  coreUntrusted,

  /// Campfire's secure storage has no password for this wallet's file.
  passwordMissing,

  /// The stored password does not open the wallet file.
  wrongPassword,

  /// The wallet's data file is missing.
  walletFileMissing,

  /// Another process has the wallet file open.
  walletInUse,

  /// The configured BEAM node could not be used.
  nodeUnreachable,

  /// Tor is switched on and not connected yet, or cannot reach the node:
  /// the wallet waits rather than connect outside Tor.
  waitingForTor,

  /// Tor is switched on and this build's core cannot go through it, so the
  /// wallet does not connect.
  torUnsupported,

  /// The core is not open yet (or was closed).
  notOpen,

  /// The wallet is not honestly synced, so spending is off.
  notSynced,

  /// The recipient is not a BEAM address.
  invalidAddress,

  /// A real BEAM address of a type this version cannot send to yet.
  unsupportedAddressType,

  /// Amount plus fee is more than the available balance.
  insufficientFunds,

  /// The amount is zero, negative or not representable.
  invalidAmount,

  /// The recovery phrase is not a valid 12-word BIP39 phrase.
  invalidPhrase,

  /// The connection dropped while sending: the payment may or may not have
  /// gone out.
  sendOutcomeUnknown,

  /// The core refused the payment.
  sendRejected,

  /// Another money flow (a payment, swap, claim or dApp approval) is open or
  /// still being confirmed; this one waits until it is done.
  walletBusy,

  /// A restored wallet is still looking for its coins.
  scanningForCoins,

  /// Anything else.
  other,
}

/// A BEAM wallet error with a message a user can act on.
///
/// [toString] is the message alone, because Campfire's dialogs show
/// `e.toString()`. Messages never contain a password, a phrase, an owner
/// key, a full address or an amount together with an address.
class BeamWalletException implements Exception {
  const BeamWalletException(this.problem, this.message);

  final BeamWalletProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// Plain-language messages, kept in one place (their text is in
/// lib/l10n/app_en.arb, in the language the app speaks).
abstract final class BeamWalletMessages {
  static String get coreNotInstalled => appL10n.walletCoreNotInstalled;

  static String get coreUntrusted => appL10n.walletCoreUntrusted;

  /// [coreNotInstalled] and [coreUntrusted] as a phone says them.
  static String get coreNotInstalledOnPhone =>
      appL10n.walletCoreNotInstalledOnPhone;

  static String get coreUntrustedOnPhone => appL10n.walletCoreUntrustedOnPhone;

  static bool get _onPhone => Platform.isAndroid || Platform.isIOS;

  /// The "core not installed" text for the device the app runs on.
  static String get coreNotInstalledHere =>
      _onPhone ? coreNotInstalledOnPhone : coreNotInstalled;

  /// The "core failed the safety check" text for the device the app runs on.
  static String get coreUntrustedHere =>
      _onPhone ? coreUntrustedOnPhone : coreUntrusted;

  static String get passwordMissing => appL10n.walletPasswordMissing;

  static String get wrongPassword => appL10n.walletWrongPassword;

  static String get walletFileMissing => appL10n.walletFileMissing;

  static String get walletInUse => appL10n.walletInUse;

  static String get notOpen => appL10n.walletNotOpen;

  static String get rescanWhileBusy => appL10n.walletRescanWhileBusy;

  static String get rescanWithTxInFlight => appL10n.walletRescanWithTxInFlight;

  static String get rescanCoreStillOpen => appL10n.walletRescanCoreStillOpen;

  static String get importedNoRescan => appL10n.walletImportedNoRescan;

  static String get waitingForTor => appL10n.walletWaitingForTor;

  static String get torUnsupported => appL10n.walletTorUnsupported;

  /// [node] is the node's address as the person entered it; null when the
  /// wallet does not know which node was picked.
  static String nodeUnreachable(String? node) => node == null
      ? appL10n.walletNodeUnreachablePicked
      : appL10n.walletNodeUnreachable(node);

  static String get coreDidNotStart => appL10n.walletCoreDidNotStart;

  static String get invalidPhrase => appL10n.walletInvalidPhrase;

  /// The core's own refusal ([reason], in English: it comes from the BEAM
  /// core) wrapped in a sentence.
  static String rpcRefused(String reason) => appL10n.walletRpcRefused(reason);
}

/// Whether [error], thrown while sending, leaves it open whether the
/// payment went out: the connection dropped or the call timed out.
bool beamSendOutcomeUnknown(Object error) =>
    (error is BeamWalletException &&
        error.problem == BeamWalletProblem.sendOutcomeUnknown) ||
    error is BeamConnectionException ||
    error is TimeoutException;

/// Maps a failure from the host, transport or core to a
/// [BeamWalletException]. A [BeamWalletException] passes through unchanged.
BeamWalletException beamWalletExceptionFrom(Object error, {String? node}) {
  if (error is BeamWalletException) return error;
  if (error is BeamHostException) {
    return switch (error.kind) {
      BeamHostError.binaryMissing ||
      BeamHostError.unsupportedPlatform => BeamWalletException(
        BeamWalletProblem.coreNotInstalled,
        BeamWalletMessages.coreNotInstalledHere,
      ),
      BeamHostError.binaryUntrusted ||
      BeamHostError.consensusMismatch => BeamWalletException(
        BeamWalletProblem.coreUntrusted,
        BeamWalletMessages.coreUntrustedHere,
      ),
      BeamHostError.wrongPassword => BeamWalletException(
        BeamWalletProblem.wrongPassword,
        BeamWalletMessages.wrongPassword,
      ),
      BeamHostError.walletNotFound => BeamWalletException(
        BeamWalletProblem.walletFileMissing,
        BeamWalletMessages.walletFileMissing,
      ),
      BeamHostError.walletInUse => BeamWalletException(
        BeamWalletProblem.walletInUse,
        BeamWalletMessages.walletInUse,
      ),
      BeamHostError.badNode => BeamWalletException(
        BeamWalletProblem.nodeUnreachable,
        BeamWalletMessages.nodeUnreachable(node),
      ),
      BeamHostError.torNotReady => BeamWalletException(
        BeamWalletProblem.waitingForTor,
        BeamWalletMessages.waitingForTor,
      ),
      BeamHostError.torUnsupported => BeamWalletException(
        BeamWalletProblem.torUnsupported,
        BeamWalletMessages.torUnsupported,
      ),
      BeamHostError.invalidInput => BeamWalletException(
        BeamWalletProblem.other,
        // Host messages never carry a secret (BeamHostException contract).
        error.message,
      ),
      BeamHostError.walletExists ||
      BeamHostError.insecurePath ||
      BeamHostError.notOwnedNode ||
      BeamHostError.timeout ||
      BeamHostError.processFailed => BeamWalletException(
        BeamWalletProblem.other,
        BeamWalletMessages.coreDidNotStart,
      ),
    };
  }
  if (error is BeamConnectionException || error is TimeoutException) {
    return BeamWalletException(
      BeamWalletProblem.notOpen,
      BeamWalletMessages.notOpen,
    );
  }
  if (error is BeamRpcException) {
    return BeamWalletException(
      BeamWalletProblem.other,
      BeamWalletMessages.rpcRefused(error.message),
    );
  }
  // `libBeam.createHost` throws a plain Exception when the BEAM flag is off.
  if ('$error'.contains('BEAM not enabled')) {
    return BeamWalletException(
      BeamWalletProblem.coreNotInstalled,
      BeamWalletMessages.coreNotInstalledHere,
    );
  }
  return BeamWalletException(BeamWalletProblem.other, '$error');
}
