// Issue #76: a copied voucher code leaves the clipboard a minute later on
// desktop, if it is still there; phones are not read back.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/secret_clipboard.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';

Future<String?> _now(ClipboardInterface c) async =>
    (await c.getData(Clipboard.kTextPlain))?.text;

void main() {
  tearDown(() => SecretClipboard.debugDesktop = null);

  testWidgets('desktop: cleared a minute later if still the copy', (
    tester,
  ) async {
    SecretClipboard.debugDesktop = true;
    final c = FakeClipboard();
    expect(await SecretClipboard.copy('CODE-ONE', clipboard: c), isTrue);
    await tester.pump(const Duration(seconds: 59));
    expect(await _now(c), 'CODE-ONE');
    await tester.pump(const Duration(seconds: 2));
    expect(await _now(c), '');
  });

  testWidgets('desktop: something copied since is left alone', (tester) async {
    SecretClipboard.debugDesktop = true;
    final c = FakeClipboard();
    await SecretClipboard.copy('CODE-ONE', clipboard: c);
    await c.setData(const ClipboardData(text: 'my own text'));
    await tester.pump(const Duration(minutes: 2));
    expect(await _now(c), 'my own text');
  });

  testWidgets('desktop: a second copy restarts the minute', (tester) async {
    SecretClipboard.debugDesktop = true;
    final c = FakeClipboard();
    await SecretClipboard.copy('CODE-ONE', clipboard: c);
    await tester.pump(const Duration(seconds: 30));
    await SecretClipboard.copy('CODE-TWO', clipboard: c);
    await tester.pump(const Duration(seconds: 40));
    expect(await _now(c), 'CODE-TWO');
    await tester.pump(const Duration(seconds: 21));
    expect(await _now(c), '');
  });

  testWidgets('phones: copied, never read back or cleared', (tester) async {
    SecretClipboard.debugDesktop = false;
    final c = FakeClipboard();
    expect(await SecretClipboard.copy('CODE-ONE', clipboard: c), isFalse);
    await tester.pump(const Duration(minutes: 2));
    expect(await _now(c), 'CODE-ONE');
  });
}
