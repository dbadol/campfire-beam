/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How the app writes amounts, in every language (the owner's rule):
//
//   * the decimal point is "." everywhere: never the device's region, never
//     the language's own comma, so "0.5 BEAM" means one thing on every
//     screen and the confirm screen reads like what was typed;
//   * thousands are grouped with "," — except in Russian, where "," is the
//     decimal comma and "1,000 BEAM" reads as one BEAM. There a narrow
//     no-break space (U+202F) groups them, as Russian typesetting does:
//     "1 000.5 BEAM".
//
// Only the language the app speaks decides (appL10n, kept in step by
// AppL10nBinding, which redraws every screen when it changes); the device
// locale never does. Fiat money ("1,19 EUR") is not an amount of a coin and
// keeps Campfire's own locale rules.

import 'package:intl/number_symbols.dart';
import 'package:intl/number_symbols_data.dart';

import 'l10n.dart';

/// Narrow no-break space: Russian's thousands separator.
const kAmountGroupRussian = ' ';

/// A locale name that is no real locale: amount formatting given it
/// (`Util.getSymbolsFor`, and through it Campfire's AmountFormatter, amount
/// fields and parsers) uses [amountNumberSymbols]: "." decimals and the app
/// language's grouping. BEAM amounts are formatted with it.
const kAppAmountLocale = 'x_campfire_amounts';

/// Whether [localeName] (an AppLocalizations.localeName) is Russian.
bool isRussianLocaleName(String localeName) {
  final language = localeName.split(RegExp('[_-]')).first.toLowerCase();
  return language == 'ru';
}

/// The separator between groups of three digits of an amount, in the
/// language the app speaks now: "," or, in Russian, [kAmountGroupRussian].
String get amountGroupSeparator =>
    isRussianLocaleName(appL10n.localeName) ? kAmountGroupRussian : ',';

/// [digits] (ASCII digits, no sign) grouped by thousands: "1234567" →
/// "1,234,567" ("1 234 567" in Russian). A leading "-" is kept.
String groupThousands(String digits, {String? separator}) {
  final sep = separator ?? amountGroupSeparator;
  final negative = digits.startsWith('-');
  final d = negative ? digits.substring(1) : digits;
  final out = StringBuffer(negative ? '-' : '');
  for (var i = 0; i < d.length; i++) {
    if (i > 0 && (d.length - i) % 3 == 0) out.write(sep);
    out.write(d[i]);
  }
  return out.toString();
}

/// [units] smallest units of a coin with [decimals] decimals, exactly:
/// every digit, trailing zeros dropped, thousands grouped, "." decimal.
/// 123456789012 → "1,234.56789012" ("1 234.56789012" in Russian); never
/// rounded (what is shown is what moves).
String formatAmountUnits(BigInt units, {int decimals = 8}) {
  final negative = units.isNegative;
  final abs = units.abs();
  final one = BigInt.from(10).pow(decimals);
  final whole = groupThousands((abs ~/ one).toString());
  final frac = decimals == 0
      ? ''
      : (abs % one)
            .toString()
            .padLeft(decimals, '0')
            .replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
}

/// Number symbols for [kAppAmountLocale]: English's, with the app
/// language's thousands separator. Not cached: the language can change
/// while the app runs.
NumberSymbols amountNumberSymbols() {
  final en = numberFormatSymbols['en'] as NumberSymbols;
  return NumberSymbols(
    NAME: kAppAmountLocale,
    DECIMAL_SEP: '.',
    GROUP_SEP: amountGroupSeparator,
    PERCENT: en.PERCENT,
    ZERO_DIGIT: en.ZERO_DIGIT,
    PLUS_SIGN: en.PLUS_SIGN,
    MINUS_SIGN: en.MINUS_SIGN,
    EXP_SYMBOL: en.EXP_SYMBOL,
    PERMILL: en.PERMILL,
    INFINITY: en.INFINITY,
    NAN: en.NAN,
    DECIMAL_PATTERN: en.DECIMAL_PATTERN,
    SCIENTIFIC_PATTERN: en.SCIENTIFIC_PATTERN,
    PERCENT_PATTERN: en.PERCENT_PATTERN,
    CURRENCY_PATTERN: en.CURRENCY_PATTERN,
    DEF_CURRENCY_CODE: en.DEF_CURRENCY_CODE,
  );
}
