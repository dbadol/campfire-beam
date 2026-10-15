/*
 * This file is part of Campfire for BEAM.
 *
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 */

// The first screen of the desktop app in every language: each button's label
// stays inside its button. The 1.3.0 trial build drew the Russian "Восстановить
// из резервной копии Campfire" past the edge of its 350 px button; a label that
// does not fit now shrinks on its one line (PrimaryButton, SecondaryButton).
// "Create new" is a TextButton whose label wraps; it is checked too.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/l10n/app_language.dart';
import 'package:stackwallet/l10n/l10n.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/intro_view.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/widgets/desktop/secondary_button.dart';

import '../airdrop_ui/beam_ui_harness.dart';
import '../assets_ui/assets_ui_harness.dart'
    as assets
    show campfireLight, installCampfireTheme;

Future<void> _pumpIntro(WidgetTester tester, Locale locale) async {
  await loadFonts(tester);
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // The intro's images are the theme's own files, read from the themes folder.
  final theme = assets.campfireLight;
  final colors = StackColors.fromStackColorTheme(theme);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeProvider.overrideWithValue(StateController<StackTheme>(theme)),
        pAppLanguage.overrideWithValue(AppLanguagePref.inMemory()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appThemeData(colors),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppLocaleScope(child: child!),
        home: const IntroView(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [label]'s painted box, scale included, lies inside [button]'s.
void _inside(WidgetTester tester, Finder button, String label) {
  final b = tester.getRect(button);
  final t = tester.getRect(find.text(label));
  expect(
    t.left >= b.left - 0.5 && t.right <= b.right + 0.5,
    isTrue,
    reason:
        '"$label" spans ${t.left}..${t.right}, '
        'its button ${b.left}..${b.right}',
  );
}

/// The footer's "Source code" link lies on one line (it was split as
/// "源代 / 码" and "Исходный / код").
void _linkOnOneLine(WidgetTester tester) {
  final footer = find.byType(PrivacyAndTOSText);
  final rich = tester.widget<RichText>(
    find.descendant(of: footer, matching: find.byType(RichText)),
  );
  final spans = (rich.text as TextSpan).children!.cast<TextSpan>();
  final start = spans.first.text!.length;
  final end = start + spans[1].text!.length;
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: footer, matching: find.byType(RichText)),
  );
  final tops = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      )
      .map((b) => b.top.round())
      .toSet();
  expect(tops, hasLength(1), reason: 'the link on one line: $tops');
}

void main() {
  late Directory tmp;
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('intro_buttons');
    assets.installCampfireTheme(Directory('${tmp.path}/themes'));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));
  tearDown(debugResetAppL10n);

  for (final locale in const [
    Locale('en'),
    Locale('ru'),
    Locale('zh'),
    Locale('ja'),
  ]) {
    testWidgets('desktop intro in ${locale.languageCode}: both buttons hold '
        'their labels, and the Source code link stays on one line', (
      tester,
    ) async {
      await _pumpIntro(tester, locale);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      expect(appL10n.localeName, locale.languageCode);
      _inside(
        tester,
        find.byType(SecondaryButton),
        appL10n.introRestoreFromBackup(AppConfig.prefix),
      );
      _inside(
        tester,
        find.byType(GetStartedButton),
        appL10n.introCreateNew(AppConfig.prefix),
      );
      _linkOnOneLine(tester);
    });
  }
}
