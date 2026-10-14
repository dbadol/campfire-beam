/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../../l10n/l10n.dart';
import '../contracts/airdrop/airdrop_constants.dart';
import '../contracts/bans/bans_constants.dart';
import '../contracts/burn/blackhole_constants.dart';
import '../contracts/dex/dex_constants.dart';
import '../contracts/minter/minter_constants.dart';

/// The Anon-Vault BANS keeps name payments in (`Vault-Anon`). BANS reports
/// it as `vault` from `role=manager,action=view_params`; recorded in
/// `test/beam/contracts/bans/fixtures/view_params.json` and
/// `the project notes` §2. A test checks the two
/// agree.
const String kVaultAnonCid = kBansVaultCid;

/// The DAO vault BANS and the minter pay their fees into (`dao-vault` in
/// BANS `view_params`, `cidDaoVault` in the minter's).
const String kDaoVaultCid =
    '0066b12078623df132b691001b25d7eb94b207b42c018020c9e58152e21ecd25';

/// The keys the core signs with on behalf of the wallet, and the contracts
/// Campfire's own modules use, as the dApp host must treat them.
///
/// A contract call signs with `m_vSig`: hashes of key ids chosen by the
/// app shader. The core derives the private key from the wallet's master
/// key and that hash (`bvm/invoke_data.cpp:184-187`), where the hash is
/// `SHA-256("bvm.m.key\0" ‖ id)` (`bvm2.cpp` `DeriveKeyPreimage`; the
/// literal is written with its NUL, `ecc_native.h:598`). The id is often
/// public — BANS uses its own contract id — so any dApp can ask the wallet
/// to sign with the key that owns the user's names. `sign_message` derives
/// its key the same way from `key_material` (`v7_0_api_handle.cpp:231-236`).
abstract final class DappWalletKeys {
  /// The `m_vSig` hash of key id [id].
  static String keyHash(List<int> id) => crypto.sha256.convert([
    ...ascii.encode('bvm.m.key'),
    0,
    ...id,
  ]).toString();

  /// Key hashes no dApp may sign with, and what each key holds: the case
  /// the refusals (`dappsRefusedReservedKey`, `dappsRefusedSignReservedKey`)
  /// select on, `names`, `airdrops` or `airdropContract`.
  ///
  /// * BANS `MyKeyID(cid)` (`bvm/Shaders/bans/app.cpp:239-245`): owns the
  ///   user's names and the name payments waiting in the Anon-Vault.
  /// * Airdrop `MyAccountID{cid, 0}` (`contracts/airdrop/app.cpp`): creates
  ///   and cancels the user's voucher batches. The hash appears verbatim in
  ///   the recorded `create_batch` raw_data (a test checks it).
  /// * Airdrop `OwnerAccountID{0xAD, 42}`: the airdrop contract's owner.
  static final Map<String, String> reserved = Map.unmodifiable({
    keyHash(_hex(kBansCid)): 'names',
    keyHash([..._hex(kAirdropContractId), 0]): 'airdrops',
    keyHash(const [0xAD, 42]): 'airdropContract',
  });

  /// What the reserved key [keyHashHex] holds ([reserved]), or null when it
  /// is not one.
  static String? reservedKind(String keyHashHex) =>
      reserved[keyHashHex.toLowerCase()];

  /// What the reserved key derived from [keyMaterial] holds ([reserved]),
  /// or null.
  static String? reservedKindOfMaterial(List<int> keyMaterial) =>
      reserved[keyHash(keyMaterial)];

  /// What the reserved key [keyHashHex] holds, in English words for logs
  /// and tests ("your airdrops"), or null when it is not one. Screens use
  /// the refusal messages, which select on [reservedKind].
  static String? reservedUse(String keyHashHex) =>
      _inWords[reservedKind(keyHashHex)];

  static const _inWords = {
    'names': 'your BEAM names',
    'airdrops': 'your airdrops',
    'airdropContract': 'the airdrop contract',
  };

  /// Contracts no dApp may call: they move the user's names and the name
  /// payments waiting for them, with the user's own key. Campfire's Names
  /// screen is the only way in.
  static const Set<String> forbiddenContracts = {kBansCid, kVaultAnonCid};

  static List<int> _hex(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// Names for the contracts Campfire knows, so the approval sheet can say
/// "Beam DEX" instead of a bare id. Anything else is "Unknown contract".
Map<String, String> get dappKnownContracts => {
  kDexContractId: 'Beam DEX',
  kBansCid: appL10n.dappsContractBans,
  kVaultAnonCid: appL10n.dappsContractBansVault,
  kDaoVaultCid: appL10n.dappsContractDaoVault,
  kAirdropContractId: appL10n.dappsContractAirdrops,
  kMinterContractId: appL10n.dappsContractMinter,
  kBlackHoleContractId: appL10n.dappsContractBlackHole,
};

/// The name of contract [cid], or null when Campfire does not know it.
String? dappContractName(String? cid) =>
    cid == null ? null : dappKnownContracts[cid.toLowerCase()];
