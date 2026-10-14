/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// D-10: buybeam.my's deposit address must be an address of the coin's own
// chain before it is shown to be paid. The web wallet's tests
// (pwa/test/unit/buy_deposit_address.test.mjs), ported: real, well-known
// addresses where they exist, otherwise addresses built with each chain's
// version bytes and checksum (the web test's own, written out); each one
// also mistyped (refused) and tried on the other chains (refused). Then the
// port is held to the web's exact answers for 2,000-odd candidates on every
// chain (deposit_address_vectors.json, written by
// scripts/beam/buy/deposit_address_vectors.mjs from the web's check).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/coin_chains.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_deposit_address.dart';

/// Valid addresses per chain (the web test's VALID; the built ones are
/// base58check / bech32 of the bytes 0x31, 0x38, 0x3f… with each chain's
/// version bytes).
const _valid = <String, List<String>>{
  'btc': [
    '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
    '3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy',
    'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
    'BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4',
    'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0',
    'bc1qxyur73jd23dky6tswalgtrynn2s63takhhzvh5keurn7aa0uqv9q3rvqx2',
  ],
  'ltc': [
    'LPiCkjYb3suSXuWWRc1UdK38djWhxaMkCn',
    'MCPQix9AUEqCAmngUSg7bZahtk2bL9apwS',
    'ltc1qxyur73jd23dky6tswalgtrynn2s63takhkjszu',
  ],
  'doge': [
    'D9dM2nBQGdZfp6zwz41ju48yJesj6NhMq6',
    '9vvX9uo6bBrfGdtFnhMC23xgGcpBSSocf1',
  ],
  'dash': [
    'XfB6KmtevvsyS3Qw7MLQCpfAFrj7sTrNH6',
    '7WtuFG1NL75QN33jeBMH7JKxVbGXBQ8PCv',
  ],
  'bch': [
    'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a',
    'qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a',
  ],
  'zec': [
    't1NMrVretwYSysjsFBtqJV75HgBLWeUUdah',
    't3P3sRQ9LVSmMxuZgJzVtujSDphdE8ft96o',
    'tex1xyur73jd23dky6tswalgtrynn2s63tak846llz',
  ],
  'tron': [
    'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
    'TETTVacV7wnLSGsyqjftsSfWLJtjypkVAq',
  ],
  'sol': [
    'So11111111111111111111111111111111111111112',
    '4K8iuPTrvEWcmLVERcBgo4dKraH9hY5cLhZr2Geaqgos',
  ],
  'xrp': [
    'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh',
    'rnVEVXNkyDCPHaFME7pBMHy4RX9RiJ4M6n',
  ],
  'eth': [
    '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
    '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
    '0x52908400098527886E0F7030069857D2E4169EE7',
    '0xdac17f958d2ee523a2206206994597c13d831ec7',
  ],
  'ton': [
    'EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N',
    '0:abababababababababababababababababababababababababababababababab',
  ],
  'stellar': ['GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'],
  'sui': ['0x5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f'],
  'near': [
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1',
    'campfire.near',
  ],
};

/// [a] with one character, three from the end, changed to another of the
/// same alphabet (the web test's rule).
String _mistyped(String a) {
  final i = a.length - 3;
  final c = a[i];
  final r = switch (c) {
    'q' => 'p',
    'Q' => 'P',
    '2' => '3',
    'a' => 'b',
    'A' => 'B',
    'z' => 'y',
    'r' => 's',
    'x' => 'w',
    _ => '2',
  };
  return a.substring(0, i) + r + a.substring(i + 1);
}

void main() {
  test('every chain: its own addresses pass; mistyped, or another '
      "chain's, they do not", () {
    const checksummed = {'btc', 'ltc', 'doge', 'dash', 'zec', 'tron', 'xrp'};
    const checked = {...checksummed, 'eth', 'sui'};
    for (final MapEntry(key: chain, value: list) in _valid.entries) {
      for (final a in list) {
        expect(
          isBuyBeamDepositAddressOf(a, chain),
          isTrue,
          reason: '$chain: $a',
        );
        final body = a.startsWith('0x') ? a.substring(2) : '';
        final mixedEvm =
            chain == 'eth' &&
            RegExp('[a-f]').hasMatch(body) &&
            RegExp('[A-F]').hasMatch(a);
        if (checksummed.contains(chain) || mixedEvm) {
          final m = _mistyped(a);
          expect(
            isBuyBeamDepositAddressOf(m, chain),
            isFalse,
            reason: '$chain mistyped: $m',
          );
        }
        for (final other in _valid.keys) {
          if (other == chain ||
              (chain == 'btc' &&
                  other == 'bch' &&
                  RegExp('^[13]').hasMatch(a))) {
            continue;
          }
          if (_valid[other]!.contains(a)) continue;
          if (!checked.contains(other)) continue;
          expect(
            isBuyBeamDepositAddressOf(a, other),
            isFalse,
            reason: '$chain address taken as $other: $a',
          );
        }
      }
    }
  });

  test('Ethereum-like chains share one rule: 0x and 40 hex digits, the '
      'EIP-55 checksum when mixed case', () {
    for (final c in kEvmChains) {
      expect(
        isBuyBeamDepositAddressOf(
          '0x52908400098527886E0F7030069857D2E4169EE7',
          c,
        ),
        isTrue,
        reason: c,
      );
    }
    expect(
      isEvmDepositAddress('0x52908400098527886E0F7030069857D2E4169Ee7'),
      isFalse,
      reason: 'one letter in the wrong case',
    );
    expect(
      isEvmDepositAddress('0x52908400098527886e0f7030069857d2e4169ee'),
      isFalse,
      reason: '39 digits',
    );
    expect(
      isBuyBeamDepositAddressOf(
        '0x52908400098527886E0F7030069857D2E4169EE7',
        'hypercore',
      ),
      isTrue,
    );
  });

  test('an unknown chain gets the loose check; nothing with spaces, '
      'controls or under 20 characters', () {
    expect(buyBeamKnowsChain('kaia'), isFalse);
    expect(buyBeamKnowsChain('btc'), isTrue);
    expect(buyBeamKnowsChain('base'), isTrue);
    expect(
      isBuyBeamDepositAddressOf(
        '0x52908400098527886E0F7030069857D2E4169EE7',
        'kaia',
      ),
      isTrue,
    );
    expect(isBuyBeamDepositAddressOf('short', 'kaia'), isFalse);
    expect(
      isBuyBeamDepositAddressOf('an address with spaces in it', 'kaia'),
      isFalse,
    );
    expect(
      isBuyBeamDepositAddressOf('abc\u202edef${'1' * 20}', 'kaia'),
      isFalse,
      reason: 'no hidden direction marks',
    );
    expect(isBuyBeamDepositAddressOf('', 'btc'), isFalse);
  });

  test('a payment link is never a deposit address, on any chain; BCH\'s '
      'own prefix is its address', () {
    for (final (a, chain) in const [
      ('bitcoin:bc1q6rga95756htd0kxemtdaehw7mlswrchr6zzx2s', 'btc'),
      ('bc1q6rga95756htd0kxemtdaehw7mlswrchr6zzx2s?amount=1', 'btc'),
      ('ethereum:0x52908400098527886E0F7030069857D2E4169EE7', 'eth'),
      (
        'ethereum:0x52908400098527886E0F7030069857D2E4169EE7@1/transfer'
            '?address=0x1&uint256=1',
        'eth',
      ),
      ('solana:So11111111111111111111111111111111111111112', 'sol'),
      ('kaia:0x52908400098527886E0F7030069857D2E4169EE7', 'kaia'),
      ('0x52908400098527886E0F7030069857D2E4169EE7?value=1', 'kaia'),
      ('bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a', 'btc'),
    ]) {
      expect(
        isBuyBeamDepositAddressOf(a, chain),
        isFalse,
        reason: '$chain: $a',
      );
    }
    expect(
      isBuyBeamDepositAddressOf(
        'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a',
        'bch',
      ),
      isTrue,
    );
    expect(
      isBuyBeamDepositAddressOf('0x${'1' * 200}', 'kaia'),
      isFalse,
      reason: 'longer than any address',
    );
  });

  test('every chain the buy offers first has its own rule', () {
    for (final (_, chain) in kBuyBeamPopular) {
      expect(buyBeamKnowsChain(chain), isTrue, reason: chain);
    }
    for (final chain in kChainNames.keys) {
      expect(buyBeamKnowsChain(chain), isTrue, reason: chain);
    }
  });

  test('the same answers as the web wallet, for every candidate on every '
      'chain', () {
    final j = jsonDecode(
      File('test/beam/buy/deposit_address_vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final chains = (j['chains']! as List).cast<String>();
    final cases = (j['cases']! as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThan(2000));
    expect(chains, containsAll(kChainNames.keys));
    final differ = <String>[];
    var valid = 0;
    for (final c in cases) {
      final a = c['a']! as String;
      final ok = (c['ok']! as List).cast<String>().toSet();
      for (final chain in chains) {
        final mine = isBuyBeamDepositAddressOf(a, chain);
        if (mine) valid++;
        if (mine != ok.contains(chain)) {
          differ.add('$chain "$a": web ${ok.contains(chain)}, app $mine');
        }
      }
    }
    expect(differ, isEmpty, reason: differ.take(40).join('\n'));
    expect(valid, greaterThan(1000));
  });
}
