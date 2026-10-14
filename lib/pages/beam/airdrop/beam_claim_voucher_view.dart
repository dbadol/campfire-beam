/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  turn a voucher code into tokens in this wallet.
//   CTA:  "Claim <amount> <ticker>" (or "Claim anyway" when the voucher is
//         worth less than its network fee).
//   Taps: open wallet → Claim a voucher → paste → Claim → PIN (3 + PIN).
//
// A code is looked up on Airdrop v3 first, then on the old contract, and
// claimed where it was found.
//
// Exit-intent, and what this screen does about each:
//   * "Is this a scam / what will it cost me?" → the value and the network
//     fee decoded from the prepared transaction are on screen before the
//     button is live; nothing is signed without the PIN.
//   * "I have no BEAM for the fee" → a code whose maker paid its fee says
//     "No BEAM needed" and claims from an empty wallet; any other says how
//     much BEAM it needs.
//   * "It costs more than it gives" → said in plain numbers, with the loss.
//   * "The code doesn't work" → the error says why and what to check,
//     without blaming the user.
//   * "Nothing happens" → checking starts by itself once a full code is in
//     and says "Checking the code…" while it works.
//   * "Did I get it?" → "Claim sent", then "received" only once the network
//     confirms it; a claim that does not go through says nothing left the
//     wallet and offers to check the code again.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../../utilities/barcode_scanner_interface.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/models/beam_transaction.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/airdrop/voucher_code_input.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/flag_secure_scope.dart';
import '../../../widgets/icon_widgets/clipboard_icon.dart';
import '../../../widgets/icon_widgets/qrcode_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/textfield_icon_button.dart';

/// Claim an airdrop voucher with its code.
///
/// Typing or pasting a full code builds the claim right away (nothing is
/// signed or sent), so the screen can show what the voucher gives and the
/// network fee the core will charge, read back from that transaction. The
/// prepared claim is discarded whenever the code changes or the screen
/// closes, which releases [service] for the next airdrop action.
///
/// After the PIN the claim is sent, and this screen follows it until the
/// network confirms it or turns it down.
class BeamClaimVoucherView extends StatefulWidget {
  const BeamClaimVoucherView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.clipboard = const ClipboardWrapper(),
    this.scanner = const BarcodeScannerWrapper(),
    this.initialCode,
    this.onDone,
  });

  static const routeName = '/beamClaimVoucher';
  static String get title => appL10n.airdropClaimTitle;

  /// This wallet's airdrops, both contracts (one instance per wallet).
  final BeamAirdrops service;

  /// The wallet's sync verdict: claiming is off unless it can spend.
  final ValueListenable<BeamSyncAssessment> sync;

  /// Defaults to names read through [service]'s wallet core.
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;
  final ClipboardInterface clipboard;

  /// Used on phones only (desktop has no camera flow in Campfire).
  final BarcodeScannerInterface scanner;

  /// A code from a link or a scan, checked on open.
  final String? initialCode;

  /// After a claim, "Done" calls this; it pops the route when null.
  final VoidCallback? onDone;

  /// How often a sent claim is asked about until the network decides.
  static const pollEvery = Duration(seconds: 5);

  @override
  State<BeamClaimVoucherView> createState() => _BeamClaimVoucherViewState();
}

/// A sent claim: on its way, in the balance, or turned down.
enum _ClaimState { sent, received, failed }

class _BeamClaimVoucherViewState extends State<BeamClaimVoucherView>
    with BeamSendFlow {
  /// Codes this module generates have 16 symbols; codes made elsewhere may
  /// differ, so shorter text is checked too, after a pause in typing.
  static const _minAutoCheck = 8;

  final _code = TextEditingController();
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);

  AirdropPreparedCall? _prepared;
  BigInt? _beamAvailable;
  Timer? _debounce;
  bool _checking = false;
  bool _inFlight = false;
  bool _again = false;

  /// After a claim was sent: what it gives, its transaction, where it is.
  String? _claimedText;
  String? _claimTx;
  String? _claimedCode;
  _ClaimState _claimState = _ClaimState.sent;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    final initial = widget.initialCode;
    if (initial != null && initial.isNotEmpty) {
      _code.text = AirdropVoucherCode.format(initial);
      _debounce = Timer(Duration.zero, _check);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _poll?.cancel();
    _dropPrepared();
    _names.removeListener(_rebuild);
    _code.dispose();
    super.dispose();
  }

  String get _normalised => AirdropVoucherCode.normalise(_code.text);

  void _dropPrepared() {
    final p = _prepared;
    if (p != null && !p.isExecuted) widget.service.discard(p);
    _prepared = null;
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _dropPrepared();
    setState(() => problem = null);
    final n = _normalised.length;
    if (n >= _minAutoCheck) {
      _debounce = Timer(
        n >= AirdropVoucherCode.length
            ? Duration.zero
            : const Duration(milliseconds: 700),
        _check,
      );
    }
  }

  Future<void> _paste() async {
    final data = await widget.clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    _code.text = AirdropVoucherCode.format(text);
    _onChanged(_code.text);
  }

  Future<void> _scan() async {
    final r = await widget.scanner.scan(context: context);
    final text = r.rawContent;
    if (text == null || !mounted) return;
    _code.text = AirdropVoucherCode.format(text);
    _onChanged(_code.text);
  }

  /// Builds the claim for the code in the field. Runs one at a time; a
  /// change while it runs re-checks once it returns, and a stale result is
  /// discarded, never shown.
  Future<void> _check() async {
    _debounce?.cancel();
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    try {
      do {
        _again = false;
        final code = _code.text;
        if (AirdropVoucherCode.normalise(code).isEmpty) break;
        _dropPrepared();
        if (mounted) {
          setState(() {
            _checking = true;
            problem = null;
          });
        }
        try {
          final p = await widget.service.prepareRedeem(code);
          if (!mounted ||
              _again ||
              AirdropVoucherCode.normalise(code) != _normalised) {
            widget.service.discard(p);
            continue;
          }
          _prepared = p;
          unawaited(_names.preload([p.summary.assetId]));
          _beamAvailable = await _beamBalance();
        } catch (e) {
          if (!mounted || _again) continue;
          problem = airdropProblem(e);
        }
      } while (_again && mounted);
    } finally {
      _inFlight = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<BigInt?> _beamBalance() async {
    try {
      return (await beamAvailableBalances(widget.service.api))[0];
    } catch (_) {
      return null; // Not known; the core checks again when sending.
    }
  }

  Future<void> _claim() async {
    final p = _prepared;
    if (p == null) return;
    final s = p.summary;
    final gets = _names.amount(s.assetId, s.assetAmount);
    final code = _code.text;
    final tx = await runSend(
      authorize: widget.authorize,
      reason: context.l10n.airdropClaimAuthReason(gets),
      send: () => widget.service.execute(p),
      explain: airdropProblem,
    );
    if (!mounted) return;
    if (p.isExecuted) _prepared = null;
    if (tx != null) {
      setState(() {
        _claimedText = gets;
        _claimTx = tx;
        _claimedCode = code;
        _claimState = _ClaimState.sent;
      });
      _schedulePoll();
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(BeamClaimVoucherView.pollEvery, _pollClaim);
  }

  /// Asks the wallet where the sent claim is, until the network decides.
  Future<void> _pollClaim() async {
    final tx = _claimTx;
    if (!mounted || tx == null || _claimState != _ClaimState.sent) return;
    try {
      final st = (await widget.service.api.txStatus(tx)).status;
      if (!mounted || _claimTx != tx) return;
      if (st == BeamTxStatus.completed) {
        setState(() => _claimState = _ClaimState.received);
        return;
      }
      if (st == BeamTxStatus.failed || st == BeamTxStatus.canceled) {
        setState(() => _claimState = _ClaimState.failed);
        return;
      }
    } catch (_) {
      // Asked again shortly.
    }
    if (mounted) _schedulePoll();
  }

  void _resetDone() {
    _poll?.cancel();
    _claimedText = null;
    _claimTx = null;
    _claimState = _ClaimState.sent;
    problem = null;
  }

  void _another() {
    setState(() {
      _resetDone();
      _claimedCode = null;
      _code.clear();
    });
  }

  /// After a claim that did not go through: the same code, checked again.
  void _checkAgain() {
    final code = _claimedCode ?? '';
    setState(() {
      _resetDone();
      _code.text = AirdropVoucherCode.format(code);
    });
    unawaited(_check());
  }

  @override
  Widget build(BuildContext context) =>
      // A code being claimed is a bearer secret: no screenshots, recordings
      // or recents thumbnail of this screen (issue #76).
      FlagSecureScope(child: _gate(context));

  Widget _gate(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      if (_claimedText != null) return _done(context);
      final p = _prepared;
      final s = p?.summary;
      final shortOfBeam =
          s != null && _beamAvailable != null && _beamAvailable! < s.beamNeeded;
      final l10n = context.l10n;
      final String label;
      VoidCallback? action;
      if (s != null) {
        label = s.claimCostsMoreThanItPays
            ? l10n.airdropClaimAnyway
            : l10n.airdropClaimCta(_names.amount(s.assetId, s.assetAmount));
        action = sync.canSpend && !shortOfBeam ? _claim : null;
      } else if (problem != null && _normalised.isNotEmpty) {
        label = l10n.airdropClaimCheckAgain;
        action = _check;
      } else if (_normalised.length >= _minAutoCheck) {
        label = l10n.airdropClaimCheckCode;
        action = _check;
      } else {
        label = l10n.airdropClaimCodeCta;
      }
      return BeamPageScaffold(
        title: BeamClaimVoucherView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.airdropClaimIntro,
              style: STextStyles.itemSubtitle(context),
            ),
            const BeamGap(16),
            _codeField(context),
            const BeamGap(16),
            if (_checking) BeamWorking(l10n.airdropClaimChecking),
            if (problem != null && !_checking)
              BeamNotice(
                key: const ValueKey('claim-problem'),
                kind: BeamNoticeKind.danger,
                title: problem!.title,
                message: problem!.message,
              ),
            if (s != null && !_checking) ...[
              if (s.codePaysFee) ...[
                BeamNotice(
                  key: const ValueKey('claim-no-beam-needed'),
                  kind: BeamNoticeKind.success,
                  title: l10n.airdropClaimNoBeamNeededTitle,
                  message: l10n.airdropClaimNoBeamNeededMessage,
                ),
                const BeamGap(8),
              ],
              _summary(context, s),
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('claim-bearer-notice'),
                kind: BeamNoticeKind.info,
                message: s.contract == AirdropContract.v3
                    ? AirdropBearerText.claimMessageV3
                    : AirdropBearerText.claimMessage,
              ),
              if (s.claimCostsMoreThanItPays) ...[
                const BeamGap(),
                _lossWarning(s),
              ],
              if (shortOfBeam) ...[
                const BeamGap(),
                BeamNotice(
                  key: const ValueKey('claim-short-of-beam'),
                  kind: BeamNoticeKind.danger,
                  title: l10n.airdropClaimShortTitle,
                  message: l10n.airdropClaimShortMessage(
                    BeamUnits.withSymbol(s.beamNeeded, 'BEAM'),
                    BeamUnits.withSymbol(_beamAvailable!, 'BEAM'),
                  ),
                ),
              ],
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s != null)
              BeamSyncNotice(sync: sync, action: BeamPausedAction.claiming),
            BeamCtaBar(
              primaryKey: const ValueKey('claim-cta'),
              label: label,
              busy: _checking || sending,
              busyLabel: sending ? l10n.airdropClaiming : l10n.airdropChecking,
              onPressed: action,
            ),
          ],
        ),
      );
    },
  );

  Widget _codeField(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    final l10n = context.l10n;
    return BeamTextField(
      fieldKey: const ValueKey('claim-code-field'),
      controller: _code,
      label: l10n.airdropClaimCodeLabel,
      hint: 'XXXX-XXXX-XXXX-XXXX',
      style: voucherCodeStyle(context),
      textCapitalization: TextCapitalization.characters,
      inputFormatters: const [VoucherCodeFormatter()],
      onChanged: _onChanged,
      helper:
          _normalised.isNotEmpty &&
              _normalised.length < AirdropVoucherCode.length &&
              _prepared == null &&
              !_checking &&
              problem == null
          ? l10n.airdropClaimCharacters(
              _normalised.length,
              AirdropVoucherCode.length,
            )
          : null,
      suffix: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFieldIconButton(
            key: const ValueKey('claim-paste'),
            semanticsLabel: l10n.airdropClaimPasteLabel,
            onTap: _paste,
            child: const ClipboardIcon(),
          ),
          if (!desktop)
            TextFieldIconButton(
              key: const ValueKey('claim-scan'),
              semanticsLabel: l10n.airdropClaimScanLabel,
              onTap: _scan,
              child: const QrCodeIcon(),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _lossWarning(AirdropSummary s) {
    String beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');
    final gives = s.receives[0]!;
    return BeamNotice(
      key: const ValueKey('claim-loss-warning'),
      kind: BeamNoticeKind.warning,
      title: context.l10n.airdropClaimLossTitle,
      message: context.l10n.airdropClaimLossMessage(
        beam(gives),
        beam(s.networkFee),
        beam(s.networkFee - gives),
      ),
    );
  }

  Widget _summary(BuildContext context, AirdropSummary s) {
    final gets = s.assetAmount;
    final isBeam = s.assetId == 0;
    final net = s.beamChange;
    String beamLine(BigInt v) =>
        '${v.isNegative ? '−' : '+'}${BeamUnits.withSymbol(v.abs(), 'BEAM')}';
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoundedWhiteContainer(
          child: BeamAssetTitle(
            display: _names.display(s.assetId),
            subtitle: l10n.airdropClaimFound,
          ),
        ),
        const BeamGap(8),
        BeamDetailCard(
          children: [
            BeamDetailRow(
              label: l10n.airdropClaimYouGet,
              value: _names.amount(s.assetId, gets),
              valueKey: const ValueKey('claim-gets'),
            ),
            BeamDetailRow(
              label: l10n.beamNetworkFee,
              value: BeamUnits.withSymbol(s.networkFee, 'BEAM'),
              detail: s.codePaysFee
                  ? l10n.airdropClaimPaidByCode
                  : isBeam
                  ? null
                  : l10n.airdropClaimPaidFromBeam,
              valueKey: const ValueKey('claim-fee'),
            ),
          ],
        ),
        const BeamGap(8),
        BeamTotalRow(
          label: isBeam
              ? l10n.airdropBalanceChangesBy
              : l10n.airdropClaimInTotal,
          value: isBeam
              ? beamLine(net)
              : '+${_names.amount(s.assetId, gets)}'
                    '${net == BigInt.zero ? '' : ', ${beamLine(net)}'}',
          valueKey: const ValueKey('claim-total'),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    final what = _claimedText!;
    final l10n = context.l10n;
    final (Widget art, String title, String message) = switch (_claimState) {
      _ClaimState.sent => (
        const BeamStickerImage(BeamMoments.coinsOnTheirWay, size: 140),
        l10n.homeClaimSentTitle,
        l10n.airdropClaimSentMessage(what),
      ),
      _ClaimState.received => (
        const BeamAnimatedStickerView(BeamMoments.claimDone, size: 140),
        l10n.airdropClaimReceivedTitle(what),
        l10n.airdropClaimReceivedMessage,
      ),
      _ClaimState.failed => (
        const BeamStickerImage(BeamMoments.somethingWentWrong, size: 140),
        l10n.airdropClaimFailedTitle,
        l10n.airdropClaimFailedMessage,
      ),
    };
    final done = widget.onDone ?? () => Navigator.of(context).maybePop();
    return BeamPageScaffold(
      title: BeamClaimVoucherView.title,
      body: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          children: [
            art,
            const BeamGap(16),
            Text(
              title,
              key: const ValueKey('claim-done'),
              textAlign: TextAlign.center,
              style: desktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            const BeamGap(8),
            Text(
              message,
              key: const ValueKey('claim-done-message'),
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
          ],
        ),
      ),
      bottom: _claimState == _ClaimState.failed
          ? BeamCtaBar(
              primaryKey: const ValueKey('claim-done-again'),
              label: l10n.airdropClaimCheckCodeAgain,
              onPressed: _checkAgain,
              secondaryLabel: l10n.commonDone,
              onSecondary: done,
            )
          : BeamCtaBar(
              label: l10n.commonDone,
              onPressed: done,
              secondaryLabel: l10n.airdropClaimAnother,
              onSecondary: _another,
            ),
    );
  }
}
