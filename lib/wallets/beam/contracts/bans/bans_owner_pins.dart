/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';

import '../../../../utilities/flutter_secure_storage_interface.dart';
import 'bans_exceptions.dart';
import 'bans_name.dart';

/// The owner key this wallet last paid each name (audit D-1).
///
/// A name changes owner when it is sold, transferred or lapses, and also
/// when the node this wallet asks lies about it: its owner key is read from
/// the node without proof. So once a name has been paid, another owner is
/// never paid silently: the Send screen shows both keys and the person has
/// to choose to pay the new one ([bansPinVerdict]). The web wallet keeps the
/// same record (pwa/src/lib/bans.js `pinVerdict`).
abstract class BansOwnerPins {
  /// The owner key [name] was last paid from this wallet, or null. Throws
  /// [BansPinsUnreadable] when the record cannot be read.
  Future<String?> pinned(BansName name);

  /// Records [ownerKey] as the owner [name] was paid. Called once the
  /// payment is sent. Throws [BansPinsUnreadable], writing nothing, when the
  /// record cannot be read: an unreadable record is never overwritten.
  Future<void> pin(BansName name, String ownerKey);
}

/// [BansKey.zero] in place of a paid owner: "this wallet paid before, but its
/// record could not be read" (`BansRecipientPayable.paidOwnerUnknown`). It
/// never equals a real owner, so the payment waits for the person's choice.
final kBansPaidOwnerUnknown = BansKey.zero;

/// [BansOwnerPins.pinned], with an unreadable record as
/// [kBansPaidOwnerUnknown] instead of an error.
Future<String?> bansPaidOwner(BansOwnerPins pins, BansName name) async {
  try {
    return await pins.pinned(name);
  } on BansPinsUnreadable {
    return kBansPaidOwnerUnknown;
  }
}

/// How the owner [now] compares with [pinned] (the key paid before) and
/// [accepted] (a new key the person saw next to the old one and chose).
enum BansPinVerdict {
  /// Never paid from this wallet.
  first,

  /// The owner it was paid before.
  same,

  /// Another owner: stop, show both keys, ask.
  changed,

  /// Another owner, the one the person chose to pay.
  accepted,
}

BansPinVerdict bansPinVerdict({
  required String? pinned,
  required String now,
  String? accepted,
}) {
  if (pinned == null) return BansPinVerdict.first;
  if (now == pinned) return BansPinVerdict.same;
  return now == accepted ? BansPinVerdict.accepted : BansPinVerdict.changed;
}

/// The app's [BansOwnerPins]: one wallet's record in Campfire's secure
/// storage, under `BEAM_BANS_PINS:<walletId>` (a JSON object of name to
/// owner key). Who a wallet paid is private, so it never goes to plain
/// preferences or a log. A record that cannot be read is reported
/// ([BansPinsUnreadable]) and never overwritten: it never counts as "never
/// paid", which would let a changed owner through unseen.
class SecureBansOwnerPins implements BansOwnerPins {
  SecureBansOwnerPins(this._storage, this.walletId) {
    if (!_id.hasMatch(walletId)) {
      throw ArgumentError.value(walletId, 'walletId', 'not a wallet id');
    }
  }

  final SecureStorageInterface _storage;
  final String walletId;

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Writes per wallet run one at a time, across every instance in this
  /// isolate, so two payments never overwrite each other's record.
  static final _tails = <String, Future<void>>{};

  String get _key => 'BEAM_BANS_PINS:$walletId';

  @override
  Future<String?> pinned(BansName name) async => (await _read())[name.value];

  @override
  Future<void> pin(BansName name, String ownerKey) => _serial(() async {
    final key = BansKey.require(ownerKey);
    final all = await _read();
    if (all[name.value] == key) return;
    await _storage.write(
      key: _key,
      value: jsonEncode({...all, name.value: key}),
    );
  });

  /// Forgets every name of this wallet: the wallet itself is being deleted.
  Future<void> deleteAll() => _serial(() => _storage.delete(key: _key));

  Future<Map<String, String>> _read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) throw const BansPinsUnreadable();
      return {
        for (final e in json.entries)
          if (e.key is String &&
              BansName.tryParse(e.key as String) != null &&
              e.value is String &&
              BansKey.isValid(e.value as String) &&
              e.value != BansKey.zero)
            e.key as String: e.value as String,
      };
    } on FormatException {
      throw const BansPinsUnreadable();
    }
  }

  Future<T> _serial<T>(Future<T> Function() op) {
    final prev = _tails[walletId] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[walletId] = done.future;
    return prev.then((_) => op()).whenComplete(done.complete);
  }
}

/// In memory, for tests and wallets without secure storage.
class MemoryBansOwnerPins implements BansOwnerPins {
  final Map<String, String> _pins = {};

  @override
  Future<String?> pinned(BansName name) async => _pins[name.value];

  @override
  Future<void> pin(BansName name, String ownerKey) async =>
      _pins[name.value] = BansKey.require(ownerKey);
}
