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

import '../../../l10n/l10n.dart';
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
  static String get title => appL10n.airdropBatchesTitle;

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

  /// Airdrop v3 listed only this wallet's first 200 batches.
  bool _v3Truncated = false;
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
    var v3Truncated = false;
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
      final list = await svc.v3Batches();
      v3 = list.batches;
      v3Truncated = list.truncated;
      final saved = _saved ?? const <AirdropSavedBatch>[];
      // view_my_batches stops at this wallet's first 200 batches: a newer
      // one whose codes are saved here is read on its own, so it can still
      // be followed and taken back.
      if (list.truncated) {
        final listed = {for (final b in v3) b.id};
        final more = <AirdropV3Batch>[];
        for (final s in saved) {
          final id = s.batchId;
          if (!s.isV3 || id == null || !listed.add(id)) continue;
          final AirdropV3BatchDetail d;
          try {
            d = await svc.v3Batch(id);
          } on BeamAirdropException catch (e) {
            // Not there: shown from what is saved, as before.
            if (e.code == AirdropErrorCode.batchNotFound) continue;
            rethrow;
          }
          if (s.creatorKey != null && d.creator != s.creatorKey) continue;
          more.add(AirdropV3Batch.fromDetail(d));
        }
        v3 = [...v3, ...more];
      }
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
      _v3Truncated = v3Error == null && v3Truncated;
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
          joinSentences([t.message, context.l10n.airdropBatchesCodesSafe]),
        );
      } else if (oldError != null || v3Error != null) {
        _partProblem = BeamProblem(
          context.l10n.airdropBatchesPartProblemTitle,
          joinSentences([
            context.l10n.airdropBatchesPartProblemMessage,
            context.l10n.airdropBatchesCodesSafe,
          ]),
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
        context.l10n.airdropBatchesTakeBackSentTitle,
        context.l10n.airdropBatchesTakeBackSentMessage(n, what),
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
          final l10n = context.l10n;
          _done = ok
              ? BeamProblem(
                  l10n.airdropBatchesTakenBackTitle,
                  l10n.airdropBatchesTakenBackMessage(p.what),
                )
              : BeamProblem(
                  l10n.airdropBatchesTakeBackFailedTitle,
                  l10n.airdropBatchesTakeBackFailedMessage,
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
        title: context.l10n.airdropBatchesForgetTitle,
        message: context.l10n.airdropBatchesForgetMessage,
        leftButton: SecondaryButton(
          label: context.l10n.airdropBatchesForgetKeep,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: context.l10n.airdropBatchesForgetRemove,
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
      final l10n = context.l10n;
      return BeamPageScaffold(
        title: BeamAirdropBatchesView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_refreshing)
              BeamWorking(l10n.airdropBatchesChecking)
            else if (_checkedNetwork && rows.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.airdropBatchesUpToDate,
                      style: STextStyles.label(context),
                    ),
                  ),
                  CustomTextButton(
                    text: l10n.airdropBatchesCheckAgain,
                    onTap: _refresh,
                  ),
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
                actionLabel: l10n.commonTryAgain,
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
                actionLabel: l10n.commonTryAgain,
                onAction: _refresh,
              ),
            ],
            if (_v3Truncated) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-truncated'),
                kind: BeamNoticeKind.info,
                title: l10n.airdropBatchesTruncatedTitle,
                message: l10n.airdropBatchesTruncatedMessage,
              ),
            ],
            if (_preparing) BeamWorking(l10n.airdropBatchesPreparingTakeBack),
            if (empty)
              BeamEmptyState(
                key: const ValueKey('batches-empty'),
                art: const BeamStickerImage(BeamSticker.hi, size: 120),
                title: l10n.airdropBatchesEmptyTitle,
                message: l10n.airdropBatchesEmptyMessage,
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
          label: empty
              ? l10n.airdropBatchesCreateFirstCta
              : l10n.airdropBatchesCreateNewCta,
          onPressed: _openCreate,
        ),
      );
    },
  );

  /// A v3 batch's state from the contract's counts.
  static BeamStatusText _v3Status(AppLocalizations l10n, AirdropV3Batch b) {
    if (b.unclaimed == 0) {
      if (b.cancelled == 0) {
        return (
          text: l10n.airdropStatusAllClaimed(b.redeemed),
          kind: BeamNoticeKind.success,
        );
      }
      return (
        text: l10n.airdropStatusClaimedTakenBack(b.redeemed, b.cancelled),
        kind: BeamNoticeKind.info,
      );
    }
    return (
      text: b.cancelled > 0
          ? l10n.airdropStatusClaimedWaitingTakenBack(
              b.redeemed,
              b.created,
              b.unclaimed,
              b.cancelled,
            )
          : l10n.airdropStatusClaimedWaiting(
              b.redeemed,
              b.created,
              b.unclaimed,
            ),
      kind: BeamNoticeKind.info,
    );
  }

  /// A saved v3 batch the contract does not list (yet): where its check is.
  static (BeamStatusText, String) _v3LocalStatus(
    AppLocalizations l10n,
    AirdropSavedBatch s,
  ) {
    if (s.txStatus == AirdropBatchTxStatus.failed && s.check == null) {
      return (
        (text: l10n.airdropStatusNotCreated, kind: BeamNoticeKind.danger),
        l10n.airdropBatchHoldsNothing,
      );
    }
    final check = s.check;
    if (check != null && !check.ok) {
      return (
        (text: l10n.airdropStatusDoNotShare, kind: BeamNoticeKind.danger),
        l10n.airdropBatchCheckFailedNote,
      );
    }
    if (check != null) {
      return (airdropBatchStatus(s, null), l10n.airdropBatchCheckedNote);
    }
    return (
      (text: l10n.airdropStatusBeingChecked, kind: BeamNoticeKind.warning),
      l10n.airdropBatchBeingCheckedNote,
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
    final l10n = context.l10n;
    String? note;
    BeamStatusText status;
    if (v != null) {
      status = _v3Status(l10n, v);
      if (s?.check != null && !s!.check!.ok) {
        status = (
          text: l10n.airdropStatusDoNotShare,
          kind: BeamNoticeKind.danger,
        );
        note = l10n.airdropBatchCheckFailedNote;
      }
    } else if (s != null && s.isV3 && c == null) {
      final (st, n) = _v3LocalStatus(l10n, s);
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
        ? _created(l10n, s.createdAt.toLocal())
        : l10n.airdropBatchCreatedAtBlock(
            '${v?.createdAtHeight ?? c!.createdAtHeight}',
          );
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
                ? l10n.airdropBatchCodeCount(count)
                : l10n.airdropBatchCodesTimes(
                    count,
                    _names.amount(assetId, each),
                  ),
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
              l10n.airdropBatchClaimFeesPaid,
              key: ValueKey('batch-gas-${v.id}'),
              style: STextStyles.label(context),
            ),
          ],
          if (s == null) ...[
            const SizedBox(height: 4),
            Text(
              unclaimed > 0
                  ? l10n.airdropBatchNotOnDevice
                  : l10n.airdropBatchNotOnDeviceNothingLeft,
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
                    text: l10n.airdropBatchShowCodes,
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
                        ? l10n.airdropBatchTakingBack
                        : l10n.airdropBatchTakeBack(unclaimed),
                    enabled: canSpend && !_preparing && _pending == null,
                    onTap: () => _cancel(contract, batchId),
                  ),
                if (settled)
                  CustomTextButton(
                    key: ValueKey('batch-forget-${s.localId}'),
                    text: l10n.airdropBatchForget,
                    onTap: () => _forget(s),
                  ),
              ],
            ),
          ],
          if (unclaimed > 0 && contract == AirdropContract.v3)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.airdropBatchTakeBackFee(
                  _beam(AirdropV3Fee.cancel(unclaimed)),
                ),
                key: ValueKey('batch-fee-v3-$batchId'),
                style: STextStyles.label(context),
              ),
            ),
        ],
      ),
    );
  }

  static String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');

  /// "Created Oct 13, 2026": the month is a case of the message (its
  /// short name is translated), the day and year are written as numbers.
  static String _created(AppLocalizations l10n, DateTime d) {
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    return l10n.airdropBatchCreatedOn(
      months[d.month - 1],
      '${d.day}',
      '${d.year}',
    );
  }
}
