/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import 'airdrop_v3_constants.dart';

/// Airdrop v3 codes, seeds and keys, exactly as the pinned v3 app shader
/// derives them (`app.cpp` `ReadCodeSeed`, `SeedToSecret`, `SecretToKey`):
///
/// ```
/// normalised = code, a-z upper-cased, every byte not then A-Z/0-9 dropped
/// seed       = SHA-256("BeamAirdropV3:" || normalised)
/// x          = scalar from SHA-256("BeamAirdropV3.key" || cid || seed)
/// key        = x·G, written as BEAM writes a PubKey (X, then 1 if Y is odd)
/// ```
///
/// Only the key goes on chain. The wallet derives it here so that every
/// batch the shader builds is checked against keys made on this device, not
/// against what the shader says it made. Seeds and secrets are as secret as
/// the codes: they go only to the app shader, and nothing here logs one.
abstract final class AirdropV3Code {
  static const _codeTag = 'BeamAirdropV3:';
  static const _keyTag = 'BeamAirdropV3.key';

  /// The secp256k1 group order.
  static final _order = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16,
  );

  static final _curve = ECCurve_secp256k1();

  /// The code as the v3 shader normalises it, on UTF-8 bytes: `a`-`z`
  /// upper-cased, every byte that is not then `A`-`Z` or `0`-`9` dropped
  /// (non-ASCII letters too). Never cut: v3 refuses a code with more than
  /// [kAirdropV3MaxCodeLength] letters and digits, so such a code is not a
  /// v3 code ([isV3Code]).
  static String normalise(String input) {
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      var c = byte;
      if (c >= 0x61 && c <= 0x7a) c -= 0x20;
      if ((c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39)) {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }

  /// Whether v3 could hold [input] at all: 1 to 64 letters and digits once
  /// normalised.
  static bool isV3Code(String input) {
    final n = normalise(input).length;
    return n > 0 && n <= kAirdropV3MaxCodeLength;
  }

  /// [input] normalised, or [ArgumentError] when v3 could not hold it.
  static String normalisedOrThrow(String input) {
    final n = normalise(input);
    if (n.isEmpty || n.length > kAirdropV3MaxCodeLength) {
      throw ArgumentError.value(
        '<${n.length} letters and digits>',
        'code',
        'a v3 code has 1 to $kAirdropV3MaxCodeLength letters and digits',
      );
    }
    return n;
  }

  /// SHA-256("BeamAirdropV3:" || normalised code): what `create_batch`
  /// takes for each code. As secret as the code.
  static Uint8List seed(String code) => Uint8List.fromList(
    crypto.sha256
        .convert(ascii.encode('$_codeTag${normalisedOrThrow(code)}'))
        .bytes,
  );

  /// The voucher's secret as the shader derives it (`HashProcessor::
  /// get_Challenge`): SHA-256("BeamAirdropV3.key" || cid || seed), hashed on
  /// with its own output appended while that is zero or not below the
  /// group order. 32 bytes, big-endian.
  static Uint8List secret(List<int> seed, {String cid = kAirdropV3ContractId}) {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'a seed is 32 bytes');
    }
    var data = <int>[...ascii.encode(_keyTag), ..._hex(cid), ...seed];
    for (;;) {
      final h = crypto.sha256.convert(data).bytes;
      final v = _toBig(h);
      if (v != BigInt.zero && v < _order) return Uint8List.fromList(h);
      data = [...data, ...h];
    }
  }

  /// x·G as BEAM writes a PubKey: X (32 bytes) then `01` when Y is odd,
  /// else `00`; 66 lowercase hex characters.
  static String keyOfSecret(List<int> secret) {
    final p = (_curve.G * _toBig(secret))!;
    final enc = p.getEncoded(true); // 02/03 || X
    final x = enc.sublist(1);
    return '${_toHex(x)}${enc[0] == 3 ? '01' : '00'}';
  }

  /// The voucher key for [code] on [cid]: what `create_batch` puts on chain
  /// and `check_voucher` finds. The same code gives another key on any
  /// other deployment.
  static String voucherKey(String code, {String cid = kAirdropV3ContractId}) =>
      keyOfSecret(secret(seed(code), cid: cid));
}

/// The `m_vSig` hashes of the keys the v3 app shader signs with: the core
/// derives each key from the wallet's master key and
/// `SHA-256("bvm.m.key\0" || id)` (`DappWalletKeys.keyHash`). A built call
/// must be signed by exactly the key it should be.
abstract final class AirdropV3SigningKeys {
  static String _hash(List<int> id) => crypto.sha256.convert([
    ...ascii.encode('bvm.m.key'),
    0,
    ...id,
  ]).toString();

  /// `CreatorID{cid, 0}`: creates and takes back this wallet's batches.
  static String creator({String cid = kAirdropV3ContractId}) =>
      _hash([..._hex(cid), 0]);

  /// `ClaimerID{cid, 'C', voucher key}`: one receiving key per voucher, so a
  /// wallet's claims are not linked to each other on chain.
  static String claimer(
    String voucherKey, {
    String cid = kAirdropV3ContractId,
  }) => _hash([..._hex(cid), 0x43, ..._hex(voucherKey)]);
}

List<int> _hex(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

String _toHex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

BigInt _toBig(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}
