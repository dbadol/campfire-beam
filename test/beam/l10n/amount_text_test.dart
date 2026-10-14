/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How amounts are written (lib/l10n/amount_text.dart): "." decimals in
// every language, whatever the device's region; thousands grouped with ","
// except in Russian, where "1,000 BEAM" reads as one BEAM and a narrow
// no-break space groups them. Every BEAM amount formatter, in English
// (unchanged) and in Russian; Campfire's own amount formatter for BEAM on a
// German or Russian device; and amounts typed with the app's rules.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/l10n/amount_text.dart';
import 'package:stackwallet/l10n/l10n.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_words.dart';
import 'package:stackwallet/pages/bridge/bridge_format.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_format.dart';
import 'package:stackwallet/providers/global/locale_provider.dart';
import 'package:stackwallet/services/locale_service.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_text.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_messages.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_units.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_format.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_text.dart';

/// Narrow no-break space.
const _n = ' ';

/// 1,234,567.89 BEAM in groth.
final BigInt _big = BigInt.parse('123456789000000');

/// 1,000.5 BEAM in groth.
final BigInt _thousand = BigInt.from(100050000000);

void _russian() => debugSetAppL10n(lookupAppLocalizations(const Locale('ru')));

class _Device extends LocaleService {
  _Device(this._name);

  final String _name;

  @override
  String get locale => _name;
}

final _fomo = BeamAssetContract(
  address: BeamAssetContract.addressFor(174),
  assetId: 174,
  name: 'FOMO',
  symbol: 'FOMO',
  decimals: 8,
  verified: true,
  metadataKnown: true,
);

/// Every BEAM amount formatter, given 1,234,567.89 (and 1,000.5) BEAM.
Map<String, String> _all() => {
  'formatAmountUnits': formatAmountUnits(_big),
  'BeamSendFormat.beam': BeamSendFormat.beam(_big),
  'dappFormatAmount': dappFormatAmount(_big),
  'BeamUnits.format': BeamUnits.format(_big),
  'BeamUnits.plain': BeamUnits.plain(_big),
  'NamesFormat.exact': NamesFormat.exact(_big),
  'BridgeFormat.coin': BridgeFormat.coin(_big, 8, 'BEAM'),
  'BridgeFormat.plain': BridgeFormat.plain(_big, 8),
  'BeamHomeText.amount': BeamHomeText.amount(_big),
  'DexFormat.exact': DexFormat.exact(_big),
  'DexFormat.plain': DexFormat.plain(_big),
  'DexFormat.compact': DexFormat.compact(_thousand),
  'UniFormat.exact': UniFormat.exact(_big, 8),
  'BuyBeamWords.beam': BuyBeamWords.beam(_thousand),
  'BeamAssetText.exact de_DE': BeamAssetText.exact(
    Amount(rawValue: _big, fractionDigits: 8),
    _fomo,
    locale: 'de_DE',
  ),
  'BeamAssetText.rounded ru_RU': BeamAssetText.rounded(
    Amount(rawValue: _big, fractionDigits: 8),
    _fomo,
    locale: 'ru_RU',
  ),
  'BeamAssetText.beam': BeamAssetText.beam(_thousand, locale: 'de_DE'),
  'BeamSyncMessages.number': BeamSyncMessages.number(4073500),
};

void main() {
  tearDown(debugResetAppL10n);

  test('English: every BEAM amount formatter writes what it wrote before', () {
    expect(_all(), {
      'formatAmountUnits': '1,234,567.89',
      'BeamSendFormat.beam': '1,234,567.89 BEAM',
      'dappFormatAmount': '1,234,567.89',
      'BeamUnits.format': '1,234,567.89',
      'BeamUnits.plain': '1234567.89',
      'NamesFormat.exact': '1,234,567.89',
      'BridgeFormat.coin': '1,234,567.89 BEAM',
      'BridgeFormat.plain': '1234567.89',
      'BeamHomeText.amount': '1,234,567.89',
      'DexFormat.exact': '1,234,567.89',
      'DexFormat.plain': '1234567.89',
      'DexFormat.compact': '1,000.5',
      'UniFormat.exact': '1,234,567.89',
      'BuyBeamWords.beam': '1,000.5 BEAM',
      'BeamAssetText.exact de_DE': '1,234,567.89 FOMO',
      'BeamAssetText.rounded ru_RU': '1,234,567.89 FOMO',
      'BeamAssetText.beam': '1,000.5 BEAM',
      'BeamSyncMessages.number': '4,073,500',
    });
  });

  test('Russian: thousands grouped with a narrow no-break space, the '
      'decimal point a dot; text for a field stays ungrouped', () {
    _russian();
    expect(appL10n.localeName, 'ru');
    expect(amountGroupSeparator, _n);
    expect(_all(), {
      'formatAmountUnits': '1${_n}234${_n}567.89',
      'BeamSendFormat.beam': '1${_n}234${_n}567.89 BEAM',
      'dappFormatAmount': '1${_n}234${_n}567.89',
      'BeamUnits.format': '1${_n}234${_n}567.89',
      'BeamUnits.plain': '1234567.89',
      'NamesFormat.exact': '1${_n}234${_n}567.89',
      'BridgeFormat.coin': '1${_n}234${_n}567.89 BEAM',
      'BridgeFormat.plain': '1234567.89',
      'BeamHomeText.amount': '1${_n}234${_n}567.89',
      'DexFormat.exact': '1${_n}234${_n}567.89',
      'DexFormat.plain': '1234567.89',
      'DexFormat.compact': '1${_n}000.5',
      'UniFormat.exact': '1${_n}234${_n}567.89',
      'BuyBeamWords.beam': '1${_n}000.5 BEAM',
      'BeamAssetText.exact de_DE': '1${_n}234${_n}567.89 FOMO',
      'BeamAssetText.rounded ru_RU': '1${_n}234${_n}567.89 FOMO',
      'BeamAssetText.beam': '1${_n}000.5 BEAM',
      'BeamSyncMessages.number': '4${_n}073${_n}500',
    });
    for (final v in _all().values) {
      expect(v, isNot(contains(',')), reason: v);
    }
  });

  test('Chinese and Japanese keep the comma', () {
    for (final code in ['zh', 'ja']) {
      debugSetAppL10n(lookupAppLocalizations(Locale(code)));
      expect(formatAmountUnits(_thousand), '1,000.5', reason: code);
    }
  });

  test('small amounts, signs and zero', () {
    _russian();
    expect(formatAmountUnits(BigInt.zero), '0');
    expect(formatAmountUnits(BigInt.from(10000000)), '0.1');
    expect(formatAmountUnits(BigInt.from(99900000000)), '999');
    expect(formatAmountUnits(-_thousand), '-1${_n}000.5');
    expect(formatAmountUnits(BigInt.from(1000500), decimals: 3), '1${_n}000.5');
    expect(groupThousands('-1234'), '-1${_n}234');
    expect(groupThousands('123'), '123');
  });

  group("Campfire's amount formatter for BEAM follows the app, never the "
      'device', () {
    String format(String device, CryptoCurrency coin) {
      final c = ProviderContainer(
        overrides: [
          localeServiceChangeNotifierProvider.overrideWithValue(
            _Device(device),
          ),
          // Campfire's defaults, without the app-wide Prefs (a container
          // disposing it would dispose the singleton).
          pAmountUnit.overrideWithProvider(
            (_) => Provider<AmountUnit>((_) => AmountUnit.normal),
          ),
          pMaxDecimals.overrideWithProvider((_) => Provider<int>((_) => 8)),
        ],
      );
      addTearDown(c.dispose);
      return c
          .read(pAmountFormatter(coin))
          .format(Amount(rawValue: _thousand, fractionDigits: 8));
    }

    final beam = Beam(CryptoCurrencyNetwork.main);

    test('a German device, English app: "1,000.50000000 BEAM"', () {
      expect(format('de_DE', beam), '1,000.50000000 BEAM');
    });

    test('a Russian device, English app: still a dot', () {
      expect(format('ru_RU', beam), '1,000.50000000 BEAM');
    });

    test('a Russian device, Russian app: "1 000.50000000 BEAM"', () {
      _russian();
      expect(format('ru_RU', beam), '1${_n}000.50000000 BEAM');
    });

    test('the device rules only what is not BEAM (Ethereum stays '
        "Campfire's)", () {
      final eth = Ethereum(CryptoCurrencyNetwork.main);
      expect(format('de_DE', eth), startsWith('1.000,5'));
    });
  });

  test('typed with the app\'s rules: a dot is the decimal point, a comma '
      'is never one', () {
    _russian();
    Amount? parse(String t) => Amount.tryParseEditableAmount(
      t,
      locale: kAppAmountLocale,
      fractionDigits: 8,
    );
    expect(parse('0.5')?.raw, BigInt.from(50000000));
    expect(parse('1000.5')?.raw, _thousand);
    expect(parse('0,5'), isNull);
    expect(parse('1,000'), isNull);
    expect(Util.getSymbolsFor(locale: kAppAmountLocale)!.DECIMAL_SEP, '.');
    // Not cached: the language can change while the app runs.
    expect(Util.getSymbolsFor(locale: kAppAmountLocale)!.GROUP_SEP, _n);
    debugResetAppL10n();
    expect(Util.getSymbolsFor(locale: kAppAmountLocale)!.GROUP_SEP, ',');
  });
}
