/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// 3-line spec:
// 1. Job: choose the app's colours: Campfire's (the default) or BEAM's, and
//    for BEAM's light, dark or like the device.
// 2. Primary CTA: none; a choice applies at once (like the web wallet's).
// 3. Taps from app open: 3 (menu or Settings, Colours, a choice).
//
// Exit-intent check: "will this break my wallet?" - nothing but colours
// changes, at once and back again with one tap, and the line under the title
// says the logo stays; "which one is which?" - each choice has its own
// swatch (page and button colour) and one line saying what it does.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/global/prefs_provider.dart';
import '../../../themes/beam/beam_themes.dart';
import '../../../themes/stack_colors.dart';
import '../../../themes/theme_providers.dart';
import '../../../themes/theme_service.dart';
import '../../../utilities/text_styles.dart';
import '../../../widgets/background.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/rounded_white_container.dart';

abstract final class BeamColoursText {
  static const title = 'Colours';
  static const subtitle = "Campfire's red or BEAM's own colours";
  static const lead =
      "BEAM's colours are the ones BEAM's own wallets use. "
      "The logo stays Campfire's.";
}

/// Each choice's swatch: its page and its main button (the themes'
/// background and button_back_primary; test/beam/theme checks they agree).
const kBeamColoursSwatches = <String, ({Color page, Color button})>{
  BeamThemes.campfire: (page: Color(0xFFFFF1F1), button: Color(0xFFB62039)),
  BeamThemes.light: (page: Color(0xFFEEF4FA), button: Color(0xFF00F6D2)),
  BeamThemes.dark: (page: Color(0xFF042548), button: Color(0xFF00F6D2)),
};

/// Saves [choice] and puts its theme on screen now.
void applyBeamColours(WidgetRef ref, BeamColours choice, Brightness platform) {
  final prefs = ref.read(prefsChangeNotifierProvider);
  final next = choice.applyTo(prefs.beamThemePrefs);
  final theme = ref
      .read(pThemeService)
      .getTheme(themeId: BeamColours.showing(next, platform));
  // A theme that is not installed is never put in the preferences either.
  if (theme == null) return;
  prefs.saveBeamThemePrefs(next);
  ref.read(themeProvider.state).state = theme;
}

/// The choices, one under another, the selected one marked.
class BeamColoursChoice extends ConsumerWidget {
  const BeamColoursChoice({super.key, this.onSelected, this.prefs});

  /// Instead of [applyBeamColours] (tests).
  final void Function(BeamColours)? onSelected;

  /// Instead of what Prefs hold (tests).
  final BeamThemePrefs? prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = BeamColours.from(
      prefs ??
          ref.watch(
            prefsChangeNotifierProvider.select((p) => p.beamThemePrefs),
          ),
    );
    void select(BeamColours? c) {
      if (c == null || c == current) return;
      if (onSelected != null) return onSelected!(c);
      applyBeamColours(ref, c, MediaQuery.platformBrightnessOf(context));
    }

    return RadioGroup<BeamColours>(
      groupValue: current,
      onChanged: select,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in BeamColours.values)
            _Option(choice: c, onTap: () => select(c)),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.choice, required this.onTap});

  final BeamColours choice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      key: Key('beamColours_${choice.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Radio<BeamColours>(
              value: choice,
              activeColor: colors.radioButtonIconEnabled,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 8),
            _Swatch(choice: choice),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(choice.label, style: STextStyles.titleBold12(context)),
                  const SizedBox(height: 2),
                  Text(
                    choice.detail,
                    style: STextStyles.itemSubtitle(context)
                        .copyWith(color: colors.textDark3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A coin of the choice's page colour with its button colour in the middle;
/// half light, half dark for "like this device".
class _Swatch extends StatelessWidget {
  const _Swatch({required this.choice});

  final BeamColours choice;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final light = switch (choice) {
      BeamColours.campfire => kBeamColoursSwatches[BeamThemes.campfire]!,
      BeamColours.beamDark => kBeamColoursSwatches[BeamThemes.dark]!,
      _ => kBeamColoursSwatches[BeamThemes.light]!,
    };
    final dark = choice == BeamColours.beamDevice
        ? kBeamColoursSwatches[BeamThemes.dark]!
        : light;
    return ExcludeSemantics(
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.textSubtitle4),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0.5, 0.5],
            colors: [light.page, dark.page],
          ),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: light.button,
          ),
        ),
      ),
    );
  }
}

/// Settings -> Colours on a phone.
class BeamColoursView extends StatelessWidget {
  const BeamColoursView({super.key, this.onSelected, this.prefs});

  final void Function(BeamColours)? onSelected;
  final BeamThemePrefs? prefs;

  /// Opens it from Settings.
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const BeamColoursView()));

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(
            BeamColoursText.title,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: RoundedWhiteContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                    child: Text(
                      BeamColoursText.lead,
                      style: STextStyles.itemSubtitle(context)
                          .copyWith(color: colors.textDark3),
                    ),
                  ),
                  BeamColoursChoice(onSelected: onSelected, prefs: prefs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings -> Colours on desktop: the panel beside the settings menu.
class BeamColoursDesktopSettings extends StatelessWidget {
  const BeamColoursDesktopSettings({super.key, this.onSelected, this.prefs});

  final void Function(BeamColours)? onSelected;
  final BeamThemePrefs? prefs;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(right: 30),
        child: RoundedWhiteContainer(
          radiusMultiplier: 2,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                BeamColoursText.title,
                style: STextStyles.desktopTextSmall(context),
              ),
              const SizedBox(height: 8),
              Text(
                BeamColoursText.lead,
                style: STextStyles.desktopTextExtraExtraSmall(context),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: BeamColoursChoice(onSelected: onSelected, prefs: prefs),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
