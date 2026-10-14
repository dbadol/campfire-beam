/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (the prompt):
// 1. Job: decide whether a dApp installed from a file may reach one server.
// 2. Primary CTA: "Allow"; "Not now" beside it (and closing it) says no
//    until the dApp is closed.
// 3. Taps: none to see it (the dApp's refused request brings it up); one
//    to answer.
//
// Spec (More):
// 1. Job: see which servers this dApp may reach, and take one back.
// 2. No primary: "Remove access" on each server; "Reload" below.
// 3. Taps from the open dApp: More = 1, Remove access = 2.
//
// The words are the web wallet's (pwa/src/screens/dapps.js), so a person
// using both reads the same thing.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/dapps/dapp_remote_origins.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';

/// What the network prompt and the More sheet say (lib/l10n, dapps*
/// keys).
abstract final class DappNetworkText {
  static String askTitle(String name, String host) =>
      appL10n.dappsReachTitle(name, host);

  static String askLead(String name, String host) =>
      appL10n.dappsReachLead(host, name);

  static String askDetail(String name) => appL10n.dappsReachDetail(name);

  /// Only while Tor is on: the dApp window does not use it.
  static String get torNote => appL10n.dappsReachTorNote;

  static String get allow => appL10n.dappsReachAllow;
  static String get notNow => appL10n.dappsReachNotNow;

  static String allowed(String name, String host) =>
      appL10n.dappsReachAllowed(name, host);

  static String allowFailed(String name, String host) =>
      appL10n.dappsReachAllowFailed(name, host);

  static String get more => appL10n.dappsServersMore;
  static String get serversTitle => appL10n.dappsServersTitle;
  static String get serverSubtitle => appL10n.dappsServerSubtitle;
  static String get removeAccess => appL10n.dappsServerRemoveAccess;
  static String get reload => appL10n.dappsServersReload;

  static String none(String name) => appL10n.dappsServersNone(name);

  static String meta({String? version, String? publisher}) {
    final l = appL10n;
    if (version == null) {
      return publisher == null
          ? l.dappsServersMetaNoVersionUnknownPublisher
          : l.dappsServersMetaNoVersionBy(publisher);
    }
    return publisher == null
        ? l.dappsServersMetaVersionUnknownPublisher(version)
        : l.dappsServersMetaVersionBy(version, publisher);
  }

  static String revoked(String name, String host) =>
      appL10n.dappsServersRevoked(name, host);

  static String revokeFailed(String name) =>
      appL10n.dappsServersRevokeFailed(name);
}

/// Asks whether the dApp [name] may connect to [origin]. True for Allow;
/// false for Not now or when it is closed.
Future<bool> showDappReachPrompt(
  BuildContext context, {
  required String name,
  required String origin,
  required bool desktop,
  bool torOn = false,
}) async {
  final prompt = DappReachPrompt(
    name: name,
    host: dappOriginHost(origin),
    desktop: desktop,
    torOn: torOn,
  );
  final bool? result;
  if (desktop) {
    result = await showDialog<bool>(
      context: context,
      builder: (_) => DesktopDialog(
        maxWidth: 520,
        maxHeight: double.infinity,
        child: prompt,
      ),
    );
  } else {
    result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => prompt,
    );
  }
  return result == true;
}

/// "Let <dApp> connect to <host>?", with Allow and Not now.
class DappReachPrompt extends StatelessWidget {
  const DappReachPrompt({
    super.key,
    required this.name,
    required this.host,
    required this.desktop,
    this.torOn = false,
  });

  final String name;
  final String host;
  final bool desktop;
  final bool torOn;

  static const allowKey = Key('dappReachAllow');
  static const notNowKey = Key('dappReachNotNow');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final allow = PrimaryButton(
      key: allowKey,
      label: DappNetworkText.allow,
      buttonHeight: desktop ? ButtonHeight.l : null,
      height: desktop ? null : 46,
      onPressed: () => Navigator.of(context).pop(true),
    );
    final notNow = SecondaryButton(
      key: notNowKey,
      label: DappNetworkText.notNow,
      buttonHeight: desktop ? ButtonHeight.l : null,
      height: desktop ? null : 46,
      onPressed: () => Navigator.of(context).pop(false),
    );
    final words = [
      Text(
        DappNetworkText.askLead(name, host),
        style:
            (desktop
                    ? STextStyles.desktopTextSmall(context)
                    : STextStyles.smallMed14(context))
                .copyWith(color: colors.textDark),
      ),
      const SizedBox(height: 12),
      _WithMoreIcon(
        text: DappNetworkText.askDetail(name),
        style: desktop
            ? STextStyles.desktopTextExtraSmall(context)
                  .copyWith(color: colors.textSubtitle1)
            : STextStyles.smallMed12(context),
      ),
      if (torOn) ...[
        const SizedBox(height: 12),
        _Note(text: DappNetworkText.torNote),
      ],
    ];
    final title = Text(
      DappNetworkText.askTitle(name, host),
      key: const Key('dappReachTitle'),
      style: desktop
          ? STextStyles.desktopH3(context)
          : STextStyles.pageTitleH2(context),
    );

    if (desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 32, top: 28),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Globe(size: 32),
                      const SizedBox(width: 12),
                      Expanded(child: title),
                    ],
                  ),
                ),
              ),
              DesktopDialogCloseButton(
                onPressedOverride: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...words,
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(child: notNow),
                    const SizedBox(width: 16),
                    Expanded(child: allow),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return _PhoneSheet(
      children: [
        const _Globe(size: 40),
        const SizedBox(height: 12),
        title,
        const SizedBox(height: 12),
        ...words,
        const SizedBox(height: 20),
        allow,
        const SizedBox(height: 8),
        notNow,
      ],
    );
  }
}

/// What the person chose in the More sheet.
@immutable
class DappServersChoice {
  const DappServersChoice.revoke(String this.origin);
  const DappServersChoice.reload() : origin = null;

  /// The server to take back; null for Reload.
  final String? origin;
}

/// The More sheet of a dApp installed from a file: what it is, the servers
/// it may reach with Remove access each, and Reload.
Future<DappServersChoice?> showDappServersSheet(
  BuildContext context, {
  required String name,
  required String meta,
  required List<String> origins,
  required bool desktop,
}) {
  final sheet = DappServersSheet(
    name: name,
    meta: meta,
    origins: origins,
    desktop: desktop,
  );
  if (desktop) {
    return showDialog<DappServersChoice>(
      context: context,
      builder: (_) => DesktopDialog(
        maxWidth: 520,
        maxHeight: double.infinity,
        child: sheet,
      ),
    );
  }
  return showModalBottomSheet<DappServersChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => sheet,
  );
}

class DappServersSheet extends StatelessWidget {
  const DappServersSheet({
    super.key,
    required this.name,
    required this.meta,
    required this.origins,
    required this.desktop,
  });

  final String name;
  final String meta;
  final List<String> origins;
  final bool desktop;

  static const reloadKey = Key('dappServersReload');
  static const noneKey = Key('dappServersNone');

  static Key removeKey(String origin) => Key('dappServerRemove_$origin');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final title = Text(
      name,
      style: desktop
          ? STextStyles.desktopH3(context)
          : STextStyles.pageTitleH2(context),
    );
    final body = [
      Text(
        meta,
        style: STextStyles.w500_12(context)
            .copyWith(color: colors.warningForeground),
      ),
      const SizedBox(height: 20),
      Text(
        DappNetworkText.serversTitle,
        style: STextStyles.sectionLabelMedium12(context),
      ),
      const SizedBox(height: 8),
      if (origins.isEmpty)
        Text(
          DappNetworkText.none(name),
          key: noneKey,
          style: STextStyles.smallMed12(context),
        )
      else
        RoundedContainer(
          color: colors.textFieldDefaultBG,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, o) in origins.indexed) ...[
                if (i > 0) Divider(height: 1, color: colors.background),
                _ServerRow(
                  origin: o,
                  onRemove: () =>
                      Navigator.of(context).pop(DappServersChoice.revoke(o)),
                ),
              ],
            ],
          ),
        ),
    ];
    final reload = SecondaryButton(
      key: reloadKey,
      label: DappNetworkText.reload,
      buttonHeight: desktop ? ButtonHeight.l : null,
      height: desktop ? null : 46,
      onPressed: () =>
          Navigator.of(context).pop(const DappServersChoice.reload()),
    );

    if (desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: title,
                ),
              ),
              const DesktopDialogCloseButton(),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [...body, const SizedBox(height: 28), reload],
            ),
          ),
        ],
      );
    }
    return _PhoneSheet(
      children: [
        title,
        const SizedBox(height: 8),
        ...body,
        const SizedBox(height: 20),
        reload,
      ],
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.origin, required this.onRemove});

  final String origin;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          const _Globe(size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dappOriginHost(origin),
                  style: STextStyles.w600_14(context)
                      .copyWith(color: colors.textDark),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  DappNetworkText.serverSubtitle,
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          CustomTextButton(
            key: DappServersSheet.removeKey(origin),
            text: DappNetworkText.removeAccess,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

/// A phone bottom sheet as the dApp approval sheet draws it.
class _PhoneSheet extends StatelessWidget {
  const _PhoneSheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.popupBG,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 60,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.textFieldDefaultBG,
                    borderRadius: BorderRadius.circular(
                      Constants.size.circularBorderRadius,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _Globe extends StatelessWidget {
  const _Globe({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colors.textFieldDefaultBG,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.public,
          size: size * 0.6,
          color: colors.textSubtitle1,
        ),
      ),
    );
  }
}

/// [text] with each "⋯" drawn as the More button's own icon, so the words
/// point at the button (and need no glyph the font may lack).
class _WithMoreIcon extends StatelessWidget {
  const _WithMoreIcon({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final parts = text.split('⋯');
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, part) in parts.indexed) ...[
            if (i > 0)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(
                  Icons.more_horiz,
                  size: (style.fontSize ?? 14) + 2,
                  color: style.color,
                ),
              ),
            TextSpan(text: part),
          ],
        ],
      ),
      style: style,
      semanticsLabel: text,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      color: colors.warningBackground,
      child: Text(
        text,
        style: STextStyles.w500_12(context)
            .copyWith(color: colors.warningForeground),
      ),
    );
  }
}
