/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The app's text in several languages.
//
// Every user-visible English sentence lives in lib/l10n/app_en.arb, with an
// "@key" description for translators; app_ru.arb, app_zh.arb and app_ja.arb
// hold the translations. Flutter's gen-l10n turns them into
// [AppLocalizations] (lib/l10n/generated/, made by `flutter pub get`).
//
// Two ways to reach a message:
//   * widgets:   `context.l10n.someKey` (rebuilds when the language changes);
//   * code with no BuildContext (the `*Text` helper classes, wallet-core
//     messages a screen shows): `appL10n.someKey`, kept in step with the
//     app's language by [AppL10nBinding].
// Both fall back to English, the source language: a widget pumped in a
// bare MaterialApp (most widget tests) reads English, exactly as before.
//
// What is never translated: amounts and their formatting (dot decimals in
// every language), addresses, transaction and kernel ids, tickers (BEAM,
// bETH, ...), BEAM names, brand names (BEAM, Campfire), seed words (BEAM's
// phrases are English BIP39 only) and anything a dApp shows.

import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// English, the source language, which every missing translation shows.
final AppLocalizations appL10nEnglish = lookupAppLocalizations(
  const Locale('en'),
);

AppLocalizations _current = appL10nEnglish;

/// The app's messages in its current language, for code with no
/// BuildContext. Widgets use [AppL10nContext.l10n] instead.
AppLocalizations get appL10n => _current;

/// Restores English as the current language. Tests that switch languages
/// call it in tearDown.
@visibleForTesting
void debugResetAppL10n() => _current = appL10nEnglish;

/// Makes [l10n] the current language for code with no BuildContext, as
/// [AppL10nBinding] does in the app. Tests reset it with
/// [debugResetAppL10n] in tearDown.
@visibleForTesting
void debugSetAppL10n(AppLocalizations l10n) => _current = l10n;

extension AppL10nContext on BuildContext {
  /// This context's messages; English where no localizations are in scope
  /// (a widget pumped in a bare MaterialApp).
  AppLocalizations get l10n => AppLocalizations.of(this) ?? appL10n;
}

/// Complete sentences shown together as one paragraph, joined the way the
/// current language joins sentences (a space in English, none in Chinese or
/// Japanese: see the `commonTwoSentences` message). Null and empty items are
/// left out. Only ever whole sentences: never build one sentence from parts.
String joinSentences(Iterable<String?> sentences, [AppLocalizations? l10n]) {
  final l = l10n ?? appL10n;
  String? out;
  for (final s in sentences) {
    if (s == null || s.isEmpty) continue;
    out = out == null ? s : l.commonTwoSentences(out, s);
  }
  return out ?? '';
}

/// The languages the app speaks, as language codes. English first: it is
/// the source and the fallback.
const appLanguageCodes = <String>['en', 'ru', 'zh', 'ja'];

/// The Locale the app uses for a language code. Chinese is Simplified
/// (script Hans), which also tells the text engine to pick Simplified glyph
/// forms when it falls back to a system font for Han characters.
Locale appLocaleFor(String languageCode) => switch (languageCode) {
  'zh' => const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  _ => Locale(languageCode),
};

/// Follows the device: the first of its preferred languages the app speaks
/// (any Chinese → Simplified Chinese, any Russian → Russian, any Japanese →
/// Japanese, any English → English), else English. Never asks.
///
/// Matches [WidgetsApp.localeListResolutionCallback]; [supported] is unused
/// because the app's own list is fixed ([appLanguageCodes]).
Locale resolveAppLocale(
  List<Locale>? preferred, [
  Iterable<Locale> supported = const [],
]) {
  for (final locale in preferred ?? const <Locale>[]) {
    if (appLanguageCodes.contains(locale.languageCode)) {
      return appLocaleFor(locale.languageCode);
    }
  }
  return appLocaleFor('en');
}

/// Keeps [appL10n] in step with the language in scope here, and rebuilds
/// everything below once when that language changes, so text computed
/// outside widgets (the `*Text` helpers) is drawn again in the new language
/// without restarting the app or losing the open screens.
///
/// Sits in MaterialApp.builder, above the Navigator. Tests that check
/// another language put it in their MaterialApp's builder the same way.
class AppL10nBinding extends StatefulWidget {
  const AppL10nBinding({super.key, required this.child});

  final Widget child;

  @override
  State<AppL10nBinding> createState() => _AppL10nBindingState();
}

class _AppL10nBindingState extends State<AppL10nBinding> {
  String? _localeName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = AppLocalizations.of(context) ?? appL10nEnglish;
    _current = l10n;
    final changed = _localeName != null && _localeName != l10n.localeName;
    _localeName = l10n.localeName;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        void rebuild(Element e) {
          e.markNeedsBuild();
          e.visitChildren(rebuild);
        }

        (context as Element).visitChildren(rebuild);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
