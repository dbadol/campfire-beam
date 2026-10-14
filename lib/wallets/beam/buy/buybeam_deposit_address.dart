/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Whether a deposit address buybeam.my gives is an address of the coin's
// own chain, before it is shown to be paid (audit D-10). The address comes
// from buybeam.my's answer; a wrong one (another chain's, a typo, a page
// that is not buybeam.my's) must never reach the screen or the QR code,
// since a payment to it is lost.
//
// A line-for-line port of the web wallet's audited check
// (pwa/src/lib/buy/deposit_address.js): shapes, and checksums wherever the
// chain has one: EVM 0x addresses (EIP-55 when written in mixed case),
// Bitcoin-family bech32 / bech32m and base58check with each chain's
// version bytes, Tron's base58check, Solana's 32-byte base58 keys, XRP's
// own base58 with its checksum, and the shapes of the rest. A chain not
// known here gets only a loose check (printable, no spaces, 20 to 128
// characters, not a payment link), so a new coin buybeam.my adds still
// works. A payment link ("bitcoin:…?amount=…") is never an address: what
// it asks for is not what the order says, so it is refused on every chain.
//
// The decoders below follow @scure/base 2.x (the web's vendored copy)
// exactly where it matters for what is accepted: bech32's length limit,
// mixed case, separator and padding rules; base58's leading zeros.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:web3dart/web3dart.dart' show keccak256;

import '../../../utilities/coin_chains.dart';

/// Whether [address] can be an address on [blockchain] (buybeam.my's chain
/// id: 'btc', 'eth', 'tron'…).
bool isBuyBeamDepositAddressOf(String address, String blockchain) {
  // Printable, without spaces, of a sane length: every chain's address is.
  if (!_printable.hasMatch(address)) return false;
  if (_paymentLink(address, blockchain)) return false;
  if (kEvmChains.contains(blockchain)) return isEvmDepositAddress(address);
  final rule = _rules[blockchain];
  return rule != null ? rule(address) : address.length >= 20;
}

/// Whether rules for [blockchain] are known here (else only the loose
/// check applies).
bool buyBeamKnowsChain(String blockchain) =>
    kEvmChains.contains(blockchain) || _rules.containsKey(blockchain);

/// 0x and 40 hex digits; in mixed case, the EIP-55 checksum must hold.
bool isEvmDepositAddress(String a) {
  if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a)) return false;
  final body = a.substring(2);
  if (body == body.toLowerCase() || body == body.toUpperCase()) return true;
  final h = _hex(
    keccak256(Uint8List.fromList(utf8.encode(body.toLowerCase()))),
  );
  for (var i = 0; i < 40; i++) {
    final want = int.parse(h[i], radix: 16) >= 8
        ? body[i].toUpperCase()
        : body[i].toLowerCase();
    if (body[i] != want) return false;
  }
  return true;
}

// ------------------------------------------------------------------- rules

final _printable = RegExp(r'^[\x21-\x7e]{2,128}$');

/// A payment link rather than an address: a scheme ("bitcoin:",
/// "ethereum:") or a query ("?amount="). BCH's own "bitcoincash:" prefix is
/// part of its address.
bool _paymentLink(String address, String blockchain) {
  if (RegExp(r'[?&=#\\]').hasMatch(address)) return true;
  final scheme = RegExp(
    r'^([a-z][a-z0-9+.-]*):',
    caseSensitive: false,
  ).firstMatch(address);
  return scheme != null &&
      !(blockchain == 'bch' && scheme.group(1) == 'bitcoincash');
}

const _p2pkhP2sh = [
  [0x00],
  [0x05],
];

final Map<String, bool Function(String)> _rules = {
  'btc': (a) => _segwit('bc', a) || _base58With(a, _p2pkhP2sh),
  'bitcoin': (a) => _segwit('bc', a) || _base58With(a, _p2pkhP2sh),
  // Litecoin's old P2SH version (5, '3…') is Bitcoin's: only its own M…
  // and L… are taken.
  'ltc': (a) =>
      _segwit('ltc', a) ||
      _base58With(a, const [
        [0x30],
        [0x32],
      ]),
  'doge': (a) => _base58With(a, const [
    [0x1e],
    [0x16],
  ]),
  'dash': (a) => _base58With(a, const [
    [0x4c],
    [0x10],
  ]),
  'bch': (a) =>
      RegExp(r'^(bitcoincash:)?[qp][qpzry9x8gf2tvdw0s3jn54khce6mua7l]{41}$')
          .hasMatch(a) ||
      _base58With(a, _p2pkhP2sh),
  'zec': (a) =>
      _base58With(a, const [
        [0x1c, 0xb8],
        [0x1c, 0xbd],
      ], 22) ||
      _bechOf(_Bech.m, 'tex', a) ||
      _bechOf(_Bech.v0, 'zs', a) ||
      _bechOf(_Bech.m, 'u', a, 1000),
  'tron': (a) => _base58With(a, const [
    [0x41],
  ]),
  'sol': _svm,
  'fogo': _svm,
  'xrp': _xrp,
  'ton': (a) =>
      RegExp(r'^[A-Za-z0-9_-]{48}$').hasMatch(a) ||
      RegExp(r'^[A-Za-z0-9+/]{48}$').hasMatch(a) ||
      RegExp(r'^-?\d{1,3}:[0-9a-fA-F]{64}$').hasMatch(a),
  'stellar': (a) => RegExp(r'^G[A-Z2-7]{55}$').hasMatch(a),
  'cardano': (a) =>
      _bechOf(_Bech.v0, 'addr', a, 1000) ||
      RegExp(r'^(Ae2|DdzFF)[1-9A-HJ-NP-Za-km-z]{50,}$').hasMatch(a),
  'sui': (a) => RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(a),
  'aptos': (a) => RegExp(r'^0x[0-9a-fA-F]{1,64}$').hasMatch(a),
  'movement': (a) => RegExp(r'^0x[0-9a-fA-F]{1,64}$').hasMatch(a),
  'starknet': (a) => RegExp(r'^0x[0-9a-fA-F]{1,64}$').hasMatch(a),
  'near': (a) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(a) ||
      RegExp(
        r'^(?=.{2,64}$)[a-z0-9]+([-_][a-z0-9]+)*(\.[a-z0-9]+([-_][a-z0-9]+)*)*$',
      ).hasMatch(a),
  'aleo': (a) => _bechOf(_Bech.m, 'aleo', a),
  'hypercore': isEvmDepositAddress,
};

/// A segwit address of [hrp]: version 0 in bech32 (20 or 32 bytes),
/// versions 1-16 in bech32m.
bool _segwit(String hrp, String a) {
  final s = a.toLowerCase();
  if ((a != s && a != a.toUpperCase()) || !s.startsWith('${hrp}1')) {
    return false;
  }
  final v0 = _bechDecode(_Bech.v0, s);
  if (v0 != null &&
      v0.prefix == hrp &&
      v0.words.isNotEmpty &&
      v0.words[0] == 0) {
    final p = _fromWords(v0.words.sublist(1));
    return p != null && (p.length == 20 || p.length == 32);
  }
  final v1 = _bechDecode(_Bech.m, s);
  if (v1 != null &&
      v1.prefix == hrp &&
      v1.words.isNotEmpty &&
      v1.words[0] >= 1 &&
      v1.words[0] <= 16) {
    final p = _fromWords(v1.words.sublist(1));
    return p != null && p.length >= 2 && p.length <= 40;
  }
  return false;
}

/// base58check whose payload is [len] bytes starting with one of
/// [prefixes] (each a list of bytes).
bool _base58With(String a, List<List<int>> prefixes, [int len = 21]) {
  final p = _base58check(a);
  if (p == null || p.length != len) return false;
  return prefixes.any((pre) {
    for (var i = 0; i < pre.length; i++) {
      if (p[i] != pre[i]) return false;
    }
    return true;
  });
}

/// bech32 or bech32m ([kind]) with this prefix, up to [limit] characters
/// (Cardano's and Zcash's are long).
bool _bechOf(_Bech kind, String prefix, String a, [int limit = 90]) {
  final d = _bechDecode(kind, a, limit);
  return d != null && d.prefix == prefix;
}

/// XRP: base58 in Ripple's alphabet, version 0, 20 bytes, checksum sha256d.
bool _xrp(String a) {
  if (!RegExp(r'^r[1-9A-HJ-NP-Za-km-z]{24,34}$').hasMatch(a)) return false;
  final b = _base58Decode(a, _xrpAlphabet);
  if (b == null || b.length != 25 || b[0] != 0) return false;
  final sum = _sha256d(b.sublist(0, 21));
  for (var i = 0; i < 4; i++) {
    if (sum[i] != b[21 + i]) return false;
  }
  return true;
}

/// Solana-family: a 32-byte ed25519 key in base58.
bool _svm(String a) {
  if (!RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$').hasMatch(a)) return false;
  final b = _base58Decode(a, _btcAlphabet);
  return b != null && b.length == 32;
}

// ----------------------------------------------------------------- base58

const _btcAlphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const _xrpAlphabet =
    'rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz';

/// [s] in base58 of [alphabet]: each leading zero digit is a zero byte,
/// the rest the number's big-endian bytes. Null for a letter outside the
/// alphabet.
Uint8List? _base58Decode(String s, String alphabet) {
  final base = BigInt.from(58);
  var n = BigInt.zero;
  var zeros = 0;
  var leading = true;
  for (var i = 0; i < s.length; i++) {
    final d = alphabet.indexOf(s[i]);
    if (d < 0) return null;
    if (leading && d == 0) {
      zeros++;
    } else {
      leading = false;
    }
    n = n * base + BigInt.from(d);
  }
  final value = <int>[];
  while (n > BigInt.zero) {
    value.add((n & BigInt.from(0xff)).toInt());
    n = n >> 8;
  }
  return Uint8List.fromList([
    for (var i = 0; i < zeros; i++) 0,
    ...value.reversed,
  ]);
}

/// base58check (Bitcoin's alphabet, 4-byte double-SHA-256 checksum): the
/// payload, or null when the text or its checksum is wrong.
Uint8List? _base58check(String s) {
  final data = _base58Decode(s, _btcAlphabet);
  if (data == null || data.length < 4) return null;
  final payload = data.sublist(0, data.length - 4);
  final sum = _sha256d(payload);
  for (var i = 0; i < 4; i++) {
    if (sum[i] != data[data.length - 4 + i]) return null;
  }
  return payload;
}

List<int> _sha256d(List<int> b) =>
    crypto.sha256.convert(crypto.sha256.convert(b).bytes).bytes;

// ----------------------------------------------------------------- bech32

enum _Bech {
  v0(1),
  m(0x2bc830a3);

  const _Bech(this.constant);

  /// BIP 173 xors the checksum with 1; BIP 350 (bech32m) with 0x2bc830a3.
  final int constant;
}

const _bechAlphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _polymodGenerators = [
  0x3b6a57b2,
  0x26508e6d,
  0x1ea119fa,
  0x3d4233dd,
  0x2a1462b3,
];

int _polymod(int pre) {
  final b = pre >> 25;
  var chk = (pre & 0x1ffffff) << 5;
  for (var i = 0; i < _polymodGenerators.length; i++) {
    if (((b >> i) & 1) == 1) chk ^= _polymodGenerators[i];
  }
  return chk;
}

/// The six checksum letters of [prefix] and [words].
String _bechChecksum(String prefix, List<int> words, int constant) {
  var chk = 1;
  for (final c in prefix.codeUnits) {
    chk = _polymod(chk) ^ (c >> 5);
  }
  chk = _polymod(chk);
  for (final c in prefix.codeUnits) {
    chk = _polymod(chk) ^ (c & 0x1f);
  }
  for (final v in words) {
    chk = _polymod(chk) ^ v;
  }
  for (var i = 0; i < 6; i++) {
    chk = _polymod(chk);
  }
  chk ^= constant;
  return String.fromCharCodes([
    for (var i = 0; i < 6; i++)
      _bechAlphabet.codeUnitAt((chk >> (5 * (5 - i))) & 31),
  ]);
}

final _bechUpperPrintable = RegExp(r'^[\x21-\x60\x7b-\x7e]+$');

/// [str] as bech32 / bech32m ([kind]): its prefix (lower case) and data
/// words without the checksum; null wherever @scure/base's decode throws.
({String prefix, List<int> words})? _bechDecode(
  _Bech kind,
  String str, [
  int limit = 90,
]) {
  if (str.length < 8 || str.length > limit) return null;
  final lowered = str.toLowerCase();
  // Mixed case is not allowed: all lower, or all upper.
  if (str != lowered && !_bechUpperPrintable.hasMatch(str)) return null;
  final sep = lowered.lastIndexOf('1');
  if (sep <= 0) return null;
  final prefix = lowered.substring(0, sep);
  final data = lowered.substring(sep + 1);
  if (data.length < 6) return null;
  final digits = <int>[];
  for (var i = 0; i < data.length; i++) {
    final d = _bechAlphabet.indexOf(data[i]);
    if (d < 0) return null;
    digits.add(d);
  }
  final words = digits.sublist(0, digits.length - 6);
  if (!data.endsWith(_bechChecksum(prefix, words, kind.constant))) return null;
  return (prefix: prefix, words: words);
}

/// 5-bit words to bytes, in canonical form only (no whole spare word, no
/// non-zero padding bits); null otherwise.
Uint8List? _fromWords(List<int> words) {
  var carry = 0;
  var pos = 0;
  final out = <int>[];
  for (final w in words) {
    if (w < 0 || w >= 32) return null;
    carry = ((carry << 5) | w) & 0xffff;
    pos += 5;
    for (; pos >= 8; pos -= 8) {
      out.add((carry >> (pos - 8)) & 0xff);
    }
  }
  carry = (carry << (8 - pos)) & 0xff;
  if (pos >= 5) return null; // excess padding
  if (carry > 0) return null; // non-zero padding
  return Uint8List.fromList(out);
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
