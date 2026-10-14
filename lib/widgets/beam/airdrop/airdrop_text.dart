/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

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
BeamProblem? beamTransportProblem(Object error) => switch (error) {
  BeamConnectionException() || TimeoutException() => const BeamProblem(
    "Couldn't reach the wallet",
    'The wallet did not answer in time. Check your connection, then try '
        'again.',
  ),
  BeamRpcException(:final message) => BeamProblem(
    'The wallet refused this',
    message.isEmpty
        ? 'Nothing was sent. Try again in a moment.'
        : 'Nothing was sent. The wallet said: "$message". Try again in a '
              'moment.',
  ),
  _ => null,
};

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
  static const createTitle = 'Codes work like cash';

  static const createMessageV3 =
      'Anyone who has a code can claim it, so give each code only to its '
      'person. Claiming never shows the code to the network, so nobody '
      'watching can take it. Codes nobody has claimed can be taken back.';

  static const claimMessageV3 =
      'The network never sees this code, so nobody watching can take your '
      'claim. Until the claim is confirmed, anyone else who has the code '
      'could still claim it first, and whoever made it could still take it '
      'back.';

  static const createMessage =
      'Anyone who has a code can claim it. Claiming also shows the code to '
      'the network before it is confirmed, so someone watching could claim '
      'it first. Use codes for small amounts, and give each one to one '
      'person.';

  static const claimMessage =
      'Claiming shows this code to the network before it is confirmed, so '
      'someone watching could claim it first. That is how this airdrop '
      'contract works; codes are meant for small amounts.';
}

/// The airdrop's refusals in plain words.
BeamProblem airdropProblem(Object error) {
  final t = beamTransportProblem(error);
  if (t != null) return t;
  if (error is! BeamAirdropException) {
    return const BeamProblem(
      'Something went wrong on our side',
      'Nothing was sent. Try again; if it keeps happening, restart the '
          'wallet.',
    );
  }
  return switch (error.code) {
    AirdropErrorCode.invalidCode => const BeamProblem(
      "That isn't a voucher code",
      'Codes are 16 letters and digits, like ABCD-EFGH-JKLM-NPQR. Paste '
          'the whole code you were given.',
    ),
    AirdropErrorCode.voucherNotFound => const BeamProblem(
      'No voucher has this code',
      'Check it letter by letter: codes never use I, O, 0 or 1. If it '
          'still fails, ask the sender: the code may have been cancelled.',
    ),
    AirdropErrorCode.alreadyRedeemed => const BeamProblem(
      'This voucher was already claimed',
      'Each code works once. Ask the sender for a new one.',
    ),
    AirdropErrorCode.busy => const BeamProblem(
      'Another airdrop action is still open',
      'Finish or close it, then try again.',
    ),
    AirdropErrorCode.codesNotSaved => const BeamProblem(
      "The codes couldn't be saved on this device",
      'So nothing was sent and nothing was locked. Free up some space or '
          'restart the wallet, then try again.',
    ),
    AirdropErrorCode.unexpectedTransaction => const BeamProblem(
      'Stopped for your safety',
      'The wallet built a different transaction than the one you asked '
          'for, so nothing was sent. Try again; if it repeats, update the '
          'app.',
    ),
    AirdropErrorCode.expired ||
    AirdropErrorCode.alreadyExecuted => const BeamProblem(
      'This confirmation is out of date',
      'Nothing new was sent. Go back and start again.',
    ),
    AirdropErrorCode.walletNotSynced => const BeamProblem(
      'The wallet is still catching up',
      'Try again once it is up to date.',
    ),
    AirdropErrorCode.batchNotFound ||
    AirdropErrorCode.nothingToCancel => const BeamProblem(
      'Nothing left to take back',
      'Every code of this batch was already claimed or cancelled.',
    ),
    AirdropErrorCode.stillHoldsFunds => const BeamProblem(
      'These codes can still unlock funds',
      'So they stay saved. Cancel the unclaimed codes first, or wait until '
          'the batch has settled on the network.',
    ),
    AirdropErrorCode.contractNotFound => const BeamProblem(
      "The airdrop contract didn't answer",
      'The wallet may be on the wrong network. Check the node in Settings.',
    ),
    AirdropErrorCode.paused => const BeamProblem(
      'New codes are paused for now',
      'The airdrop contract is not taking new batches at the moment. Claims '
          'and take-backs still work. Try again later.',
    ),
    AirdropErrorCode.changed => const BeamProblem(
      'Some codes were just claimed',
      'Nothing was sent. The batch has been read again: take back what is '
          'left.',
    ),
    AirdropErrorCode.notBatchCreator => const BeamProblem(
      'Another wallet made this batch',
      'Only the wallet that made a batch can take it back. Nothing was sent.',
    ),
    _ => BeamProblem('The airdrop refused this', error.message),
  };
}

/// Why a new batch's codes failed the check before sharing, in plain words
/// (the screen adds what to do next).
String airdropCheckProblemText(AirdropCheckProblem? p) => switch (p) {
  AirdropCheckProblem.notFound => 'A code is not on the network.',
  AirdropCheckProblem.otherKey =>
    'A code points somewhere other than where this wallet put it.',
  AirdropCheckProblem.otherValue =>
    'A code holds a different amount than this batch locked.',
  AirdropCheckProblem.otherBatch =>
    'A code belongs to a batch other than the one this wallet made.',
  AirdropCheckProblem.notMine =>
    'The codes belong to a batch another wallet made.',
  null => 'A code did not check out.',
};
