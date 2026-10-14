/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM's colours as Campfire themes: asset_sources/default_themes/campfire/
// beam_{light,dark}.zip (scripts/beam/theme/beam_brand_theme.py), offered in
// Settings -> Colours (lib/pages/beam/colours/beam_colours_view.dart, choice
// logic in lib/themes/beam/beam_themes.dart). Campfire's light.zip stays the
// default. Every text colour reads at 4.5:1 or more on what it sits on; the
// history's arrows and the controls' marks at 3:1. The goldens render BEAM
// screens in the new themes only (existing goldens are Campfire's and do not
// change).
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens test/beam/theme
//   scripts/beam/host_test.sh --no-analyze test/beam/theme

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/beam/colours/beam_colours_view.dart';
import 'package:stackwallet/pages/wallet_view/transaction_views/tx_v2/transaction_v2_card.dart';
import 'package:stackwallet/providers/global/prefs_provider.dart';
import 'package:stackwallet/themes/beam/beam_themes.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/utilities/constants.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

import '../home_ui/home_ui_support.dart' as home;
import '../tx_ui/tx_ui_harness.dart' as tx;

const _dir = 'asset_sources/default_themes/campfire';

Archive _zip(String name) =>
    ZipDecoder().decodeBytes(File('$_dir/$name.zip').readAsBytesSync());

Map<String, dynamic> _json(String name) => Map<String, dynamic>.from(
  jsonDecode(
    utf8.decode(
      _zip(name).files.singleWhere((f) => f.name == 'theme.json').content
          as List<int>,
    ),
  ) as Map,
);

StackTheme _theme(String name) => StackTheme.fromJson(json: _json(name));

/// "0xAARRGGBB" -> Color.
Color _c(Object? s) => Color(int.parse((s! as String).substring(2), radix: 16));

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _lum(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

/// WCAG 2 contrast of two opaque colours.
double _ratio(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// [top] at [alpha] over [base].
Color _over(Color top, double alpha, Color base) => Color.from(
  alpha: 1,
  red: top.r * alpha + base.r * (1 - alpha),
  green: top.g * alpha + base.g * (1 - alpha),
  blue: top.b * alpha + base.b * (1 - alpha),
);

// Text colours, each on every surface text sits on: the page, cards and
// dialogs (popup_bg), text fields, and the settings / info rows.
const _texts = [
  'text_dark_one',
  'text_dark_two',
  'text_dark_three',
  'text_subtitle_one',
  'text_subtitle_two',
  'text_subtitle_three',
  'text_error',
  'text_restore',
  'text_confirm_total_amount',
  'text_selected_word_table_iterm',
  'accent_color_blue',
  'accent_color_green',
  'accent_color_red',
  'accent_color_yellow',
  'accent_color_orange',
  'accent_color_dark',
  'button_text_borderless',
  'button_text_primary_disabled', // Stack's desktop text styles draw text in it
  'custom_text_button_enabled_text',
  'info_item_label',
  'info_item_text',
  'radio_button_text_enabled',
  'radio_button_label_enabled',
  'checkbox_text_label',
  'text_field_active_text',
  'text_field_default_text',
  'text_field_active_label',
  'settings_item_level_two_active_text',
  'settings_item_level_two_active_sub',
  'token_summary_text_primary',
  'token_summary_text_secondary',
];
const _surfaces = [
  'background',
  'popup_bg',
  'text_field_default_bg',
  'info_item_bg',
  'settings_item_level_two_active_bg',
  'token_summary_bg',
];
// Text on its own background.
const _pairs = [
  ['button_text_primary', 'button_back_primary'],
  ['button_text_secondary', 'button_back_secondary'],
  ['numpad_text_default', 'numpad_back_default'],
  ['number_text_default', 'number_back_default'],
  ['bottom_nav_text', 'bottom_nav_back'],
  ['bottom_nav_icon_icon_highlighted', 'bottom_nav_back'],
  ['snack_bar_text_success', 'snack_bar_back_success'],
  ['snack_bar_text_error', 'snack_bar_back_error'],
  ['snack_bar_text_info', 'snack_bar_back_info'],
  ['warning_foreground', 'warning_background'],
  ['text_field_error_text', 'text_field_error_bg'],
  ['text_field_error_label', 'text_field_error_bg'],
  ['text_field_success_text', 'text_field_success_bg'],
  ['text_field_success_label', 'text_field_success_bg'],
  ['step_indicator_icon_text', 'step_indicator_bg_check'],
  ['step_indicator_icon_number', 'step_indicator_bg_number'],
  ['step_indicator_icon_inactive', 'step_indicator_bg_inactive'],
  ['eth_tag_text', 'eth_tag_bg'],
  ['eth_wallet_tag_text', 'eth_wallet_tag_bg'],
];
// Marks and controls, 3:1 (WCAG 1.4.11).
const _marks = [
  ['checkbox_icon_checked', 'checkbox_bg_checked'],
  ['switch_circle_on', 'switch_bg_on'],
  ['settings_icon_icon', 'settings_icon_back'],
  ['settings_icon_element', 'settings_icon_back_two'],
  ['switch_bg_on', 'popup_bg'],
  ['checkbox_bg_checked', 'popup_bg'],
  ['radio_button_icon_enabled', 'popup_bg'],
  ['step_indicator_bg_lines', 'background'],
  ['top_nav_icon_primary', 'background'],
  ['bottom_nav_icon_icon', 'bottom_nav_back'],
];

const _beam = [BeamThemes.light, BeamThemes.dark];

void main() {
  group('the themes', () {
    test("BEAM light and BEAM dark, at BeamThemes.version; Campfire's light "
        'theme is still the default', () {
      final light = _theme(BeamThemes.light);
      final dark = _theme(BeamThemes.dark);
      expect(
        [light.themeId, light.name, light.brightness, light.version],
        [BeamThemes.light, 'BEAM light', Brightness.light, BeamThemes.version],
      );
      expect(
        [dark.themeId, dark.name, dark.brightness, dark.version],
        [BeamThemes.dark, 'BEAM dark', Brightness.dark, BeamThemes.version],
      );
      final campfire = _theme('light');
      expect(campfire.themeId, BeamThemes.campfire);
      expect(
        StackColors.fromStackColorTheme(campfire).background,
        const Color(0xFFFFF1F1),
      );
    });

    test('stored as the app does at startup: every theme in the V3 image '
        'format, read back whole', () async {
      // theme.json's "version" also picks the image format. At 1, BEAM's themes
      // parsed as V1 and the app stopped at startup storing them (a black
      // window; found in the 1.3.0 trial build). Parsing alone never showed it:
      // the unset V1 fields only fail when Isar sizes the record.
      final mocked = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        await Isar.initializeIsarCore(download: true);
      } finally {
        HttpOverrides.global = mocked;
      }
      final dir = Directory.systemTemp.createTempSync('beam_theme_isar');
      final isar = await Isar.open(
        [StackThemeSchema],
        directory: dir.path,
        name: 'beam_theme_test',
      );
      addTearDown(() async {
        await isar.close(deleteFromDisk: true);
        dir.deleteSync(recursive: true);
      });
      for (final name in [BeamThemes.campfire, ..._beam]) {
        final theme = _theme(name);
        expect(theme.version, greaterThanOrEqualTo(3), reason: name);
        expect(theme.assetsV3, isNotNull, reason: name);
        expect([theme.assetsV1, theme.assetsV2], [null, null], reason: name);
        await isar.writeTxn(() => isar.stackThemes.put(theme));
        final back = await isar.stackThemes
            .where()
            .themeIdEqualTo(name)
            .findFirst();
        expect(
          back?.assetsV3?.coinIconsString,
          theme.assetsV3!.coinIconsString,
          reason: name,
        );
      }
    });

    test("Campfire's images: only theme.json and the history's icons differ, "
        'and theme.json names the same assets', () {
      final campfire = {
        for (final f in _zip('light').files) f.name: f.content as List<int>,
      };
      for (final name in _beam) {
        final files = {
          for (final f in _zip(name).files) f.name: f.content as List<int>,
        };
        expect(files.keys.toList(), campfire.keys.toList(), reason: name);
        final changed = [
          for (final k in files.keys)
            if (!_same(files[k]!, campfire[k]!)) k,
        ]..sort();
        expect(changed, [
          'assets/svg/tx-exchange-icon-failed.svg',
          'assets/svg/tx-exchange-icon-pending.svg',
          'assets/svg/tx-exchange-icon.svg',
          'assets/svg/tx-icon-receive-failed.svg',
          'assets/svg/tx-icon-receive-pending.svg',
          'assets/svg/tx-icon-receive.svg',
          'assets/svg/tx-icon-send-failed.svg',
          'assets/svg/tx-icon-send-pending.svg',
          'assets/svg/tx-icon-send.svg',
          'theme.json',
        ], reason: name);
        expect(_json(name)['assets'], _json('light')['assets'], reason: name);
        expect(
          (_json(name)['colors'] as Map).keys.toSet(),
          (_json('light')['colors'] as Map).keys.toSet(),
          reason: name,
        );
      }
    });

    test("BEAM's own colours: the navy page, the turquoise button with its "
        'marine label, the BEAM coin card', () {
      final dark = _json(BeamThemes.dark)['colors'] as Map;
      final light = _json(BeamThemes.light)['colors'] as Map;
      expect(dark['background'], '0xFF042548');
      expect(dark['popup_bg'], '0xFF103051');
      expect(dark['text_subtitle_one'], '0xFF8DA1AD');
      for (final c in [dark, light]) {
        expect(c['button_back_primary'], '0xFF00F6D2');
        expect(c['button_text_primary'], '0xFF032E49');
        expect((c['coin'] as Map)['beam'], '0xFF00F6D2');
        expect(c['text_favorite'], '0xFF032E49');
      }
      expect(light['text_dark_one'], '0xFF042548');
    });

    for (final name in _beam) {
      test('$name: every text colour reads at 4.5:1 on what it sits on, and '
          'marks at 3:1', () {
        final c = _json(name)['colors'] as Map;
        final low = <String>[];
        void check(String f, String b, double min) {
          final r = _ratio(_c(c[f]), _c(c[b]));
          if (r < min) low.add('$f on $b ${r.toStringAsFixed(2)}');
        }

        for (final f in _texts) {
          for (final b in _surfaces) {
            check(f, b, 4.5);
          }
        }
        for (final p in _pairs) {
          check(p[0], p[1], 4.5);
        }
        for (final p in _marks) {
          check(p[0], p[1], 3);
        }
        // The wallet's card: text on the BEAM coin colour, also at 85%.
        final coin = _c((c['coin'] as Map)['beam']);
        final onCoin = _c(c['text_favorite']);
        for (final a in [1.0, 0.85]) {
          final r = _ratio(_over(onCoin, a, coin), coin);
          if (r < 4.5) low.add('text_favorite@$a on coin.beam $r');
        }
        expect(low, isEmpty);
      });

      test("$name: the history's arrows in BEAM's received / sent / swap "
          'colours, at 3:1 on their discs', () {
        final c = _json(name)['colors'] as Map;
        final card = _c(c['popup_bg']);
        final svgs = {
          for (final f in _zip(name).files)
            if (f.name.startsWith('assets/svg/tx-'))
              f.name.split('/').last: utf8.decode(f.content as List<int>),
        };
        final want = name == BeamThemes.dark
            ? {'receive': '#0BCCF7', 'send': '#DA68F5', 'exchange': '#39FDF2'}
            : {'receive': '#04728B', 'send': '#AB0DCE', 'exchange': '#017972'};
        for (final e in svgs.entries) {
          final kind = e.key.contains('receive')
              ? 'receive'
              : e.key.contains('send')
              ? 'send'
              : 'exchange';
          expect(e.value, contains(want[kind]), reason: e.key);
          expect(e.value, contains('opacity="0.15"'), reason: e.key);
          expect(e.value, isNot(contains('#00A578')), reason: e.key);
          final arrow = Color(
            int.parse('FF${want[kind]!.substring(1)}', radix: 16),
          );
          expect(
            _ratio(arrow, _over(arrow, 0.15, card)),
            greaterThanOrEqualTo(3),
            reason: e.key,
          );
        }
      });
    }

    test("Settings -> Colours' swatches are the themes' own colours", () {
      for (final id in [BeamThemes.campfire, ...BeamThemes.ids]) {
        final c = _json(id)['colors'] as Map;
        expect(kBeamColoursSwatches[id]!.page, _c(c['background']), reason: id);
        expect(
          kBeamColoursSwatches[id]!.button,
          _c(c['button_back_primary']),
          reason: id,
        );
      }
    });
  });

  group('Settings -> Colours', () {
    const stock = (
      followDevice: false,
      themeId: 'light',
      lightId: 'light',
      darkId: 'dark',
    );

    test("Campfire's unless one of BEAM's is chosen", () {
      expect(BeamColours.from(stock), BeamColours.campfire);
      expect(
        BeamColours.from((
          followDevice: true,
          themeId: 'light',
          lightId: 'light',
          darkId: 'dark',
        )),
        BeamColours.campfire,
        reason: "following the device with Campfire's ids is still Campfire",
      );
      expect(
        BeamColours.from((
          followDevice: false,
          themeId: 'ocean_breeze',
          lightId: 'light',
          darkId: 'dark',
        )),
        BeamColours.campfire,
      );
      for (final c in BeamColours.values) {
        expect(BeamColours.from(c.applyTo(stock)), c, reason: c.name);
      }
    });

    test('each choice: what is saved, and what is on screen on a light and '
        'a dark device', () {
      String on(BeamColours c, Brightness b) =>
          BeamColours.showing(c.applyTo(stock), b);
      expect(on(BeamColours.campfire, Brightness.dark), 'light');
      expect(on(BeamColours.beamLight, Brightness.dark), BeamThemes.light);
      expect(on(BeamColours.beamDark, Brightness.light), BeamThemes.dark);
      expect(on(BeamColours.beamDevice, Brightness.light), BeamThemes.light);
      expect(on(BeamColours.beamDevice, Brightness.dark), BeamThemes.dark);
      // Campfire again after following the device: it stops following it
      // (Campfire has no dark theme).
      final back = BeamColours.campfire.applyTo(
        BeamColours.beamDevice.applyTo(stock),
      );
      expect(back.followDevice, isFalse);
      expect(back.themeId, 'light');
    });

    test('offered in the Campfire build, which has BEAM and no Stack Wallet '
        'theme choice', () {
      expect(BeamThemes.offered, isTrue);
    });
  });

  group('goldens', () {
    Future<void> fonts(WidgetTester tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      await tester.runAsync(() async {
        for (final w in [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ]) {
          GoogleFonts.inter(fontWeight: w);
        }
        await GoogleFonts.pendingFonts();
      });
    }

    Widget themed(String name, Widget child) {
      final theme = _theme(name);
      final colors = StackColors.fromStackColorTheme(theme);
      return ProviderScope(
        overrides: [
          // Background reads the theme for an optional background image.
          themeProvider.overrideWithValue(StateController<StackTheme>(theme)),
        ],
        child: RepaintBoundary(
          key: const ValueKey('beam-theme-shot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: home.appThemeData(colors),
            home: child,
          ),
        ),
      );
    }

    for (final (name, prefs) in [
      (
        'light',
        (
          followDevice: false,
          themeId: 'light',
          lightId: 'light',
          darkId: 'dark',
        ),
      ),
      (
        BeamThemes.light,
        (
          followDevice: false,
          themeId: BeamThemes.light,
          lightId: 'light',
          darkId: 'dark',
        ),
      ),
      (
        BeamThemes.dark,
        (
          followDevice: true,
          themeId: 'light',
          lightId: BeamThemes.light,
          darkId: BeamThemes.dark,
        ),
      ),
    ]) {
      testWidgets('phone: Settings -> Colours in $name', (tester) async {
        tester.view.physicalSize = const Size(750, 1334);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await fonts(tester);
        final chosen = <BeamColours>[];
        await tester.pumpWidget(
          themed(name, BeamColoursView(prefs: prefs, onSelected: chosen.add)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Colours'), findsOneWidget);
        for (final c in BeamColours.values) {
          expect(find.text(c.label), findsOneWidget);
        }
        await expectLater(
          find.byKey(const ValueKey('beam-theme-shot')),
          matchesGoldenFile('goldens/phone_colours_$name.png'),
        );
        await tester.tap(find.byKey(const Key('beamColours_beamDark')));
        expect(chosen, [BeamColours.beamDark]);
      });
    }

    testWidgets('desktop: Settings -> Colours in BEAM dark', (tester) async {
      tester.view.physicalSize = const Size(900, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await fonts(tester);
      final colors = StackColors.fromStackColorTheme(_theme(BeamThemes.dark));
      await tester.pumpWidget(
        themed(
          BeamThemes.dark,
          Scaffold(
            backgroundColor: colors.background,
            body: const Padding(
              padding: EdgeInsets.all(24),
              child: BeamColoursDesktopSettings(
                prefs: (
                  followDevice: false,
                  themeId: BeamThemes.dark,
                  lightId: 'light',
                  darkId: 'dark',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('beam-theme-shot')),
        matchesGoldenFile('goldens/desktop_colours_beam_dark.png'),
      );
    });

    for (final name in _beam) {
      testWidgets('phone: the BEAM wallet home in $name', (tester) async {
        home.useWindow(tester, home.mobileSize);
        await home.loadFonts(tester);
        final theme = _theme(name);
        await home.pumpHome(
          tester,
          theme: theme,
          frame: const home.MobileHomeFrame(),
          overrides: [
            // Prefs without Hive (the app's singleton is gone after one test).
            prefsChangeNotifierProvider.overrideWithValue(_Prefs()),
            ...home.homeOverrides(
              source: home.FakeHomeSource(),
              balance: home.beamBalance(spendable: 42.685, pending: 12),
              totals: {36: home.assetTotals(36, 0.00001975)},
              format: home.beamFormat(usdPerBeam: '0.0089'),
              coinColor: theme.coinColors['beam'],
            ),
          ],
        );
        await home.settleImages(tester);
        await home.precacheAllImages(tester);
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await expectLater(
          find.byKey(const ValueKey('beam-home-golden')),
          matchesGoldenFile('goldens/phone_home_$name.png'),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets("phone: the history in $name: BEAM's received, sent and "
          'swap colours', (tester) async {
        var t = 1760300000;
        int next() => t -= 5400;
        final rows = [
          tx.simpleTxJson(
            seed: 1,
            status: BeamTxStatus.inProgress,
            income: true,
            value: 1200000000,
            createTime: next(),
          ),
          tx.simpleTxJson(
            seed: 2,
            status: BeamTxStatus.completed,
            income: true,
            value: 2500000000,
            createTime: next(),
          ),
          tx.simpleTxJson(
            seed: 3,
            status: BeamTxStatus.completed,
            value: 350000000,
            createTime: next(),
          ),
          tx.contractTxJson(seed: 4, otherAsset: 36, createTime: next()),
          tx.simpleTxJson(
            seed: 5,
            status: BeamTxStatus.failed,
            failure: 'Transaction timed out',
            value: 100000000,
            createTime: next(),
          ),
        ];
        final txs = rows.map(tx.mapped).toList();
        final fake = tx.FakeTxBackend()..serveTxStatus(rows);
        tx.setSurface(tester, desktop: false, h: 640);
        await tx.loadFonts(tester);
        final colors = StackColors.fromStackColorTheme(tx.campfireTheme(name));
        await tester.pumpWidget(
          tx.app(
            home: _cards(txs, colors),
            fake: fake,
            desktop: false,
            theme: name,
          ),
        );
        await tx.settle(tester);
        await expectLater(
          find.byKey(tx.kShot),
          matchesGoldenFile('goldens/phone_history_$name.png'),
        );
      });
    }
  });
}

/// Prefs without Hive: what the home reads.
class _Prefs extends ChangeNotifier implements Prefs {
  @override
  bool get externalCalls => false;

  @override
  String get currency => 'USD';

  @override
  AmountUnit amountUnit(CryptoCurrency coin) => AmountUnit.normal;

  @override
  int maxDecimals(CryptoCurrency coin) => Prefs.defaultMaxDecimals(coin);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The history as the wallet lists it: Campfire's cards in one container.
Widget _cards(List<TransactionV2> txs, StackColors colors) => Scaffold(
  backgroundColor: colors.background,
  body: SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final t in txs)
            Container(
              decoration: BoxDecoration(
                color: colors.popupBG,
                borderRadius: BorderRadius.circular(
                  Constants.size.circularBorderRadius,
                ),
              ),
              child: TransactionCardV2(transaction: t),
            ),
        ],
      ),
    ),
  ),
);
