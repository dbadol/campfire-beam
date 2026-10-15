/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Scan a QR code from the BEAM wallet and go where it belongs.
//
// Spec:
//   1. Job: read a QR code and open the screen that pays or claims it, with
//      everything the code said already filled in.
//   2. Primary CTA: the Scan button (the phone wallet's top bar; the desktop
//      wallet's top bar, "Scan QR code"). Then the destination's own button
//      ("Send 1.5 BEAM", "Claim …"), after the person has looked.
//   3. Taps from app open: wallet → Scan (2) → point the camera → the filled
//      form (+ that form's confirm and PIN).
//
// Where each kind goes (scan_route.dart decides, this file carries it out):
//   BEAM address / beam: link   BEAM Send, address and amount filled
//   BEAM name                   BEAM Send, the name looked up as typed
//   Ethereum address / link     the Ethereum wallet's Send, recipient and
//                               amount filled; which wallet is asked when
//                               there are several; none: how to add one
//   airdrop code                Claim a code, the code checked (nothing is
//                               claimed until its button)
//   anything else               a sheet with the text and why nothing was
//                               opened; a web link is never followed
//
// Exit-intent, and the answer to each:
//   * "Did it just pay someone?" Never: every path ends on a form or a
//     sheet, and only that screen's own button (and the PIN) sends.
//   * "Why didn't it open?" The sheet says what the code is, in words.
//   * "Is my camera picture kept?" Nothing is kept or logged; the text is
//     read and dropped.

import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:tuple/tuple.dart';

import '../../../app_config.dart';
import '../../../l10n/l10n.dart';
import '../../../models/add_wallet_list_entity/sub_classes/coin_entity.dart';
import '../../../models/send_view_auto_fill_data.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../pages/add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import '../../../pages/beam/airdrop/beam_claim_voucher_view.dart';
import '../../../pages/send_view/send_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send.dart';
import '../../../providers/global/node_service_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/beam/scan_recognize.dart';
import '../../../utilities/beam/scan_route.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/show_loading.dart';
import '../../../utilities/show_node_tor_settings_mismatch.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../wallets/wallet/wallet.dart';
import '../../../wallets/wallet/wallet_mixin_interfaces/view_only_option_interface.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import '../airdrop/beam_layout.dart';
import '../dex/dex_widgets.dart' show kAddressFontFeatures;
import '../send/beam_send_fill.dart';
import '../wallet_home/beam_wallet_home.dart' show BeamClaimSheetFrame;
import '../wiring/beam_feature_menu.dart';
import '../wiring/beam_wallet_listenables.dart';
import 'beam_qr_reader.dart';
import 'beam_scan_text.dart';

// ------------------------------------------------------------- what we have

/// The Ethereum wallets that can pay (view-only ones cannot).
List<ScanEthWallet> beamScanEthWallets(Iterable<Wallet> wallets) => [
  for (final w in wallets)
    if (w is EthereumWallet && !_viewOnly(w))
      ScanEthWallet(w.walletId, w.info.name),
];

bool _viewOnly(Wallet w) => w is ViewOnlyOptionInterface && w.isViewOnly;

/// Whether this build holds Ethereum at all.
bool get beamScanEthereumInApp => AppConfig.coins.any((c) => c is Ethereum);

/// The symbol of a token Campfire lists by default (WBEAM, USDT, USDC), for
/// a token payment's sheet.
String? beamScanTokenSymbol(String? contract) {
  if (contract == null) return null;
  for (final t in AppConfig.defaultEthTokens) {
    if (t.address.toLowerCase() == contract.toLowerCase()) return t.symbol;
  }
  return null;
}

/// Where [text] goes when scanned [from] the home or BEAM Send, with the
/// wallets of [ref].
ScanDestination beamScanDestinationFor(
  WidgetRef ref,
  String text, {
  ScanFrom from = ScanFrom.home,
}) => scanDestination(
  recognizeScan(text),
  text: text,
  from: from,
  ethWallets: beamScanEthWallets(ref.read(pWallets).wallets),
  ethereumInApp: beamScanEthereumInApp,
);

// ------------------------------------------------------------------- home

/// The home's Scan: reads a code and opens where it belongs.
Future<void> beamScanFromHome(
  BuildContext context,
  WidgetRef ref,
  BeamWallet wallet, {
  required bool desktop,
}) async {
  final text = await ref.read(pBeamQrReader).read(context, desktop: desktop);
  if (text == null || !context.mounted) return;
  await beamScanOpen(
    context,
    ref,
    wallet,
    beamScanDestinationFor(ref, text),
    desktop: desktop,
  );
}

/// Opens [destination] from [wallet]'s screen at [context].
Future<void> beamScanOpen(
  BuildContext context,
  WidgetRef ref,
  BeamWallet wallet,
  ScanDestination destination, {
  required bool desktop,
}) async {
  switch (destination) {
    case ScanToBeamSend(:final recipient, :final amount, :final amountUnread):
      await _openBeamSend(
        context,
        ref,
        wallet,
        recipient,
        amount,
        amountUnread: amountUnread,
        desktop: desktop,
      );
    case final ScanToEthereumSend d:
      await _openEthereumSend(context, ref, d, desktop: desktop);
    case final ScanChooseEthereumWallet d:
      final chosen = await _chooseEthereumWallet(context, d.wallets);
      if (chosen == null || !context.mounted) return;
      await _openEthereumSend(context, ref, d.pick(chosen), desktop: desktop);
    case ScanToClaim(:final code):
      BeamWalletWiring.of(wallet).attach(context);
      await Navigator.of(context).pushNamed(
        BeamClaimVoucherView.routeName,
        arguments: (wallet: wallet, code: code),
      );
    case final ScanStopped stopped:
      final next = await showBeamScanSheet(
        context,
        stopped,
        desktop: desktop,
        walletName: (id) => ref.read(pWallets).getWallet(id).info.name,
      );
      if (!context.mounted) return;
      switch (next) {
        case BeamScanSheetChoice.onward:
          final onward = stopped.onward;
          if (onward != null) {
            await beamScanOpen(context, ref, wallet, onward, desktop: desktop);
          }
        case BeamScanSheetChoice.addEthereumWallet:
          await _addEthereumWallet(context);
        case null:
          break;
      }
  }
}

/// BEAM Send for [wallet]: a page on a phone; on desktop the wallet's own
/// Send tab, brought forward and filled.
Future<void> _openBeamSend(
  BuildContext context,
  WidgetRef ref,
  BeamWallet wallet,
  String recipient,
  String? amount, {
  bool amountUnread = false,
  required bool desktop,
}) async {
  if (desktop) {
    ref.read(pBeamSendFill(wallet.walletId).notifier).state = BeamSendFill.next(
      recipient,
      amount: amount,
      amountUnread: amountUnread,
    );
    return;
  }
  await Navigator.of(context).pushNamed(
    SendView.routeName,
    arguments: Tuple3(
      wallet.walletId,
      wallet.cryptoCurrency,
      SendViewAutoFillData(
        address: recipient,
        contactLabel: recipient,
        amount: amount == null ? null : Decimal.parse(amount),
        amountUnread: amountUnread,
      ),
    ),
  );
}

/// The Ethereum wallet's own Send, opened the way Campfire opens a wallet
/// (its node and Tor settings checked, then loaded), with the recipient and
/// amount filled in. Its own preview, fee and PIN come before anything is
/// sent.
Future<void> _openEthereumSend(
  BuildContext context,
  WidgetRef ref,
  ScanToEthereumSend d, {
  required bool desktop,
}) async {
  final wallet = ref.read(pWallets).getWallet(d.walletId);
  final go = await checkShowNodeTorSettingsMismatch(
    context: context,
    currency: wallet.cryptoCurrency,
    prefs: ref.read(prefsChangeNotifierProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    allowCancel: true,
    rootNavigator: desktop,
  );
  if (!go || !context.mounted) return;
  await showLoading(
    whileFuture: wallet.init(),
    context: context,
    message: context.l10n.scanOpeningWallet(wallet.info.name),
    rootNavigator: desktop,
  );
  if (!context.mounted) return;
  final wei = d.valueWei;
  final fill = SendViewAutoFillData(
    address: d.to,
    contactLabel: d.to,
    amount: wei == null ? null : Decimal.parse(scanWeiToEther(wei)),
  );
  if (!desktop) {
    await Navigator.of(context).pushNamed(
      SendView.routeName,
      arguments: Tuple3(d.walletId, wallet.cryptoCurrency, fill),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => DesktopDialog(
      key: const Key('beamScanEthereumSendDialog'),
      maxWidth: 580,
      maxHeight: MediaQuery.sizeOf(context).height - 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(
                  context.l10n.scanSendFromWallet(
                    wallet.cryptoCurrency.ticker,
                    wallet.info.name,
                  ),
                  style: STextStyles.desktopH3(context),
                ),
              ),
              const DesktopDialogCloseButton(),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: DesktopSend(walletId: d.walletId, autoFillData: fill),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Which Ethereum wallet pays, when there are several.
Future<ScanEthWallet?> _chooseEthereumWallet(
  BuildContext context,
  List<ScanEthWallet> wallets,
) async {
  ScanEthWallet? chosen;
  await showBeamFeatureMenu(
    context,
    title: context.l10n.scanChooseEthWalletTitle,
    options: [
      for (final w in wallets)
        BeamFeatureMenuOption(
          key: Key('beamScanEthWallet_${w.id}'),
          icon: Assets.svg.walletDesktop,
          title: w.name,
          detail: context.l10n.scanChooseEthWalletDetail,
          onSelected: (_) => chosen = w,
        ),
    ],
  );
  return chosen;
}

Future<void> _addEthereumWallet(BuildContext context) =>
    Navigator.of(context, rootNavigator: Util.isDesktop).pushNamed(
      CreateOrRestoreWalletView.routeName,
      arguments: CoinEntity(Ethereum(CryptoCurrencyNetwork.main)),
    );

// ------------------------------------------------------------------ sheet

/// What the person chose on the sheet; null when they closed it.
enum BeamScanSheetChoice { onward, addEthereumWallet }

/// Shows what [stopped] is and why nothing was opened: a bottom sheet on a
/// phone, a dialog on desktop.
Future<BeamScanSheetChoice?> showBeamScanSheet(
  BuildContext context,
  ScanStopped stopped, {
  required bool desktop,
  String Function(String walletId)? walletName,
  ClipboardInterface clipboard = const ClipboardWrapper(),
}) {
  final text = beamScanSheetText(
    stopped,
    tokenSymbol: beamScanTokenSymbol(stopped.token),
    walletName: walletName,
    ethereumInApp: beamScanEthereumInApp,
  );
  Widget sheet(BuildContext context) => BeamScanSheet(
    stopped: stopped,
    text: text,
    desktop: desktop,
    clipboard: clipboard,
  );
  if (desktop) {
    return showDialog<BeamScanSheetChoice>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Flexible(child: SingleChildScrollView(child: sheet(context))),
          ],
        ),
      ),
    );
  }
  return showModalBottomSheet<BeamScanSheetChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => BeamClaimSheetFrame(child: sheet(context)),
  );
}

/// The sheet: what the code is, why nothing was opened, the text itself,
/// and a way on (or a copy of the text) where there is one.
class BeamScanSheet extends StatelessWidget {
  const BeamScanSheet({
    super.key,
    required this.stopped,
    required this.text,
    required this.desktop,
    this.clipboard = const ClipboardWrapper(),
  });

  final ScanStopped stopped;
  final BeamScanSheetText text;
  final bool desktop;
  final ClipboardInterface clipboard;

  /// What the copy button copies: the Ethereum recipient when the code
  /// had one ("Copy address"), else the scanned text.
  String get _copied => stopped.to ?? stopped.text;

  Future<void> _copy(BuildContext context) async {
    await clipboard.setData(ClipboardData(text: _copied));
    if (!context.mounted) return;
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.info,
        message: context.l10n.commonCopied,
        iconAsset: Assets.svg.copy,
        context: context,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final title = desktop
        ? STextStyles.desktopH3(context)
        : STextStyles.pageTitleH2(context);
    final body =
        (desktop
                ? STextStyles.desktopTextExtraExtraSmall(context)
                : STextStyles.w500_14(context))
            .copyWith(color: c.textDark3);
    // Inter's contextual forms draw "0x" as "0×" in an address.
    final mono = STextStyles.w500_12(context)
        .copyWith(color: c.textDark, fontFeatures: kAddressFontFeatures);
    final height = desktop ? ButtonHeight.l : null;
    final action = text.action;
    final choice = stopped.onward != null
        ? BeamScanSheetChoice.onward
        : BeamScanSheetChoice.addEthereumWallet;
    final copy = text.copy;
    final close = SecondaryButton(
      key: const Key('beamScanSheetClose'),
      label: context.l10n.commonClose,
      buttonHeight: height,
      onPressed: () => Navigator.of(context).pop(),
    );
    final go = PrimaryButton(
      key: const Key('beamScanSheetAction'),
      label: action ?? '',
      buttonHeight: height,
      onPressed: () => Navigator.of(context).pop(choice),
    );
    return Padding(
      key: const Key('beamScanSheet'),
      padding: EdgeInsets.fromLTRB(
        desktop ? 32 : 16,
        desktop ? 0 : 16,
        desktop ? 32 : 16,
        desktop ? 32 : 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text.title, key: const Key('beamScanSheetTitle'), style: title),
          const SizedBox(height: 12),
          Text(
            text.message,
            key: const Key('beamScanSheetMessage'),
            style: body,
          ),
          if (stopped.text.isNotEmpty) ...[
            const SizedBox(height: 16),
            RoundedContainer(
              color: desktop ? c.textFieldDefaultBG : c.popupBG,
              borderColor: desktop ? null : c.textFieldDefaultBG,
              padding: const EdgeInsets.all(12),
              // Selectable, so a person who trusts it can still take it
              // elsewhere themselves; never opened from here.
              child: SelectableText(
                stopped.text,
                key: const Key('beamScanSheetText'),
                maxLines: 4,
                minLines: 1,
                style: mono,
              ),
            ),
          ],
          if (copy != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CustomTextButton(
                  key: const Key('beamScanSheetCopy'),
                  text: copy,
                  onTap: () => unawaited(_copy(context)),
                ),
              ),
            ),
          SizedBox(height: copy != null ? 16 : 20),
          if (action == null)
            PrimaryButton(
              key: const Key('beamScanSheetClose'),
              label: context.l10n.commonClose,
              buttonHeight: height,
              onPressed: () => Navigator.of(context).pop(),
            )
          else if (desktop)
            Row(
              children: [
                Expanded(child: close),
                const SizedBox(width: 16),
                Expanded(child: go),
              ],
            )
          else ...[
            go,
            const SizedBox(height: 12),
            close,
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- buttons

/// The phone wallet's top-bar Scan button (beside network and alerts).
class BeamHomeScanButton extends ConsumerWidget {
  const BeamHomeScanButton({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<StackColors>()!;
    return AppBarIconButton(
      key: const Key('beamHomeScanButton'),
      semanticsLabel: context.l10n.scanButtonLabel,
      size: 36,
      shadows: const [],
      color: c.background,
      icon: SvgPicture.asset(
        Assets.svg.qrcode,
        width: 20,
        height: 20,
        colorFilter: ColorFilter.mode(c.topNavIconPrimary, BlendMode.srcIn),
      ),
      onPressed: () => unawaited(
        beamScanFromHome(
          context,
          ref,
          ref.read(pWallets).getWallet(walletId) as BeamWallet,
          desktop: BeamLayoutScope.isDesktop(context),
        ),
      ),
    );
  }
}

/// The desktop wallet's top-bar "Scan QR code", in the look of Campfire's
/// "Wallet keys" beside it.
class BeamDesktopScanButton extends ConsumerWidget {
  const BeamDesktopScanButton({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<StackColors>()!;
    return RawMaterialButton(
      key: const Key('beamDesktopScanButton'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(1000)),
      onPressed: () => unawaited(
        beamScanFromHome(
          context,
          ref,
          ref.read(pWallets).getWallet(walletId) as BeamWallet,
          desktop: true,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 19, horizontal: 32),
        child: Row(
          children: [
            SvgPicture.asset(
              Assets.svg.qrcode,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                c.buttonTextSecondary,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              context.l10n.scanQrCode,
              style: STextStyles.desktopMenuItemSelected(context),
            ),
          ],
        ),
      ),
    );
  }
}
