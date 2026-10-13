/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about the Airdrop v3 contract on mainnet. Source: the v3
/// contract's README and `app.cpp` (`~/Desktop/Beam/Airdrop/contracts/v3`),
/// checked on mainnet on 2026-10-13.
///
/// The web wallet (`pwa/src/lib/shaders.js`, `pwa/src/lib/airdrop_v3.js`)
/// ships the same app shader; its build refuses to run unless this file pins
/// the same SHA-256 and size. The app itself does not use v3 yet.
library;

import '../common/pinned_shader.dart';

/// Airdrop v3, deployed at height 4,078,350 from the contract shader whose
/// shader ID is [kAirdropV3ShaderId]. A claim is signed by a key derived from
/// the code, so the code never leaves the claimer's device. New codes are
/// made here only; the live contract (`kAirdropContractId`) keeps working for
/// the codes it already holds.
const kAirdropV3ContractId =
    'ac85d74b88aca36a8033f19b00b89df55e9c75a45c8a567c0ee158e9c11aeffe';

/// The shader ID of the v3 contract shader (`contract.wasm`). The app shader
/// below has it built in and refuses any contract not derived from it.
const kAirdropV3ShaderId =
    '3ed14be85bb30ae3755d9df426283612142265e978813d2ed9fabaf741515070';

/// The v3 app shader (`contracts/v3/app.wasm`).
const kAirdropV3AppShaderName = 'airdrop_v3_app.wasm';
const kAirdropV3AppShaderSha256 =
    'a61a8577bd450e33d01f1f0a788bea943b95836cb2b3e899353bc3b2c5ee69b8';
const kAirdropV3AppShaderSize = 20019;

/// The pinned Airdrop v3 app shader, read from [source].
PinnedShader airdropV3AppShader(ShaderSource source) => PinnedShader(
  name: kAirdropV3AppShaderName,
  sha256: kAirdropV3AppShaderSha256,
  size: kAirdropV3AppShaderSize,
  source: source,
);
