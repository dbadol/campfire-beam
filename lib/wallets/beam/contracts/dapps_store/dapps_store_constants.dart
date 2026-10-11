/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about BEAM's DApp Store contract, which lists publishers and
/// their dApps (`BeamMW/beam-dapps-store`, `shaders/dapps_store_contract.*`,
/// commit `53760f0c`; the app shader ships in `BeamMW/beam-ui`).
library;

import '../common/pinned_shader.dart';

/// The store on mainnet: an Upgradable2 wrapper (explorer kind
/// `Wrapper: upgradable2`, subtype `95ad6aff…e33c`) around the store's code.
/// One admin key can replace that code with no delay, so what the store says
/// is read, never trusted: a package must match its own on-chain hash.
const kDappsStoreContractId =
    'e2d24b686e8d31a0fe97eade9cd23281e7059b74b5757bdb96c820ef9e2af41c';

/// `ui/dapps_store_app.wasm` in `BeamMW/beam-ui` at tag
/// `beam-7.5.14493.5867` (commit `2f36c21e`), byte-identical to
/// `shaders/dapps_store_app.wasm` in `BeamMW/beam-dapps-store`.
const kDappsStoreAppShaderName = 'dapps_store_app.wasm';
const kDappsStoreAppShaderSha256 =
    '14d9d11bb0f6f66d290e7fd3d2949599867b3446e1bf3432544d87109476b95b';
const kDappsStoreAppShaderSize = 9788;

/// The pinned DApp Store app shader, read from [source].
PinnedShader dappsStoreAppShader(ShaderSource source) => PinnedShader(
  name: kDappsStoreAppShaderName,
  sha256: kDappsStoreAppShaderSha256,
  size: kDappsStoreAppShaderSize,
  source: source,
);
