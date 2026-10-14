/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: find a buy of this wallet and see where it is.
// 2. Primary action: tap the buy (its deposit address and steps open).
// 3. Taps from app open: wallet → Buy (1) → "Your buys" (2) → the buy (3).
//
// Exit-intent: "Where is my BEAM?" — each buy says where it is in
// words, the unfinished ones first by date. "I have none" — says so, with
// the way back to buying.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_order_view.dart';
import 'buy_beam_routes.dart';
import 'buy_beam_widgets.dart';

class BuyBeamOrdersView extends StatefulWidget {
  const BuyBeamOrdersView({super.key, required this.deps});

  final BuyBeamDeps deps;

  static Future<void> show(BuildContext context, BuyBeamDeps deps) =>
      showBuyBeamPage<void>(
        context,
        deps,
        (_) => BuyBeamOrdersView(deps: deps),
      );

  @override
  State<BuyBeamOrdersView> createState() => _BuyBeamOrdersViewState();
}

class _BuyBeamOrdersViewState extends State<BuyBeamOrdersView> {
  BuyBeamController get c => widget.deps.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    unawaited(c.resumeAll());
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = c.orders(beamWalletId: widget.deps.walletId);
    final open = all.where((o) => o.isOpen).toList();
    final ended = all.where((o) => !o.isOpen).toList();
    final l10n = context.l10n;
    return DexPage(
      deps: widget.deps,
      title: l10n.buyYourBuys,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (all.isEmpty)
            DexNotice(
              key: const Key('buy-orders-empty'),
              title: l10n.buyNoBuysTitle,
              detail: l10n.buyNoBuysDetail(widget.deps.walletName),
              actionLabel: l10n.buyBeamButton,
              onAction: () => Navigator.of(context).pop(),
            ),
          for (final o in [...open, ...ended]) ...[
            BuyOrderCard(
              order: o,
              onTap: () => unawaited(
                BuyBeamOrderView.show(context, widget.deps, o.depositAddress),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
