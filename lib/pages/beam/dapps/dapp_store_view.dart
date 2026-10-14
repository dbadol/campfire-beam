/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. Job: open a BEAM dApp, or install one of the checked dApps first.
// 2. Primary action: "Open" on an installed dApp (the whole card opens it);
//    "Install" on a bundled one. "Install from a file" is secondary.
// 3. Taps from app open: wallet → dApps → Open = 3 (4 the first time,
//    with Install).
//
// Exit-intent — what would make an impatient person close the app:
// * "Is this safe?" The first line says a dApp cannot move money without
//   asking; bundled dApps say they are checked against a pinned
//   fingerprint; a dApp from a file says plainly that Campfire did not
//   check it.
// * Waiting with no feedback: a row being installed says what is happening.
// * Errors that blame them or end nowhere: every failure says what
//   happened and the next step, and the list stays usable.
// * Platforms without the dApp window: the page says so up front instead
//   of failing on Open.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../l10n/l10n.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/beam/file_picker_failure.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/dapps/dapp_installer.dart';
import '../../../wallets/beam/dapps/dapp_package.dart';
import '../../../wallets/beam/dapps/dapp_remote_origins.dart';
import '../../../wallets/beam/dapps/host/dapp_host.dart';
import '../../../wallets/beam/dapps/host/dapp_store_controller.dart';
import '../../../widgets/background.dart';
import '../../../widgets/beam/dapps/dapp_avatar.dart';
import '../../../widgets/beam/dapps/dapp_webview.dart';
import '../../../widgets/conditional_parent.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_dialog.dart';
import 'dapp_browser_view.dart';

/// Picks a `.dapp` file; null when the user cancelled.
typedef DappFilePicker = Future<String?> Function();

/// The file picker's filter for a .dapp file. Phones get every file: iOS
/// has no type for ".dapp" (nothing declares one), so a ".dapp" filter
/// greys out every file there, and Android cannot map it to a MIME type
/// either. Whatever is picked is checked as a package when it is read
/// (DappStoreController.readFile).
({FileType type, List<String>? allowedExtensions}) dappFilePickerFilter({
  required bool phone,
}) => phone
    ? (type: FileType.any, allowedExtensions: null)
    : (type: FileType.custom, allowedExtensions: const ['dapp']);

class DappStoreView extends ConsumerStatefulWidget {
  const DappStoreView({
    super.key,
    required this.host,
    this.controller,
    this.pickFile,
    this.desktop,
    this.webviewAvailable,
  });

  static const String routeName = "/beamDappStore";
  static String get title => appL10n.dappsStoreTitle;

  final DappHost host;

  /// A ready controller (tests); otherwise one is made from [host].
  final DappStoreController? controller;
  final DappFilePicker? pickFile;

  /// Overrides `Util.isDesktop` (tests).
  final bool? desktop;

  /// Overrides the platform check for the dApp window (tests).
  final bool? webviewAvailable;

  @override
  ConsumerState<DappStoreView> createState() => _DappStoreViewState();
}

class _DappStoreViewState extends ConsumerState<DappStoreView> {
  DappStoreController? _controller;
  bool _ownsController = false;
  bool _setupFailed = false;

  bool get _desktop => widget.desktop ?? Util.isDesktop;

  @override
  void initState() {
    super.initState();
    unawaited(_setup());
  }

  Future<void> _setup() async {
    try {
      final c =
          widget.controller ??
          DappStoreController(
            installer: await widget.host.installer(),
            fetcher: widget.host.fetcher,
          );
      _ownsController = widget.controller == null;
      if (!mounted) {
        if (_ownsController) c.dispose();
        return;
      }
      c.addListener(_changed);
      setState(() {
        _controller = c;
        _setupFailed = false;
      });
      if (widget.controller == null || c.status == DappStoreStatus.loading) {
        await c.refresh();
      }
    } catch (_) {
      if (mounted) setState(() => _setupFailed = true);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  void _open(DappInstallation installation) {
    unawaited(
      Navigator.of(context).pushNamed(
        DappBrowserView.routeName,
        arguments: (host: widget.host, installation: installation),
      ),
    );
  }

  Future<void> _install(DappStoreItem item) async {
    final c = _controller;
    final entry = item.bundled;
    if (c == null || entry == null) return;
    try {
      await c.installBundled(entry);
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.success,
            message: context.l10n.dappsStoreInstalledToast(item.name),
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) _problem(dappInstallErrorText(e, name: item.name));
    }
  }

  Future<String?> _pickFile() async {
    final picker = widget.pickFile;
    if (picker != null) return picker();
    final filter = dappFilePickerFilter(
      phone: Platform.isAndroid || Platform.isIOS,
    );
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: context.l10n.dappsStorePickFileTitle,
      type: filter.type,
      allowedExtensions: filter.allowedExtensions,
      lockParentWindow: true,
    );
    return result?.paths.firstOrNull;
  }

  Future<void> _installFromFile() async {
    final c = _controller;
    if (c == null) return;
    final String? path;
    try {
      path = await _pickFile();
    } catch (_) {
      if (mounted) {
        _problem(filePickerFailureText());
      }
      return;
    }
    if (path == null || !mounted) return;
    final DappPackage package;
    try {
      package = await c.readFile(path);
    } catch (e) {
      if (mounted) _problem(dappInstallErrorText(e));
      return;
    }
    if (!mounted) return;
    final existing = c.existingFor(package);
    var keeps = const <String>[];
    if (existing != null) {
      try {
        keeps = await c.installer.allowedOrigins(existing.guid);
      } catch (_) {
        // Not shown; the servers are kept either way.
      }
      if (!mounted) return;
    }
    final ok = await _confirmFromFile(
      package,
      existing,
      copies: c.bundledNameCopiedBy(package),
      keeps: keeps,
    );
    if (ok != true || !mounted) return;
    try {
      await c.installPackage(package, replace: existing != null);
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.success,
            message: context.l10n.dappsStoreInstalledToast(
              package.manifest.name,
            ),
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _problem(dappInstallErrorText(e, name: package.manifest.name));
      }
    }
  }

  Future<void> _remove(DappStoreItem item) async {
    final c = _controller;
    if (c == null) return;
    final l10n = context.l10n;
    final ok = await _confirm(
      title: l10n.dappsStoreRemoveTitle(item.name),
      message: l10n.dappsStoreRemoveMessage,
      confirm: l10n.dappsStoreRemove,
    );
    if (ok != true) return;
    try {
      await c.uninstall(item.guid);
    } catch (_) {
      if (mounted) {
        _problem(context.l10n.dappsStoreRemoveFailed(item.name));
      }
    }
  }

  void _problem(String message) => unawaited(
    showFloatingFlushBar(
      type: FlushBarType.warning,
      message: message,
      context: context,
    ),
  );

  Future<bool?> _confirmFromFile(
    DappPackage package,
    DappInstallation? existing, {
    String? copies,
    List<String> keeps = const [],
  }) {
    final l10n = context.l10n;
    final m = package.manifest;
    final version = m.version;
    final publisher = m.publisher;
    final installedVersion = existing?.manifest.version;
    final lines = [
      if (version == null)
        publisher == null
            ? l10n.dappsFromFileNoVersionUnknownPublisher
            : l10n.dappsFromFileNoVersionBy(publisher)
      else
        publisher == null
            ? l10n.dappsFromFileVersionUnknownPublisher(version)
            : l10n.dappsFromFileVersionBy(version, publisher),
      if (existing != null)
        joinSentences([
          installedVersion == null
              ? l10n.dappsFromFileReplacesNoVersion
              : l10n.dappsFromFileReplaces(installedVersion),
          if (keeps.isNotEmpty)
            l10n.dappsFromFileKeepsServers(
              keeps.map(dappOriginHost).join(", "),
            ),
        ], l10n),
      if (copies != null) l10n.dappsFromFileNameCopies(copies),
      l10n.dappsFromFileNotChecked,
    ];
    return _confirm(
      title: l10n.dappsFromFileInstallTitle(m.name),
      message: lines.join("\n\n"),
      confirm: existing == null
          ? l10n.dappsStoreInstall
          : l10n.dappsFromFileReplace,
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirm,
  }) {
    if (_desktop) {
      return showDialog<bool>(
        context: context,
        builder: (context) => DesktopDialog(
          maxWidth: 520,
          maxHeight: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.desktopH3(context)),
                const SizedBox(height: 16),
                Text(message, style: STextStyles.desktopTextSmall(context)),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: context.l10n.commonCancel,
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PrimaryButton(
                        label: confirm,
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    final colors = Theme.of(context).extension<StackColors>()!;
    return showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: message,
        leftButton: TextButton(
          style: colors.getSecondaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            context.l10n.commonCancel,
            style: STextStyles.button(context)
                .copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm, style: STextStyles.button(context)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop;
    final content = _content(context, desktop);
    return ConditionalParent(
      condition: desktop,
      builder: (child) => DesktopScaffold(
        appBar: DesktopAppBar(
          isCompactHeight: true,
          useSpacers: false,
          background: Theme.of(context).extension<StackColors>()!.popupBG,
          leading: Expanded(
            child: Row(
              children: [
                const SizedBox(width: 32),
                AppBarIconButton(
                  size: 32,
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textFieldDefaultBG,
                  shadows: const [],
                  icon: SvgPicture.asset(
                    Assets.svg.arrowLeft,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      Theme.of(context)
                          .extension<StackColors>()!
                          .topNavIconPrimary,
                      BlendMode.srcIn,
                    ),
                  ),
                  onPressed: Navigator.of(context).pop,
                ),
                const SizedBox(width: 12),
                Text(
                  DappStoreView.title,
                  style: STextStyles.desktopH3(context),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: child,
          ),
        ),
      ),
      child: ConditionalParent(
        condition: !desktop,
        builder: (child) => Background(
          child: Scaffold(
            backgroundColor: Theme.of(context)
                .extension<StackColors>()!
                .background,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: AppBarBackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                DappStoreView.title,
                style: STextStyles.navBarTitle(context),
              ),
            ),
            body: SafeArea(child: child),
          ),
        ),
        child: content,
      ),
    );
  }

  Widget _content(BuildContext context, bool desktop) {
    final c = _controller;
    final colors = Theme.of(context).extension<StackColors>()!;
    final pad = desktop ? 24.0 : 16.0;
    final l10n = context.l10n;

    if (_setupFailed || c?.status == DappStoreStatus.failed) {
      return Padding(
        padding: EdgeInsets.all(pad),
        child: _Notice(
          title: l10n.dappsStoreLoadFailedTitle,
          body: l10n.dappsStoreLoadFailedBody,
          action: PrimaryButton(
            label: l10n.commonTryAgain,
            buttonHeight: desktop ? ButtonHeight.l : null,
            height: desktop ? null : 46,
            onPressed: () {
              setState(() => _setupFailed = false);
              if (c == null) {
                unawaited(_setup());
              } else {
                unawaited(c.refresh());
              }
            },
          ),
        ),
      );
    }
    if (c == null || c.status == DappStoreStatus.loading) {
      return Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              l10n.dappsStoreLoading,
              style: STextStyles.smallMed14(context),
            ),
          ],
        ),
      );
    }

    final installed = c.installed;
    final available = c.available;
    final windowAvailable = widget.webviewAvailable ?? dappWebviewAvailable();
    return ListView(
      padding: EdgeInsets.all(pad),
      children: [
        Text(
          l10n.dappsStoreIntro,
          style: STextStyles.smallMed14(context)
              .copyWith(color: colors.textDark),
        ),
        if (!windowAvailable) ...[
          const SizedBox(height: 12),
          RoundedContainer(
            color: colors.textFieldDefaultBG,
            child: Text(
              joinSentences([
                dappWindowPlatformsSentence,
                l10n.dappsStoreManageHere,
              ], l10n),
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textDark3),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _SectionLabel(text: l10n.dappsStoreInstalledSection),
        const SizedBox(height: 8),
        if (installed.isEmpty)
          _Notice(
            title: l10n.dappsStoreNoneInstalledTitle,
            body: l10n.dappsStoreNoneInstalledBody,
          ),
        for (final item in installed)
          _DappRow(
            item: item,
            busy: c.isBusy(item.guid),
            onTap: () => _open(item.installed!),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SecondaryButton(
                  key: Key("dappOpen_${item.guid}"),
                  label: l10n.dappsStoreOpen,
                  width: 76,
                  buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
                  enabled: !c.isBusy(item.guid),
                  onPressed: () => _open(item.installed!),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: Key("dappRemove_${item.guid}"),
                  tooltip: l10n.dappsStoreRemove,
                  onPressed: c.isBusy(item.guid) ? null : () => _remove(item),
                  icon: SvgPicture.asset(
                    Assets.svg.trash,
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(
                      colors.textSubtitle1,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        _SectionLabel(text: l10n.dappsStoreAvailableSection),
        const SizedBox(height: 8),
        if (available.isEmpty)
          _Notice(
            title: l10n.dappsStoreAllInstalledTitle,
            body: l10n.dappsStoreAllInstalledBody,
          ),
        for (final item in available)
          _DappRow(
            item: item,
            busy: c.isBusy(item.guid),
            trailing: SecondaryButton(
              key: Key("dappInstall_${item.guid}"),
              label: l10n.dappsStoreInstall,
              width: 88,
              buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
              enabled: !c.isBusy(item.guid),
              onPressed: () => _install(item),
            ),
          ),
        const SizedBox(height: 20),
        RoundedWhiteContainer(
          child: Flex(
            direction: desktop ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: desktop
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.dappsStoreHaveFile,
                style: STextStyles.smallMed12(context),
              ),
              if (desktop) const Spacer() else const SizedBox(height: 10),
              SecondaryButton(
                key: const Key("dappInstallFromFile"),
                label: l10n.dappsStoreInstallFromFile,
                width: desktop ? 200 : null,
                buttonHeight: desktop ? ButtonHeight.s : null,
                // 40 clipped the label by 2 px on phones; 46 as the other
                // phone buttons here.
                height: desktop ? null : 46,
                onPressed: _installFromFile,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: STextStyles.sectionLabelMedium12(context));
}

class _Notice extends StatelessWidget {
  const _Notice({required this.title, required this.body, this.action});

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: STextStyles.w600_14(context)
                .copyWith(color: colors.textDark),
          ),
          const SizedBox(height: 4),
          Text(body, style: STextStyles.smallMed12(context)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class _DappRow extends StatelessWidget {
  const _DappRow({
    required this.item,
    required this.busy,
    required this.trailing,
    this.onTap,
  });

  final DappStoreItem item;
  final bool busy;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final installed = item.installed;
    final l10n = context.l10n;
    final String meta;
    if (busy) {
      meta = installed == null
          ? l10n.dappsStoreRowDownloading
          : l10n.beamWorking;
    } else if (installed == null) {
      meta = l10n.dappsStoreRowDownloadChecked('${item.downloadLabel}');
    } else {
      final v = installed.manifest.version;
      if (item.isPinned) {
        meta = v == null
            ? l10n.dappsStoreRowPinnedNoVersion
            : l10n.dappsStoreRowPinned(v);
      } else {
        meta = v == null
            ? l10n.dappsStoreRowFromFileNoVersion
            : l10n.dappsStoreRowFromFile(v);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RoundedWhiteContainer(
        onPressed: busy ? null : onTap,
        child: Row(
          children: [
            DappAvatar(
              name: item.name,
              iconFile: item.iconFile,
              iconAsset: item.iconAsset,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: STextStyles.w600_14(context)
                        .copyWith(color: colors.textDark),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.description!,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (busy) ...[
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          meta,
                          style: STextStyles.w500_10(context).copyWith(
                            color: item.isPinned || busy
                                ? colors.textSubtitle2
                                : colors.warningForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}
