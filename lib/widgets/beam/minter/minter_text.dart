/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/contracts/burn/burn.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
import '../airdrop/airdrop_text.dart';

/// The Minter's and the BlackHole's refusals in plain words: what happened,
/// never the user's fault, and the next step.
BeamProblem minterProblem(Object error) {
  final t = beamTransportProblem(error);
  if (t != null) return t;
  if (error is BeamBurnException) return _burn(error);
  final l = appL10n;
  if (error is! BeamMinterException) {
    return BeamProblem(l.beamProblemOurSideTitle, l.beamProblemOurSideMessage);
  }
  return switch (error.code) {
    MinterErrorCode.busy => BeamProblem(
      l.minterErrBusyTitle,
      l.minterErrBusyMessage,
    ),
    MinterErrorCode.noSuchToken => BeamProblem(
      l.minterErrNoSuchTokenTitle,
      l.minterErrNoSuchTokenMessage,
    ),
    MinterErrorCode.notOwner => BeamProblem(
      l.minterErrNotOwnerTitle,
      l.minterErrNotOwnerMessage,
    ),
    MinterErrorCode.aboveLimit => BeamProblem(
      l.minterErrAboveLimitTitle,
      joinSentences([error.message, l.minterErrLowerAmount], l),
    ),
    MinterErrorCode.unexpectedTransaction => BeamProblem(
      l.beamProblemUnexpectedTxTitle,
      l.beamProblemUnexpectedTxMessage,
    ),
    MinterErrorCode.expired || MinterErrorCode.alreadyExecuted => BeamProblem(
      l.beamProblemOutOfDateTitle,
      l.beamProblemOutOfDateMessage,
    ),
    MinterErrorCode.noSuchContract => BeamProblem(
      l.minterErrNoContractTitle,
      l.minterErrNoContractMessage,
    ),
    MinterErrorCode.shaderError => BeamProblem(
      l.minterErrRefusedTitle,
      l.minterErrRefusedWithReason(error.message),
    ),
  };
}

BeamProblem _burn(BeamBurnException error) {
  final l = appL10n;
  return switch (error.code) {
    BurnErrorCode.busy => BeamProblem(
      l.minterBurnErrBusyTitle,
      l.minterErrBusyMessage,
    ),
    BurnErrorCode.notAcknowledged => BeamProblem(
      l.minterBurnErrNotAckTitle,
      l.minterBurnErrNotAckMessage,
    ),
    BurnErrorCode.unexpectedTransaction => BeamProblem(
      l.beamProblemUnexpectedTxTitle,
      l.minterBurnErrUnexpectedTxMessage,
    ),
    BurnErrorCode.expired || BurnErrorCode.alreadyExecuted => BeamProblem(
      l.beamProblemOutOfDateTitle,
      l.minterBurnErrOutOfDateMessage,
    ),
    BurnErrorCode.shaderError => BeamProblem(
      l.minterBurnErrRefusedTitle,
      l.minterBurnErrRefusedWithReason(error.message),
    ),
  };
}
