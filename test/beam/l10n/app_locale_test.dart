/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The app's language: the device's when the app has it, else English, never
// asked; Settings → Language overrides it without closing any screen; a
// missing translation shows English; amounts keep dot decimals in every
// language.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:stackwallet/l10n/app_language.dart';
import 'package:stackwallet/l10n/generated/app_localizations_en.dart';
import 'package:stackwallet/l10n/l10n.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/beam/settings/app_language_view.dart';
import 'package:stackwallet/pages/beam/split/beam_split_view.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/wallets/beam/models/beam_utxo.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coin_split.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coins.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_layout.dart';
import 'package:stackwallet/widgets/beam/split/beam_split_backend.dart';

import '../airdrop_ui/beam_ui_harness.dart';

/// Russian with exactly two messages translated: one a widget reads through
/// its context (splitNowLabel), one a text helper reads with no context
/// (splitTitle, through BeamSplitText and appL10n). Everything else falls
/// back to English, as an incomplete catalogue does.
class _FakeRu extends AppLocalizationsEn {
  _FakeRu() : super('ru');

  @override
  String get splitTitle => 'Разделить монеты';

  @override
  String get splitNowLabel => 'Сейчас';
}

class _FakeRuDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _FakeRuDelegate();

  @override
  bool isSupported(Locale locale) =>
      appLanguageCodes.contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) => SynchronousFuture(
    locale.languageCode == 'ru' ? _FakeRu() : lookupAppLocalizations(locale),
  );

  @override
  bool shouldReload(_FakeRuDelegate old) => false;
}

class _Backend implements BeamSplitBackend {
  final _sync = ValueNotifier<BeamSyncAssessment>(synced());

  @override
  final names = BeamAssetNames();

  @override
  ValueListenable<BeamSyncAssessment> get sync => _sync;

  @override
  Listenable? get coinsChanged => null;

  @override
  Future<Map<int, BeamCoinSummary>> coins() async => BeamCoinSummary.of([
    BeamUtxo(
      id: 'c0',
      assetId: 0,
      amount: BigInt.from(4520000000),
      type: 'norm',
      statusCode: 1,
      statusString: 'available',
    ),
  ]);

  @override
  bool isPoolShare(int assetId) => false;

  @override
  String? get blocked => null;

  @override
  Future<BeamPreparedSplit> prepare(BeamSplitPlan plan) =>
      throw UnimplementedError();

  @override
  Future<String> confirm(BeamPreparedSplit split) => throw UnimplementedError();

  @override
  VoidCallback? get addFunds => null;
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Locale? locale,
  List<LocalizationsDelegate<dynamic>> extra = const [],
  AppLanguagePref? language,
}) async {
  tester.view.physicalSize = const Size(375, 812) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final theme = campfireLightTheme();
  final colors = StackColors.fromStackColorTheme(theme);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithValue(StateController<StackTheme>(theme)),
        pAppLanguage.overrideWithValue(language ?? AppLanguagePref.inMemory()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appThemeData(colors),
        locale: locale,
        localizationsDelegates: [
          ...extra,
          ...AppLocalizations.localizationsDelegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: resolveAppLocale,
        builder: (context, child) => AppLocaleScope(
          child: BeamLayoutScope(desktop: false, child: child!),
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(debugResetAppL10n);

  group('following the device', () {
    Locale r(List<Locale>? l) => resolveAppLocale(l);

    test('ru-*, zh-*, ja-* and en-* map to the app language', () {
      expect(r(const [Locale('ru', 'RU')]), const Locale('ru'));
      expect(r(const [Locale('ru', 'UA')]), const Locale('ru'));
      expect(r(const [Locale('ja', 'JP')]), const Locale('ja'));
      expect(r(const [Locale('en', 'GB')]), const Locale('en'));
      const hans = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
      expect(r(const [Locale('zh', 'CN')]), hans);
      expect(r(const [Locale('zh', 'TW')]), hans);
      expect(
        r(const [
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'HK',
          ),
        ]),
        hans,
      );
    });

    test('anything else is English; a later preferred language counts', () {
      expect(r(const [Locale('de', 'DE')]), const Locale('en'));
      expect(r(null), const Locale('en'));
      expect(r(const []), const Locale('en'));
      expect(r(const [Locale('de'), Locale('ru')]), const Locale('ru'));
    });

    test('the choices: each language under its own name', () {
      expect(AppLanguage.values.first, AppLanguage.system);
      expect(
        [for (final l in AppLanguage.values) l.endonym],
        [null, 'English', 'Русский', '简体中文', '日本語'],
      );
      expect(AppLanguage.fromName('ja'), AppLanguage.ja);
      expect(AppLanguage.fromName('xx'), AppLanguage.system);
      expect(AppLanguage.fromName(null), AppLanguage.system);
    });
  });

  testWidgets('Russian: the split screen in Russian, amounts with a dot', (
    tester,
  ) async {
    await _pump(
      tester,
      BeamSplitView(backend: _Backend()),
      locale: const Locale('ru'),
    );
    expect(
      Localizations.localeOf(tester.element(find.byType(BeamSplitView))),
      const Locale('ru'),
    );
    expect(appL10n.localeName, 'ru');
    expect(find.text('Разделить монеты'), findsWidgets);
    expect(find.text('Split coins'), findsNothing);
    expect(find.text('Сейчас'), findsOneWidget);
    expect(find.text('Отправляйте несколько платежей сразу'), findsOneWidget);
    expect(find.textContaining('45.2 BEAM'), findsWidgets);
    // Nothing picked the language up for numbers.
    expect(Intl.defaultLocale, isNull);
    expect(NumberFormat.decimalPattern().format(1234.5), '1,234.5');
  });

  testWidgets('Russian with a translated message: shown, through a widget '
      'and through a text helper; the rest stays English', (tester) async {
    await _pump(
      tester,
      BeamSplitView(backend: _Backend()),
      locale: const Locale('ru'),
      extra: const [_FakeRuDelegate()],
    );
    expect(find.text('Разделить монеты'), findsWidgets);
    expect(find.text('Split coins'), findsNothing);
    expect(find.text('Сейчас'), findsOneWidget);
    expect(find.text('Send several payments at once'), findsOneWidget);
    expect(find.textContaining('45.2 BEAM'), findsWidgets);
  });

  testWidgets(
    'choosing a language applies at once and keeps the open screens',
    (tester) async {
      final language = AppLanguagePref.inMemory();
      await _pump(
        tester,
        const AppLanguageView(),
        locale: const Locale('en'),
        extra: const [_FakeRuDelegate()],
        language: language,
      );
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => BeamSplitView(backend: _Backend()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Split coins'), findsWidgets);

      language.value = AppLanguage.ru;
      await tester.pumpAndSettle();
      expect(find.text('Разделить монеты'), findsWidgets);
      expect(find.text('Сейчас'), findsOneWidget);
      // Still two screens deep: nothing was closed.
      expect(nav.canPop(), isTrue);

      language.value = AppLanguage.system;
      await tester.pumpAndSettle();
      expect(find.text('Split coins'), findsWidgets);
      expect(nav.canPop(), isTrue);
    },
  );

  testWidgets('Settings → Language lists "Like this device" and each '
      'language by its own name; tapping one picks it', (tester) async {
    final language = AppLanguagePref.inMemory();
    await _pump(tester, const AppLanguageView(), language: language);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Like this device'), findsOneWidget);
    for (final name in ['English', 'Русский', '简体中文', '日本語']) {
      expect(find.text(name), findsWidgets);
    }
    await tester.tap(find.byKey(const ValueKey('app-language-ja')));
    await tester.pumpAndSettle();
    expect(language.value, AppLanguage.ja);
    // The page redraws in Japanese at once; the languages keep their names.
    expect(find.text('言語'), findsOneWidget);
    expect(find.text('端末と同じ'), findsOneWidget);
    expect(find.text('Like this device'), findsNothing);
    for (final name in ['English', 'Русский', '简体中文', '日本語']) {
      expect(find.text(name), findsWidgets);
    }
  });
}
