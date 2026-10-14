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
/// the same SHA-256 and size.
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

/// The height the v3 contract was deployed at.
const kAirdropV3DeployHeight = 4078350;

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

/// Contract methods (`contract.h`, `AirdropV3::Method`). The app builds
/// these three and nothing else: no `SponsorGas` (7) and no owner method.
abstract final class AirdropV3Method {
  static const createBatch = 2;
  static const redeem = 3;
  static const cancelBatch = 4;
}

/// BVM charge units the v3 app shader declares (`app.cpp` `Charge`). They
/// set the network fee: 0.001 BEAM + max(0.01 BEAM, 10 groth per unit).
abstract final class AirdropV3Charge {
  /// A claim with `use_gas_pool=0` (the only kind the app builds).
  static const redeem = 200000;
  static const createBase = 115000;
  static const createPerVoucher = 30000;
  static const cancelBase = 35000;
  static const cancelPerVoucher = 28000;

  static int createBatch(int count) => createBase + createPerVoucher * count;
  static int cancelBatch(int count) => cancelBase + cancelPerVoucher * count;
}

/// Kernel comments the v3 app shader writes (the same words as the old
/// contract's, so history reads alike).
abstract final class AirdropV3KernelComment {
  static const createBatch = 'Create airdrop batch';
  static const redeem = 'Redeem airdrop voucher';
  static const cancelBatch = 'Cancel airdrop batch';
}

/// Vouchers in one v3 batch (`s_MaxVouchersPerBatch`). The app shader
/// declares its charge per voucher, so a batch of 100 is a valid
/// transaction (README "Measured charges").
const kAirdropV3MaxVouchersPerBatch = 100;

/// The claim fee a creator can prepay per code: 0.022 BEAM, the 0.021 BEAM
/// claim fee and 0.001 to spare. The app offers 0 or exactly this (README
/// "Checklist for wallets" 5); the shader refuses anything between 0 and
/// the claim fee.
final kAirdropV3GasPerVoucher = BigInt.from(2200000);

/// Confirmations a new batch waits for before its codes are checked and
/// shown as ready to share (README "Checklist for wallets" 11).
const kAirdropV3ConfirmationsBeforeCheck = 3;

/// The longest code v3 holds, in letters and digits after normalising.
/// Longer codes are refused, never cut (`ReadCodeSeed`).
const kAirdropV3MaxCodeLength = 64;

/// Fees, in groth, exactly as a standard wallet pays them for the charges
/// above (README "Fees" and "Checklist for wallets" 7). The service refuses
/// any built transaction whose fee differs, so these are also the fees the
/// confirmation screens show.
abstract final class AirdropV3Fee {
  static final _std = BigInt.from(100000);
  static final _bvmMin = BigInt.from(1000000);
  static final _u64Max = (BigInt.one << 64) - BigInt.one;
  static final _bps = BigInt.from(100);
  static final _bpsTotal = BigInt.from(10000);

  /// 0.001 BEAM + max(0.01 BEAM, 10 groth × [units]).
  static BigInt forUnits(int units) {
    final bvm = BigInt.from(10 * units);
    return _std + (bvm < _bvmMin ? _bvmMin : bvm);
  }

  /// 0.021 BEAM: every claim the app builds (no gas pool).
  static final claim = forUnits(AirdropV3Charge.redeem);

  /// 0.0155 BEAM for 1 code … 0.3125 BEAM for 100.
  static BigInt create(int count) =>
      forUnits(AirdropV3Charge.createBatch(count));

  /// 0.011 BEAM up to 2 codes … 0.2845 BEAM for 100.
  static BigInt cancel(int count) =>
      forUnits(AirdropV3Charge.cancelBatch(count));

  /// The 1% creation fee exactly as v3 computes it (`contract.h` `CalcFee`):
  /// floored, at least 1 groth, and without the old contract's wrap-around
  /// for any 64-bit total.
  static BigInt creationFee(BigInt total) {
    if (total.isNegative || total > _u64Max) {
      throw ArgumentError.value(total, 'total', 'not a 64-bit amount');
    }
    final fee =
        (total ~/ _bpsTotal) * _bps +
        (total.remainder(_bpsTotal) * _bps) ~/ _bpsTotal;
    return fee == BigInt.zero ? BigInt.one : fee;
  }
}
