/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  hand out a batch's codes, and keep a copy of them, once they are
//         safe to share.
//   CTA:  "Copy all codes". Before a new Airdrop v3 batch's codes are
//         checked: "Done" (the screen says what it waits for); if the check
//         fails: "Make new codes".
//   Taps: right after creating a batch (0 taps), or My batches → Show
//         codes (2 from the airdrop menu).
//
// Exit-intent: "where are my codes / are they safe?" → said at the top, with
// a plain warning that they are the only key to the funds and are not in
// the wallet backup; "did it work, can I share them now?" → a new v3 batch
// shows its steps (sent, confirmed by the network n of 3, every code
// checked n of N) and its codes appear only after that; "something went
// wrong" → a failed check says plainly not to share these codes, that the
// funds are safe, and offers new codes and taking the batch back; "how do I
// send them?" → copy one, copy all, share, or export a file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/beam/secret_clipboard.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_batch_status.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/airdrop/voucher_code_input.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/flag_secure_scope.dart';
import '../../../widgets/icon_widgets/copy_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/textfield_icon_button.dart';
import 'beam_airdrop_batches_view.dart';
import 'beam_create_airdrop_view.dart';

/// The codes of one saved batch, read from the wallet's code store.
///
/// An Airdrop v3 batch's codes are shown only once the check before sharing
/// passed (README "Checklist for wallets" 11): until then the screen shows
/// where the batch is, and asks the network again every [checkEvery].
class BeamAirdropCodesView extends StatefulWidget {
  const BeamAirdropCodesView({
    super.key,
    required this.service,
    required this.localId,
    this.assetNames,
    this.justCreated = false,
    this.notice,
    this.sync,
    this.authorize = campfireAuthorizeSpend,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamAirdropCodes';

  /// How often a v3 batch that waits for confirmations is asked about.
  static const checkEvery = Duration(seconds: 10);

  final BeamAirdrops service;

  /// [AirdropSavedBatch.localId] of the batch to show.
  final String localId;
  final BeamAssetNames? assetNames;

  /// Opened right after the batch was sent.
  final bool justCreated;

  /// Shown above the codes, e.g. when sending could not be confirmed.
  final BeamProblem? notice;

  /// For "Make new codes" and "Take the batch back" after a failed check;
  /// without it those offer only the way back.
  final ValueListenable<BeamSyncAssessment>? sync;
  final BeamSpendAuthorizer authorize;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;

  @override
  State<BeamAirdropCodesView> createState() => _BeamAirdropCodesViewState();
}

class _BeamAirdropCodesViewState extends State<BeamAirdropCodesView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  AirdropSavedBatch? _batch;
  BeamProblem? _problem;
  bool _loading = true;

  // A v3 batch: where its check stands.
  AirdropV3Verdict? _verdict;
  bool _checking = false;
  int? _checked;
  int? _toCheck;
  BeamProblem? _checkError;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    unawaited(_load());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wait?.cancel();
    _names.removeListener(_rebuild);
    super.dispose();
  }

  bool get _v3NotReady {
    final b = _batch;
    return b != null && b.isV3 && _verdict?.state != AirdropV3BatchState.ready;
  }

  /// Where a v3 batch stands; asks again while the network has not
  /// confirmed it enough.
  Future<void> _runCheck() async {
    _wait?.cancel();
    final b = _batch;
    if (!mounted || b == null || !b.isV3 || _checking) return;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final v = await widget.service.verifyBatch(
        b.localId,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _checked = done;
            _toCheck = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _batch = v.batch;
        _verdict = v;
        if (v.state == AirdropV3BatchState.waiting) {
          _checked = null;
          _toCheck = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkError = airdropProblem(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (mounted &&
        _checkError == null &&
        _verdict?.state == AirdropV3BatchState.waiting) {
      _wait = Timer(BeamAirdropCodesView.checkEvery, _runCheck);
    }
  }

  Future<void> _load() async {
    try {
      final all = await widget.service.savedBatches();
      final found = all.where((b) => b.localId == widget.localId);
      if (!mounted) return;
      setState(() {
        _batch = found.isEmpty ? null : found.single;
        _loading = false;
        if (found.isEmpty) {
          _problem = const BeamProblem(
            "These codes aren't on this device",
            'They may have been saved by another device or app. Open My '
                'batches to see what this wallet has.',
          );
        }
      });
      if (found.isNotEmpty) unawaited(_names.preload([found.single.assetId]));
      if (found.isNotEmpty && found.single.isV3) unawaited(_runCheck());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _problem = const BeamProblem(
          "Couldn't open the saved codes",
          'The secure storage on this device did not answer. Close this '
              'screen and open it again; the codes are not lost.',
        );
      });
    }
  }

  Future<void> _copy(String text, String what) async {
    // A code is a bearer claim on locked funds (issue #76): on desktop it
    // leaves the clipboard a minute later if it is still there.
    final clears = await SecretClipboard.copy(
      text,
      clipboard: widget.clipboard,
    );
    if (!mounted) return;
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.info,
        message: clears
            ? '$what copied. It leaves the clipboard in a minute.'
            : '$what copied',
        context: context,
      ),
    );
  }

  String get _allCodes => _batch!.codes.map((c) => c.code).join('\n');

  Future<void> _export() async {
    final b = _batch!;
    final csv = AirdropCsv.export(
      b,
      formatValue: BeamUnits.format,
      assetLabel: _names.symbol(b.assetId),
    );
    final day = b.createdAt.toIso8601String().substring(0, 10);
    try {
      final where = await widget.exporter.saveCsv(
        context,
        fileName: 'airdrop-codes-$day-${b.count}.csv',
        csv: csv,
      );
      if (where == null || !mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.success,
          message: 'Codes exported',
          context: context,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: "Couldn't export the file. Try Copy all codes instead.",
          context: context,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _batch;
    if (b != null && _v3NotReady) {
      return BeamPageScaffold(
        title: widget.justCreated ? 'Your airdrop codes' : 'Airdrop codes',
        body: _notReady(context, b),
        bottom: _notReadyCta(context, b),
      );
    }
    return BeamPageScaffold(
      title: widget.justCreated ? 'Your airdrop codes' : 'Airdrop codes',
      body: _loading
          ? const BeamWorking('Opening your saved codes…')
          : b == null
          ? BeamNotice(
              kind: BeamNoticeKind.danger,
              title: _problem!.title,
              message: _problem!.message,
            )
          // No screenshots or recents thumbnail of the codes (issue #76).
          : FlagSecureScope(child: _codes(context, b)),
      bottom: b == null
          ? BeamCtaBar(
              label: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : BeamCtaBar(
              primaryKey: const ValueKey('codes-copy-all'),
              label: 'Copy all codes',
              onPressed: () => _copy(_allCodes, 'All ${b.count} codes'),
            ),
    );
  }

  // ------------------------------------------------------- v3, not ready

  static const _takeBackText =
      'take this batch back in My batches to get them back,';

  static bool _prepaid(AirdropSavedBatch b) =>
      (b.gasPerVoucher ?? BigInt.zero) > BigInt.zero;

  String _summaryLine(AirdropSavedBatch b) {
    final same = b.codes.every((c) => c.value == b.codes.first.value);
    final n = b.count == 1 ? '1 code' : '${b.count} codes';
    return same
        ? '$n · ${_names.amount(b.assetId, b.codes.first.value)} each'
        : '$n · ${_names.amount(b.assetId, b.total)} in total';
  }

  Widget _title(AirdropSavedBatch b) => RoundedWhiteContainer(
    child: BeamAssetTitle(
      display: _names.display(b.assetId),
      subtitle: _summaryLine(b),
    ),
  );

  Widget _notReady(BuildContext context, AirdropSavedBatch b) {
    final v = _verdict;
    if (v?.state == AirdropV3BatchState.failed) {
      final mined = v!.mined;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(b),
          const BeamGap(),
          BeamNotice(
            key: const ValueKey('codes-check-failed'),
            kind: BeamNoticeKind.danger,
            title: 'Do not share these codes',
            message:
                '${airdropCheckProblemText(v.problem)} Someone may have '
                'copied this batch while it was on its way, so the codes '
                'could point to empty vouchers. Your funds are safe: '
                '${mined ? _takeBackText : 'nothing more was locked,'} '
                'and make new codes.',
          ),
        ],
      );
    }
    if (v?.state == AirdropV3BatchState.notSent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(b),
          const BeamGap(),
          BeamNotice(
            key: const ValueKey('codes-not-sent'),
            kind: BeamNoticeKind.info,
            title: 'This batch did not go through',
            message: v!.onChain
                ? 'The network turned it down, so nothing was locked and '
                      'these codes hold nothing. Do not use them: make new '
                      'codes.'
                : 'It was never sent, so nothing was locked and these codes '
                      'hold nothing. They stay saved here anyway.',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.justCreated && widget.notice == null) ...[
          const BeamNotice(
            key: ValueKey('codes-sent'),
            kind: BeamNoticeKind.success,
            title: 'Batch sent',
            message: 'Wait a few minutes before sharing the codes.',
          ),
          const BeamGap(),
        ],
        if (widget.notice != null) ...[
          BeamNotice(
            key: const ValueKey('codes-notice'),
            kind: BeamNoticeKind.warning,
            title: widget.notice!.title,
            message: widget.notice!.message,
          ),
          const BeamGap(),
        ],
        _title(b),
        const BeamGap(),
        _steps(context),
        const BeamGap(),
        Text(
          'Before you share them, Campfire makes sure every code points to '
          'the batch you made, so nobody can swap them for empty ones. The '
          'codes appear here once that is done. You can leave this screen '
          'and come back.',
          key: const ValueKey('codes-wait-why'),
          style: STextStyles.label(context),
        ),
        if (_checkError != null) ...[
          const BeamGap(),
          BeamNotice(
            key: const ValueKey('codes-check-error'),
            kind: BeamNoticeKind.danger,
            title: "The codes couldn't be checked",
            message: '${_checkError!.message} They are saved on this device.',
            actionLabel: 'Check again',
            onAction: _runCheck,
          ),
        ],
      ],
    );
  }

  /// Sent → confirmed by the network (n of 3) → every code checked (n of N).
  Widget _steps(BuildContext context) {
    final checking = _toCheck != null;
    final failedAt = _checkError == null ? null : (checking ? 2 : 1);
    final c = _verdict?.confirmations;
    const need = kAirdropV3ConfirmationsBeforeCheck;
    final rows = <({_StepMark mark, String label, String? note})>[
      (mark: _StepMark.done, label: 'Batch sent', note: null),
      (
        mark: checking
            ? _StepMark.done
            : failedAt == 1
            ? _StepMark.failed
            : _StepMark.active,
        label: 'Confirmed by the network',
        note: checking
            ? null
            : c == null
            ? 'waiting'
            : '${math.min(c, need)} of $need',
      ),
      (
        mark: failedAt == 2
            ? _StepMark.failed
            : checking
            ? _StepMark.active
            : _StepMark.waiting,
        label: 'Every code checked',
        note: checking ? '${_checked ?? 0} of $_toCheck' : null,
      ),
    ];
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      key: const ValueKey('codes-steps'),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                key: ValueKey('codes-step-$i'),
                children: [
                  Icon(
                    switch (rows[i].mark) {
                      _StepMark.done => Icons.check_circle_rounded,
                      _StepMark.active => Icons.schedule_rounded,
                      _StepMark.waiting => Icons.radio_button_unchecked,
                      _StepMark.failed => Icons.cancel_rounded,
                    },
                    size: 20,
                    color: switch (rows[i].mark) {
                      _StepMark.done => colors.accentColorGreen,
                      _StepMark.active => colors.accentColorBlue,
                      _StepMark.waiting => colors.textSubtitle2,
                      _StepMark.failed => colors.accentColorRed,
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rows[i].label,
                      style: STextStyles.itemSubtitle12(context),
                    ),
                  ),
                  if (rows[i].note != null)
                    Text(
                      rows[i].note!,
                      key: ValueKey('codes-step-$i-note'),
                      style: STextStyles.label(context),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _notReadyCta(BuildContext context, AirdropSavedBatch b) {
    final state = _verdict?.state;
    final failed = state == AirdropV3BatchState.failed;
    if (failed || state == AirdropV3BatchState.notSent) {
      final canAct = widget.sync != null;
      final mined = failed && _verdict!.mined;
      return BeamCtaBar(
        primaryKey: const ValueKey('codes-make-new'),
        label: 'Make new codes',
        onPressed: canAct ? () => _makeNew(b) : null,
        secondaryLabel: mined && canAct ? 'Take the batch back' : 'My batches',
        onSecondary: _toBatches,
      );
    }
    return BeamCtaBar(
      primaryKey: const ValueKey('codes-done'),
      label: 'Done',
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }

  /// New codes for the same airdrop: same asset, amount per code, count and
  /// prepaid claim fees.
  void _makeNew(AirdropSavedBatch b) {
    final sync = widget.sync;
    if (sync == null) return;
    final same = b.codes.every((c) => c.value == b.codes.first.value);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BeamCreateAirdropView(
            service: widget.service,
            sync: sync,
            assetNames: _names,
            authorize: widget.authorize,
            initialAssetId: b.assetId,
            initialValue: same ? b.codes.first.value : null,
            initialCount: b.count,
            initialPrepayClaimFees: _prepaid(b),
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  /// My batches: back to it when it opened this screen, else in place of
  /// this one.
  void _toBatches() {
    final sync = widget.sync;
    if (!widget.justCreated || sync == null) {
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BeamAirdropBatchesView(
            service: widget.service,
            sync: sync,
            assetNames: _names,
            authorize: widget.authorize,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ the codes

  Widget _codes(BuildContext context, AirdropSavedBatch b) {
    final same = b.codes.every((c) => c.value == b.codes.first.value);
    final status = airdropBatchStatus(b, null);
    final desktop = BeamLayoutScope.isDesktop(context);
    final ready = b.isV3 && _verdict?.state == AirdropV3BatchState.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ready) ...[
          BeamNotice(
            key: const ValueKey('codes-ready'),
            kind: BeamNoticeKind.success,
            title: 'Ready to share',
            message:
                'Every code is on the network in your batch'
                '${_prepaid(b) ? ', with its claim fee paid' : ''}.',
          ),
          const BeamGap(),
        ] else if (widget.justCreated && widget.notice == null) ...[
          const Row(
            children: [
              BeamAnimatedStickerView(BeamMoments.walletCreated, size: 72),
              SizedBox(width: 8),
              Expanded(
                child: BeamNotice(
                  key: ValueKey('codes-sent'),
                  kind: BeamNoticeKind.success,
                  title: 'Batch sent',
                  message:
                      'The codes start working once the network confirms it, '
                      'usually within a few minutes.',
                ),
              ),
            ],
          ),
          const BeamGap(),
        ],
        if (widget.notice != null && !ready) ...[
          BeamNotice(
            key: const ValueKey('codes-notice'),
            kind: BeamNoticeKind.warning,
            title: widget.notice!.title,
            message: widget.notice!.message,
          ),
          const BeamGap(),
        ],
        RoundedWhiteContainer(
          child: BeamAssetTitle(
            display: _names.display(b.assetId),
            subtitle: same
                ? '${b.count} codes · '
                      '${_names.amount(b.assetId, b.codes.first.value)} each'
                : '${b.count} codes · '
                      '${_names.amount(b.assetId, b.total)} in total',
            trailing: widget.justCreated
                ? null
                : BeamPill(text: status.text, kind: status.kind),
          ),
        ),
        const BeamGap(),
        const BeamNotice(
          key: ValueKey('codes-key-warning'),
          kind: BeamNoticeKind.warning,
          title: 'These codes are the only key to the locked funds',
          message:
              'Anyone who has a code can claim it, so send each one only to '
              'its recipient. They are saved on this device but not in your '
              'wallet backup: export a copy to keep them safe.',
        ),
        const BeamGap(8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CustomTextButton(
              key: const ValueKey('codes-export'),
              text: 'Export file',
              onTap: _export,
            ),
            if (!desktop) ...[
              const SizedBox(width: 16),
              CustomTextButton(
                key: const ValueKey('codes-share'),
                text: 'Share',
                onTap: () => widget.exporter.shareText(context, _allCodes),
              ),
            ],
          ],
        ),
        const BeamGap(8),
        for (var i = 0; i < b.codes.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _codeRow(context, b, i),
          ),
      ],
    );
  }

  Widget _codeRow(BuildContext context, AirdropSavedBatch b, int i) {
    final c = b.codes[i];
    final st = airdropCodeStatus(c, b.txStatus);
    return RoundedWhiteContainer(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${i + 1}', style: STextStyles.label(context)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  c.code,
                  key: ValueKey('code-$i'),
                  style: voucherCodeStyle(context, size: 15),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _names.amount(b.assetId, c.value),
                        style: STextStyles.label(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!widget.justCreated) ...[
                      const SizedBox(width: 8),
                      BeamPill(text: st.text, kind: st.kind),
                    ],
                  ],
                ),
              ],
            ),
          ),
          TextFieldIconButton(
            key: ValueKey('code-copy-$i'),
            semanticsLabel: 'Copy code',
            onTap: () => _copy(c.code, 'Code'),
            child: const CopyIcon(),
          ),
        ],
      ),
    );
  }
}

enum _StepMark { done, active, waiting, failed }
