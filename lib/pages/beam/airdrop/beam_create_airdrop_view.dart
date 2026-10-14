/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  lock tokens into one-time codes to hand out.
//   CTA:  "Create <n> codes" (then "Create <n> codes" again on the
//         confirmation, which shows the amounts read back from the built
//         transaction).
//   Taps: open wallet → Airdrop → Create codes → amount → Create (→ confirm
//         → PIN): 4 + confirm + PIN, BEAM, 10 codes and paid claim fees
//         pre-filled.
//
// Every new batch is made on Airdrop v3: 1 to 100 codes, whose claims never
// show the code to the network.
//
// Exit-intent: "what will this cost?" → the locked total, the 1% fee, the
// claim fees paid ahead and the network fee update as the user types, with
// what leaves the wallet in total; the confirmation shows the same figures
// read back from the built transaction; "my friends have no BEAM for the
// fee" → "Pay the claim fee for each code" is on by default (0.022 BEAM
// per code), one tap turns it off; "can I share them right away?" → said
// before the button: the codes are checked on the network first, a few
// minutes after the batch is confirmed; "what if I lose the codes?" → saved
// on this device before anything is sent; "I tapped twice — did I pay
// twice?" → one batch per tap, guarded here and in the service.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_airdrop_codes_view.dart';
import 'beam_airdrop_confirm_view.dart';

/// Create a batch of airdrop codes.
class BeamCreateAirdropView extends StatefulWidget {
  const BeamCreateAirdropView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.initialAssetId = 0,
    this.initialValue,
    this.initialCount,
    this.initialPrepayClaimFees = true,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamCreateAirdrop';
  static const title = 'Create airdrop codes';

  /// This wallet's airdrops; they must have a code store.
  final BeamAirdrops service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Pre-selected asset (BEAM by default).
  final int initialAssetId;

  /// Pre-filled amount per code and number of codes, when new codes replace
  /// a batch whose codes failed their check ("Make new codes").
  final BigInt? initialValue;
  final int? initialCount;

  /// Whether "Pay the claim fee for each code" starts on (it does, unless a
  /// replaced batch had it off).
  final bool initialPrepayClaimFees;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;

  @override
  State<BeamCreateAirdropView> createState() => _BeamCreateAirdropViewState();
}

class _BeamCreateAirdropViewState extends State<BeamCreateAirdropView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  late final _amount = TextEditingController(
    text: widget.initialValue == null
        ? ''
        : BeamUnits.format(widget.initialValue!).replaceAll(',', ''),
  );
  late final _count = TextEditingController(
    text: '${widget.initialCount ?? 10}',
  );

  late int _assetId = widget.initialAssetId;
  late bool _prepay = widget.initialPrepayClaimFees;
  Map<int, BigInt>? _balances;
  BeamProblem? _loadProblem;
  BeamProblem? _problem;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    unawaited(_loadBalances());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _names.removeListener(_rebuild);
    _amount.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _loadBalances() async {
    setState(() => _loadProblem = null);
    try {
      final b = await beamAvailableBalances(widget.service.api);
      if (!mounted) return;
      setState(() => _balances = b);
      unawaited(_names.preload(b.keys));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _loadProblem =
            beamTransportProblem(e) ??
            const BeamProblem(
              "Couldn't read your balances",
              'The wallet did not answer. Try again in a moment.',
            ),
      );
    }
  }

  List<BeamHeldAsset> get _held => [
    for (final e in (_balances ?? const <int, BigInt>{}).entries)
      if (e.value > BigInt.zero) BeamHeldAsset(e.key, e.value),
  ]..sort((a, b) => a.assetId.compareTo(b.assetId));

  BigInt get _available => _balances?[_assetId] ?? BigInt.zero;

  int? get _n {
    final n = int.tryParse(_count.text.trim());
    return n != null && n >= 1 && n <= kAirdropV3MaxVouchersPerBatch ? n : null;
  }

  String? get _countProblem {
    if (_count.text.trim().isEmpty) return null;
    return _n == null
        ? 'Choose 1 to $kAirdropV3MaxVouchersPerBatch codes'
        : null;
  }

  BigInt? get _value => BeamUnits.parse(_amount.text);

  /// The largest amount a call's funds carry (signed 64-bit).
  static final _maxFunds = (BigInt.one << 63) - BigInt.one;

  /// What the batch costs, for valid input: locked for the codes, the 1%
  /// fee, the claim fees paid ahead and the network fee (the fee the
  /// service requires the built transaction to carry, exactly).
  ({BigInt total, BigInt fee, BigInt gas, BigInt network})? get _plan {
    final v = _value;
    final n = _n;
    if (v == null || n == null) return null;
    final total = v * BigInt.from(n);
    if (total > _maxFunds) return null;
    final fee = AirdropV3Fee.creationFee(total);
    final gas = _prepay
        ? kAirdropV3GasPerVoucher * BigInt.from(n)
        : BigInt.zero;
    if (total + fee + (_assetId == 0 ? gas : BigInt.zero) > _maxFunds) {
      return null;
    }
    return (total: total, fee: fee, gas: gas, network: AirdropV3Fee.create(n));
  }

  BigInt get _beamAvailable => _balances?[0] ?? BigInt.zero;

  String? get _fundsProblem {
    final p = _plan;
    if (p == null || _balances == null) return null;
    final lock = p.total + p.fee;
    final beam = p.gas + p.network;
    String b(BigInt v) => BeamUnits.withSymbol(v, 'BEAM');
    if (_assetId == 0) {
      if (lock + beam <= _available) return null;
      return 'This needs ${b(lock + beam)}, fees included, and you have '
          '${b(_available)}.';
    }
    if (lock > _available) {
      return 'This needs ${_names.amount(_assetId, lock)} with the 1% fee, '
          'and you have ${_names.amount(_assetId, _available)}.';
    }
    if (beam > _beamAvailable) {
      final what = p.gas > BigInt.zero
          ? 'The claim fees and the network fee are'
          : 'The network fee is';
      return '$what paid in BEAM: ${b(beam)}, and you have '
          '${b(_beamAvailable)}.';
    }
    return null;
  }

  /// Which asset runs short, for the notice's title.
  String get _shortSymbol {
    final p = _plan;
    if (_assetId == 0 || p == null) return _names.symbol(_assetId);
    return p.total + p.fee > _available ? _names.symbol(_assetId) : 'BEAM';
  }

  Future<void> _pickAsset() async {
    final picked = await showBeamAssetPicker(
      context: context,
      assets: _held,
      names: _names,
      title: 'What to give away',
    );
    if (picked != null && mounted) setState(() => _assetId = picked);
  }

  Future<void> _create() async {
    // Claimed before the first await: a second tap finds it set.
    if (_preparing) return;
    final v = _value;
    final n = _n;
    if (v == null || n == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    AirdropPreparedCall? p;
    try {
      p = await widget.service.prepareCreateBatch(
        assetId: _assetId,
        values: List.filled(n, v),
        prepayClaimFees: _prepay,
      );
    } catch (e) {
      if (mounted) setState(() => _problem = airdropProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (p == null) return;
    if (!mounted) {
      widget.service.discard(p);
      return;
    }
    final sent = await Navigator.of(context).push<BeamAirdropSent>(
      MaterialPageRoute(
        builder: (_) => BeamAirdropConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (sent == null || !mounted) return;
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BeamAirdropCodesView(
            service: widget.service,
            localId: p!.savedLocalId!,
            assetNames: _names,
            justCreated: true,
            notice: sent.problem,
            sync: widget.sync,
            authorize: widget.authorize,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  static String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');

  static const _orNoClaimFees = ', or turn off paying the claim fees';

  /// "Pay the claim fee for each code": on by default, so people with an
  /// empty wallet can claim (README "Gasless claims", prepaid gas).
  Widget _prepayToggle(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      key: const ValueKey('create-prepay'),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      onPressed: () => setState(() => _prepay = !_prepay),
      child: Row(
        children: [
          Checkbox(
            key: const ValueKey('create-prepay-box'),
            value: _prepay,
            onChanged: (v) => setState(() => _prepay = v ?? false),
            activeColor: colors.checkboxBGChecked,
            checkColor: colors.checkboxIconChecked,
          ),
          Expanded(
            child: Text(
              'Pay the claim fee for each code '
              '(${BeamUnits.withSymbol(kAirdropV3GasPerVoucher, 'BEAM')} per '
              'code), so people with an empty wallet can claim',
              style: STextStyles.itemSubtitle12(context),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final plan = _plan;
      final n = _n;
      final valid =
          plan != null &&
          _fundsProblem == null &&
          _balances != null &&
          _available > BigInt.zero;
      return BeamPageScaffold(
        title: BeamCreateAirdropView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Lock tokens into one-time codes. Whoever gets a code can claim '
              'its tokens once.',
              style: STextStyles.itemSubtitle(context),
            ),
            const BeamGap(16),
            if (_loadProblem != null) ...[
              BeamNotice(
                kind: BeamNoticeKind.danger,
                title: _loadProblem!.title,
                message: _loadProblem!.message,
                actionLabel: 'Try again',
                onAction: _loadBalances,
              ),
              const BeamGap(),
            ],
            const BeamLabel('What to give away'),
            RoundedWhiteContainer(
              key: const ValueKey('create-asset'),
              onPressed: _held.length > 1 ? _pickAsset : null,
              child: BeamAssetTitle(
                display: _names.display(_assetId),
                subtitle: _balances == null
                    ? 'Reading your balance…'
                    : 'You have ${_names.amount(_assetId, _available)}',
                trailing: _held.length > 1
                    ? Icon(
                        Icons.expand_more_rounded,
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textSubtitle1,
                      )
                    : null,
              ),
            ),
            const BeamGap(16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: BeamTextField(
                    fieldKey: const ValueKey('create-amount'),
                    controller: _amount,
                    label: 'Each code gives',
                    hint: '0.1',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    error: BeamUnits.problem(_amount.text),
                    suffix: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          _names.symbol(_assetId),
                          style: STextStyles.label(context),
                        ),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: BeamTextField(
                    fieldKey: const ValueKey('create-count'),
                    controller: _count,
                    label: 'Number of codes',
                    hint: '10',
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    error: _countProblem,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const BeamGap(12),
            _prepayToggle(context),
            const BeamGap(12),
            if (plan != null) ...[
              BeamDetailCard(
                children: [
                  BeamDetailRow(
                    label: 'Locked for the codes',
                    value: _names.amount(_assetId, plan.total),
                    detail: '$n × ${_names.amount(_assetId, _value!)}',
                    valueKey: const ValueKey('create-locked'),
                  ),
                  BeamDetailRow(
                    label: 'Airdrop fee (1%)',
                    value: _names.amount(_assetId, plan.fee),
                    detail: 'Kept by the airdrop contract',
                    valueKey: const ValueKey('create-fee'),
                  ),
                  if (_prepay)
                    BeamDetailRow(
                      label: 'Claim fees paid ahead',
                      value: BeamUnits.withSymbol(plan.gas, 'BEAM'),
                      detail:
                          '$n × '
                          '${_beam(kAirdropV3GasPerVoucher)}',
                      valueKey: const ValueKey('create-gas'),
                    ),
                  BeamDetailRow(
                    label: 'Network fee',
                    value: BeamUnits.withSymbol(plan.network, 'BEAM'),
                    valueKey: const ValueKey('create-network-fee'),
                  ),
                ],
              ),
              const BeamGap(8),
              BeamTotalRow(
                confirm: false,
                label: 'Leaves your wallet',
                value: _assetId == 0
                    ? BeamUnits.withSymbol(
                        plan.total + plan.fee + plan.gas + plan.network,
                        'BEAM',
                      )
                    : '${_names.amount(_assetId, plan.total + plan.fee)} + '
                          '${_beam(plan.gas + plan.network)}',
                valueKey: const ValueKey('create-total'),
              ),
            ],
            if (_fundsProblem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('create-funds-problem'),
                kind: BeamNoticeKind.danger,
                title: 'Not enough $_shortSymbol',
                message:
                    '${_fundsProblem!} Lower the amount or the number '
                    'of codes${_prepay ? _orNoClaimFees : ''}.',
              ),
            ],
            const BeamGap(),
            // What a code is, closest to the button (the scariest question
            // sits next to the action).
            const BeamNotice(
              key: ValueKey('create-bearer-warning'),
              kind: BeamNoticeKind.warning,
              title: AirdropBearerText.createTitle,
              message: AirdropBearerText.createMessageV3,
            ),
            const BeamGap(8),
            Text(
              'Share the codes once Campfire has checked them: it waits for '
              'the network to confirm the batch, then checks every code. This '
              'takes a few minutes. Codes nobody claims can be taken back '
              'later${_prepay ? ', with their claim fees' : ''}.',
              key: const ValueKey('create-check-note'),
              style: STextStyles.label(context),
            ),
            if (_problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('create-problem'),
                kind: BeamNoticeKind.danger,
                title: _problem!.title,
                message: _problem!.message,
              ),
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamSyncNotice(sync: sync, what: 'Creating codes'),
            BeamCtaBar(
              primaryKey: const ValueKey('create-cta'),
              label: n == null ? 'Create codes' : 'Create $n codes',
              busy: _preparing,
              busyLabel: 'Preparing…',
              onPressed: valid && sync.canSpend ? _create : null,
            ),
          ],
        ),
      );
    },
  );
}
