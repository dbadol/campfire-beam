/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../l10n/l10n.dart';
import '../../wallet/impl/beam_wallet.dart';
import '../../wallet/wallet.dart';

/// The names of the wallets a Campfire backup (.swb) cannot hold: BEAM
/// wallets imported from their wallet.db have no recovery phrase, and
/// `SWB.createStackWalletJSON` leaves them out.
List<String> beamWalletsNotInBackup(Iterable<Wallet> wallets) => [
  for (final w in wallets)
    if (w is BeamWallet && w.isImportedFromFile) w.info.name,
];

/// What the backup screens tell the user about [names] once a backup is
/// saved; null when every wallet is in it.
String? beamBackupOmissionNotice(List<String> names) {
  if (names.isEmpty) return null;
  final list = names.map((n) => '"$n"').join(', ');
  return appL10n.walletBackupOmission(names.length, list);
}
