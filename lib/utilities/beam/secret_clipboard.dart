/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

import '../clipboard_interface.dart';

/// Copies a secret (an airdrop voucher code: whoever has it can claim it)
/// and takes it off the clipboard [clearAfter] later, on every platform,
/// and at once when the app locks (issue #76, release audit 1.3.0). The
/// web wallet does the same (`pwa/src/lib/ui.js` `copySecret`).
///
/// On desktop the clipboard is read back first, and something the person
/// copied since is left alone; only a SHA-256 of the copy is kept for that,
/// never the text. Phones are not read back (Android 12+ and iOS tell the
/// person each time an app reads the clipboard), so there it is emptied
/// without comparing, as the toast said it would be. Best effort: a phone
/// that keeps the app asleep empties it when the app runs again, and
/// clipboard-history apps may keep their own copy. (Marking the copy
/// sensitive needs the platform's own clipboard API, not done yet.)
class SecretClipboard {
  SecretClipboard._();

  static const clearAfter = Duration(minutes: 1);

  static Timer? _timer;
  static String? _digest;
  static ClipboardInterface? _clipboard;

  /// Overrides the platform, for tests: true reads the clipboard back
  /// before emptying it (desktop), false empties it without reading
  /// (phones).
  static bool? debugDesktop;

  /// Whether the clipboard is read back before it is emptied: desktop only.
  static bool get comparesFirst =>
      debugDesktop ??
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  /// A secret copied here waits to be taken off the clipboard.
  static bool get pending => _digest != null;

  static String _hash(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// Copies [text] and schedules its removal. Returns whether it will be
  /// cleared by itself: always, on every platform.
  static Future<bool> copy(
    String text, {
    ClipboardInterface clipboard = const ClipboardWrapper(),
  }) async {
    await clipboard.setData(ClipboardData(text: text));
    _digest = _hash(text);
    _clipboard = clipboard;
    _timer?.cancel();
    _timer = Timer(
      clearAfter,
      () => unawaited(clearIfOurs(clipboard: clipboard)),
    );
    return true;
  }

  /// The app locked: the secret leaves the clipboard now, not a minute
  /// later.
  static Future<void> onAppLocked() =>
      clearIfOurs(clipboard: _clipboard ?? const ClipboardWrapper());

  /// Takes the last secret copied off the clipboard: on desktop only if
  /// the clipboard still holds it (or cannot be read), on phones without
  /// reading it back. Nothing happens when no secret waits.
  static Future<void> clearIfOurs({
    ClipboardInterface clipboard = const ClipboardWrapper(),
  }) async {
    final digest = _digest;
    _timer?.cancel();
    _timer = null;
    _digest = null;
    _clipboard = null;
    if (digest == null) return;
    if (comparesFirst) {
      String? text;
      var read = true;
      try {
        text = (await clipboard.getData(Clipboard.kTextPlain))?.text;
      } catch (_) {
        // Nothing to compare with: emptied anyway, as on phones.
        read = false;
      }
      // Something else is there now (or nothing): left alone.
      if (read && (text == null || _hash(text) != digest)) return;
    }
    try {
      await clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // Best effort: a clipboard that cannot be written keeps the copy.
    }
  }
}
