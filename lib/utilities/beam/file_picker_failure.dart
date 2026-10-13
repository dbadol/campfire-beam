/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

/// What to say when the system file picker could not be opened (issue #1).
///
/// On Linux, file_picker 10.x opens the picker only through the desktop's
/// xdg-desktop-portal service, so on a desktop without it every attempt
/// fails the same way and "Try again" alone would not help: the message
/// names what to install. [linux] overrides the platform, for tests.
String filePickerFailureText({String app = 'Campfire', bool? linux}) {
  if (linux ?? Platform.isLinux) {
    return "$app couldn't open the file picker. On Linux it uses your "
        "desktop's file chooser service: install xdg-desktop-portal and "
        'xdg-desktop-portal-gtk (xdg-desktop-portal-kde on KDE), then try '
        'again.';
  }
  return "$app couldn't open the file picker. Try again.";
}
