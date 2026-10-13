/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: say which BEAM to buy, the private coin or the token on
//    Ethereum. Shown only where Campfire cannot tell (the desktop side
//    menu's Buy BEAM); a wallet's own Buy already knows.
// 2. No primary button: two equal cards, one tap each.
// 3. Clicks from app open: Buy BEAM (1) → a card (2) → its form.
//
// Exit-intent:
// * "What's the difference?" — each card says in one line where the coin
//   ends up and what pays for it.
// * "I don't have that wallet" — the card still works: it says so and
//   leads to creating the wallet, never to a dead end.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/wbeam_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../eth/uniswap/uniswap_widgets.dart';
import 'buy_beam_widgets.dart';

/// What the chooser needs: which wallets exist, and what each card opens.
class BuyChooserDeps implements DexLayout {
  BuyChooserDeps({
    required this.hasBeamWallet,
    required this.hasEthWallet,
    required this.onBeam,
    required this.onWbeam,
    this.isDesktop = false,
  });

  final bool hasBeamWallet;
  final bool hasEthWallet;

  /// Buy BEAM, or create a BEAM wallet first.
  final void Function(BuildContext context, WidgetRef ref) onBeam;

  /// The Ethereum wallet's swap to WBEAM, or create one first.
  final void Function(BuildContext context, WidgetRef ref) onWbeam;

  final bool isDesktop;

  @override
  bool get desktop => isDesktop;
}

class BuyChooserView extends ConsumerWidget {
  const BuyChooserView({super.key, required this.deps, this.embedded = false});

  final BuyChooserDeps deps;

  /// Inside the desktop side menu's page, which has its own title.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final beam = _ChoiceCard(
      key: const Key('buy-choose-beam'),
      icon: const BuyBeamIcon(size: 40),
      title: 'BEAM',
      text: l10n.buyChooserBeamText,
      action: deps.hasBeamWallet
          ? l10n.buyBeamButton
          : l10n.buyCreateBeamWalletFirst,
      onTap: () => deps.onBeam(context, ref),
    );
    final wbeam = _ChoiceCard(
      key: const Key('buy-choose-wbeam'),
      icon: const _WbeamOnEthereumIcon(size: 40),
      title: l10n.buyChooserWbeamTitle,
      text: l10n.buyChooserWbeamText,
      action: deps.hasEthWallet
          ? l10n.buyWbeamButton
          : l10n.buyCreateEthWalletFirst,
      onTap: () => deps.onWbeam(context, ref),
    );
    final heading = Text(
      l10n.buyChooserQuestion,
      key: const Key('buy-chooser-title'),
      style: embedded
          ? STextStyles.desktopTextMedium(context)
          : STextStyles.pageTitleH2(context),
    );
    if (embedded) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 16),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: beam),
                      const SizedBox(width: 16),
                      Expanded(child: wbeam),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return DexPage(
      deps: deps,
      title: l10n.buyChooserTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          heading,
          const SizedBox(height: 4),
          Text(
            l10n.buyChooserBothBeam,
            style: STextStyles.label(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 16),
          beam,
          const SizedBox(height: 12),
          wbeam,
        ],
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    required this.action,
    required this.onTap,
  });

  final Widget icon;
  final String title;
  final String text;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: RoundedWhiteContainer(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: STextStyles.titleBold12(context)
                          .copyWith(color: colors.textDark, fontSize: 18),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                text,
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      action,
                      style: STextStyles.smallMed14(context)
                          .copyWith(color: colors.accentColorBlue),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: colors.accentColorBlue,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// WBEAM's icon with a small Ethereum mark.
class _WbeamOnEthereumIcon extends StatelessWidget {
  const _WbeamOnEthereumIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      children: [
        WbeamIcon(size: size),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).extension<StackColors>()!.popupBG,
            ),
            child: UniTokenIcon(token: UniToken.eth, size: size * 0.4),
          ),
        ),
      ],
    ),
  );
}
