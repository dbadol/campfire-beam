/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Buy BEAM screens need from the app, in one object, so they can
// be tested with fakes: the buy controller, the BEAM wallet the BEAM
// arrives in (its name, and a way to make it a new address), the user's
// own address on the coin's chain when Campfire has one, and where to send
// the user next (WBEAM on Ethereum, the delivered transaction,
// buybeam.my's support).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/isar/models/blockchain_data/transaction.dart'
    show TransactionType;
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';

/// BEAM this wallet received in one transaction.
@immutable
class BuyBeamReceipt {
  const BuyBeamReceipt({required this.groth, required this.address});

  /// BEAM (asset 0) received, in groth.
  final BigInt groth;

  /// The wallet's own address it was received at.
  final String address;

  /// What [tx], this wallet's record of a BEAM transaction, says it
  /// received: BEAM (not another asset), a payment (not a contract's
  /// payout), completed and in a block, at one of the wallet's own
  /// addresses; null otherwise.
  static BuyBeamReceipt? of(TransactionV2? tx) {
    if (tx == null || !tx.isBeamTransaction) return null;
    if (tx.type != TransactionType.incoming || tx.height == null) return null;
    if ((tx.beamAssetId ?? 0) != 0 || tx.contractAddress != null) return null;
    final mine = [
      for (final o in tx.outputs)
        if (o.walletOwns) o,
    ];
    if (mine.length != 1) return null;
    final address = mine.single.addresses.firstOrNull ?? '';
    final groth = BigInt.tryParse(mine.single.valueStringSats);
    if (address.isEmpty || groth == null || groth <= BigInt.zero) return null;
    return BuyBeamReceipt(groth: groth, address: address);
  }

  /// Received at [beamAddress] (an order's), and something was.
  bool isFor(String beamAddress) =>
      groth > BigInt.zero &&
      address.trim().toLowerCase() == beamAddress.trim().toLowerCase();
}

class BuyBeamDeps implements DexLayout {
  BuyBeamDeps({
    required this.controller,
    required this.walletId,
    required this.walletName,
    required this.newBeamAddress,
    this.refundAddressFor,
    this.receivedInWallet,
    this.onWantWbeam,
    this.onOpenTransaction,
    this.onOpenSupport,
    this.torOn,
    this.isDesktop,
  });

  final BuyBeamController controller;

  /// The BEAM wallet the BEAM arrives in.
  final String walletId;
  final String walletName;

  /// A new address of that wallet, one per buy (throws when the wallet
  /// cannot make one yet).
  final Future<String> Function() newBeamAddress;

  /// The user's own address on [BuyBeamAsset.blockchain], when Campfire
  /// has a wallet there (the Ethereum wallet for coins on Ethereum).
  final Future<String?> Function(BuyBeamAsset asset)? refundAddressFor;

  /// Opens WBEAM on Ethereum instead (the Ethereum wallet's swap); null
  /// hides the link. [ref] belongs to the screen asking, which stays open
  /// under what this opens.
  final void Function(BuildContext context, WidgetRef ref)? onWantWbeam;

  /// What this wallet received in the BEAM transaction [txId], once it is
  /// received and confirmed; null until then (buybeam.my having sent it is
  /// not the same: a regular address receives only while Campfire is open
  /// and accepts it). The screen says "arrived" only for BEAM received at
  /// the buy's own address, and shows that amount.
  final Future<BuyBeamReceipt?> Function(String txId)? receivedInWallet;

  /// Shows the BEAM transaction [txId] in this wallet (or the wallet's
  /// history while Campfire has not seen it yet).
  final Future<void> Function(BuildContext context, String? txId)?
  onOpenTransaction;

  /// Opens buybeam.my, where its support is.
  final VoidCallback? onOpenSupport;

  /// Whether Tor is on (the "no answer" message says what helps).
  final bool Function()? torOn;

  final bool? isDesktop;

  @override
  bool get desktop => isDesktop ?? Util.isDesktop;

  bool get tor => torOn?.call() ?? false;
}

/// Thrown by [BuyBeamDeps.newBeamAddress] while the BEAM wallet is not
/// running yet.
class BuyBeamWalletNotReady implements Exception {
  const BuyBeamWalletNotReady();
}
