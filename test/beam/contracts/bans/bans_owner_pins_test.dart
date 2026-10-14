// The owner key a wallet paid each name (audit D-1): the verdict, and the
// secure-storage record behind it.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';

import 'bans_fixtures.dart';

const _wallet = '0c5e6a6e-8a52-11f0-9d9b-3b1d0f6c2a11';
const _other = '1d6f7b7f-9b63-11f0-8e8c-4c2e1f7d3b22';
const _newKey =
    'ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd3400';

void main() {
  test('the verdict: first, same, changed, accepted', () {
    expect(bansPinVerdict(pinned: null, now: beamOwnerKey), BansPinVerdict.first);
    expect(
      bansPinVerdict(pinned: beamOwnerKey, now: beamOwnerKey),
      BansPinVerdict.same,
    );
    expect(
      bansPinVerdict(pinned: beamOwnerKey, now: _newKey),
      BansPinVerdict.changed,
    );
    expect(
      bansPinVerdict(pinned: beamOwnerKey, now: _newKey, accepted: _newKey),
      BansPinVerdict.accepted,
    );
    // Accepting one new key never accepts another.
    expect(
      bansPinVerdict(pinned: beamOwnerKey, now: _newKey, accepted: fakeMyKey),
      BansPinVerdict.changed,
    );
  });

  test('a pin is kept per wallet and per name, and replaced on the next payment', () async {
    final s = FakeSecureStorage();
    final pins = SecureBansOwnerPins(s, _wallet);
    final beam = BansName('beam');
    expect(await pins.pinned(beam), isNull);
    await pins.pin(beam, beamOwnerKey);
    expect(await pins.pinned(beam), beamOwnerKey);
    expect(await pins.pinned(BansName('alice')), isNull);
    expect(await SecureBansOwnerPins(s, _other).pinned(beam), isNull, reason: 'another wallet');
    await pins.pin(beam, _newKey);
    expect(await pins.pinned(beam), _newKey);
    // A fresh instance reads what was written.
    expect(await SecureBansOwnerPins(s, _wallet).pinned(beam), _newKey);
  });

  test('two payments at once both land', () async {
    final s = FakeSecureStorage();
    await Future.wait([
      SecureBansOwnerPins(s, _wallet).pin(BansName('beam'), beamOwnerKey),
      SecureBansOwnerPins(s, _wallet).pin(BansName('alice'), _newKey),
    ]);
    final pins = SecureBansOwnerPins(s, _wallet);
    expect(await pins.pinned(BansName('beam')), beamOwnerKey);
    expect(await pins.pinned(BansName('alice')), _newKey);
  });

  test('an unreadable record is never "never paid" and is never overwritten '
      '(audit D-1 review L-1)', () async {
    final s = FakeSecureStorage();
    await s.write(key: 'BEAM_BANS_PINS:$_wallet', value: 'not json');
    final broken = SecureBansOwnerPins(s, _wallet);
    await expectLater(
      broken.pinned(BansName('beam')),
      throwsA(isA<BansPinsUnreadable>()),
    );
    expect(await bansPaidOwner(broken, BansName('beam')), kBansPaidOwnerUnknown);
    await expectLater(
      broken.pin(BansName('alice'), _newKey),
      throwsA(isA<BansPinsUnreadable>()),
    );
    expect(
      await s.read(key: 'BEAM_BANS_PINS:$_wallet'),
      'not json',
      reason: 'left as it was',
    );
  });

  test('one malformed entry makes the whole record unreadable: every name is '
      'compared first, none counts as never paid (release audit 1.3.0)',
      () async {
    for (final bad in [
      '"beam": "${'00' * 33}"', // the all-zero key is no owner
      '"beam": "not a key"',
      '"beam": 7',
      '"Bad Name": "$beamOwnerKey"',
    ]) {
      final s = FakeSecureStorage();
      final raw = '{$bad, "alice": "$_newKey"}';
      await s.write(key: 'BEAM_BANS_PINS:$_wallet', value: raw);
      final pins = SecureBansOwnerPins(s, _wallet);
      for (final name in ['beam', 'alice', 'bob']) {
        await expectLater(
          pins.pinned(BansName(name)),
          throwsA(isA<BansPinsUnreadable>()),
          reason: '$bad: $name',
        );
        expect(
          await bansPaidOwner(pins, BansName(name)),
          kBansPaidOwnerUnknown,
          reason: '$bad: $name',
        );
      }
      await expectLater(
        pins.pin(BansName('bob'), beamOwnerKey),
        throwsA(isA<BansPinsUnreadable>()),
      );
      expect(
        await s.read(key: 'BEAM_BANS_PINS:$_wallet'),
        raw,
        reason: 'left as it was',
      );
    }
  });

  test('only a real owner key is pinned; deleteAll forgets the wallet', () async {
    final s = FakeSecureStorage();
    final pins = SecureBansOwnerPins(s, _wallet);
    await expectLater(pins.pin(BansName('beam'), '00' * 33), throwsA(isA<BansInvalidKey>()));
    await pins.pin(BansName('beam'), beamOwnerKey);
    await pins.deleteAll();
    expect(await pins.pinned(BansName('beam')), isNull);
    expect(await s.read(key: 'BEAM_BANS_PINS:$_wallet'), isNull);
    expect(() => SecureBansOwnerPins(s, 'not/an:id'), throwsArgumentError);
  });
}
