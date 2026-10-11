/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where a scanned code goes (lib/utilities/beam/scan_route.dart), from the
// home and from BEAM Send, with and without Ethereum wallets; the sheet's
// words for every code that opens nothing (beam_scan_text.dart); and what
// BEAM Send's field says about an Ethereum address or another coin's link.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/scan_recognize.dart';
import 'package:stackwallet/utilities/beam/scan_route.dart';
import 'package:stackwallet/widgets/beam/scan/beam_scan_text.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_model.dart';

const _hex =
    '2d37efaaf8e80a576d3dabb9bb2799dfe1b40b5bd29c6436ccd729744c806a7355e';
const _eth = '0x52908400098527886E0F7030069857D2E4169EE7';
const _token = '0x1111111111111111111111111111111111111111';
const _a = ScanEthWallet('eth-a', 'Savings ETH');
const _b = ScanEthWallet('eth-b', 'Daily ETH');

ScanDestination _go(
  String text, {
  ScanFrom from = ScanFrom.home,
  List<ScanEthWallet> eth = const [],
  bool ethereumInApp = true,
}) => scanDestination(
  recognizeScan(text),
  text: text,
  from: from,
  ethWallets: eth,
  ethereumInApp: ethereumInApp,
);

void main() {
  group('from the home', () {
    test('a BEAM address or link: BEAM Send, the amount carried over', () {
      expect(_go(_hex), const ScanToBeamSend(_hex));
      expect(
        _go('beam:$_hex?amount=1.5'),
        const ScanToBeamSend(_hex, amount: '1.5'),
      );
      // A bad amount is dropped, the address is still filled in.
      expect(_go('beam:$_hex?amount=-1'), const ScanToBeamSend(_hex));
    });

    test('a BEAM name: BEAM Send with "name.beam", looked up there', () {
      expect(_go('Alice.BEAM'), const ScanToBeamSend('alice.beam'));
      expect(_go('beam:alice.beam'), const ScanToBeamSend('alice.beam'));
    });

    test('an Ethereum address: that wallet\'s Send, amount in wei', () {
      expect(_go(_eth, eth: [_a]), const ScanToEthereumSend('eth-a', _eth));
      expect(
        _go('ethereum:$_eth?value=2.014e18', eth: [_a]),
        const ScanToEthereumSend(
          'eth-a',
          _eth,
          valueWei: '2014000000000000000',
        ),
      );
    });

    test('several Ethereum wallets: the person picks one', () {
      final d = _go('ethereum:$_eth@1?value=1000', eth: [_a, _b]);
      expect(
        d,
        const ScanChooseEthereumWallet([_a, _b], _eth, valueWei: '1000'),
      );
      expect(
        (d as ScanChooseEthereumWallet).pick(_b),
        const ScanToEthereumSend('eth-b', _eth, valueWei: '1000'),
      );
    });

    test('no Ethereum wallet: says so, and offers to add one', () {
      expect(
        _go(_eth),
        const ScanStopped(
          ScanStop.noEthereumWallet,
          _eth,
          canAddEthereumWallet: true,
          to: _eth,
        ),
      );
    });

    test('a build without Ethereum: says so, offers nothing', () {
      expect(
        _go(_eth, eth: [_a], ethereumInApp: false),
        const ScanStopped(ScanStop.ethereumNotInApp, _eth, to: _eth),
      );
    });

    test('a token payment is never turned into an ETH payment', () {
      const link =
          'ethereum:$_token/transfer?address=$_eth&uint256=1e6';
      expect(
        _go(link, eth: [_a]),
        const ScanStopped(ScanStop.token, link, token: _token, to: _eth),
      );
    });

    test('an airdrop code: the claim screen with the code', () {
      expect(
        _go('abcd efgh jklm npqr'),
        const ScanToClaim('ABCDEFGHJKLMNPQR'),
      );
    });

    test('another chain, another coin, a web link, anything else, '
        'nothing: never opened', () {
      for (final (text, reason) in [
        ('ethereum:$_eth@137?value=1000', ScanStop.chain),
        ('bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq', ScanStop.coin),
        ('https://example.com/pay', ScanStop.link),
        ('hello world', ScanStop.unknown),
        // A bare name is not a name to the home (as in the web wallet).
        ('alice', ScanStop.unknown),
        ('   ', ScanStop.empty),
      ]) {
        final d = _go(text, eth: [_a]);
        expect(d, isA<ScanStopped>(), reason: text);
        d as ScanStopped;
        expect(d.reason, reason, reason: text);
        expect(d.onward, isNull, reason: text);
        expect(d.text, scanFirstLine(text), reason: text);
      }
    });

    test('the sheet shows only the first line', () {
      final d = _go('hello world\nsecond line') as ScanStopped;
      expect(d.text, 'hello world');
    });
  });

  group('from BEAM Send', () {
    const send = ScanFrom.beamSend;

    test('a BEAM address, link or name fills the field', () {
      expect(
        _go('beam:$_hex?amount=2', from: send),
        const ScanToBeamSend(_hex, amount: '2'),
      );
      expect(_go('alice.beam', from: send), const ScanToBeamSend('alice.beam'));
    });

    test('anything else unrecognised goes into the field as typed: a bare '
        'name is a name there', () {
      expect(_go('alice', from: send), const ScanToBeamSend('alice'));
      expect(_go(' alice \nnote', from: send), const ScanToBeamSend('alice'));
    });

    test('an Ethereum address says so and offers that wallet\'s Send', () {
      expect(
        _go(_eth, from: send, eth: [_a]),
        const ScanStopped(
          ScanStop.ethereumInBeamSend,
          _eth,
          onward: ScanToEthereumSend('eth-a', _eth),
          to: _eth,
        ),
      );
      expect(
        _go(_eth, from: send),
        const ScanStopped(
          ScanStop.ethereumInBeamSend,
          _eth,
          canAddEthereumWallet: true,
          to: _eth,
        ),
      );
    });

    test('an airdrop code says so and offers the claim screen', () {
      expect(
        _go('ABCD-EFGH-JKLM-NPQR', from: send),
        const ScanStopped(
          ScanStop.codeInBeamSend,
          'ABCD-EFGH-JKLM-NPQR',
          onward: ScanToClaim('ABCDEFGHJKLMNPQR'),
        ),
      );
    });

    test('a web link is still never opened', () {
      expect(
        _go('https://example.com', from: send),
        const ScanStopped(ScanStop.link, 'https://example.com'),
      );
    });
  });

  test('wei in ether, without float error or trailing zeros', () {
    expect(scanWeiToEther('2014000000000000000'), '2.014');
    expect(scanWeiToEther('1000'), '0.000000000000001');
    expect(scanWeiToEther('1000000000000000000'), '1');
    expect(scanWeiToEther('123456789012345678901'), '123.456789012345678901');
    expect(scanWeiToEther('0'), '0');
  });

  group('the sheet says what it is and why nothing opened', () {
    BeamScanSheetText words(
      ScanDestination d, {
      String? symbol,
      bool ethereumInApp = true,
    }) => beamScanSheetText(
      d as ScanStopped,
      tokenSymbol: symbol,
      walletName: (id) => id == 'eth-a' ? 'Savings ETH' : 'Other',
      ethereumInApp: ethereumInApp,
    );

    test('a web link: never opened, and why', () {
      final t = words(_go('https://example.com/pay'));
      expect(t.title, 'A web link');
      expect(t.message, contains('never opens links'));
      expect(t.message, contains('recovery phrase'));
      expect(t.action, isNull);
      expect(t.copy, isNull, reason: 'a link is not made easy to open');
    });

    test('another coin: names the scheme it starts with', () {
      final t = words(_go('bitcoin:bc1qxy'));
      expect(t.message, startsWith('It starts with "bitcoin:"'));
      expect(t.message, contains('BEAM and Ethereum only'));
      expect(
        words(_go('bitcoin:bc1qxy'), ethereumInApp: false).message,
        contains('pays in BEAM only'),
      );
    });

    test('another network: names the network', () {
      final t = words(_go('ethereum:$_eth@137?value=1'));
      expect(t.message, contains('network 137'));
    });

    test('a token payment: names the token when Campfire knows it', () {
      const link = 'ethereum:$_token/transfer?address=$_eth';
      final known = words(_go(link, eth: [_a]), symbol: 'USDT');
      expect(known.message, contains('USDT, not ETH, to 0x5290…9EE7'));
      expect(known.copy, 'Copy address');
      final unknown = words(_go(link, eth: [_a]));
      expect(unknown.message, contains('a token, not ETH'));
    });

    test('no Ethereum wallet: the button adds one', () {
      final t = words(_go(_eth));
      expect(t.title, 'An Ethereum address');
      expect(t.action, 'Add an Ethereum wallet');
    });

    test('BEAM Send: an Ethereum address offers that wallet by name', () {
      final one = words(_go(_eth, from: ScanFrom.beamSend, eth: [_a]));
      expect(one.message, startsWith("BEAM can't be sent to an Ethereum"));
      expect(one.action, 'Pay from Savings ETH');
      final two = words(_go(_eth, from: ScanFrom.beamSend, eth: [_a, _b]));
      expect(two.action, 'Pay from an Ethereum wallet');
      final none = words(_go(_eth, from: ScanFrom.beamSend));
      expect(none.action, 'Add an Ethereum wallet');
    });

    test('BEAM Send: an airdrop code offers to see what it holds', () {
      final t = words(_go('ABCD-EFGH-JKLM-NPQR', from: ScanFrom.beamSend));
      expect(t.title, 'An airdrop code');
      expect(t.action, 'See what it holds');
    });

    test('unknown and empty', () {
      expect(words(_go('hello world')).copy, 'Copy text');
      final empty = words(_go(''));
      expect(empty.title, 'Nothing in this code');
      expect(empty.copy, isNull);
    });
  });

  group("BEAM Send's field", () {
    test('an Ethereum address or another link is named, never looked up '
        'as a name', () {
      for (final (text, says) in [
        (_eth.toLowerCase(), "That's an Ethereum address"),
        ('ethereum:$_eth', "That's an Ethereum address"),
        ('https://example.com', "That's a web link"),
        ('bitcoin:bc1q', "That's a link for another coin or app"),
        ('ethereum:$_eth@137', "That's a payment for another network"),
      ]) {
        final r = BeamSendModel.foreignRecipient(text);
        expect(r, isNotNull, reason: text);
        expect(BeamSendModel.describeForeign(r!), startsWith(says));
      }
    });

    test('BEAM addresses, names and typos are left to BEAM\'s own checks', () {
      for (final text in [
        _hex,
        'alice',
        'alice.beam',
        'ab!cd',
        'beam:$_hex',
        'ABCD-EFGH-JKLM-NPQR',
      ]) {
        expect(BeamSendModel.foreignRecipient(text), isNull, reason: text);
      }
    });
  });
}
