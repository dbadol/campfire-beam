/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/widgets.dart';

import '../../app_config.dart';
import '../../l10n/l10n.dart';
import '../../utilities/prefs.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';

/// BEAM's colours as two optional Campfire themes (owner, 2026-10-13: "make
/// Beam Theme with Beam Brand kit colors"), next to Campfire's own light theme,
/// which stays the default. Stack Wallet's theme system as it is: a StackTheme
/// zip each (asset_sources/default_themes/campfire/beam_{light,dark}.zip, made
/// by scripts/beam/theme/beam_brand_theme.py from Campfire's own zip, so every
/// image, the Beam girl and the logo stay Campfire's), installed by
/// ThemeService at startup and chosen in Settings -> Colours.
abstract final class BeamThemes {
  /// Campfire's own (and only) theme.
  static const campfire = 'light';
  static const light = 'beam_light';
  static const dark = 'beam_dark';
  static const ids = [light, dark];

  /// The zips' theme.json "version": an installed copy older than this is
  /// replaced at startup.
  static const version = 1;

  /// Offered where Stack Wallet's own theme choice is not: the Campfire build
  /// (no AppFeature.themeSelection) that has BEAM.
  static bool get offered =>
      !AppConfig.hasFeature(AppFeature.themeSelection) &&
      AppConfig.coins.any((c) => c is Beam);
}

/// The theme preferences, in Prefs' own keys (Stack Wallet's).
typedef BeamThemePrefs = ({
  bool followDevice,
  String themeId,
  String lightId,
  String darkId,
});

/// Settings -> Colours, in the order shown. BEAM is dark by default (owner,
/// 2026-10-14): the choice named just "BEAM" is the dark one, first after
/// Campfire.
enum BeamColours {
  campfire,
  beamDark,
  beamLight,
  beamDevice;

  /// The choice's name. "Campfire" and "BEAM" are brand names, never
  /// translated.
  String get label => switch (this) {
    campfire => 'Campfire',
    beamDark => 'BEAM',
    beamLight => appL10n.settingsColoursBeamLight,
    beamDevice => appL10n.settingsColoursBeamDevice,
  };

  /// The line under the choice's name.
  String get detail => switch (this) {
    campfire => appL10n.settingsColoursCampfireDetail,
    beamDevice => appL10n.settingsColoursBeamDeviceDetail,
    beamLight => appL10n.settingsColoursBeamLightDetail,
    beamDark => appL10n.settingsColoursBeamDarkDetail,
  };

  /// What [prefs] show. Anything that is not one of BEAM's choices is
  /// Campfire's, the default.
  static BeamColours from(BeamThemePrefs prefs) {
    if (prefs.followDevice) {
      return prefs.lightId == BeamThemes.light &&
              prefs.darkId == BeamThemes.dark
          ? beamDevice
          : campfire;
    }
    return switch (prefs.themeId) {
      BeamThemes.light => beamLight,
      BeamThemes.dark => beamDark,
      _ => campfire,
    };
  }

  /// [prefs] with this choice saved. Campfire and the fixed BEAM themes stop
  /// following the device (Campfire has no dark theme to follow it with).
  BeamThemePrefs applyTo(BeamThemePrefs prefs) => switch (this) {
    campfire => (
      followDevice: false,
      themeId: BeamThemes.campfire,
      lightId: prefs.lightId,
      darkId: prefs.darkId,
    ),
    beamLight => (
      followDevice: false,
      themeId: BeamThemes.light,
      lightId: prefs.lightId,
      darkId: prefs.darkId,
    ),
    beamDark => (
      followDevice: false,
      themeId: BeamThemes.dark,
      lightId: prefs.lightId,
      darkId: prefs.darkId,
    ),
    beamDevice => (
      followDevice: true,
      themeId: prefs.themeId,
      lightId: BeamThemes.light,
      darkId: BeamThemes.dark,
    ),
  };

  /// The theme on screen for [prefs] on a device that is [platform].
  static String showing(BeamThemePrefs prefs, Brightness platform) =>
      prefs.followDevice
      ? (platform == Brightness.dark ? prefs.darkId : prefs.lightId)
      : prefs.themeId;
}

/// Prefs' theme keys as [BeamThemePrefs], and back.
extension BeamThemePrefsOf on Prefs {
  BeamThemePrefs get beamThemePrefs => (
    followDevice: enableSystemBrightness,
    themeId: themeId,
    lightId: systemBrightnessLightThemeId,
    darkId: systemBrightnessDarkThemeId,
  );

  void saveBeamThemePrefs(BeamThemePrefs p) {
    // The ids first: once following the device is on, both must be BEAM's.
    systemBrightnessLightThemeId = p.lightId;
    systemBrightnessDarkThemeId = p.darkId;
    themeId = p.themeId;
    enableSystemBrightness = p.followDevice;
  }
}
