/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/hive/db.dart';
import '../utilities/logger.dart';
import 'l10n.dart';

/// The language the person chose in Settings → Language. [system] (the
/// default, never asked on first run) follows the device.
enum AppLanguage {
  system(null),
  en('en'),
  ru('ru'),
  zh('zh'),
  ja('ja');

  const AppLanguage(this.code);

  /// The language code, or null for "like this device".
  final String? code;

  /// Each language's own name, the same in every language, so a person who
  /// cannot read the current one still finds theirs. Null for [system],
  /// whose label is translated.
  String? get endonym => switch (this) {
    system => null,
    en => 'English',
    ru => 'Русский',
    zh => '简体中文',
    ja => '日本語',
  };

  /// The override for MaterialApp's locale, or null to follow the device.
  Locale? get locale => code == null ? null : appLocaleFor(code!);

  static AppLanguage fromName(Object? name) => AppLanguage.values.firstWhere(
    (l) => l.name == name,
    orElse: () => AppLanguage.system,
  );
}

/// The endonym of the language the device resolves to, for "Like this
/// device · English".
String appLanguageEndonymFor(Locale locale) =>
    AppLanguage.fromName(locale.languageCode).endonym ?? 'English';

/// The chosen language, kept in the app's preferences (the Hive "prefs"
/// box, like every other setting).
class AppLanguagePref extends ChangeNotifier {
  AppLanguagePref._() : _persist = true;

  /// A preference that starts at [initial] and is never saved.
  @visibleForTesting
  AppLanguagePref.inMemory([AppLanguage initial = AppLanguage.system])
    : _value = initial,
      _persist = false;

  static final AppLanguagePref instance = AppLanguagePref._();

  static const _key = 'appLanguage';

  final bool _persist;
  AppLanguage? _value;

  AppLanguage get value => _value ??= _read();

  set value(AppLanguage language) {
    if (language == value) return;
    _value = language;
    notifyListeners();
    if (!_persist) return;
    DB.instance
        .put<dynamic>(boxName: DB.boxNamePrefs, key: _key, value: language.name)
        .catchError((Object e, StackTrace s) {
          Logging.instance.w('appLanguage not saved', error: e, stackTrace: s);
        });
  }

  static AppLanguage _read() {
    try {
      return AppLanguage.fromName(
        DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: _key),
      );
    } catch (_) {
      // Preferences not open (a widget test): follow the device.
      return AppLanguage.system;
    }
  }
}

final pAppLanguage = ChangeNotifierProvider<AppLanguagePref>(
  (ref) => AppLanguagePref.instance,
);

/// Applies the chosen language to everything below it (all routes, dialogs
/// and notices: it sits in MaterialApp.builder, above the Navigator) without
/// restarting the app, and keeps [appL10n] in step.
class AppLocaleScope extends ConsumerWidget {
  const AppLocaleScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Always the same shape, with or without an override: switching between
    // "like this device" and a chosen language must not rebuild the
    // Navigator from scratch (that would close every open screen).
    return Localizations.override(
      context: context,
      locale: ref.watch(pAppLanguage.select((p) => p.value)).locale,
      child: AppL10nBinding(child: child),
    );
  }
}
