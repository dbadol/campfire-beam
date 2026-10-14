/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/beam/tx/beam_tx_actions.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_white_container.dart';
import '../../stack_dialog.dart';
import '../../stack_text_field.dart';
import 'beam_tx_backend.dart';
import 'beam_tx_text.dart';

/// Campfire's two-button dialog. Returns true when the user confirmed.
///
/// [destructive] gives the confirm button Campfire's delete style, so a
/// money-affecting choice never looks like the safe one.
Future<bool> showBeamConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  required String keep,
  required bool isDesktop,
  bool destructive = false,
}) async {
  final colors = Theme.of(context).extension<StackColors>()!;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      width: isDesktop ? 460 : null,
      title: title,
      message: message,
      leftButton: TextButton(
        key: const Key('beamTxConfirmKeep'),
        style: colors.getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          keep,
          textAlign: TextAlign.center,
          style: STextStyles.button(context)
              .copyWith(color: colors.accentColorDark),
        ),
      ),
      rightButton: TextButton(
        key: const Key('beamTxConfirmYes'),
        style: destructive
            ? colors.getDeleteEnabledButtonStyle(context)
            : colors.getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(
          confirm,
          textAlign: TextAlign.center,
          style: destructive
              ? STextStyles.button(context)
                    .copyWith(color: colors.accentColorRed)
              : STextStyles.button(context),
        ),
      ),
    ),
  );
  return ok ?? false;
}

/// A one-button notice: what happened and, where there is one, what to do.
Future<void> showBeamNotice(
  BuildContext context, {
  required String title,
  String? message,
  required bool isDesktop,
}) => showDialog<void>(
  context: context,
  builder: (_) => StackOkDialog(
    title: title,
    message: message,
    maxWidth: isDesktop ? 400 : null,
  ),
);

/// Campfire's block-explorer privacy warning, then the explorer.
Future<void> openBeamExplorer(
  BuildContext context, {
  required BeamTxBackend backend,
  required String kernelId,
  required bool isDesktop,
}) async {
  final uri = backend.explorerUri(kernelId);
  if (!backend.skipExplorerWarning()) {
    final l10n = context.l10n;
    final go = await showBeamConfirm(
      context,
      title: l10n.txExplorerWarningTitle,
      message: l10n.txExplorerWarning('${uri.scheme}://${uri.host}'),
      confirm: l10n.commonContinue,
      keep: l10n.commonCancel,
      isDesktop: isDesktop,
    );
    if (!go) return;
  }
  var opened = false;
  try {
    opened = await backend.openUrl(uri);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    await showBeamNotice(
      context,
      title: context.l10n.txExplorerOpenFailedTitle,
      message: context.l10n.txExplorerOpenFailed('$uri'),
      isDesktop: isDesktop,
    );
  }
}

/// Copies [text] and says so, the way Campfire's copy buttons do: with
/// [message], or "Copied to clipboard" when it is null.
Future<void> copyWithToast(
  BuildContext context,
  String text, {
  String? message,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.info,
        message: message ?? context.l10n.txCopiedToClipboard,
        context: context,
      ),
    );
  }
}

/// The dialog frame both proof dialogs use: Campfire's mobile dialog, or a
/// fixed-width card on desktop.
class _ProofFrame extends StatelessWidget {
  const _ProofFrame({required this.isDesktop, required this.child});

  final bool isDesktop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StackDialogBase(
      width: isDesktop ? 520 : null,
      child: SingleChildScrollView(child: child),
    );
  }
}

// Spec — payment proof (export):
//   Job:  give the payer something the receiver can check.
//   CTA:  "Copy proof".
//   Taps: entry → Get payment proof → Copy proof (from the details: 2).
// Exit-intent: "What am I handing over?" → the dialog says exactly what a
// proof shows (amount, both addresses, the transaction ID) and nothing else.

/// Shows a payment proof the core exported, with copy (and share on
/// phones).
class BeamProofExportDialog extends ConsumerWidget {
  const BeamProofExportDialog({
    super.key,
    required this.walletId,
    required this.proof,
  });

  final String walletId;
  final String proof;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = ref.watch(pBeamTxIsDesktop);
    final backend = ref.watch(pBeamTxBackend(walletId));
    final l10n = context.l10n;
    return _ProofFrame(
      isDesktop: isDesktop,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.txPaymentProof, style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 8),
          Text(
            l10n.txProofExportExplain,
            style: STextStyles.smallMed14(context),
          ),
          const SizedBox(height: 16),
          RoundedWhiteContainer(
            borderColor: Theme.of(context)
                .extension<StackColors>()!
                .backgroundAppBar,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              BeamTxText.short(proof, head: 24, tail: 24),
              key: const Key('beamProofText'),
              style: STextStyles.itemSubtitle12(context),
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            key: const Key('beamProofCopy'),
            label: l10n.txProofCopy,
            onPressed: () async {
              await copyWithToast(context, proof, message: l10n.txProofCopied);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!isDesktop)
                Expanded(
                  child: SecondaryButton(
                    label: l10n.txShare,
                    onPressed: () => backend.share(proof),
                  ),
                ),
              if (!isDesktop) const SizedBox(width: 12),
              Expanded(
                child: SecondaryButton(
                  label: l10n.commonDone,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Spec — payment proof (check):
//   Job:  tell whether a proof someone sent really shows a payment.
//   CTA:  "Check proof".
//   Taps: entry → Check a payment proof → paste → Check proof (3).
// Exit-intent: "Did it work?" → the answer is one sentence with the amount
// and both addresses; a bad paste is explained without blaming anyone.

/// Paste a proof, get one sentence back.
class BeamProofCheckDialog extends ConsumerStatefulWidget {
  const BeamProofCheckDialog({
    super.key,
    required this.walletId,
    required this.formatter,
  });

  final String walletId;
  final AmountFormatter formatter;

  @override
  ConsumerState<BeamProofCheckDialog> createState() =>
      _BeamProofCheckDialogState();
}

class _BeamProofCheckDialogState extends ConsumerState<BeamProofCheckDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _checking = false;
  BeamProofVerdict? _verdict;
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _verdict = null;
      _problem = null;
    });
    final api = ref.read(pBeamTxBackend(widget.walletId)).api();
    try {
      if (api == null) throw StateError('no BEAM core');
      final info = await api.verifyPaymentProof(text);
      _verdict = BeamProofVerdict.of(
        info,
        describeAmount: (amount, assetId) =>
            BeamTxText.amount(amount, assetId, widget.formatter),
      );
    } on BeamRpcException {
      _problem = BeamTxText.proofNotAProof;
    } catch (_) {
      _problem = BeamTxText.notConnected;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = ref.watch(pBeamTxIsDesktop);
    final colors = Theme.of(context).extension<StackColors>()!;
    final verdict = _verdict;
    final l10n = context.l10n;
    return _ProofFrame(
      isDesktop: isDesktop,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.txProofCheckTitle, style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 8),
          Text(
            l10n.txProofCheckExplain,
            style: STextStyles.smallMed14(context),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TextField(
              key: const Key('beamProofInput'),
              controller: _controller,
              focusNode: _focus,
              minLines: 3,
              maxLines: 5,
              style: STextStyles.itemSubtitle12(context),
              onChanged: (_) => setState(() {
                _verdict = null;
                _problem = null;
              }),
              decoration: standardInputDecoration(
                l10n.txPaymentProof,
                _focus,
                context,
              ).copyWith(filled: true),
            ),
          ),
          if (verdict != null || _problem != null) const SizedBox(height: 12),
          if (verdict != null)
            Text(
              BeamTxText.plainVerdict(verdict.sentence),
              key: const Key('beamProofVerdict'),
              style: STextStyles.smallMed14(context).copyWith(
                color: verdict.valid
                    ? colors.accentColorGreen
                    : colors.textError,
              ),
            ),
          if (_problem != null)
            Text(
              _problem!,
              key: const Key('beamProofProblem'),
              style: STextStyles.smallMed14(context)
                  .copyWith(color: colors.textError),
            ),
          const SizedBox(height: 20),
          PrimaryButton(
            key: const Key('beamProofCheck'),
            label: _checking ? l10n.txProofChecking : l10n.txProofCheckButton,
            enabled: !_checking && _controller.text.trim().isNotEmpty,
            onPressed: _check,
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            label: l10n.commonClose,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
