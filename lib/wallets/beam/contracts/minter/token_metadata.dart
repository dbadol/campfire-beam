/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../l10n/l10n.dart';

/// Which field of a [BeamTokenMetadata] is wrong, and how.
enum TokenMetadataField {
  name,
  shortName,
  unitName,
  nthUnitName,
  shortDescription,
  longDescription,
  color,
  siteUrl,
  pdfUrl,
  logoUrl,
  whole,
}

class TokenMetadataException implements Exception {
  const TokenMetadataException(this.field, this.message, {this.tickerMessage});

  final TokenMetadataField field;

  /// Plain words the UI can show next to the field, in the app's language.
  final String message;

  /// [message] with the short name called "Ticker", as the Create a token
  /// screen labels that field; null when [message] does not name it.
  final String? tickerMessage;

  /// [tickerMessage], or [message] when it does not name the short name.
  String get asTicker => tickerMessage ?? message;

  @override
  String toString() => 'TokenMetadataException(${field.name}): $message';
}

/// A Confidential Asset's metadata in BEAM's standard schema:
///
/// ```
/// STD:SCH_VER=1;N=<name>;SN=<short>;UN=<unit>;NTHUN=<smallest unit>;
/// NTH_RATIO=100000000[;OPT_SHORT_DESC=…][;OPT_LONG_DESC=…]
/// [;OPT_COLOR=#RRGGBB][;OPT_SITE_URL=…][;OPT_PDF_URL=…][;OPT_LOGO_URL=…]
/// ```
///
/// The rules are the BEAM wallet core's own (`WalletAssetMeta::Parse`,
/// `wallet/core/assets_utils.cpp` at `beam-7.5.14493`): a value that breaks
/// them makes every BEAM wallet show the asset as non-standard. There is
/// no escaping in this format, so a character that would corrupt it is
/// refused, never silently dropped:
///
/// * `;` separates fields, so no value may contain one;
/// * `N`, `SN`, `UN` and `NTHUN` may only hold ASCII letters, digits,
///   space and `. , - _`, and none may be empty;
/// * `SN` is at most 6 characters (`MAX_SHORT_NAME_LEN`). LightWallet
///   allowed 16, which made such assets non-standard;
/// * `OPT_SHORT_DESC` is at most 128 bytes and `OPT_LONG_DESC` 1,024;
/// * `OPT_COLOR` is `#RGB` or `#RRGGBB`.
///
/// The text also travels inside one quoted shader argument, whose parser
/// ends the value at a `"` and treats `\` as an escape, so `"` and `\` are
/// refused everywhere, as are control characters.
///
/// `NTH_RATIO` is not read by the core, and every BEAM wallet shows assets
/// on the groth scale (8 decimals), so it is always written as 10^8 to
/// match what wallets display; offering other "decimals" would only make
/// the label disagree with every balance. `OPT_LOGO_URL` is LightWallet's
/// key for an icon; the core ignores unknown keys.
@immutable
class BeamTokenMetadata {
  BeamTokenMetadata({
    required this.name,
    required this.shortName,
    required this.unitName,
    this.nthUnitName = 'groth',
    this.shortDescription,
    this.longDescription,
    this.color,
    this.siteUrl,
    this.pdfUrl,
    this.logoUrl,
  }) {
    _validate();
  }

  static const maxNameLength = 64;
  static const maxShortNameLength = 6;
  static const maxUnitNameLength = 8;
  static const maxNthUnitNameLength = 16;
  static const maxShortDescriptionBytes = 128;
  static const maxLongDescriptionBytes = 1024;
  static const maxUrlLength = 512;

  /// `Asset::Info::s_MetadataMaxSize`.
  static const maxEncodedBytes = 16 * 1024;

  /// Full name, `N`.
  final String name;

  /// Short name, `SN`: the ticker most BEAM wallets show. At most 6.
  final String shortName;

  /// Unit name, `UN`, e.g. `FOMO`.
  final String unitName;

  /// Name of the smallest unit, `NTHUN`, e.g. `groth`.
  final String nthUnitName;

  final String? shortDescription;
  final String? longDescription;

  /// `#RGB` or `#RRGGBB`.
  final String? color;
  final String? siteUrl;
  final String? pdfUrl;
  final String? logoUrl;

  /// Always 10^8: the groth scale every BEAM wallet displays.
  static final BigInt nthRatio = BigInt.from(100000000);

  /// The metadata string, exactly as it will be stored on chain.
  String encode() {
    final fields = <String, String?>{
      'SCH_VER': '1',
      'N': name,
      'SN': shortName,
      'UN': unitName,
      'NTHUN': nthUnitName,
      'NTH_RATIO': nthRatio.toString(),
      'OPT_SHORT_DESC': shortDescription,
      'OPT_LONG_DESC': longDescription,
      'OPT_COLOR': color,
      'OPT_SITE_URL': siteUrl,
      'OPT_PDF_URL': pdfUrl,
      'OPT_LOGO_URL': logoUrl,
    };
    final s =
        'STD:${[for (final f in fields.entries)
          if (f.value != null) '${f.key}=${f.value}'].join(';')}';
    if (utf8.encode(s).length > maxEncodedBytes) {
      throw TokenMetadataException(
        TokenMetadataField.whole,
        appL10n.minterMetaTooLongTotal,
      );
    }
    return s;
  }

  /// Total supply in the smallest unit for [wholeTokens] whole tokens.
  BigInt supplyOf(BigInt wholeTokens) => wholeTokens * nthRatio;

  static final _standardChars = RegExp(r'^[A-Za-z0-9 .,\-_]+$');
  static final _color = RegExp(r'^#(?:[0-9a-fA-F]{3}){1,2}$');
  static final _url = RegExp(r'^https?://[^\s;"\\]+$');
  static final _forbidden = RegExp(r'[;"\\\x00-\x1f\x7f]');

  void _validate() {
    _standard(name, maxNameLength, TokenMetadataField.name);
    _standard(shortName, maxShortNameLength, TokenMetadataField.shortName);
    _standard(unitName, maxUnitNameLength, TokenMetadataField.unitName);
    _standard(
      nthUnitName,
      maxNthUnitNameLength,
      TokenMetadataField.nthUnitName,
    );
    _text(
      shortDescription,
      maxShortDescriptionBytes,
      TokenMetadataField.shortDescription,
    );
    _text(
      longDescription,
      maxLongDescriptionBytes,
      TokenMetadataField.longDescription,
    );
    final c = color;
    if (c != null && !_color.hasMatch(c)) {
      throw TokenMetadataException(
        TokenMetadataField.color,
        appL10n.minterMetaColor,
      );
    }
    _link(siteUrl, TokenMetadataField.siteUrl);
    _link(pdfUrl, TokenMetadataField.pdfUrl);
    _link(logoUrl, TokenMetadataField.logoUrl);
  }

  /// [field] names itself in the messages (the `field` select of the
  /// minterMeta* messages); the short name also gets its "Ticker" wording.
  static void _standard(String v, int max, TokenMetadataField field) {
    final l = appL10n;
    TokenMetadataException fail(String Function(String field) say) =>
        TokenMetadataException(
          field,
          say(field.name),
          tickerMessage: field == TokenMetadataField.shortName
              ? say('ticker')
              : null,
        );
    if (v.isEmpty || v.trim() != v) throw fail(l.minterMetaEmpty);
    if (v.length > max) throw fail((f) => l.minterMetaTooLong(f, max));
    if (!_standardChars.hasMatch(v)) throw fail(l.minterMetaCharacters);
  }

  static void _text(String? v, int maxBytes, TokenMetadataField field) {
    if (v == null) return;
    if (v.isEmpty || _forbidden.hasMatch(v)) {
      throw TokenMetadataException(field, appL10n.minterMetaDescription);
    }
    if (utf8.encode(v).length > maxBytes) {
      throw TokenMetadataException(
        field,
        appL10n.minterMetaDescriptionTooLong(maxBytes),
      );
    }
  }

  static void _link(String? v, TokenMetadataField field) {
    if (v == null) return;
    if (v.length > maxUrlLength || !_url.hasMatch(v)) {
      throw TokenMetadataException(field, appL10n.minterMetaLink);
    }
  }

  /// Reads asset metadata the way the core does: the `STD:` prefix, then
  /// `;`-separated `key=value` pairs split at the first `=`. Chain metadata
  /// is untrusted (anyone can create an asset), so nothing here is
  /// validated beyond the split: display it as plain text only. Null when
  /// it is not `STD:` metadata.
  static Map<String, String>? parseFields(String metadata) {
    if (!metadata.startsWith('STD:')) return null;
    final out = <String, String>{};
    for (final token in metadata.substring(4).split(';')) {
      final eq = token.indexOf('=');
      if (token.isEmpty || eq < 0) continue;
      out[token.substring(0, eq)] = token.substring(eq + 1);
    }
    return out;
  }
}
