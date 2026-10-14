/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   1. Job: choose the language the app speaks; it follows the device until
//      one is chosen.
//   2. Primary CTA: none — tapping a language applies it at once (the
//      outcome is the screen itself changing language).
//   3. Taps: Settings → Language → a language (2 taps from Settings).
//
// Exit-intent: "which one is mine?" → every language is written in its own
// script, so a person who cannot read the current one still finds theirs;
// "did it work?" → the screen redraws in the new language right away, with
// nothing closed; "why is some text still English?" → the note under the
// list says what is not translated yet.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../../../l10n/app_language.dart';
import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../widgets/background.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/rounded_white_container.dart';

/// Settings → Language on a phone: the language list on its own page.
class AppLanguageView extends StatelessWidget {
  const AppLanguageView({super.key});

  @override
  Widget build(BuildContext context) => Background(
    child: Scaffold(
      backgroundColor: Theme.of(context).extension<StackColors>()!.background,
      appBar: AppBar(
        leading: AppBarBackButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(
          context.l10n.settingsLanguageTitle,
          style: STextStyles.navBarTitle(context),
        ),
      ),
      body: const SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: AppLanguageList(),
        ),
      ),
    ),
  );
}

/// Settings → Language on desktop: the settings pane, with the list in it
/// (no dialog in between).
class DesktopAppLanguageSettings extends StatelessWidget {
  const DesktopAppLanguageSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(right: 30),
      child: RoundedWhiteContainer(
        radiusMultiplier: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: SvgPicture.asset(
                Assets.svg.circleLanguage,
                width: 48,
                height: 48,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.settingsLanguageTitle,
                    style: STextStyles.desktopTextSmall(context),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.settingsLanguageDescription,
                    style: STextStyles.desktopTextExtraExtraSmall(context),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(width: 512, child: AppLanguageList()),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Like this device" and each language, as radio rows, plus the note on
/// what stays in English.
class AppLanguageList extends ConsumerWidget {
  const AppLanguageList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final chosen = ref.watch(pAppLanguage.select((p) => p.value));
    final device = resolveAppLocale(
      WidgetsBinding.instance.platformDispatcher.locales,
    );
    void choose(AppLanguage language) =>
        ref.read(pAppLanguage).value = language;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoundedWhiteContainer(
          padding: const EdgeInsets.all(4),
          child: RadioGroup<AppLanguage>(
            groupValue: chosen,
            onChanged: (language) {
              if (language != null) choose(language);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final language in AppLanguage.values)
                  _LanguageRow(
                    key: ValueKey('app-language-${language.name}'),
                    language: language,
                    title: language.endonym ?? l10n.settingsLanguageLikeDevice,
                    subtitle: language == AppLanguage.system
                        ? appLanguageEndonymFor(device)
                        : null,
                    onTap: () => choose(language),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.settingsLanguageUntranslatedNote,
          style: Util.isDesktop
              ? STextStyles.desktopTextExtraExtraSmall(context)
              : STextStyles.itemSubtitle(context),
        ),
      ],
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    super.key,
    required this.language,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final AppLanguage language;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RawMaterialButton(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          Constants.size.circularBorderRadius,
        ),
      ),
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Radio<AppLanguage>(
                activeColor: colors.radioButtonIconEnabled,
                value: language,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Util.isDesktop
                        ? STextStyles.desktopTextExtraSmall(context)
                              .copyWith(color: colors.textDark)
                        : STextStyles.titleBold12(context),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: Util.isDesktop
                          ? STextStyles.desktopTextExtraExtraSmall(context)
                          : STextStyles.itemSubtitle(context),
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
