/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:intl/intl.dart';

import '../../../l10n/l10n.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import 'beam_private_receive.dart';

/// Every word the BEAM receive screens show, in one place.
///
/// Plain language only: never "SBBS", "voucher",
/// "Lelantus", "shielded" or "token". Each address type is described by
/// what it does for the person being paid. The text is in
/// lib/l10n/app_en.arb (receive* keys), in the language the app speaks.
abstract final class BeamReceiveText {
  // ------------------------------------------------------------ receive

  static String get yourAddress => appL10n.receiveYourAddress;
  static String get regularExplainer => appL10n.receiveRegularExplainer;
  static String get copy => appL10n.receiveCopyAddress;
  static String get copied => appL10n.receiveAddressCopied;
  static String get share => appL10n.receiveShare;
  static String get newAddress => appL10n.receiveNewAddress;
  static String get newAddressReady => appL10n.receiveNewAddressReady;
  static String get allAddresses => appL10n.receiveAllAddresses;

  static String get gettingAddress => appL10n.receiveGettingAddress;
  static String get gettingAddressSlow => appL10n.receiveGettingAddressSlow;
  static String get cantGetAddress => appL10n.receiveCantGetAddress;
  static String get tryAgain => appL10n.commonTryAgain;
  static String get offlineWarning => appL10n.receiveOfflineWarning;

  // --------------------------------------------------------------- name

  /// "Your name:", the label before a name the wallet owns.
  static String get yourName => appL10n.receiveYourNameLabel;
  static String get nameExplainer => appL10n.receiveNameExplainer;
  static String get nameCopied => appL10n.receiveNameCopied;

  // ---------------------------------------------------- more ways to receive

  static String get moreWays => appL10n.receiveMoreWays;
  static String get moreWaysHint => appL10n.receiveMoreWaysHint;
  static String get needsPrivateNode => appL10n.receiveNeedsPrivateNode;
  static String get openNodeSettings => appL10n.receiveOpenNodeSettings;
  static String get making => appL10n.receiveMaking;

  /// Title of an address type, as a person would say it.
  static String typeTitle(BeamAddressType type) => switch (type) {
    BeamAddressType.regular => appL10n.receiveTypeTitleRegular,
    BeamAddressType.regularNew => appL10n.receiveTypeTitleRegularProof,
    BeamAddressType.offline => appL10n.receiveTypeTitleOffline,
    BeamAddressType.maxPrivacy => appL10n.receiveTypeTitleMaxPrivacy,
    BeamAddressType.publicOffline => appL10n.receiveTypeTitlePublic,
    BeamAddressType.unknown => appL10n.receiveTypeTitleOther,
  };

  /// Short label for lists.
  static String typeLabel(BeamAddressType type) => switch (type) {
    BeamAddressType.regular => appL10n.receiveTypeLabelRegular,
    BeamAddressType.regularNew => appL10n.receiveTypeLabelRegularProof,
    BeamAddressType.offline => appL10n.receiveTypeLabelOffline,
    BeamAddressType.maxPrivacy => appL10n.receiveTypeLabelMaxPrivacy,
    BeamAddressType.publicOffline => appL10n.receiveTypeLabelPublic,
    BeamAddressType.unknown => appL10n.receiveTypeLabelOther,
  };

  /// What the address does for the person being paid.
  static String typeExplainer(BeamAddressType type) => switch (type) {
    BeamAddressType.regular || BeamAddressType.regularNew => regularExplainer,
    BeamAddressType.offline => appL10n.receiveTypeExplainerOffline,
    BeamAddressType.maxPrivacy => appL10n.receiveTypeExplainerMaxPrivacy,
    BeamAddressType.publicOffline => appL10n.receiveTypeExplainerPublic,
    BeamAddressType.unknown => '',
  };

  /// Why the private types are off, and whether Node settings helps.
  static ({String reason, bool showNodeSettings}) privateReason(
    BeamPrivateReceive gate,
  ) => switch (gate.block) {
    null => (reason: '', showNodeSettings: false),
    BeamPrivateReceiveBlock.connecting => (
      reason: appL10n.receivePrivateConnecting,
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.notOnThisDevice => (
      reason: appL10n.receivePrivateNotOnThisDevice,
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.nodeOff => (
      reason: appL10n.receivePrivateNodeOff,
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeStarting => (
      reason: appL10n.receivePrivateNodeStarting,
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeDownloading => (
      reason: switch (gate.percent) {
        null => appL10n.receivePrivateNodeDownloading,
        final percent => appL10n.receivePrivateNodeDownloadingPercent(percent),
      },
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeCatchingUp => (
      reason: appL10n.receivePrivateNodeCatchingUp,
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeSwitching => (
      reason: appL10n.receivePrivateNodeSwitching,
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.nodeConfirming => (
      reason: appL10n.receivePrivateNodeConfirming,
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeProblem => (
      reason: appL10n.receivePrivateNodeProblem,
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeServingOtherWallet => (
      reason: appL10n.receivePrivateNodeServingOther,
      showNodeSettings: true,
    ),
  };

  // ------------------------------------------------------- address list

  static String get active => appL10n.receiveActive;
  static String expiredCount(int n) => appL10n.receiveExpiredCount(n);
  static String get noLabel => appL10n.receiveNoLabel;
  static String get onReceive => appL10n.receiveShownOnReceive;
  static String get editLabel => appL10n.receiveEditLabel;
  static String get delete => appL10n.receiveDelete;
  static String get cancel => appL10n.commonCancel;
  static String get saveLabel => appL10n.receiveSaveLabel;
  static String get labelHint => appL10n.receiveLabelHint;
  static String get labelSaved => appL10n.receiveLabelSaved;
  static String get deleteTitle => appL10n.receiveDeleteTitle;
  static String get deleteMessage => appL10n.receiveDeleteMessage;
  static String get deleted => appL10n.receiveDeleted;
  static String get noAddresses => appL10n.receiveNoAddresses;
  static String get noAddressesHint => appL10n.receiveNoAddressesHint;
  static String get getMyAddress => appL10n.receiveGetMyAddress;
  static String get cantShowAddresses => appL10n.receiveCantShowAddresses;

  static final DateFormat _date = DateFormat('d MMM y');

  /// "Created 22 Jun 2024 · Never expires" and the like.
  static String lifetime(BeamAddress a) {
    final created = _date.format(a.createdAt.toLocal());
    final ends = a.expiresAt;
    if (ends == null) return appL10n.receiveLifetimeNeverExpires(created);
    final when = _date.format(ends.toLocal());
    return a.expired
        ? appL10n.receiveLifetimeExpired(created, when)
        : appL10n.receiveLifetimeExpires(created, when);
  }

  /// First and last characters, for lists where the full address is one
  /// tap away.
  static String short(String address, {int keep = 10}) =>
      address.length <= keep * 2 + 1
      ? address
      : '${address.substring(0, keep)}…'
            '${address.substring(address.length - keep)}';

  // ------------------------------------------------------------- errors

  /// What went wrong, in words that never blame the person, with the fix.
  static String error(Object e) {
    if (e is BeamRpcException) {
      if (e.code == -32005) return appL10n.receiveErrorNotOnPrivateNode;
      final m = e.message.toLowerCase();
      if (m.contains('active transaction') || m.contains('in use')) {
        return appL10n.receiveErrorInProgress;
      }
      return appL10n.receiveErrorCouldNotDo;
    }
    if (e is BeamConnectionException) return appL10n.receiveErrorConnecting;
    if (e is TimeoutException) return appL10n.receiveErrorSlow;
    return appL10n.receiveErrorOurSide;
  }
}
