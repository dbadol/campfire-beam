/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The words of the scan sheet (beam_scan.dart): what the code is, why
// nothing was opened, and what to do instead. Plain sentences: no "EIP-681",
// no "chain id", nothing that blames the person who scanned. The text is in
// lib/l10n/app_en.arb (scan* keys), in the language the app speaks.

import '../../../l10n/l10n.dart';
import '../../../utilities/beam/scan_route.dart';

/// The sheet's title, its explanation and its buttons' labels.
class BeamScanSheetText {
  const BeamScanSheetText({
    required this.title,
    required this.message,
    this.action,
    this.copy,
  });

  final String title;
  final String message;

  /// The button that goes on (to Ethereum Send, the claim screen, adding a
  /// wallet), or null when there is nowhere to go.
  final String? action;

  /// The label of the button that copies the scanned text (or a token
  /// payment's recipient), or null when copying is no use, or, for a web
  /// link, not something to make easy.
  final String? copy;
}

final _scheme = RegExp(r'^([a-z][a-z0-9+.-]*):', caseSensitive: false);
final _chain = RegExp(r'@(\d+)');

/// "0x5290…9EE7": enough of an address to recognise it.
String beamScanShort(String address) => address.length <= 14
    ? address
    : '${address.substring(0, 6)}…${address.substring(address.length - 4)}';

/// The words for [stopped]. [tokenSymbol] names a token payment's token
/// when the app knows it ("USDT"); [walletName] names an Ethereum wallet;
/// [ethereumInApp] is false in a build without Ethereum.
BeamScanSheetText beamScanSheetText(
  ScanStopped stopped, {
  String? tokenSymbol,
  String Function(String walletId)? walletName,
  bool ethereumInApp = true,
}) {
  final l = appL10n;
  switch (stopped.reason) {
    case ScanStop.empty:
      return BeamScanSheetText(
        title: l.scanEmptyTitle,
        message: l.scanEmptyMessage,
      );
    case ScanStop.unknown:
      return BeamScanSheetText(
        title: l.scanUnknownTitle,
        message: ethereumInApp
            ? l.scanUnknownMessageEthereum
            : l.scanUnknownMessage,
        copy: l.scanCopyText,
      );
    case ScanStop.link:
      return BeamScanSheetText(
        title: l.scanLinkTitle,
        message: l.scanLinkMessage,
      );
    case ScanStop.coin:
      final scheme = _scheme.firstMatch(stopped.text)?.group(1);
      return BeamScanSheetText(
        title: l.scanCoinTitle,
        message: switch ((scheme?.toLowerCase(), ethereumInApp)) {
          (null, true) => l.scanCoinMessageEthereum,
          (null, false) => l.scanCoinMessage,
          (final String s, true) => l.scanCoinSchemeMessageEthereum(s),
          (final String s, false) => l.scanCoinSchemeMessage(s),
        },
        copy: l.scanCopyText,
      );
    case ScanStop.chain:
      final chain = _chain.firstMatch(stopped.text)?.group(1);
      return BeamScanSheetText(
        title: l.scanChainTitle,
        message: chain == null
            ? l.scanChainMessage
            : l.scanChainMessageId(chain),
        copy: l.scanCopyText,
      );
    case ScanStop.token:
      final to = stopped.to;
      final short = to == null ? null : beamScanShort(to);
      return BeamScanSheetText(
        title: l.scanTokenTitle,
        message: joinSentences([
          switch ((tokenSymbol, short)) {
            (final String t, final String s) => l.scanTokenAsksTo(t, s),
            (final String t, null) => l.scanTokenAsks(t),
            (null, final String s) => l.scanTokenAsksUnknownTo(s),
            (null, null) => l.scanTokenAsksUnknown,
          },
          tokenSymbol == null
              ? l.scanTokenOpenUnknown
              : l.scanTokenOpen(tokenSymbol),
          l.scanNothingOpened,
        ], l),
        copy: to == null ? null : l.scanCopyAddress,
      );
    case ScanStop.noEthereumWallet:
      return BeamScanSheetText(
        title: l.scanEthereumAddressTitle,
        message: l.scanNoEthWalletMessage,
        action: l.scanAddEthereumWallet,
        copy: l.scanCopyAddress,
      );
    case ScanStop.ethereumNotInApp:
      return BeamScanSheetText(
        title: l.scanEthereumAddressTitle,
        message: l.scanEthNotInAppMessage,
        copy: l.scanCopyAddress,
      );
    case ScanStop.ethereumInBeamSend:
      final onward = stopped.onward;
      final String? action;
      final String? next;
      if (onward is ScanToEthereumSend) {
        final name = walletName?.call(onward.walletId);
        action = name == null
            ? l.scanPayFromEthereum
            : l.scanPayFromWallet(name);
        next = l.scanPayFromYourEthWallet;
      } else if (onward is ScanChooseEthereumWallet) {
        action = l.scanPayFromAnEthWallet;
        next = l.scanPayFromOneOfEthWallets;
      } else if (stopped.canAddEthereumWallet && ethereumInApp) {
        action = l.scanAddEthereumWallet;
        next = l.scanAddEthWalletToPay;
      } else {
        action = null;
        next = null;
      }
      return BeamScanSheetText(
        title: l.scanEthereumAddressTitle,
        message: joinSentences([l.scanEthInBeamSendMessage, next], l),
        action: action,
      );
    case ScanStop.codeInBeamSend:
      return BeamScanSheetText(
        title: l.scanCodeTitle,
        message: l.scanCodeMessage,
        action: l.scanSeeWhatItHolds,
      );
  }
}
