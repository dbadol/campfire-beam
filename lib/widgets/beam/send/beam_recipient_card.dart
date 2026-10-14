/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The card under the Send screen's recipient field.
//
// Spec:
//   1. Job: show, before anything is built, who a typed name pays — or why
//      it can't be paid — so a name is never resolved silently.
//   2. Primary CTA: none here (the screen's "Send"); "Try again" is a text
//      link on a failed lookup only.
//   3. Taps: 0 — it appears as the user types.
//
// Exit-intent: "is this the right person?" → owner key fingerprint
// and expiry; "why can't I send?" → every not-payable state says what to do;
// "is it stuck?" → a skeleton with the name being looked up.

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_recipient.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../rounded_white_container.dart';
import 'beam_send_widgets.dart';

/// "18 May 2028". Dates from heights are estimates (one block a minute).
String beamDate(DateTime d) => DateFormat('d MMM y').format(d.toLocal());

/// The resolution card for a name in the recipient field.
class BeamNameCard extends StatelessWidget {
  const BeamNameCard({
    super.key,
    required this.state,
    required this.onRetry,
    required this.typedText,
    this.onAcceptNewOwner,
    this.newOwnerAccepted = false,
  });

  final BansRecipientState state;
  final VoidCallback onRetry;

  /// "Pay the new owner": the name has another owner than when this wallet
  /// last paid it, and the person chooses to pay that one (audit D-1).
  final VoidCallback? onAcceptNewOwner;
  final bool newOwnerAccepted;

  /// What the user typed, to tell a mistyped address from a name.
  final String typedText;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return KeyedSubtree(
      key: const Key('beamNameCard'),
      child: switch (state) {
        BansRecipientResolving(:final name) => _Resolving(name),
        final BansRecipientPayable s => _Payable(
          s,
          onAcceptNewOwner: onAcceptNewOwner,
          newOwnerAccepted: newOwnerAccepted,
        ),
        BansRecipientNotPayable(:final name, :final status) => BeamNotice(
          kind: BeamNoticeKind.error,
          title: status == BansNameStatus.availableAgain
              ? l10n.sendNameExpiredTitle(name.display)
              : l10n.sendNameUnownedTitle(name.display),
          message: status == BansNameStatus.availableAgain
              ? l10n.sendNameExpiredMessage(name.display)
              : joinSentences([
                  l10n.sendNameCheckSpelling,
                  if (typedText.trim().length >= 26) l10n.sendNamePastedAddress,
                ], l10n),
        ),
        BansRecipientFailed(:final name, :final error) => BeamNotice(
          kind: BeamNoticeKind.error,
          title: l10n.sendNameCheckFailedTitle(name.display),
          message: _failure(error),
          action: CustomTextButton(text: l10n.commonTryAgain, onTap: onRetry),
        ),
      },
    );
  }

  static String _failure(Object e) {
    if (e is BansException) return e.message;
    if (e is BeamWalletException) return e.message;
    if (e is BeamConnectionException) return BeamWalletMessages.notOpen;
    return appL10n.sendNameLookupFailed;
  }
}

class _Resolving extends StatelessWidget {
  const _Resolving(this.name);

  final BansName name;

  @override
  Widget build(BuildContext context) {
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.sendNameLookingUp(name.display),
            style: STextStyles.itemSubtitle12(context),
          ),
          const SizedBox(height: 10),
          const BeamSkeletonLine(width: 180),
          const SizedBox(height: 8),
          const BeamSkeletonLine(width: 240),
        ],
      ),
    );
  }
}

class _Payable extends StatelessWidget {
  const _Payable(
    this.s, {
    required this.onAcceptNewOwner,
    required this.newOwnerAccepted,
  });

  final BansRecipientPayable s;
  final VoidCallback? onAcceptNewOwner;
  final bool newOwnerAccepted;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final r = s.resolution;
    final expires = r.expiresAt;
    final holdEnds = r.holdEndsAt;
    final listed = r.domain?.isListed ?? false;
    final l10n = context.l10n;
    final owner = BansKey.checkCode(s.ownerKey);
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset(
                Assets.svg.checkCircle,
                width: 16,
                height: 16,
                colorFilter: ColorFilter.mode(
                  c.accentColorGreen,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.name.display,
                  style: STextStyles.titleBold12(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                l10n.sendNameRegistered,
                style: STextStyles.label(context)
                    .copyWith(color: c.accentColorGreen),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            !s.onHold && expires != null
                ? l10n.sendNameOwnerKeyUntil(owner, beamDate(expires))
                : l10n.sendNameOwnerKey(owner),
            key: const Key('beamNameCardOwner'),
            style: STextStyles.label(context),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.sendNameAnonymousCard,
            style: STextStyles.label(context).copyWith(color: c.textDark3),
          ),
          if (s.ownerChangedSincePaid) ...[
            const SizedBox(height: 8),
            BeamNotice(
              key: const Key('beamNameNewOwner'),
              kind: newOwnerAccepted
                  ? BeamNoticeKind.info
                  : BeamNoticeKind.warning,
              title: s.paidOwnerUnknown
                  ? (newOwnerAccepted
                        ? l10n.sendNameOwnerCheckedTitle
                        : l10n.sendNameCheckOwnerTitle)
                  : (newOwnerAccepted
                        ? l10n.sendNameNewOwnerChosenTitle
                        : l10n.sendNameNewOwnerTitle),
              message: s.paidOwnerUnknown
                  ? l10n.sendNameOwnerUnknownMessage(owner)
                  : l10n.sendNameOwnerChangedMessage(
                      BansKey.checkCode(s.paidOwnerKey!),
                      owner,
                    ),
              action: newOwnerAccepted || onAcceptNewOwner == null
                  ? null
                  : CustomTextButton(
                      key: const Key('beamNameAcceptNewOwner'),
                      text: s.paidOwnerUnknown
                          ? l10n.sendNamePayThisOwner
                          : l10n.sendNamePayNewOwner,
                      onTap: onAcceptNewOwner!,
                    ),
            ),
          ],
          if (s.onHold) ...[
            const SizedBox(height: 8),
            BeamNotice(
              kind: BeamNoticeKind.warning,
              title: l10n.sendNameLapsedTitle,
              message: joinSentences([
                expires == null
                    ? l10n.sendNameLapsedExpired
                    : l10n.sendNameLapsedExpiredOn(beamDate(expires)),
                holdEnds == null
                    ? l10n.sendNameLapsedRenew
                    : l10n.sendNameLapsedRenewUntil(beamDate(holdEnds)),
                l10n.sendNameLapsedMayPass,
              ], l10n),
            ),
          ],
          if (listed && !s.onHold) ...[
            const SizedBox(height: 8),
            BeamNotice(
              kind: BeamNoticeKind.warning,
              message: l10n.sendNameListedForSale,
            ),
          ],
          if (s.maybeStale) ...[
            const SizedBox(height: 8),
            BeamNotice(
              kind: BeamNoticeKind.warning,
              message: l10n.sendNameMaybeStale,
            ),
          ],
        ],
      ),
    );
  }
}

/// The note under an address in the recipient field: its type in plain
/// words, or why it can't be paid yet.
class BeamAddressNote extends StatelessWidget {
  const BeamAddressNote({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => BeamNotice(
    key: const Key('beamAddressNote'),
    kind: BeamNoticeKind.info,
    title: title,
    message: note,
  );
}
