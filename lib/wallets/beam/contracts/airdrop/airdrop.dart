/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// The voucher Airdrop: claim tokens with a code, create batches of codes,
/// take them back. Pure logic, no UI.
///
/// Start at `BeamAirdrops`: new batches go to Airdrop v3, whose claims never
/// show the code to the network; codes of the old contract keep working
/// there. The app supplies a `VoucherCodeStore` on secure storage.
library;

export 'airdrop_args.dart';
export 'airdrop_constants.dart';
export 'airdrop_models.dart';
export 'airdrop_v3_args.dart';
export 'airdrop_v3_constants.dart';
export 'airdrop_v3_keys.dart';
export 'airdrop_v3_models.dart';
export 'beam_airdrop_service.dart';
export 'beam_airdrop_v3_service.dart';
export 'beam_airdrops.dart';
export 'voucher_blob.dart';
export 'voucher_code.dart';
export 'voucher_code_store.dart';
