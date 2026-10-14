/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  see which codes were claimed, and take back what nobody claimed.
//   CTA:  "Create new codes" (each batch has its own "Show codes" and
//         "Take back <n> unclaimed" actions).
//   Taps: open wallet → Airdrop → My batches (2–3).
//
// Batches of Airdrop v3 (where every new batch is made) and of the old
// contract are listed together, each taken back on its own contract.
//
// Exit-intent: "where did my money go?" → every batch says how many
// codes were claimed, taken back and still waiting; "can I get it back?" →
// the take-back action is on the batch, with what comes back (claim fees
// paid ahead included) and its exact fee shown before confirming; "did the
// take-back work?" → sent, then done once the network confirms it; if a
// code was claimed first, it says nothing changed and shows what is left;
// "is the list stale?" → it shows the saved list at once and says while it
// checks the network.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/models/beam_transaction.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_batch_status.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_dialog.dart';
import 'beam_airdrop_codes_view.dart';
import 'beam_airdrop_confirm_view.dart';
import 'beam_create_airdrop_view.dart';

/// This wallet's airdrop batches on both contracts: the ones whose codes
/// are saved here and the ones the contracts list for this wallet, matched
/// by their codes. Never removes a batch on its own.
class BeamAirdropBatchesView extends StatefulWidget {
  const BeamAirdropBatchesView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.onCreateBatch,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
    this.clock = DateTime.now,
  });

  static const routeName = '/beamAirdropBatches';
  static const title = 'My airdrop batches';

  /// How often a sent take-back is asked about until the network decides.
  static const pollEvery = Duration(seconds: 6);

  final BeamAirdrops service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Opens the create form; when null this screen pushes
  /// [BeamCreateAirdropView] itself.
  final VoidCallback? onCreateBatch;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;
  final DateTime Function() clock;

  @override
  State<BeamAirdropBatchesView> createState() => _BeamAirdropBatchesViewState();
}

/// One card: a batch on a contract, its saved codes, or both.
class _Row {
  const _Row({this.saved, this.chain, this.v3});

  final AirdropSavedBatch? saved;

  /// The old contract's record of it.
  final AirdropBatch? chain;

  /// Airdrop v3's record of it.
  final AirdropV3Batch? v3;
}

/// A take-back that was sent and is not decided yet.
typedef _Pending = ({String txId, String key, String what});

class _BeamAirdropBatchesViewState extends State<BeamAirdropBatchesView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);

  List<AirdropSavedBatch>? _saved;
  List<AirdropBatch> _chain = const [];
  List<AirdropV3Batch> _v3 = const [];
  final _chainHashes = <BigInt, Set<String>>{};
  final _v3Keys = <BigInt, Set<String>>{};
  bool _refreshing = false;
  bool _checkedNetwork = false;
  bool _preparing = false;
  BeamProblem? _problem;
  BeamProblem? _partProblem;
  BeamProblem? _done;
  BeamNoticeKind _doneKind = BeamNoticeKind.success;
  _Pending? _pending;
  Timer? _poll;

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
    _poll?.cancel();
    _names.removeListener(_rebuild);
    super.dispose();
  }

  /// The saved list first (instant, from this device), then the network.
  Future<void> _load() async {
    try {
      final saved = await widget.service.savedBatches();
      if (!mounted) return;
      setState(() => _saved = saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saved = const []);
    }
    await _refresh();
  }

  static bool _needsCheck(AirdropSavedBatch b) =>
      // A new v3 batch is checked by its codes screen, once: never here.
      // Once checked (or never created), its codes' states are read here.
      (!b.isV3 ||
          (b.check?.ok ?? false) ||
          b.txStatus == AirdropBatchTxStatus.failed) &&
      (b.txStatus == AirdropBatchTxStatus.unconfirmed ||
          b.txStatus == AirdropBatchTxStatus.broadcast ||
          b.codes.any(
            (c) =>
                c.status == AirdropCodeStatus.available ||
                c.status == AirdropCodeStatus.unknown,
          ));

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _problem = null;
      _partProblem = null;
    });
    final svc = widget.service;
    Object? oldError;
    Object? v3Error;
    var chain = const <AirdropBatch>[];
    final hashes = <BigInt, Set<String>>{};
    var v3 = const <AirdropV3Batch>[];
    final keys = <BigInt, Set<String>>{};
    try {
      chain = await svc.oldBatches();
      for (final c in chain) {
        hashes[c.id] = {
          for (final v in await svc.oldBatchVouchers(c.id)) v.hashHex,
        };
      }
    } catch (e) {
      oldError = e;
      chain = const [];
    }
    try {
      v3 = (await svc.v3Batches()).batches;
      final saved = _saved ?? const <AirdropSavedBatch>[];
      final known = {
        for (final s in saved)
          if (s.isV3 && s.batchId != null) s.batchId!,
      };
      // A batch not matched by its id yet (its codes not checked yet) is
      // matched by its vouchers' keys. view_my_batches lists only this
      // wallet's batches, so a copy made by someone else never matches.
      if (saved.any((s) => s.isV3 && s.batchId == null)) {
        for (final b in v3) {
          if (known.contains(b.id)) continue;
          keys[b.id] = {
            for (final v in (await svc.v3Batch(b.id)).vouchers) v.key,
          };
        }
      }
    } catch (e) {
      v3Error = e;
      v3 = const [];
    }
    try {
      for (final s in _saved ?? const <AirdropSavedBatch>[]) {
        if (_needsCheck(s)) await svc.refreshSavedBatch(s);
      }
    } catch (e) {
      oldError ??= e;
    }
    List<AirdropSavedBatch>? saved;
    try {
      saved = await svc.savedBatches();
    } catch (_) {
      saved = _saved;
    }
    if (!mounted) return;
    setState(() {
      _chain = chain;
      _chainHashes
        ..clear()
        ..addAll(hashes);
      _v3 = v3;
      _v3Keys
        ..clear()
        ..addAll(keys);
      _saved = saved;
      _refreshing = false;
      _checkedNetwork = oldError == null || v3Error == null;
      if (oldError != null && v3Error != null) {
        final t = airdropProblem(v3Error);
        _problem = BeamProblem(
          t.title,
          '${t.message} Your saved codes are safe on this device.',
        );
      } else if (oldError != null || v3Error != null) {
        _partProblem = const BeamProblem(
          "Some batches couldn't be read just now",
          'The list may be missing some. Your saved codes are safe on this '
              'device.',
        );
      }
    });
    unawaited(
      _names.preload({
        for (final c in chain) c.assetId,
        for (final b in v3) b.assetId,
        for (final s in saved ?? const <AirdropSavedBatch>[]) s.assetId,
      }),
    );
  }

  List<_Row> get _rows {
    final saved = _saved ?? const <AirdropSavedBatch>[];
    final used = <String>{};
    final rows = <_Row>[];
    for (final b in _v3) {
      final keys = _v3Keys[b.id] ?? const <String>{};
      final match = saved.where(
        (s) =>
            s.isV3 &&
            !used.contains(s.localId) &&
            (s.batchId == b.id ||
                (s.batchId == null &&
                    s.codes.any((c) => c.key != null && keys.contains(c.key)))),
      );
      final s = match.isEmpty ? null : match.first;
      if (s != null) used.add(s.localId);
      rows.add(_Row(v3: b, saved: s));
    }
    for (final c in _chain) {
      final hashes = _chainHashes[c.id] ?? const <String>{};
      final match = saved.where(
        (s) =>
            !s.isV3 &&
            !used.contains(s.localId) &&
            s.codes.any((code) => hashes.contains(code.hashHex)),
      );
      final s = match.isEmpty ? null : match.first;
      if (s != null) used.add(s.localId);
      rows.add(_Row(chain: c, saved: s));
    }
    for (final s in saved) {
      if (!used.contains(s.localId)) rows.add(_Row(saved: s));
    }
    BigInt height(_Row r) =>
        r.v3?.createdAtHeight ?? r.chain?.createdAtHeight ?? BigInt.zero;
    rows.sort((a, b) {
      final ta = a.saved?.createdAt;
      final tb = b.saved?.createdAt;
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return height(b).compareTo(height(a));
    });
    return rows;
  }

  void _openCreate() {
    final open = widget.onCreateBatch;
    if (open != null) {
      open();
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BeamCreateAirdropView(
            service: widget.service,
            sync: widget.sync,
            assetNames: _names,
            authorize: widget.authorize,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  Future<void> _showCodes(AirdropSavedBatch s) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BeamAirdropCodesView(
          service: widget.service,
          localId: s.localId,
          assetNames: _names,
          sync: widget.sync,
          authorize: widget.authorize,
          clipboard: widget.clipboard,
          exporter: widget.exporter,
        ),
      ),
    );
    // The codes screen may have checked a new batch: show where it is now.
    if (mounted) unawaited(_refresh());
  }

  /// What a take-back returns, in words: its value, and prepaid claim fees.
  String _backText(AirdropSummary s) {
    if (s.assetId == 0) {
      return _names.amount(0, s.receives[0] ?? BigInt.zero);
    }
    final value = _names.amount(s.assetId, s.assetAmount);
    return s.claimFees > BigInt.zero
        ? '$value + ${BeamUnits.withSymbol(s.claimFees, 'BEAM')}'
        : value;
  }

  Future<void> _cancel(AirdropContract contract, BigInt id) async {
    if (_preparing || _pending != null) return;
    setState(() {
      _preparing = true;
      _problem = null;
      _done = null;
    });
    AirdropPreparedCall? p;
    var changed = false;
    try {
      p = await widget.service.prepareCancelBatch(contract, id);
    } catch (e) {
      changed = e is BeamAirdropException && e.code == AirdropErrorCode.changed;
      if (mounted && !changed) setState(() => _problem = airdropProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    // A claim landed while the take-back was prepared: nothing was sent.
    // Read the batch again, so the button shows what is left, then say so.
    if (changed) {
      if (!mounted) return;
      await _refresh();
      if (mounted) {
        setState(
          () => _problem = airdropProblem(
            const BeamAirdropException(AirdropErrorCode.changed, ''),
          ),
        );
      }
      return;
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
    final tx = sent?.txId;
    if (tx == null || !mounted) return;
    final what = _backText(p.summary);
    final n = p.summary.voucherCount ?? 0;
    setState(() {
      _doneKind = BeamNoticeKind.success;
      _done = BeamProblem(
        'Take-back sent',
        'The $n unclaimed ${n == 1 ? 'code stops' : 'codes stop'} working '
            'and $what comes back once the network confirms it, usually '
            'within 2 minutes.',
      );
      _pending = (txId: tx, key: '${contract.name}:$id', what: what);
    });
    _schedulePoll();
    unawaited(_refresh());
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(BeamAirdropBatchesView.pollEvery, _pollCancel);
  }

  /// A sent take-back counts once the network confirms it; one that fails
  /// (a code was claimed first) changed nothing.
  Future<void> _pollCancel() async {
    final p = _pending;
    if (!mounted || p == null) return;
    try {
      final st = (await widget.service.api.txStatus(p.txId)).status;
      if (!mounted || _pending != p) return;
      final ok = st == BeamTxStatus.completed;
      if (ok || st == BeamTxStatus.failed || st == BeamTxStatus.canceled) {
        setState(() {
          _pending = null;
          _doneKind = ok ? BeamNoticeKind.success : BeamNoticeKind.info;
          _done = ok
              ? BeamProblem('Taken back', '${p.what} is back in your wallet.')
              : const BeamProblem(
                  'The take-back did not go through',
                  'Nothing changed and nothing left your wallet. If a code '
                      'was claimed in the meantime, take back what is left '
                      'now.',
                );
        });
        unawaited(_refresh());
        return;
      }
    } catch (_) {
      // Asked again shortly.
    }
    if (mounted) _schedulePoll();
  }

  Future<void> _forget(AirdropSavedBatch s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: 'Remove this batch from the list?',
        message:
            'Every code is claimed or cancelled, so none of them holds funds '
            'any more. This removes them from this device only.',
        leftButton: SecondaryButton(
          label: 'Keep',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: 'Remove',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.service.forgetSavedBatch(s);
      final saved = await widget.service.savedBatches();
      if (mounted) setState(() => _saved = saved);
    } catch (e) {
      if (mounted) setState(() => _problem = airdropProblem(e));
    }
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final rows = _rows;
      final loaded = _saved != null;
      final empty = loaded && rows.isEmpty && !_refreshing && _problem == null;
      return BeamPageScaffold(
        title: BeamAirdropBatchesView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_refreshing)
              const BeamWorking('Checking your codes on the network…')
            else if (_checkedNetwork && rows.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Up to date with the network',
                      style: STextStyles.label(context),
                    ),
                  ),
                  CustomTextButton(text: 'Check again', onTap: _refresh),
                ],
              ),
            if (_done != null) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-done'),
                kind: _doneKind,
                title: _done!.title,
                message: _done!.message,
              ),
            ],
            if (_problem != null) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-problem'),
                kind: BeamNoticeKind.danger,
                title: _problem!.title,
                message: _problem!.message,
                actionLabel: 'Try again',
                onAction: _refresh,
              ),
            ],
            if (_partProblem != null && _problem == null) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-part-problem'),
                kind: BeamNoticeKind.warning,
                title: _partProblem!.title,
                message: _partProblem!.message,
                actionLabel: 'Try again',
                onAction: _refresh,
              ),
            ],
            if (_preparing) const BeamWorking('Preparing the take-back…'),
            if (empty)
              const BeamEmptyState(
                key: ValueKey('batches-empty'),
                art: BeamStickerImage(BeamSticker.hi, size: 120),
                title: 'No airdrop codes yet',
                message:
                    'Create codes to give tokens to people. Each code can be '
                    'claimed once, by whoever has it.',
              ),
            const BeamGap(8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _card(context, r, sync.canSpend),
              ),
          ],
        ),
        bottom: BeamCtaBar(
          primaryKey: const ValueKey('batches-create'),
          label: empty ? 'Create airdrop codes' : 'Create new codes',
          onPressed: _openCreate,
        ),
      );
    },
  );

  /// A v3 batch's state from the contract's counts.
  static BeamStatusText _v3Status(AirdropV3Batch b) {
    if (b.unclaimed == 0) {
      if (b.cancelled == 0) {
        return (
          text: 'All ${b.redeemed} claimed',
          kind: BeamNoticeKind.success,
        );
      }
      return (
        text: '${b.redeemed} claimed · ${b.cancelled} taken back',
        kind: BeamNoticeKind.info,
      );
    }
    return (
      text:
          '${b.redeemed} of ${b.created} claimed · ${b.unclaimed} waiting'
          '${b.cancelled > 0 ? ' · ${b.cancelled} taken back' : ''}',
      kind: BeamNoticeKind.info,
    );
  }

  /// A saved v3 batch the contract does not list (yet): where its check is.
  static (BeamStatusText, String) _v3LocalStatus(AirdropSavedBatch s) {
    if (s.txStatus == AirdropBatchTxStatus.failed && s.check == null) {
      return (
        (text: 'Not created — nothing was locked', kind: BeamNoticeKind.danger),
        'These codes hold nothing.',
      );
    }
    final check = s.check;
    if (check != null && !check.ok) {
      return (
        (text: 'Do not share', kind: BeamNoticeKind.danger),
        'These codes did not pass the check. Show codes says what to do.',
      );
    }
    if (check != null) {
      return (airdropBatchStatus(s, null), 'Checked and ready to share.');
    }
    return (
      (text: 'Being checked', kind: BeamNoticeKind.warning),
      'Being confirmed and checked before you share the codes. Show codes to '
          'see how far it is.',
    );
  }

  Widget _card(BuildContext context, _Row r, bool canSpend) {
    final s = r.saved;
    final c = r.chain;
    final v = r.v3;
    final assetId = s?.assetId ?? v?.assetId ?? c!.assetId;
    final count = s?.count ?? v?.created ?? c!.totalCount;
    final BigInt? each = s != null
        ? (s.codes.every((x) => x.value == s.codes.first.value)
              ? s.codes.first.value
              : null)
        : c?.valuePerVoucher;
    String? note;
    BeamStatusText status;
    if (v != null) {
      status = _v3Status(v);
      if (s?.check != null && !s!.check!.ok) {
        status = (text: 'Do not share', kind: BeamNoticeKind.danger);
        note =
            'These codes did not pass the check. Show codes says what to '
            'do.';
      }
    } else if (s != null && s.isV3 && c == null) {
      final (st, n) = _v3LocalStatus(s);
      status = st;
      note = n;
    } else {
      status = airdropBatchStatus(s, c);
    }
    final colors = Theme.of(context).extension<StackColors>()!;
    final unclaimed = v?.unclaimed ?? c?.unclaimedCount ?? 0;
    final settled =
        s != null &&
        c == null &&
        v == null &&
        airdropBatchLooksSettled(s, widget.clock());
    final created = s != null
        ? 'Created ${_date(s.createdAt.toLocal())}'
        : 'Created at block ${v?.createdAtHeight ?? c!.createdAtHeight}';
    final contract = v != null || (s?.isV3 ?? false)
        ? AirdropContract.v3
        : AirdropContract.v2;
    final batchId = v?.id ?? c?.id;
    final key = '${contract.name}:$batchId';
    return RoundedWhiteContainer(
      key: ValueKey(
        'batch-${s?.localId ?? (v != null ? 'v3-${v.id}' : c!.id)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BeamAssetTitle(
            display: _names.display(assetId),
            subtitle: each == null
                ? _codes(count)
                : '${_codes(count)} × ${_names.amount(assetId, each)}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              BeamPill(text: status.text, kind: status.kind),
              Text(created, style: STextStyles.label(context)),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note, style: STextStyles.label(context)),
          ],
          if (v != null && v.gasPerVoucher > BigInt.zero) ...[
            const SizedBox(height: 4),
            Text(
              'Claim fees paid: people with an empty wallet can claim.',
              key: ValueKey('batch-gas-${v.id}'),
              style: STextStyles.label(context),
            ),
          ],
          if (s == null) ...[
            const SizedBox(height: 4),
            Text(
              unclaimed > 0
                  ? 'Its codes are not on this device, but you can still '
                        'take back what nobody claimed.'
                  : 'Its codes are not on this device. Nothing is left to '
                        'claim.',
              style: STextStyles.label(context),
            ),
          ],
          if (s != null || unclaimed > 0 || settled) ...[
            const SizedBox(height: 4),
            Divider(color: colors.background, height: 12),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                if (s != null)
                  CustomTextButton(
                    key: ValueKey('batch-codes-${s.localId}'),
                    text: 'Show codes',
                    onTap: () => _showCodes(s),
                  ),
                if (unclaimed > 0 && batchId != null)
                  CustomTextButton(
                    key: ValueKey(
                      contract == AirdropContract.v3
                          ? 'batch-cancel-v3-$batchId'
                          : 'batch-cancel-$batchId',
                    ),
                    text: _pending?.key == key
                        ? 'Taking back…'
                        : 'Take back $unclaimed unclaimed',
                    enabled: canSpend && !_preparing && _pending == null,
                    onTap: () => _cancel(contract, batchId),
                  ),
                if (settled)
                  CustomTextButton(
                    key: ValueKey('batch-forget-${s.localId}'),
                    text: 'Remove from this list',
                    onTap: () => _forget(s),
                  ),
              ],
            ),
          ],
          if (unclaimed > 0 && contract == AirdropContract.v3)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Network fee to take back: '
                '${_beam(AirdropV3Fee.cancel(unclaimed))}',
                key: ValueKey('batch-fee-v3-$batchId'),
                style: STextStyles.label(context),
              ),
            ),
        ],
      ),
    );
  }

  static String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');

  static String _codes(int n) => n == 1 ? '1 code' : '$n codes';

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
