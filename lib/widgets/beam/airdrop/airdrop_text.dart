/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';

/// What went wrong, whose fault it is (never the user's) and the one thing
/// that fixes it (no dead ends).
class BeamProblem {
  const BeamProblem(this.title, this.message);

  final String title;
  final String message;
}

/// Problems every contract screen shares: the core or the network.
BeamProblem? beamTransportProblem(Object error) {
  final l = appL10n;
  return switch (error) {
    BeamConnectionException() || TimeoutException() => BeamProblem(
      l.beamProblemNoAnswerTitle,
      l.beamProblemNoAnswerMessage,
    ),
    BeamRpcException(:final message) => BeamProblem(
      l.beamProblemRefusedTitle,
      message.isEmpty
          ? l.beamProblemRefusedMessage
          : l.beamProblemRefusedWithReason(message),
    ),
    _ => null,
  };
}

/// What a voucher code is, said where codes are made and claimed.
///
/// The old Airdrop contract redeems with the code itself (the preimage of
/// the hash it stores), so a claim carries the code in a transaction that
/// the network sees before it is in a block. Anyone watching could take the
/// code and claim the voucher first. Campfire cannot change that contract;
/// it says so where its codes are claimed ([claimMessage]).
///
/// Airdrop v3, where every new code is made, signs a claim with a key made
/// from the code, so the code never reaches the network and a copied claim
/// pays only its claimer. The code itself still works like cash, and its
/// maker can take it back until a claim is confirmed ([createMessageV3],
/// [claimMessageV3]; the web wallet's `BEARER_TEXT_V3`, word for word).
abstract final class AirdropBearerText {
  static String get createTitle => appL10n.airdropBearerCreateTitle;

  static String get createMessageV3 => appL10n.airdropBearerCreateMessageV3;

  static String get claimMessageV3 => appL10n.airdropBearerClaimMessageV3;

  static String get claimMessage => appL10n.airdropBearerClaimMessage;
}

/// The airdrop's refusals in plain words.
BeamProblem airdropProblem(Object error) {
  final t = beamTransportProblem(error);
  if (t != null) return t;
  final l = appL10n;
  if (error is! BeamAirdropException) {
    return BeamProblem(l.beamProblemOurSideTitle, l.beamProblemOurSideMessage);
  }
  return switch (error.code) {
    AirdropErrorCode.invalidCode => BeamProblem(
      l.airdropErrInvalidCodeTitle,
      l.airdropErrInvalidCodeMessage,
    ),
    AirdropErrorCode.voucherNotFound => BeamProblem(
      l.airdropErrNotFoundTitle,
      l.airdropErrNotFoundMessage,
    ),
    AirdropErrorCode.alreadyRedeemed => BeamProblem(
      l.airdropErrAlreadyClaimedTitle,
      l.airdropErrAlreadyClaimedMessage,
    ),
    AirdropErrorCode.busy => BeamProblem(
      l.airdropErrBusyTitle,
      l.airdropErrBusyMessage,
    ),
    AirdropErrorCode.codesNotSaved => BeamProblem(
      l.airdropErrCodesNotSavedTitle,
      l.airdropErrCodesNotSavedMessage,
    ),
    AirdropErrorCode.unexpectedTransaction => BeamProblem(
      l.beamProblemUnexpectedTxTitle,
      l.beamProblemUnexpectedTxMessage,
    ),
    AirdropErrorCode.expired || AirdropErrorCode.alreadyExecuted => BeamProblem(
      l.beamProblemOutOfDateTitle,
      l.beamProblemOutOfDateMessage,
    ),
    AirdropErrorCode.walletNotSynced => BeamProblem(
      l.beamProblemNotSyncedTitle,
      l.beamProblemNotSyncedMessage,
    ),
    AirdropErrorCode.batchNotFound ||
    AirdropErrorCode.nothingToCancel => BeamProblem(
      l.airdropErrNothingToCancelTitle,
      l.airdropErrNothingToCancelMessage,
    ),
    AirdropErrorCode.stillHoldsFunds => BeamProblem(
      l.airdropErrStillHoldsFundsTitle,
      l.airdropErrStillHoldsFundsMessage,
    ),
    AirdropErrorCode.contractNotFound => BeamProblem(
      l.airdropErrContractNotFoundTitle,
      l.airdropErrContractNotFoundMessage,
    ),
    AirdropErrorCode.paused => BeamProblem(
      l.airdropErrPausedTitle,
      l.airdropErrPausedMessage,
    ),
    AirdropErrorCode.changed => BeamProblem(
      l.airdropErrChangedTitle,
      l.airdropErrChangedMessage,
    ),
    AirdropErrorCode.notBatchCreator => BeamProblem(
      l.airdropErrNotBatchCreatorTitle,
      l.airdropErrNotBatchCreatorMessage,
    ),
    AirdropErrorCode.notAcknowledged => BeamProblem(
      l.airdropClaimOldContractTitle,
      l.airdropClaimOldContractMessage,
    ),
    _ => BeamProblem(l.airdropErrRefusedTitle, error.message),
  };
}

/// Why a new batch's codes failed the check before sharing, in plain words
/// (the screen adds what to do next).
String airdropCheckProblemText(AirdropCheckProblem? p) {
  final l = appL10n;
  return switch (p) {
    AirdropCheckProblem.notFound => l.airdropCheckProblemNotFound,
    AirdropCheckProblem.otherKey => l.airdropCheckProblemOtherKey,
    AirdropCheckProblem.otherValue => l.airdropCheckProblemOtherValue,
    AirdropCheckProblem.otherBatch => l.airdropCheckProblemOtherBatch,
    AirdropCheckProblem.notMine => l.airdropCheckProblemNotMine,
    null => l.airdropCheckProblemUnknown,
  };
}
