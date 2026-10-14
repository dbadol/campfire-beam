/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  show exactly what a prepared airdrop batch (or cancel) will do,
//         from the transaction the core built, and send it after the PIN.
//   CTA:  "Create <n> codes" / "Get back <amount>".
//   Taps: reached from the create form or My batches; 1 tap + PIN here.
//
// Exit-intent: "how much does this really cost?" → every amount and
// the network fee are read back from the built transaction; "what if I
// lose the codes?" → said before confirming; "did it work?" → the next
// screen says so, and says plainly when it could not be confirmed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/rounded_white_container.dart';

/// What [BeamAirdropConfirmView] pops with once the transaction left this
/// screen: its id, or, when sending could not be confirmed (a timeout),
/// no id and a [problem] to show next to the codes, which are saved
/// either way.
@immutable
class BeamAirdropSent {
  const BeamAirdropSent({this.txId, this.problem});

  final String? txId;
  final BeamProblem? problem;
}

/// Confirms a prepared `create_batch` or `cancel_batch`.
///
/// Leaving without sending discards [prepared], which releases [service].
class BeamAirdropConfirmView extends StatefulWidget {
  const BeamAirdropConfirmView({
    super.key,
    required this.service,
    required this.prepared,
    required this.sync,
    required this.assetNames,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamAirdrops service;
  final AirdropPreparedCall prepared;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames assetNames;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamAirdropConfirmView> createState() => _BeamAirdropConfirmViewState();
}

class _BeamAirdropConfirmViewState extends State<BeamAirdropConfirmView>
    with BeamSendFlow {
  BigInt? _beamAvailable;

  AirdropSummary get _s => widget.prepared.summary;
  bool get _create => widget.prepared.action == AirdropAction.createBatch;
  BeamAssetNames get _names => widget.assetNames;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBalance());
  }

  Future<void> _loadBalance() async {
    try {
      final b = await beamAvailableBalances(widget.service.api);
      if (mounted) setState(() => _beamAvailable = b[0]);
    } catch (_) {
      // Unknown: the core refuses an unaffordable transaction anyway.
    }
  }

  @override
  void dispose() {
    final p = widget.prepared;
    if (!p.isExecuted) widget.service.discard(p);
    super.dispose();
  }

  BigInt get _beamNeeded => _s.beamNeeded;

  String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');
  String _amount(BigInt units) => _names.amount(_s.assetId, units);

  Future<void> _confirm() async {
    final p = widget.prepared;
    Object? failure;
    final tx = await runSend(
      authorize: widget.authorize,
      reason: _create
          ? context.l10n.airdropConfirmAuthCreate
          : context.l10n.airdropConfirmAuthTakeBack,
      send: () => widget.service.execute(p),
      explain: (e) {
        failure = e;
        return airdropProblem(e);
      },
    );
    if (!mounted) return;
    if (tx != null) {
      Navigator.of(context).pop(BeamAirdropSent(txId: tx));
      return;
    }
    // The core refused it, or the service stopped it before sending
    // (codes not saved): nothing left the wallet, so stay and say why.
    final f = failure;
    final refused = f is BeamRpcException || f is BeamAirdropException;
    if (_create && p.isExecuted && f != null && !refused) {
      // Sent, but no answer: the batch may still go through, and its
      // codes are saved. Show them, with the warning.
      Navigator.of(context).pop(
        BeamAirdropSent(
          problem: BeamProblem(
            context.l10n.airdropConfirmNotConfirmedTitle,
            context.l10n.airdropConfirmNotConfirmedMessage,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final spent = widget.prepared.isExecuted;
      final short = _beamAvailable != null && _beamAvailable! < _beamNeeded;
      final l10n = context.l10n;
      return BeamPageScaffold(
        title: _create
            ? l10n.airdropConfirmCreateTitle
            : l10n.airdropConfirmTakeBackTitle,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RoundedWhiteContainer(
              child: BeamAssetTitle(
                display: _names.display(_s.assetId),
                subtitle: _create
                    ? l10n.airdropConfirmNewCodes
                    : l10n.airdropConfirmBatchUnclaimed('${_s.batchId}'),
              ),
            ),
            const BeamGap(8),
            if (_create) ..._createRows() else ..._cancelRows(),
            if (short) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('confirm-short-of-beam'),
                kind: BeamNoticeKind.danger,
                title: l10n.airdropNotEnoughBeamTitle,
                message: l10n.airdropConfirmNotEnoughBeamMessage(
                  _beam(_beamNeeded),
                  _beam(_beamAvailable!),
                ),
              ),
            ],
            if (problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('confirm-problem'),
                kind: BeamNoticeKind.danger,
                title: problem!.title,
                message: problem!.message,
              ),
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamSyncNotice(
              sync: sync,
              action: _create
                  ? BeamPausedAction.creatingCodes
                  : BeamPausedAction.takingBack,
            ),
            if (spent && problem != null)
              BeamCtaBar(
                label: l10n.commonBack,
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              BeamCtaBar(
                primaryKey: const ValueKey('airdrop-confirm-cta'),
                label: _create
                    ? l10n.airdropCreateCodesCta(_s.voucherCount!)
                    : l10n.airdropConfirmGetBackCta(_backText()),
                busy: sending,
                busyLabel: l10n.airdropSending,
                onPressed: sync.canSpend && !short ? _confirm : null,
              ),
          ],
        ),
      );
    },
  );

  List<Widget> _createRows() {
    final values = _s.voucherValues!;
    final same = values.every((v) => v == values.first);
    final locked = values.fold(BigInt.zero, (a, v) => a + v);
    final isBeam = _s.assetId == 0;
    final l10n = context.l10n;
    return [
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: l10n.airdropEachCodeGives,
            value: same
                ? _amount(values.first)
                : l10n.airdropConfirmDifferentAmounts,
          ),
          BeamDetailRow(
            label: l10n.airdropNumberOfCodes,
            value: '${_s.voucherCount}',
          ),
          BeamDetailRow(
            label: l10n.airdropLockedForCodes,
            value: _amount(locked),
            valueKey: const ValueKey('confirm-locked'),
          ),
          BeamDetailRow(
            label: l10n.airdropFeeLabel,
            value: _amount(_s.creationFee!),
            detail: l10n.airdropConfirmFeeKept,
            valueKey: const ValueKey('confirm-creation-fee'),
          ),
          if (_s.claimFees > BigInt.zero)
            BeamDetailRow(
              label: l10n.airdropConfirmClaimFeesLabel,
              value: _beam(_s.claimFees),
              detail:
                  '${_s.voucherCount} × '
                  '${_beam(_s.gasPerVoucher ?? BigInt.zero)}',
              valueKey: const ValueKey('confirm-gas'),
            ),
          BeamDetailRow(
            label: l10n.beamNetworkFee,
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('confirm-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: l10n.airdropLeavesWallet,
        value: isBeam
            ? _beam(_s.beamOut)
            : '${_amount(_s.pays[_s.assetId]!)} + ${_beam(_s.beamOut)}',
        valueKey: const ValueKey('confirm-total'),
      ),
      const BeamGap(),
      BeamNotice(
        kind: BeamNoticeKind.warning,
        title: l10n.airdropConfirmOnlyKeyTitle,
        message: l10n.airdropConfirmOnlyKeyMessage,
      ),
      const BeamGap(8),
      BeamNotice(
        key: const ValueKey('confirm-share-note'),
        kind: BeamNoticeKind.info,
        message: _s.contract != AirdropContract.v3
            ? l10n.airdropConfirmCancelLater
            : _s.claimFees > BigInt.zero
            ? l10n.airdropConfirmShareAfterCheckWithFees
            : l10n.airdropConfirmShareAfterCheck,
      ),
    ];
  }

  /// What a take-back returns: the codes' value, and their prepaid claim
  /// fees when the batch had them.
  String _backText() {
    final value = _amount(_s.assetAmount);
    if (_s.assetId == 0) return _beam(_s.receives[0] ?? BigInt.zero);
    return _s.claimFees > BigInt.zero
        ? '$value + ${_beam(_s.claimFees)}'
        : value;
  }

  List<Widget> _cancelRows() {
    final isBeam = _s.assetId == 0;
    final net = _s.beamChange;
    String beamLine(BigInt v) => '${v.isNegative ? '−' : '+'}${_beam(v.abs())}';
    final l10n = context.l10n;
    return [
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: l10n.airdropConfirmCodesStop,
            value: '${_s.voucherCount}',
          ),
          BeamDetailRow(
            label: l10n.airdropConfirmComesBack,
            value: _backText(),
            detail: _s.claimFees > BigInt.zero
                ? l10n.airdropConfirmWithClaimFees
                : null,
            valueKey: const ValueKey('confirm-returned'),
          ),
          BeamDetailRow(
            label: l10n.beamNetworkFee,
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('confirm-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: l10n.airdropBalanceChangesBy,
        value: isBeam
            ? beamLine(net)
            : '+${_amount(_s.assetAmount)}, ${beamLine(net)}',
        valueKey: const ValueKey('confirm-total'),
      ),
      const BeamGap(),
      BeamNotice(
        kind: BeamNoticeKind.warning,
        message: l10n.airdropConfirmCancelWarning(_s.voucherCount!),
      ),
    ];
  }
}
