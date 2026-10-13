/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Coverage guard: the BEAM screens keep their user-visible English in
// lib/l10n/app_en.arb, not in Dart string literals, so every language can
// translate them.
//
// A pragmatic scan, not a parser: every string literal (adjacent literals
// joined) in the scanned files that reads like prose — two words or more,
// or one capitalised word given to a Text, a label, a title, a message or
// a hint — fails the test, unless
//   * its line is logging, a key, an assert or a developer error, or
//   * it is listed in ui_literals_allowlist.txt (file | literal | why):
//     technical strings, protocol words, brand names, text a dApp or the
//     BEAM core supplies, test-only fixtures.
//
// When this fails: move the text into app_en.arb (with a description) and
// read it through context.l10n / appL10n; or, if it is not user-visible,
// add it to the allow-list with the reason.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The BEAM UI directories and the core files whose text screens show:
/// each area joins the list once its text is in the catalogue.
const scanned = <String>['lib/l10n', 'lib/pages/beam/settings'];

final _skipLine = RegExp(
  r'Logging\.instance|debugPrint\(|\blog\(|\bKey\(|ValueKey\(|assert\(|'
  r'^\s*(import|export|part) |@pragma|RouteSettings\(|routeName\s*=|'
  r'StateError\(|ArgumentError\(|UnimplementedError\(|UnsupportedError\(|'
  r'FormatException\(|semanticsIdentifier:|debugLabel:|restorationId:',
);

/// A named argument or call that shows its string to the person.
final _uiPosition = RegExp(
  r'(Text|SelectableText|Tooltip|Semantics)\(\s*$|'
  r'\b(text|title|label|labelText|hintText|helperText|errorText|message|'
  r'subtitle|tooltip|semanticLabel|semanticsLabel|buttonTitle|hint|'
  r'description|detail|heading|caption|actionLabel|busyLabel|cta|'
  r'placeholder|confirmLabel|cancelLabel)\s*:\s*$',
);

class Literal {
  Literal(this.file, this.line, this.text, this.before);
  final String file;
  final int line;
  final String text;

  /// The code right before the literal on its line(s), to tell a label
  /// argument from any other string.
  final String before;

  @override
  String toString() => '$file:$line: $text';
}

/// Every group of adjacent string literals in [src], interpolations shown
/// as `${…}` / `$name`.
List<Literal> literalsOf(String file, String src) {
  final out = <Literal>[];
  final lineStarts = <int>[0];
  for (var i = 0; i < src.length; i++) {
    if (src.codeUnitAt(i) == 10) lineStarts.add(i + 1);
  }
  int lineOf(int pos) {
    var lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }

  bool isWord(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

  var i = 0;
  final n = src.length;
  StringBuffer? cur;
  var curStart = 0;
  var lastEnd = -1;
  void flush() {
    if (cur == null) return;
    final lineNo = lineOf(curStart);
    final lineStart = lineStarts[lineNo - 1];
    final prevLine = lineNo >= 2
        ? src.substring(lineStarts[lineNo - 2], lineStart)
        : '';
    out.add(
      Literal(
        file,
        lineNo,
        cur.toString(),
        prevLine + src.substring(lineStart, curStart),
      ),
    );
    cur = null;
  }

  while (i < n) {
    if (src.startsWith('//', i)) {
      final j = src.indexOf('\n', i);
      i = j < 0 ? n : j;
      continue;
    }
    if (src.startsWith('/*', i)) {
      final j = src.indexOf('*/', i + 2);
      i = j < 0 ? n : j + 2;
      continue;
    }
    final c = src[i];
    final raw =
        c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"');
    if ((c == "'" || c == '"' || raw) && (i == 0 || !isWord(src[i - 1]))) {
      final qStart = raw ? i + 1 : i;
      final q = src.startsWith("'''", qStart)
          ? "'''"
          : src.startsWith('"""', qStart)
          ? '"""'
          : src[qStart];
      var j = qStart + q.length;
      final buf = StringBuffer();
      while (j < n && !src.startsWith(q, j)) {
        final d = src[j];
        if (!raw && d == r'\') {
          final e = j + 1 < n ? src[j + 1] : '';
          buf.write(e == 'n' ? '\n' : e);
          j += 2;
          continue;
        }
        if (!raw && d == r'$' && j + 1 < n && src[j + 1] == '{') {
          var depth = 0;
          var k = j + 1;
          while (k < n) {
            if (src[k] == '{') depth++;
            if (src[k] == '}') {
              depth--;
              if (depth == 0) break;
            }
            k++;
          }
          buf.write(r'${…}');
          j = k + 1;
          continue;
        }
        if (!raw &&
            d == r'$' &&
            j + 1 < n &&
            RegExp(r'[A-Za-z_]').hasMatch(src[j + 1])) {
          var k = j + 1;
          while (k < n && isWord(src[k])) {
            k++;
          }
          buf.write(src.substring(j, k));
          j = k;
          continue;
        }
        buf.write(d);
        j++;
      }
      final between = lastEnd >= 0 ? src.substring(lastEnd, i) : 'x';
      if (cur != null && between.trim().isEmpty) {
        cur!.write(buf);
      } else {
        flush();
        cur = buf;
        curStart = i;
      }
      i = j + q.length;
      lastEnd = i;
      continue;
    }
    i++;
  }
  flush();
  return out;
}

bool isUserText(Literal l) {
  final plain = l.text
      .replaceAll(RegExp(r'\$\{…\}|\$[A-Za-z_]\w*'), ' ')
      .trim();
  if (plain.contains('://') || plain.startsWith('package:')) return false;
  final prose = RegExp(r"[A-Za-z]{2,}[ ,.'’?!:;—-]+[A-Za-z]{2,}")
      .hasMatch(plain);
  if (prose) return true;
  final word = RegExp(r'^[A-Z][a-z]{2,}[.!?…]?$').hasMatch(plain);
  return word && _uiPosition.hasMatch(l.before.trimRight());
}

List<String> _sourceFiles() => [
  for (final path in scanned)
    if (FileSystemEntity.isFileSync(path))
      path
    else if (FileSystemEntity.isDirectorySync(path))
      for (final e in Directory(path).listSync(recursive: true))
        if (e is File &&
            e.path.endsWith('.dart') &&
            !e.path.contains('/generated/'))
          e.path,
]..sort();

/// file | literal | reason, one per line; '#' starts a comment line.
Map<String, Set<String>> _allowList() {
  final out = <String, Set<String>>{};
  final lines = File('test/beam/l10n/ui_literals_allowlist.txt')
      .readAsLinesSync();
  for (final line in lines) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final parts = line.split(' | ');
    if (parts.length < 3 || parts[2].trim().isEmpty) {
      throw FormatException('allow-list line needs file | literal | why', line);
    }
    out.putIfAbsent(parts[0].trim(), () => {}).add(parts[1]);
  }
  return out;
}

void main() {
  test('no user-visible English literal is left in the BEAM screens', () {
    final allowed = _allowList();
    final found = <Literal>[];
    final used = <String>{};
    for (final file in _sourceFiles()) {
      final src = File(file).readAsStringSync();
      final lines = src.split('\n');
      for (final l in literalsOf(file, src)) {
        if (_skipLine.hasMatch(lines[l.line - 1])) continue;
        if (!isUserText(l)) continue;
        if (allowed[file]?.contains(l.text) ?? false) {
          used.add('$file | ${l.text}');
          continue;
        }
        found.add(l);
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          '${found.length} literal(s) to move into lib/l10n/app_en.arb '
          '(or to allow-list with a reason):\n${found.join('\n')}',
    );
    // A stale allow-list entry hides nothing but rots: keep it exact.
    final stale = [
      for (final e in allowed.entries)
        for (final t in e.value)
          if (!used.contains('${e.key} | $t')) '${e.key} | $t',
    ];
    expect(
      stale,
      isEmpty,
      reason: 'unused allow-list entries:\n${stale.join('\n')}',
    );
  });

  test('the scan sees labels, prose and interpolations', () {
    const src = '''
      Text('Split coins');
      const x = 'Your \$symbol coins';
      final y = 'abc_def';
      label: 'Now',
      foo('Now');
      Logging.instance.i('Some log line here');
      final z = 'two '
          'parts';
    ''';
    final lits = literalsOf('f.dart', src);
    final lines = src.split('\n');
    final user = [
      for (final l in lits)
        if (!_skipLine.hasMatch(lines[l.line - 1]) && isUserText(l)) l.text,
    ];
    expect(user, ['Split coins', r'Your $symbol coins', 'Now', 'two parts']);
  });
}
