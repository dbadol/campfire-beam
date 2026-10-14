/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The message catalogue (lib/l10n/*.arb) stays usable by translators:
//
//   * every English message has a description and declares exactly the
//     placeholders it uses, none of them formatted by the locale;
//   * every translation file has the English key set: no key English lacks
//     (a stale or misspelt key), and, once a language is marked complete in
//     [completeLocales], no key missing; until then a missing key shows the
//     English text (gen-l10n's fallback), which this test reports;
//   * no translation is empty (it would show as blank, not as English) or
//     drops or invents a placeholder;
//   * no fragment is left in lib/l10n/parts/ (merge with
//     scripts/beam/l10n_merge.py --write --consume);
//   * no Russian message groups a number with a comma (its decimal sign).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Languages whose translation is finished: their file must have exactly
/// the English key set. A message added to English must be translated into
/// each of them in the same change.
const completeLocales = <String>{'ru', 'zh', 'ja'};

const _types = {'String', 'int', 'DateTime'};

Map<String, Object?> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Iterable<String> _messageKeys(Map<String, Object?> arb) =>
    arb.keys.where((k) => !k.startsWith('@'));

/// The {placeholders} an ICU message uses, plural/select selectors and the
/// placeholders inside their cases included (not the case labels).
Set<String> placeholdersOf(String message) {
  final names = <String>{};
  final s = message;

  int skipWs(int i) {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
    return i;
  }

  (String?, int) ident(int i) {
    final m = RegExp(r'=?[A-Za-z0-9_]+').matchAsPrefix(s, i);
    return m == null ? (null, i) : (m[0], m.end);
  }

  late int Function(int) argument;

  int text(int i, bool nested) {
    while (i < s.length) {
      final c = s[i];
      if (c == '{') {
        i = argument(i + 1);
      } else if (c == '}' && nested) {
        return i + 1;
      } else {
        i++;
      }
    }
    return i;
  }

  argument = (int i) {
    i = skipWs(i);
    final (name, after) = ident(i);
    if (name != null) names.add(name);
    i = skipWs(after);
    if (i < s.length && s[i] == '}') return i + 1;
    if (i < s.length && s[i] == ',') {
      i = ident(skipWs(i + 1)).$2; // plural / select
      i = skipWs(i);
      if (i < s.length && s[i] == ',') i++;
      while (true) {
        i = skipWs(i);
        if (i >= s.length || s[i] == '}') return i + 1;
        i = skipWs(ident(i).$2); // one / other / =1
        if (i < s.length && s[i] == '{') {
          i = text(i + 1, true);
        } else {
          return i;
        }
      }
    }
    return i;
  };

  text(0, false);
  return names;
}

void main() {
  final en = _read('lib/l10n/app_en.arb');
  final enKeys = _messageKeys(en).toSet();
  final translations = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'app_[a-z_A-Z]+\.arb$').hasMatch(f.path))
      .where((f) => !f.path.endsWith('app_en.arb'))
      .toList();

  test('the expected languages exist: ru, zh, ja', () {
    final locales = translations
        .map((f) => RegExp(r'app_(\w+)\.arb$').firstMatch(f.path)![1])
        .toSet();
    expect(locales, containsAll(<String>{'ru', 'zh', 'ja'}));
    expect(en['@@locale'], 'en');
  });

  test('every English message is described, named and well-formed', () {
    final problems = <String>[];
    for (final key in enKeys) {
      if (!RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(key)) {
        problems.add('$key: not lowerCamelCase');
      }
      final value = en[key];
      if (value is! String || value.trim().isEmpty) {
        problems.add('$key: empty');
        continue;
      }
      final meta = en['@$key'];
      if (meta is! Map ||
          (meta['description'] as String? ?? '').trim().length < 10) {
        problems.add('$key: no description for translators');
        continue;
      }
      final declared = (meta['placeholders'] as Map? ?? const {})
          .cast<String, Object?>();
      final used = placeholdersOf(value);
      for (final p in used.difference(declared.keys.toSet())) {
        problems.add('$key: uses {$p} but does not declare it');
      }
      for (final p in declared.keys.toSet().difference(used)) {
        problems.add('$key: declares $p but does not use it');
      }
      for (final e in declared.entries) {
        final spec = (e.value as Map?) ?? const {};
        if (!_types.contains(spec['type'])) {
          problems.add('$key.${e.key}: type ${spec['type']}');
        }
        // Numbers are never formatted by the locale: amounts arrive as
        // ready-made strings (dot decimals in every language), counts as
        // plain integers.
        if (spec.containsKey('format')) {
          problems.add('$key.${e.key}: has a number/date format');
        }
        final example = spec['example'];
        if (example != null && (example is! String || example.isEmpty)) {
          problems.add('$key.${e.key}: example must be a non-empty string');
        }
      }
    }
    for (final k in en.keys.where(
      (k) => k.startsWith('@') && k != '@@locale',
    )) {
      if (!enKeys.contains(k.substring(1))) {
        problems.add('$k describes no message');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  for (final file in translations) {
    final name = file.uri.pathSegments.last;
    test('$name: only English keys, no empty text, same placeholders', () {
      final arb = _read(file.path);
      final locale = RegExp(r'app_(\w+)\.arb$').firstMatch(name)![1]!;
      expect(arb['@@locale'], locale);
      final keys = _messageKeys(arb).toSet();
      final problems = <String>[
        for (final k in keys.difference(enKeys)) '$k: not an English key',
      ];
      for (final k in keys.intersection(enKeys)) {
        final value = arb[k];
        if (value is! String || value.trim().isEmpty) {
          problems.add('$k: empty (would show blank instead of English)');
          continue;
        }
        final want = placeholdersOf(en[k]! as String);
        final got = placeholdersOf(value);
        if (!want.containsAll(got) || !got.containsAll(want)) {
          problems.add('$k: placeholders $got, English has $want');
        }
      }
      final missing = enKeys.difference(keys);
      if (completeLocales.contains(locale)) {
        for (final k in missing) {
          problems.add('$k: missing (the language is marked complete)');
        }
      } else if (missing.isNotEmpty) {
        // Not an error until the language is marked complete: missing
        // messages show in English.
        printOnFailure(
          '$name: ${missing.length} of ${enKeys.length} not '
          'translated yet',
        );
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  // Russian writes "1,5" for one and a half: a number grouped with commas
  // there ("100,000,000") reads as 100. Its thousands take a narrow
  // no-break space, as lib/l10n/amount_text.dart writes amounts.
  test('app_ru.arb: no number is grouped with a comma', () {
    final ru = _read('lib/l10n/app_ru.arb');
    final grouped = RegExp(r'\d,\d{3}(?!\d)');
    final problems = <String>[
      for (final k in _messageKeys(ru))
        if (ru[k] case final String v when grouped.hasMatch(v)) '$k: $v',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
    expect(ru['minterNthHelper'], contains('100\u202F000\u202F000'));
  });

  test('no fragment is left unmerged in lib/l10n/parts', () {
    final parts = Directory('lib/l10n/parts');
    final left = parts.existsSync()
        ? parts.listSync().map((e) => e.path).toList()
        : const <String>[];
    expect(left, isEmpty);
  });

  test('the placeholder reader handles plurals and selects', () {
    expect(
      placeholdersOf(
        '{count, plural, one{{countText} block} other{{countText} blocks}}',
      ),
      {'count', 'countText'},
    );
    expect(placeholdersOf('{n, select, a{x} other{y {z}}} for {amount}'), {
      'n',
      'z',
      'amount',
    });
    expect(placeholdersOf('Plain text'), isEmpty);
  });
}
