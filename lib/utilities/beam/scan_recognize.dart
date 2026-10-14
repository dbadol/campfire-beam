/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What a scanned QR code (or a pasted text) is, and so where it goes (the
// wallet home's Scan, BEAM Send's scan and paste). The Dart twin of the web
// wallet's pwa/src/lib/scan_recognize.js: the same kinds, fields and rules,
// checked against the same cases (test/beam/scan/scan_vectors.json).
//
//   beam         a BEAM address (hex, or base58 as BEAM's newer addresses
//                are), or a "beam:" link, with its amount when the link
//                carries a valid one                    -> Send (BEAM)
//   name         a BEAM name, "alice.beam" (or "beam:alice.beam")
//                                                       -> Send (BEAM)
//   eth          an Ethereum address, or an EIP-681 "ethereum:" link on
//                Ethereum mainnet (chain 1), with its value in wei when it
//                is a whole number, and the token of a "/transfer" link
//                                                       -> Send (Ethereum)
//   code         an airdrop code, ABCD-EFGH-JKLM-NPQR  -> Claim a code
//   unsupported  a link of another chain (chain), another coin (coin), or a
//                web link (link): said, never opened
//   unknown      anything else: shown as text, nothing done with it
//   empty
//
// Pure. Nothing is looked up or opened here: an address is checked again by
// the screen it goes to (BEAM's own validation, the Ethereum checksum), and
// a web link is never followed.
//
// Where Dart's string functions differ from JavaScript's (String.trim also
// strips U+0085, toLowerCase maps U+0130 to a plain "i", utf8.decode drops a
// leading byte order mark), the JavaScript behaviour is rebuilt below, and
// decodeURIComponent and URLSearchParams follow the web's rules, so both
// apps read every text the same way.

import 'dart:convert';

import 'package:meta/meta.dart';

/// What a scanned text is.
enum ScanKind { beam, name, eth, code, unsupported, unknown, empty }

/// Why an `unsupported` text is not opened: a payment on another chain, a
/// link for another coin, or a web link.
enum ScanUnsupportedReason { chain, coin, link }

/// The meaning of one scanned text. Only the fields of its [kind] are set,
/// as in the web wallet's objects ([toJson] gives that object).
@immutable
final class ScanRecognition {
  /// A kind with no fields (unknown, empty).
  const ScanRecognition._(this.kind)
    : address = null,
      amount = null,
      name = null,
      to = null,
      valueWei = null,
      token = null,
      code = null,
      reason = null;

  /// A BEAM address, with the amount in BEAM ("1.5") a link carried.
  const ScanRecognition.beam(String this.address, {this.amount})
    : kind = ScanKind.beam,
      name = null,
      to = null,
      valueWei = null,
      token = null,
      code = null,
      reason = null;

  /// A BEAM name, without ".beam" ("alice").
  const ScanRecognition.name(String this.name)
    : kind = ScanKind.name,
      address = null,
      amount = null,
      to = null,
      valueWei = null,
      token = null,
      code = null,
      reason = null;

  /// An Ethereum recipient, as scanned; [valueWei] a decimal string of wei;
  /// [token] the ERC-20 contract of a transfer link.
  const ScanRecognition.eth(String this.to, {this.valueWei, this.token})
    : kind = ScanKind.eth,
      address = null,
      amount = null,
      name = null,
      code = null,
      reason = null;

  /// An airdrop code, normalised (16 symbols, upper case, no dashes).
  const ScanRecognition.code(String this.code)
    : kind = ScanKind.code,
      address = null,
      amount = null,
      name = null,
      to = null,
      valueWei = null,
      token = null,
      reason = null;

  const ScanRecognition.unsupported(ScanUnsupportedReason this.reason)
    : kind = ScanKind.unsupported,
      address = null,
      amount = null,
      name = null,
      to = null,
      valueWei = null,
      token = null,
      code = null;

  static const unknown = ScanRecognition._(ScanKind.unknown);
  static const empty = ScanRecognition._(ScanKind.empty);

  final ScanKind kind;
  final String? address;

  /// Decimal BEAM, trailing zeros dropped ("1.5").
  final String? amount;
  final String? name;
  final String? to;

  /// Whole wei as a decimal string ("2014000000000000000").
  final String? valueWei;
  final String? token;
  final String? code;
  final ScanUnsupportedReason? reason;

  /// The web wallet's object for this result: `kind` and the fields set.
  Map<String, String> toJson() => {
    'kind': kind.name,
    'address': ?address,
    'amount': ?amount,
    'name': ?name,
    'to': ?to,
    'valueWei': ?valueWei,
    'token': ?token,
    'code': ?code,
    'reason': ?reason?.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ScanRecognition &&
      other.kind == kind &&
      other.address == address &&
      other.amount == amount &&
      other.name == name &&
      other.to == to &&
      other.valueWei == valueWei &&
      other.token == token &&
      other.code == code &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(
    kind,
    address,
    amount,
    name,
    to,
    valueWei,
    token,
    code,
    reason,
  );

  @override
  String toString() => 'ScanRecognition(${toJson()})';
}

final _hexAddr = RegExp(r'^[0-9a-fA-F]{60,72}$');
final _b58Addr = RegExp(r'^[1-9A-HJ-NP-Za-km-z]{40,1024}$');
final _ethAddr = RegExp(r'^0x[0-9a-fA-F]{40}$');
final _name = RegExp(r'^([a-z0-9_~-]{3,64})\.beam$');
const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _codeLength = 16;

final _space = RegExp(r'\s');
final _spaces = RegExp(r'\s+');
final _edgeSpaces = RegExp(r'^\s+|\s+$');
final _lineBreak = RegExp(r'[\r\n]');
final _scheme = RegExp(r'^([a-z][a-z0-9+.-]*):(.*)$', caseSensitive: false);
final _beamLink = RegExp(r'^(?:\/\/)?([^?#]*)(?:\?([^#]*))?');
final _ethLink = RegExp(
  r'^(?:pay-)?(0x[0-9a-fA-F]{40})(?:@(\d+))?(?:\/([A-Za-z]+))?(?:\?(.*))?$',
);
final _wei = RegExp(r'^(\d+)(?:\.(\d+))?(?:[eE](\d{1,3}))?$');
final _nonZeroDigit = RegExp('[1-9]');
final _codeShape = RegExp(r'^[A-Za-z0-9]{4}([\s-]?[A-Za-z0-9]{4}){3}$');
final _codeSeparators = RegExp(r'[\s-]+');

final _grothPerCoin = BigInt.from(100000000);
// Number.MAX_SAFE_INTEGER: tx_send takes a JSON number.
final _maxSafe = BigInt.parse('9007199254740991');
const _decimals = 8;

/// The scanned text's meaning (see the table at the top of this file).
ScanRecognition recognizeScan(String? raw) {
  final s = scanFirstLine(raw);
  if (s.isEmpty) return ScanRecognition.empty;
  final scheme = _scheme.firstMatch(s);
  if (scheme != null && !_ethAddr.hasMatch(s)) {
    final sch = scheme.group(1)!.toLowerCase();
    final rest = scheme.group(2)!;
    if (sch == 'beam') {
      final m = _beamLink.firstMatch(rest)!;
      final q = _FormQuery(m.group(2) ?? '');
      final a = q.get('amount') ?? q.get('tx_amount');
      String? amount;
      if (a != null) {
        final g = _parseGroth(a);
        if (g != null && g > BigInt.zero) amount = _formatBeam(g);
      }
      final path = m.group(1)!;
      return _beamOf(_jsTrim(_decodeUriComponent(path) ?? path), amount);
    }
    if (sch == 'ethereum') return _ethereumLink(rest);
    if (sch == 'http' || sch == 'https') {
      return const ScanRecognition.unsupported(ScanUnsupportedReason.link);
    }
    return const ScanRecognition.unsupported(ScanUnsupportedReason.coin);
  }
  if (_ethAddr.hasMatch(s)) return ScanRecognition.eth(s);
  final name = _nameOf(s);
  if (name != null) return ScanRecognition.name(name);
  // An airdrop code: 16 symbols of its alphabet, in groups of 4 or not.
  final compact = _asciiUpper(s.replaceAll(_codeSeparators, ''));
  if (compact.length == _codeLength &&
      compact.codeUnits.every(
        (u) => _codeAlphabet.contains(String.fromCharCode(u)),
      ) &&
      _codeShape.hasMatch(s)) {
    return ScanRecognition.code(compact);
  }
  if (_space.hasMatch(s)) return ScanRecognition.unknown;
  return _beamOf(s);
}

/// Whether [raw] is a `beam:` link (by its scheme, in any case), whatever
/// it points to: a payment request, which BEAM Send takes as a new payment.
bool scanIsBeamLink(String? raw) {
  final scheme = _scheme.firstMatch(scanFirstLine(raw));
  return scheme != null && scheme.group(1)!.toLowerCase() == 'beam';
}

/// The amount a `beam:` link asks for, exactly as written in it (`amount`,
/// or else `tx_amount`), or null when [raw] is no `beam:` link or asks for
/// none. [recognizeScan] keeps a link's amount only when it is a valid one
/// and the link is to an address; this tells an amount it refused
/// ("1,000") from no amount at all.
String? scanBeamLinkAmountText(String? raw) {
  final scheme = _scheme.firstMatch(scanFirstLine(raw));
  if (scheme == null || scheme.group(1)!.toLowerCase() != 'beam') return null;
  final q = _FormQuery(_beamLink.firstMatch(scheme.group(2)!)!.group(2) ?? '');
  return q.get('amount') ?? q.get('tx_amount');
}

/// The text a scan is read from: trimmed, and only its first line (a code
/// may carry a label on the next one).
String scanFirstLine(String? raw) {
  var s = _jsTrim(raw ?? '');
  final nl = s.indexOf(_lineBreak);
  if (nl >= 0) s = _jsTrim(s.substring(0, nl));
  return s;
}

/// A wei amount from EIP-681's number ("1000", "2.014e18"), as a decimal
/// string; null unless whole and positive.
String? scanWeiOf(String? text) {
  final m = _wei.firstMatch(text ?? '');
  if (m == null) return null;
  final frac = m.group(2) ?? '';
  final exp = int.parse(m.group(3) ?? '0');
  if (frac.length > exp && _nonZeroDigit.hasMatch(frac.substring(exp))) {
    return null;
  }
  final kept = frac.length > exp ? frac.substring(0, exp) : frac;
  final v = BigInt.parse('${m.group(1)}${kept.padRight(exp, '0')}');
  return v > BigInt.zero ? v.toString() : null;
}

String? _nameOf(String s) => _name.firstMatch(_jsLower(s))?.group(1);

ScanRecognition _beamOf(String addr, [String? amount]) {
  final a = addr.replaceAll(_spaces, '');
  final name = _nameOf(a);
  if (name != null) return ScanRecognition.name(name);
  if (!_hexAddr.hasMatch(a) && !_b58Addr.hasMatch(a)) {
    return ScanRecognition.unknown;
  }
  return ScanRecognition.beam(a, amount: amount);
}

// ethereum:<target>[@chain][/function]?params (EIP-681)
ScanRecognition _ethereumLink(String rest) {
  final m = _ethLink.firstMatch(rest);
  if (m == null) return ScanRecognition.unknown;
  final chain = m.group(2);
  if (chain != null && chain != '1') {
    return const ScanRecognition.unsupported(ScanUnsupportedReason.chain);
  }
  final q = _FormQuery(m.group(4) ?? '');
  final function = m.group(3);
  if (function != null) {
    if (function != 'transfer') return ScanRecognition.unknown;
    final to = q.get('address');
    return to != null && _ethAddr.hasMatch(to)
        ? ScanRecognition.eth(to, token: m.group(1))
        : ScanRecognition.unknown;
  }
  final wei = q.has('value') ? scanWeiOf(q.get('value')) : null;
  return ScanRecognition.eth(m.group(1)!, valueWei: wei);
}

// ------------------------------------------------------------- amounts
// The web wallet's lib/amount.js parseAmount and formatAmount (no grouping),
// except that a comma is refused: "amount=1,000" may mean a thousand (a
// thousands separator) or one (a decimal comma), a thousandfold apart, so a
// link's amount takes only a dot, as the DEX and Buy amounts do. The link's
// address still fills the form; the amount is left for the person to type.

/// Groth from what a person typed, or null where parseAmount throws (and
/// for any comma).
BigInt? _parseGroth(String input) {
  final s = input.replaceAll(_space, '');
  if (s.isEmpty || s.startsWith('-') || s.contains(',')) return null;
  if ('.'.allMatches(s).length > 1) return null;
  if (!RegExp(r'^\d*\.?\d*$').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
    return null;
  }
  final dot = s.indexOf('.');
  final whole = dot < 0 ? s : s.substring(0, dot);
  final frac = dot < 0 ? '' : s.substring(dot + 1);
  if (frac.length > _decimals) return null;
  final groth =
      BigInt.parse(whole.isEmpty ? '0' : whole) * _grothPerCoin +
      BigInt.parse('${frac}00000000'.substring(0, _decimals));
  return groth > _maxSafe ? null : groth;
}

/// "1.5": the whole BEAM, then the decimals without trailing zeros.
String _formatBeam(BigInt groth) {
  final whole = groth ~/ _grothPerCoin;
  final frac = (groth % _grothPerCoin)
      .toString()
      .padLeft(_decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return frac.isEmpty ? '$whole' : '$whole.$frac';
}

// ------------------------------------------------------ JavaScript's rules

/// String.prototype.trim: the same white space as a regular expression's
/// `\s` (Dart's trim also strips U+0085).
String _jsTrim(String s) => s.replaceAll(_edgeSpaces, '');

/// toLowerCase, as far as it can matter here: the only character outside
/// ASCII that JavaScript lowers into ASCII is the Kelvin sign. Every other
/// one stays outside ASCII, where no rule below can match it.
String _jsLower(String s) {
  final out = StringBuffer();
  for (final u in s.codeUnits) {
    out.writeCharCode(
      u >= 0x41 && u <= 0x5a
          ? u + 0x20
          : u == 0x212a
          ? 0x6b
          : u,
    );
  }
  return out.toString();
}

/// toUpperCase for a code: a text with any character outside ASCII fails
/// the code's shape anyway.
String _asciiUpper(String s) {
  final out = StringBuffer();
  for (final u in s.codeUnits) {
    out.writeCharCode(u >= 0x61 && u <= 0x7a ? u - 0x20 : u);
  }
  return out.toString();
}

/// UTF-8 bytes to text, keeping a leading byte order mark as JavaScript's
/// decoders do (Dart's drops it). Throws on malformed input unless
/// [allowMalformed].
String _utf8(List<int> bytes, {bool allowMalformed = false}) {
  final bom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  final text = utf8.decode(
    bom ? bytes.sublist(3) : bytes,
    allowMalformed: allowMalformed,
  );
  return bom ? '﻿$text' : text;
}

int _hexValue(int u) {
  if (u >= 0x30 && u <= 0x39) return u - 0x30;
  if (u >= 0x41 && u <= 0x46) return u - 0x41 + 10;
  if (u >= 0x61 && u <= 0x66) return u - 0x61 + 10;
  return -1;
}

/// decodeURIComponent, or null where it throws (a lone or malformed `%`
/// escape, or escapes that are not UTF-8).
String? _decodeUriComponent(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final u = s.codeUnitAt(i);
    if (u != 0x25) {
      out.writeCharCode(u);
      i++;
      continue;
    }
    final bytes = <int>[];
    while (i < s.length && s.codeUnitAt(i) == 0x25) {
      if (i + 2 >= s.length) return null;
      final hi = _hexValue(s.codeUnitAt(i + 1));
      final lo = _hexValue(s.codeUnitAt(i + 2));
      if (hi < 0 || lo < 0) return null;
      bytes.add(hi * 16 + lo);
      i += 3;
    }
    try {
      out.write(_utf8(bytes));
    } on FormatException {
      return null;
    }
  }
  return out.toString();
}

/// URLSearchParams over a query string (application/x-www-form-urlencoded:
/// `+` is a space, a bad `%` escape is kept as it is, the first value of a
/// repeated name wins).
class _FormQuery {
  _FormQuery(String query) {
    final q = query.startsWith('?') ? query.substring(1) : query;
    for (final part in q.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      _pairs.add((
        _decode(eq < 0 ? part : part.substring(0, eq)),
        _decode(eq < 0 ? '' : part.substring(eq + 1)),
      ));
    }
  }

  final _pairs = <(String, String)>[];

  String? get(String name) {
    for (final (n, v) in _pairs) {
      if (n == name) return v;
    }
    return null;
  }

  bool has(String name) => _pairs.any((p) => p.$1 == name);

  static String _decode(String s) {
    final input = utf8.encode(s.replaceAll('+', ' '));
    final bytes = <int>[];
    for (var i = 0; i < input.length; i++) {
      final b = input[i];
      if (b == 0x25 && i + 2 < input.length) {
        final hi = _hexValue(input[i + 1]);
        final lo = _hexValue(input[i + 2]);
        if (hi >= 0 && lo >= 0) {
          bytes.add(hi * 16 + lo);
          i += 2;
          continue;
        }
      }
      bytes.add(b);
    }
    return _utf8(bytes, allowMalformed: true);
  }
}
