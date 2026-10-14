/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import '../../l10n/l10n.dart';

/// What to say when the system file picker could not be opened (issue #1).
///
/// On Linux, file_picker 10.x opens the picker only through the desktop's
/// xdg-desktop-portal service, so on a desktop without it every attempt
/// fails the same way and "Try again" alone would not help: the message
/// names what to install. [linux] overrides the platform, for tests.
String filePickerFailureText({String app = 'Campfire', bool? linux}) {
  if (linux ?? Platform.isLinux) return appL10n.scanFilePickerFailedLinux(app);
  return appL10n.scanFilePickerFailed(app);
}
