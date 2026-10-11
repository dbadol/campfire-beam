/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where a scanned code goes, decided from what it is (scan_recognize.dart)
// and what the app holds: pure, so every branch is tested without a camera
// or a wallet. lib/widgets/beam/scan/beam_scan.dart carries it out.
//
// Every destination is a screen the person reviews: a form filled in, never
// a payment made. Nothing a code says is sent, signed or claimed by itself.

import 'package:meta/meta.dart';

import 'scan_recognize.dart';

/// Where the scan was started.
enum ScanFrom {
  /// The wallet home's Scan: any code goes where it belongs.
  home,

  /// BEAM Send's recipient field: a BEAM address or name fills the field;
  /// anything else says what it is and offers where it belongs.
  beamSend,
}

/// An Ethereum wallet that can pay (not view-only).
@immutable
final class ScanEthWallet {
  const ScanEthWallet(this.id, this.name);

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is ScanEthWallet && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Why a scan opened nothing; the sheet's words follow from it.
enum ScanStop {
  /// The code held no text.
  empty,

  /// Not something Campfire can pay or claim.
  unknown,

  /// A web link: never opened.
  link,

  /// A payment link for another coin.
  coin,

  /// An Ethereum payment on another network than mainnet.
  chain,

  /// An ERC-20 token payment: paid from that token's own page.
  token,

  /// An Ethereum address, and no Ethereum wallet yet.
  noEthereumWallet,

  /// An Ethereum address, in a build without Ethereum.
  ethereumNotInApp,

  /// An Ethereum address scanned into BEAM Send.
  ethereumInBeamSend,

  /// An airdrop code scanned into BEAM Send.
  codeInBeamSend,
}

/// What to open for a scanned code.
@immutable
sealed class ScanDestination {
  const ScanDestination();
}

/// BEAM Send with [recipient] (an address, or a name as "alice.beam") and,
/// when the code carried one, [amount] in BEAM ("1.5").
final class ScanToBeamSend extends ScanDestination {
  const ScanToBeamSend(this.recipient, {this.amount});

  final String recipient;
  final String? amount;

  @override
  bool operator ==(Object other) =>
      other is ScanToBeamSend &&
      other.recipient == recipient &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(recipient, amount);

  @override
  String toString() => 'ScanToBeamSend($recipient, $amount)';
}

/// The Send screen of Ethereum wallet [walletId], paying [to] and, when the
/// code said, [valueWei] (whole wei, a decimal string).
final class ScanToEthereumSend extends ScanDestination {
  const ScanToEthereumSend(this.walletId, this.to, {this.valueWei});

  final String walletId;
  final String to;
  final String? valueWei;

  @override
  bool operator ==(Object other) =>
      other is ScanToEthereumSend &&
      other.walletId == walletId &&
      other.to == to &&
      other.valueWei == valueWei;

  @override
  int get hashCode => Object.hash(walletId, to, valueWei);

  @override
  String toString() => 'ScanToEthereumSend($walletId, $to, $valueWei)';
}

/// Several Ethereum wallets could pay: the person picks one, then its Send
/// screen opens as [ScanToEthereumSend].
final class ScanChooseEthereumWallet extends ScanDestination {
  const ScanChooseEthereumWallet(this.wallets, this.to, {this.valueWei});

  final List<ScanEthWallet> wallets;
  final String to;
  final String? valueWei;

  ScanToEthereumSend pick(ScanEthWallet wallet) =>
      ScanToEthereumSend(wallet.id, to, valueWei: valueWei);

  @override
  bool operator ==(Object other) =>
      other is ScanChooseEthereumWallet &&
      _sameList(other.wallets, wallets) &&
      other.to == to &&
      other.valueWei == valueWei;

  @override
  int get hashCode => Object.hash(Object.hashAll(wallets), to, valueWei);

  @override
  String toString() => 'ScanChooseEthereumWallet($wallets, $to, $valueWei)';
}

/// The airdrop claim screen with [code] filled in; it shows what the code
/// holds and the fee, and claims only on its own button.
final class ScanToClaim extends ScanDestination {
  const ScanToClaim(this.code);

  final String code;

  @override
  bool operator ==(Object other) => other is ScanToClaim && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'ScanToClaim($code)';
}

/// Nothing was opened: a sheet shows [text] and says why ([reason]).
/// [onward] is where its button goes, when the code belongs somewhere else
/// in the app; [canAddEthereumWallet] offers to add one.
final class ScanStopped extends ScanDestination {
  const ScanStopped(
    this.reason,
    this.text, {
    this.onward,
    this.canAddEthereumWallet = false,
    this.token,
    this.to,
  });

  final ScanStop reason;

  /// The scanned text's first line, as read.
  final String text;
  final ScanDestination? onward;
  final bool canAddEthereumWallet;

  /// The token contract of a token payment ([ScanStop.token]).
  final String? token;

  /// The Ethereum recipient, when the code had one (a token payment's
  /// recipient for [ScanStop.token]): what "Copy address" copies.
  final String? to;

  @override
  bool operator ==(Object other) =>
      other is ScanStopped &&
      other.reason == reason &&
      other.text == text &&
      other.onward == onward &&
      other.canAddEthereumWallet == canAddEthereumWallet &&
      other.token == token &&
      other.to == to;

  @override
  int get hashCode =>
      Object.hash(reason, text, onward, canAddEthereumWallet, token, to);

  @override
  String toString() =>
      'ScanStopped($reason, $text, onward: $onward, '
      'canAddEthereumWallet: $canAddEthereumWallet, token: $token, to: $to)';
}

bool _sameList(List<ScanEthWallet> a, List<ScanEthWallet> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Where [scanned] (read by [recognizeScan] from [text]) goes, started
/// [from] the home or BEAM Send. [ethWallets] are the Ethereum wallets that
/// can pay; [ethereumInApp] is false in a build without Ethereum.
ScanDestination scanDestination(
  ScanRecognition scanned, {
  required String text,
  ScanFrom from = ScanFrom.home,
  List<ScanEthWallet> ethWallets = const [],
  bool ethereumInApp = true,
}) {
  final line = scanFirstLine(text);
  final home = from == ScanFrom.home;
  switch (scanned.kind) {
    case ScanKind.beam:
      return ScanToBeamSend(scanned.address!, amount: scanned.amount);
    case ScanKind.name:
      return ScanToBeamSend('${scanned.name}.beam');
    case ScanKind.eth:
      final token = scanned.token;
      if (token != null) {
        return ScanStopped(ScanStop.token, line, token: token, to: scanned.to);
      }
      if (!ethereumInApp) {
        return ScanStopped(ScanStop.ethereumNotInApp, line, to: scanned.to);
      }
      final ScanDestination? pay = switch (ethWallets.length) {
        0 => null,
        1 => ScanToEthereumSend(
          ethWallets.single.id,
          scanned.to!,
          valueWei: scanned.valueWei,
        ),
        _ => ScanChooseEthereumWallet(
          List.unmodifiable(ethWallets),
          scanned.to!,
          valueWei: scanned.valueWei,
        ),
      };
      if (home) {
        return pay ??
            ScanStopped(
              ScanStop.noEthereumWallet,
              line,
              canAddEthereumWallet: true,
              to: scanned.to,
            );
      }
      return ScanStopped(
        ScanStop.ethereumInBeamSend,
        line,
        onward: pay,
        canAddEthereumWallet: pay == null,
        to: scanned.to,
      );
    case ScanKind.code:
      final claim = ScanToClaim(scanned.code!);
      return home
          ? claim
          : ScanStopped(ScanStop.codeInBeamSend, line, onward: claim);
    case ScanKind.unsupported:
      return ScanStopped(switch (scanned.reason!) {
        ScanUnsupportedReason.chain => ScanStop.chain,
        ScanUnsupportedReason.coin => ScanStop.coin,
        ScanUnsupportedReason.link => ScanStop.link,
      }, line);
    case ScanKind.unknown:
      // BEAM Send's field reads it as typed: a bare name ("alice") is
      // unknown here, and a name there.
      return home ? ScanStopped(ScanStop.unknown, line) : ScanToBeamSend(line);
    case ScanKind.empty:
      return ScanStopped(ScanStop.empty, line);
  }
}

/// [wei] (whole wei, a decimal string) in ether, as a decimal string without
/// trailing zeros: "2014000000000000000" is "2.014".
String scanWeiToEther(String wei) {
  final digits = wei.replaceFirst(RegExp('^0+'), '');
  if (digits.isEmpty) return '0';
  final padded = digits.padLeft(19, '0');
  final whole = padded.substring(0, padded.length - 18);
  final frac = padded
      .substring(padded.length - 18)
      .replaceFirst(RegExp(r'0+$'), '');
  return frac.isEmpty ? whole : '$whole.$frac';
}
