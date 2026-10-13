/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  hand out a batch's codes, and keep a copy of them.
//   CTA:  "Copy all codes".
//   Taps: right after creating a batch (0 taps), or My batches → Show
//         codes (2 from the airdrop menu).
//
// Exit-intent: "where are my codes / are they safe?" → they are on
// screen at once, with a plain warning that they are the only key to the
// funds and are not in the wallet backup; "how do I send them?" → copy one,
// copy all, share, or export a file; "did the batch work?" → the status
// line says whether the network has it yet.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../utilities/beam/secret_clipboard.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../widgets/beam/airdrop/airdrop_batch_status.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/airdrop/voucher_code_input.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/flag_secure_scope.dart';
import '../../../widgets/icon_widgets/copy_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/textfield_icon_button.dart';

/// The codes of one saved batch, read from the wallet's code store.
class BeamAirdropCodesView extends StatefulWidget {
  const BeamAirdropCodesView({
    super.key,
    required this.service,
    required this.localId,
    this.assetNames,
    this.justCreated = false,
    this.notice,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamAirdropCodes';

  final BeamAirdropService service;

  /// [AirdropSavedBatch.localId] of the batch to show.
  final String localId;
  final BeamAssetNames? assetNames;

  /// Opened right after the batch was sent.
  final bool justCreated;

  /// Shown above the codes, e.g. when sending could not be confirmed.
  final BeamProblem? notice;
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
    _names.removeListener(_rebuild);
    super.dispose();
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
          _problem = BeamProblem(
            context.l10n.airdropCodesNotOnDeviceTitle,
            context.l10n.airdropCodesNotOnDeviceMessage,
          );
        }
      });
      if (found.isNotEmpty) unawaited(_names.preload([found.single.assetId]));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _problem = BeamProblem(
          context.l10n.airdropCodesCantOpenTitle,
          context.l10n.airdropCodesCantOpenMessage,
        );
      });
    }
  }

  /// [copied] says what was copied; [copiedClears] says the same and that
  /// it leaves the clipboard in a minute.
  Future<void> _copy(
    String text, {
    required String copied,
    required String copiedClears,
  }) async {
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
        message: clears ? copiedClears : copied,
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
          message: context.l10n.airdropCodesExported,
          context: context,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: context.l10n.airdropCodesExportFailed,
          context: context,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _batch;
    final l10n = context.l10n;
    return BeamPageScaffold(
      title: widget.justCreated
          ? l10n.airdropCodesTitleNew
          : l10n.airdropCodesTitle,
      body: _loading
          ? BeamWorking(l10n.airdropCodesOpening)
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
              label: l10n.commonBack,
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : BeamCtaBar(
              primaryKey: const ValueKey('codes-copy-all'),
              label: l10n.airdropCodesCopyAll,
              onPressed: () => _copy(
                _allCodes,
                copied: l10n.airdropCodesAllCopied(b.count),
                copiedClears: l10n.airdropCodesAllCopiedClears(b.count),
              ),
            ),
    );
  }

  Widget _codes(BuildContext context, AirdropSavedBatch b) {
    final same = b.codes.every((c) => c.value == b.codes.first.value);
    final status = airdropBatchStatus(b, null);
    final desktop = BeamLayoutScope.isDesktop(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.justCreated && widget.notice == null) ...[
          Row(
            children: [
              const BeamAnimatedStickerView(
                BeamMoments.walletCreated,
                size: 72,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BeamNotice(
                  key: const ValueKey('codes-sent'),
                  kind: BeamNoticeKind.success,
                  title: l10n.airdropCodesBatchSentTitle,
                  message: l10n.airdropCodesBatchSentMessage,
                ),
              ),
            ],
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
        RoundedWhiteContainer(
          child: BeamAssetTitle(
            display: _names.display(b.assetId),
            subtitle: same
                ? l10n.airdropCodesCountEach(
                    b.count,
                    _names.amount(b.assetId, b.codes.first.value),
                  )
                : l10n.airdropCodesCountTotal(
                    b.count,
                    _names.amount(b.assetId, b.total),
                  ),
            trailing: widget.justCreated
                ? null
                : BeamPill(text: status.text, kind: status.kind),
          ),
        ),
        const BeamGap(),
        BeamNotice(
          key: const ValueKey('codes-key-warning'),
          kind: BeamNoticeKind.warning,
          title: l10n.airdropCodesKeyWarningTitle,
          message: l10n.airdropCodesKeyWarningMessage,
        ),
        const BeamGap(8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CustomTextButton(
              key: const ValueKey('codes-export'),
              text: l10n.airdropCodesExport,
              onTap: _export,
            ),
            if (!desktop) ...[
              const SizedBox(width: 16),
              CustomTextButton(
                key: const ValueKey('codes-share'),
                text: l10n.airdropCodesShare,
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
            semanticsLabel: context.l10n.airdropCodeCopyLabel,
            onTap: () => _copy(
              c.code,
              copied: context.l10n.airdropCodeCopied,
              copiedClears: context.l10n.airdropCodeCopiedClears,
            ),
            child: const CopyIcon(),
          ),
        ],
      ),
    );
  }
}
