/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about Fuddle v9, the Wordle tournament contract. Source: the
/// Fuddle repository's `v9/README.md`, `v9/contract.h` and `v9/app.cpp` at
/// commit 8e86b3140.
///
/// The web wallet (`pwa/src/lib/shaders.js`, `pwa/src/lib/fuddle.js`) ships
/// the same app shader; its build refuses to run unless this file pins the
/// same SHA-256 and size. The app itself does not use Fuddle yet.
library;

import '../common/pinned_shader.dart';

/// The Fuddle v9 contract id. Not deployed yet: it is only known once the
/// owner deploys `v9/contract.wasm` (its constructor arguments carry the
/// owner, the answer service's key and the three dictionary roots). The web
/// wallet keeps its own copy in `pwa/src/lib/fuddle_id.js`.
const String? kFuddleContractId = null;

/// The shader ID of the v9 contract shader (`contract.wasm`, 31,406 bytes),
/// as computed by the v9 test harness and BEAM's `generate-sid`.
const kFuddleShaderId =
    '1d49c1e90b1aa05ec892bfe227a33b775f492c3341b94d387360bb244e1ec400';

/// The v9 app shader (`v9/app.wasm`).
const kFuddleAppShaderName = 'fuddle_app.wasm';
const kFuddleAppShaderSha256 =
    '52067c773a6f91b8eaadd892b133ccbf131f6df4a1c7d12b7305ff725f724e62';
const kFuddleAppShaderSize = 59518;

/// The pinned Fuddle v9 app shader, read from [source].
PinnedShader fuddleAppShader(ShaderSource source) => PinnedShader(
  name: kFuddleAppShaderName,
  sha256: kFuddleAppShaderSha256,
  size: kFuddleAppShaderSize,
  source: source,
);
