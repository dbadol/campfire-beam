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
// no "chain id", nothing that blames the person who scanned.

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
  final coins = ethereumInApp ? 'BEAM and Ethereum' : 'BEAM';
  final askFor = ethereumInApp ? 'a BEAM or Ethereum' : 'a BEAM';
  switch (stopped.reason) {
    case ScanStop.empty:
      return const BeamScanSheetText(
        title: 'Nothing in this code',
        message:
            'The QR code had no text in it. Try scanning it again, a little '
            'closer.',
      );
    case ScanStop.unknown:
      return BeamScanSheetText(
        title: 'Not a payment Campfire can open',
        message:
            "This isn't a BEAM address, a BEAM name, "
            "${ethereumInApp ? 'an Ethereum address ' : ''}or an airdrop "
            'code, so nothing was opened. Ask for $askFor address or a '
            'payment QR code instead.',
        copy: 'Copy text',
      );
    case ScanStop.link:
      return const BeamScanSheetText(
        title: 'A web link',
        message:
            'Campfire never opens links from QR codes: a link can lead to a '
            'fake wallet page that asks for your recovery phrase. Nothing '
            'was opened. To pay someone, ask for their BEAM address.',
      );
    case ScanStop.coin:
      final scheme = _scheme.firstMatch(stopped.text)?.group(1);
      final starts = scheme == null
          ? 'It is for another coin or app'
          : 'It starts with "${scheme.toLowerCase()}:"';
      return BeamScanSheetText(
        title: 'A payment for another coin',
        message:
            '$starts, and Campfire pays in $coins only, so nothing was '
            'opened. Ask for $askFor address instead.',
        copy: 'Copy text',
      );
    case ScanStop.chain:
      final chain = _chain.firstMatch(stopped.text)?.group(1);
      return BeamScanSheetText(
        title: 'A payment on another network',
        message:
            'This asks for a payment on '
            '${chain == null ? 'another network' : 'network $chain'}, not '
            "on Ethereum. Campfire's Ethereum wallet pays on Ethereum only, "
            'so nothing was opened. Ask for an address on Ethereum itself '
            'instead.',
        copy: 'Copy text',
      );
    case ScanStop.token:
      final what = tokenSymbol ?? 'a token';
      final to = stopped.to;
      return BeamScanSheetText(
        title: 'A token payment on Ethereum',
        message:
            'This asks for $what, not ETH'
            '${to == null ? '' : ', to ${beamScanShort(to)}'}. Open '
            '${tokenSymbol ?? 'that token'} in your Ethereum wallet and send '
            'it from there. Nothing was opened.',
        copy: to == null ? null : 'Copy address',
      );
    case ScanStop.noEthereumWallet:
      return const BeamScanSheetText(
        title: 'An Ethereum address',
        message:
            'To pay it, add an Ethereum wallet to Campfire, then scan the '
            'code again.',
        action: 'Add an Ethereum wallet',
        copy: 'Copy address',
      );
    case ScanStop.ethereumNotInApp:
      return const BeamScanSheetText(
        title: 'An Ethereum address',
        message:
            'This version of Campfire pays in BEAM only, so nothing was '
            'opened. Ask for a BEAM address instead.',
        copy: 'Copy address',
      );
    case ScanStop.ethereumInBeamSend:
      final onward = stopped.onward;
      final String? action;
      final String next;
      if (onward is ScanToEthereumSend) {
        final name = walletName?.call(onward.walletId);
        action = name == null ? 'Pay from Ethereum' : 'Pay from $name';
        next = ' Pay it from your Ethereum wallet instead.';
      } else if (onward is ScanChooseEthereumWallet) {
        action = 'Pay from an Ethereum wallet';
        next = ' Pay it from one of your Ethereum wallets instead.';
      } else if (stopped.canAddEthereumWallet && ethereumInApp) {
        action = 'Add an Ethereum wallet';
        next = ' To pay it, add an Ethereum wallet to Campfire.';
      } else {
        action = null;
        next = '';
      }
      return BeamScanSheetText(
        title: 'An Ethereum address',
        message: "BEAM can't be sent to an Ethereum address.$next",
        action: action,
      );
    case ScanStop.codeInBeamSend:
      return const BeamScanSheetText(
        title: 'An airdrop code',
        message:
            "This code holds coins for you to claim. It isn't an address to "
            'pay.',
        action: 'See what it holds',
      );
  }
}
