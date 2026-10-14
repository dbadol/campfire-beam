// Issue #76 and release audit 1.3.0: a copied voucher code leaves the
// clipboard a minute later on every platform (desktop reads it back first;
// phones are not read back and empty it anyway), and at once when the app
// locks.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/secret_clipboard.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';

/// Counts reads, and can refuse them like a platform that cannot compare.
class _Clipboard extends FakeClipboard {
  int reads = 0;
  bool unreadable = false;

  @override
  Future<ClipboardData?> getData(String format) {
    reads++;
    if (unreadable) throw PlatformException(code: 'denied');
    return super.getData(format);
  }
}

Future<String?> _now(_Clipboard c) async {
  final reads = c.reads;
  final unreadable = c.unreadable;
  c.unreadable = false;
  final v = (await c.getData(Clipboard.kTextPlain))?.text;
  c.reads = reads;
  c.unreadable = unreadable;
  return v;
}

void main() {
  tearDown(() async {
    await SecretClipboard.clearIfOurs(clipboard: FakeClipboard());
    SecretClipboard.debugDesktop = null;
  });

  testWidgets('desktop: cleared a minute later if still the copy', (
    tester,
  ) async {
    SecretClipboard.debugDesktop = true;
    final c = _Clipboard();
    expect(await SecretClipboard.copy('CODE-ONE', clipboard: c), isTrue);
    await tester.pump(const Duration(seconds: 59));
    expect(await _now(c), 'CODE-ONE');
    await tester.pump(const Duration(seconds: 2));
    expect(await _now(c), '');
    expect(c.reads, 1, reason: 'read back once, to compare');
  });

  testWidgets('desktop: something copied since is left alone', (tester) async {
    SecretClipboard.debugDesktop = true;
    final c = _Clipboard();
    await SecretClipboard.copy('CODE-ONE', clipboard: c);
    await c.setData(const ClipboardData(text: 'my own text'));
    await tester.pump(const Duration(minutes: 2));
    expect(await _now(c), 'my own text');
  });

  testWidgets('desktop: a clipboard that cannot be read is emptied anyway', (
    tester,
  ) async {
    SecretClipboard.debugDesktop = true;
    final c = _Clipboard();
    await SecretClipboard.copy('CODE-ONE', clipboard: c);
    c.unreadable = true;
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    expect(await _now(c), '');
  });

  testWidgets('desktop: a second copy restarts the minute', (tester) async {
    SecretClipboard.debugDesktop = true;
    final c = _Clipboard();
    await SecretClipboard.copy('CODE-ONE', clipboard: c);
    await tester.pump(const Duration(seconds: 30));
    await SecretClipboard.copy('CODE-TWO', clipboard: c);
    await tester.pump(const Duration(seconds: 40));
    expect(await _now(c), 'CODE-TWO');
    await tester.pump(const Duration(seconds: 21));
    expect(await _now(c), '');
  });

  testWidgets('phones: emptied a minute later too, without reading the '
      'clipboard back (the system would tell the person)', (tester) async {
    SecretClipboard.debugDesktop = false;
    final c = _Clipboard();
    expect(await SecretClipboard.copy('CODE-ONE', clipboard: c), isTrue);
    expect(SecretClipboard.pending, isTrue);
    await tester.pump(const Duration(seconds: 59));
    expect(await _now(c), 'CODE-ONE');
    await tester.pump(const Duration(seconds: 2));
    expect(await _now(c), '');
    expect(c.reads, 0);
    expect(SecretClipboard.pending, isFalse);
  });

  for (final desktop in [true, false]) {
    final where = desktop ? 'desktop' : 'phones';
    testWidgets('$where: the lock empties it at once; with nothing copied '
        'the lock leaves the clipboard alone', (tester) async {
      SecretClipboard.debugDesktop = desktop;
      final c = _Clipboard();
      await SecretClipboard.copy('CODE-ONE', clipboard: c);
      await tester.pump(const Duration(seconds: 5));
      await SecretClipboard.onAppLocked();
      expect(await _now(c), '');
      expect(SecretClipboard.pending, isFalse);
      // Nothing waits any more: no clear later, and the lock touches
      // nothing the person copies themselves.
      await c.setData(const ClipboardData(text: 'my own text'));
      await SecretClipboard.onAppLocked();
      await tester.pump(const Duration(minutes: 2));
      expect(await _now(c), 'my own text');
    });
  }

  test('both idle locks (phone and desktop) take the code off the '
      'clipboard', () {
    for (final f in [
      'lib/pages/home_view/home_view.dart',
      'lib/pages_desktop_specific/desktop_home_view.dart',
    ]) {
      final src = File(f).readAsStringSync();
      final idle = src.indexOf('void _onIdle() async {');
      expect(idle, isNot(-1), reason: f);
      final body = src.substring(idle, src.indexOf('\n  }\n', idle));
      expect(
        body,
        contains('SecretClipboard.onAppLocked()'),
        reason: '$f: the lock must clear a copied code',
      );
    }
  });
}
