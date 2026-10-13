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
/// and, on desktop, takes it off the clipboard [clearAfter] later if the
/// clipboard still holds that copy (issue #76). The web wallet does the same
/// (`pwa/src/lib/ui.js` `copySecret`).
///
/// Only a SHA-256 of the copy is kept, never the text. Something the person
/// copied since is left alone. On phones the clipboard is not read back:
/// Android 12+ and iOS tell the person each time an app reads it, so there
/// the copy stays until the person replaces it (marking it sensitive needs
/// the platform's own clipboard API, not done yet).
class SecretClipboard {
  SecretClipboard._();

  static const clearAfter = Duration(minutes: 1);

  static Timer? _timer;
  static String? _digest;

  /// Overrides the platform, for tests.
  static bool? debugDesktop;

  static bool get clearsByItself =>
      debugDesktop ??
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  static String _hash(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// Copies [text]. Returns whether it will be cleared by itself.
  static Future<bool> copy(
    String text, {
    ClipboardInterface clipboard = const ClipboardWrapper(),
  }) async {
    await clipboard.setData(ClipboardData(text: text));
    if (!clearsByItself) return false;
    _digest = _hash(text);
    _timer?.cancel();
    _timer = Timer(
      clearAfter,
      () => unawaited(clearIfOurs(clipboard: clipboard)),
    );
    return true;
  }

  /// Empties the clipboard if it still holds the last secret copied.
  static Future<void> clearIfOurs({
    ClipboardInterface clipboard = const ClipboardWrapper(),
  }) async {
    final digest = _digest;
    _timer?.cancel();
    _timer = null;
    _digest = null;
    if (digest == null || !clearsByItself) return;
    try {
      final now = await clipboard.getData(Clipboard.kTextPlain);
      final text = now?.text;
      if (text != null && _hash(text) == digest) {
        await clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // The clipboard could not be read: nothing to compare, nothing cleared.
    }
  }
}
