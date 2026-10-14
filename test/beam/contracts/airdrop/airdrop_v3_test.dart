/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Airdrop v3, the parts without a wallet: the pins, the fees from the
// declared charges (equal to what the core charges), the seed and voucher
// keys exactly as the pinned app shader derives them (vectors the real
// shader printed on mainnet), the argument builders (the pool never asked,
// no fee ever passed), answer parsing, the shader's error texts, and the
// check before a new batch's codes are shared, truncated lists included.
// Mirrors the web wallet's pwa/test/unit/airdrop_v3.test.mjs.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_wallet_keys.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_view.dart';

import 'airdrop_v3_fixtures.dart';

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

List<int> _bytes(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

// Printed by the pinned v3 app shader (role=user,action=voucher_key) in the
// wallet engine, against mainnet, on 2026-10-13 (the web wallet's
// airdrop_v3.test.mjs SHADER_KEYS). Both Y parities.
const _shaderKeys = [
  (
    'ABCD-EFGH-JKLM-NPQR',
    '2342225dbd5417975dd1d8b813abe5b9e5239c39f780ee6d4d113fed24c7a2ef01',
  ),
  (
    'abcd efgh jklm npqr',
    '2342225dbd5417975dd1d8b813abe5b9e5239c39f780ee6d4d113fed24c7a2ef01',
  ),
  ('7', 'bca7cab8c0518ea59df5726191fbd165076556dddeafe7b130787bfd721f422e01'),
  (
    'ZZZZ-ZZZZ-ZZZZ-ZZZZ',
    '221176133c612973a7721d85f99bc4355f205af81a481e52914ed17d8ff0404d01',
  ),
  (
    'A2B3-C4D5-E6F7-G8H9',
    '07f09729a570295b57cabaa3ae21491f837b3044f41eb960e7846636df4dd22e01',
  ),
  (
    'BBBB-BBBB-BBBB-BBBB',
    'c0171b79e33b7fd9ea848261cd6eb614bbed9e22dbc28ed342a392792d0e735100',
  ),
  (
    'CCCC-CCCC-CCCC-CCCC',
    '55d4cb0a7938ec2872081f9775775da1cd3034c92c0be362818c31254d93d65c00',
  ),
  (
    'HHHH-HHHH-HHHH-HHHH',
    'cc4d0ad546c5410ce65583d51e9ab956dbdd969ecf31e39543aae37266fcb97000',
  ),
  (
    'DDDD-DDDD-DDDD-DDDD',
    '365daa3a9228e38233e0db97e94c87c23964e8bc927b78ff76ebbb69dbf9d91501',
  ),
];
const _shaderSeeds = {
  '7': '74f16d9c8a33bd9c3f03cba97b9b11f86bc2105a1a10d3fcb9ed9d7785b961eb',
  'ZZZZ-ZZZZ-ZZZZ-ZZZZ':
      '93e9ea885d30f00f6d152d742c99a1c232299efda350d45b0f21bfdca3a9f5c3',
  'A2B3-C4D5-E6F7-G8H9':
      '29b5cb24aa9009a001439892f87ead3521f548f57ece53533ae5ce2463c4d3ba',
};

/// A fake chain for the check: check_voucher, view_my_batches, view_batch.
typedef _Chain = ({
  List<int> looked,
  Future<AirdropV3VoucherInfo?> Function(String) lookup,
  Future<AirdropV3BatchList> Function() myBatches,
  Future<AirdropV3BatchDetail> Function(BigInt) viewBatch,
});

void main() {
  const g = BigInt.from;

  group('facts', () {
    test('the v3 contract and its app shader are pinned as the README '
        'states; the bundled file is that shader', () {
      expect(
        kAirdropV3ContractId,
        'ac85d74b88aca36a8033f19b00b89df55e9c75a45c8a567c0ee158e9c11aeffe',
      );
      expect(
        kAirdropV3ShaderId,
        '3ed14be85bb30ae3755d9df426283612142265e978813d2ed9fabaf741515070',
      );
      final bytes = File('assets/beam/shaders/airdrop_v3_app.wasm')
          .readAsBytesSync();
      expect(bytes.length, kAirdropV3AppShaderSize);
      expect(
        crypto.sha256.convert(bytes).toString(),
        kAirdropV3AppShaderSha256,
      );
      expect(
        kAirdropV3AppShaderSha256,
        'a61a8577bd450e33d01f1f0a788bea943b95836cb2b3e899353bc3b2c5ee69b8',
      );
      // The old contract keeps its own shader and id.
      expect(kAirdropAppShaderSha256.substring(0, 8), 'cddf4a63');
      expect(kAirdropV3ContractId, isNot(kAirdropContractId));
      expect(AirdropV3Method.createBatch, 2);
      expect(AirdropV3Method.redeem, 3);
      expect(AirdropV3Method.cancelBatch, 4);
      expect(kAirdropV3MaxVouchersPerBatch, 100);
      // The old contract's cap stays for it only.
      expect(kAirdropMaxVouchersPerBatch, 29);
      // History names calls to either contract as airdrops.
      expect(
        BeamContractKind.of([kAirdropV3ContractId]),
        BeamContractKind.airdrop,
      );
      expect(
        BeamContractKind.of([kAirdropContractId]),
        BeamContractKind.airdrop,
      );
    });

    test('network fees: claim 0.021, create and cancel by the README '
        'formulas for 1..100 codes, equal to what the core charges', () {
      expect(AirdropV3Fee.claim, g(2100000));
      BigInt readme(int base, int per, int n) {
        final v = g(100000 + 10 * (base + per * n));
        return v > g(1100000) ? v : g(1100000);
      }

      for (var n = 1; n <= 100; n++) {
        expect(AirdropV3Fee.create(n), readme(115000, 30000, n), reason: '$n');
        expect(AirdropV3Fee.cancel(n), readme(35000, 28000, n), reason: '$n');
        // BeamContractFee is the core's get_FeeMin: what process_invoke_data
        // pays for the built entry (creator 33 + asset 4 + count 4 + gas 8,
        // then 41 per code; cancel: 45, then 33 per code).
        for (final spend in [
          [0],
          [36, 0],
          [36],
        ]) {
          expect(
            BeamContractFee.forEntry(
              argsBytes: 49 + 41 * n,
              dataBytes: 0,
              spendAssets: spend,
              charge: AirdropV3Charge.createBatch(n),
            ),
            AirdropV3Fee.create(n),
          );
          expect(
            BeamContractFee.forEntry(
              argsBytes: 45 + 33 * n,
              dataBytes: 0,
              spendAssets: spend,
              charge: AirdropV3Charge.cancelBatch(n),
            ),
            AirdropV3Fee.cancel(n),
          );
        }
      }
      expect(
        BeamContractFee.forEntry(
          argsBytes: 139,
          dataBytes: 0,
          spendAssets: const [36, 0],
          charge: AirdropV3Charge.redeem,
        ),
        AirdropV3Fee.claim,
      );
      // The README's table, and the live test's fees (create 3 → 2,150,000;
      // claim 2,100,000; cancel 1 → 1,100,000).
      expect(AirdropV3Fee.create(1), g(1550000));
      expect(AirdropV3Fee.create(3), g(2150000));
      expect(AirdropV3Fee.create(100), g(31250000));
      expect(AirdropV3Fee.cancel(1), g(1100000));
      expect(AirdropV3Fee.cancel(2), g(1100000));
      expect(AirdropV3Fee.cancel(3), g(1290000));
      expect(AirdropV3Fee.cancel(100), g(28450000));
      expect(kAirdropV3GasPerVoucher, g(2200000));
      expect(kAirdropV3GasPerVoucher >= AirdropV3Fee.claim, isTrue);
    });

    test('the 1% creation fee never wraps around; equal to the old rule '
        'wherever that one does not; at least 1 groth', () {
      final u64 = (BigInt.one << 64) - BigInt.one;
      for (final t in [
        g(1),
        g(99),
        g(100),
        g(101),
        g(9999),
        g(10000),
        g(123456789),
        g(9000000),
        AirdropFee.maxTotal,
      ]) {
        expect(AirdropV3Fee.creationFee(t), AirdropFee.creationFee(t));
      }
      expect(AirdropV3Fee.creationFee(g(1)), BigInt.one);
      expect(AirdropV3Fee.creationFee(g(9000000)), g(90000)); // live test
      expect(AirdropV3Fee.creationFee(u64), u64 ~/ g(100));
      expect(() => AirdropV3Fee.creationFee(g(-1)), throwsArgumentError);
      expect(
        () => AirdropV3Fee.creationFee(u64 + BigInt.one),
        throwsArgumentError,
      );
    });
  });

  group('seeds and keys', () {
    test('the seed is SHA-256("BeamAirdropV3:" || normalised code): the '
        'README test vector', () {
      const v =
          '722f480abe6a26a479b9bdd177c979d320254787b2f24c11b618689c613ff8f3';
      expect(_hex(AirdropV3Code.seed('ABCD-EFGH-JKLM-NPQR')), v);
      expect(_hex(AirdropV3Code.seed('abcd efgh jklm npqr')), v);
      expect(_hex(AirdropV3Code.seed(' Abcd_efgh.JKLM-npqr ')), v);
      expect(
        v,
        crypto.sha256
            .convert(utf8.encode('BeamAirdropV3:ABCDEFGHJKLMNPQR'))
            .toString(),
      );
      // Not the old contract's key for the same code (public on chain).
      expect(v, isNot(AirdropVoucherCode.hashHex('ABCD-EFGH-JKLM-NPQR')));
    });

    test('normalising: as the v3 shader; past 64 letters and digits '
        'refused, never cut', () {
      expect(
        AirdropV3Code.normalise('abcd-efgh jklm_npqr'),
        'ABCDEFGHJKLMNPQR',
      );
      expect(AirdropV3Code.normalise('aßb'), 'AB');
      expect(AirdropV3Code.normalise('A' * 65), 'A' * 65);
      expect(AirdropVoucherCode.normalise('A' * 65), 'A' * 64);
      expect(AirdropV3Code.isV3Code('A' * 64), isTrue);
      expect(AirdropV3Code.isV3Code('A' * 65), isFalse);
      expect(AirdropV3Code.isV3Code('----'), isFalse);
      expect(AirdropV3Code.isV3Code('7'), isTrue);
      expect(() => AirdropV3Code.seed('A' * 65), throwsArgumentError);
      expect(() => AirdropV3Code.seed('- -'), throwsArgumentError);
    });

    test('voucher keys: the same as the pinned shader derives, for both Y '
        'parities; bound to the contract id', () {
      for (final (code, key) in _shaderKeys) {
        expect(AirdropV3Code.voucherKey(code), key, reason: code);
      }
      for (final e in _shaderSeeds.entries) {
        expect(_hex(AirdropV3Code.seed(e.key)), e.value, reason: e.key);
      }
      expect({for (final (_, k) in _shaderKeys) k.substring(64)}, {'00', '01'});
      expect(
        AirdropV3Code.voucherKey(
          'ABCD-EFGH-JKLM-NPQR',
          cid: kAirdropContractId,
        ),
        isNot(_shaderKeys.first.$2),
      );
      // The secret is SHA-256(tag || cid || seed) when that is a valid
      // scalar (practically always).
      final seed = AirdropV3Code.seed('ABCD-EFGH-JKLM-NPQR');
      expect(
        _hex(AirdropV3Code.secret(seed)),
        crypto.sha256.convert([
          ...utf8.encode('BeamAirdropV3.key'),
          ..._bytes(kAirdropV3ContractId),
          ...seed,
        ]).toString(),
      );
      expect(
        () => AirdropV3Code.secret(List.filled(31, 0)),
        throwsArgumentError,
      );
    });

    test('signing keys: the creator key is the one dApps may never sign '
        'with; each claim signs with its own voucher\'s receiving key', () {
      final creator = AirdropV3SigningKeys.creator();
      expect(
        creator,
        DappWalletKeys.keyHash([..._bytes(kAirdropV3ContractId), 0]),
      );
      expect(DappWalletKeys.reservedUse(creator), 'your airdrops');
      expect(dappContractName(kAirdropV3ContractId), 'Campfire airdrops');
      final k = _shaderKeys.first.$2;
      expect(
        AirdropV3SigningKeys.claimer(k),
        DappWalletKeys.keyHash([
          ..._bytes(kAirdropV3ContractId),
          0x43,
          ..._bytes(k),
        ]),
      );
      expect(
        AirdropV3SigningKeys.claimer(k),
        isNot(AirdropV3SigningKeys.claimer(_shaderKeys[2].$2)),
      );
    });
  });

  group('arguments', () {
    test('every action names v3 and every argument; the pool is never '
        'asked; no fee is ever passed', () {
      const c = 'cid=$kAirdropV3ContractId';
      expect(
        AirdropV3Args.redeem(normalisedCode: 'ABCDEFGHJKLMNPQR'),
        'role=user,action=redeem,$c,code=ABCDEFGHJKLMNPQR,use_gas_pool=0',
      );
      expect(
        AirdropV3Args.checkVoucher(normalisedCode: 'ABCDEFGHJKLMNPQR'),
        'role=user,action=check_voucher,$c,code=ABCDEFGHJKLMNPQR',
      );
      expect(
        AirdropV3Args.voucherKey(normalisedCode: '7'),
        'role=user,action=voucher_key,$c,code=7',
      );
      expect(
        AirdropV3Args.viewMyBatches(),
        'role=user,action=view_my_batches,$c',
      );
      expect(
        AirdropV3Args.viewBatch(batchId: g(12)),
        'role=user,action=view_batch,$c,batch_id=12',
      );
      expect(
        AirdropV3Args.cancelBatch(batchId: g(5)),
        'role=user,action=cancel_batch,$c,batch_id=5',
      );
      final s1 = AirdropV3Code.seed('ABCD-EFGH-JKLM-NPQR');
      final s2 = AirdropV3Code.seed('ZZZZ-ZZZZ-ZZZZ-ZZZZ');
      expect(
        AirdropV3Args.createBatch(
          assetId: 36,
          gasPerVoucher: kAirdropV3GasPerVoucher,
          entries: [
            AirdropV3SeedEntry(s1, g(100000)),
            AirdropV3SeedEntry(s2, g(100000)),
          ],
        ),
        'role=user,action=create_batch,$c,asset_id=36,count=2,'
        'gas_per_voucher=2200000,seeds=${_hex(s1)}a086010000000000'
        '${_hex(s2)}a086010000000000',
      );
      expect(
        AirdropV3Args.createBatch(
          assetId: 0,
          gasPerVoucher: BigInt.zero,
          entries: [AirdropV3SeedEntry(s1, BigInt.one)],
        ),
        contains(',gas_per_voucher=0,'),
      );
      final every = [
        AirdropV3Args.redeem(normalisedCode: 'A'),
        AirdropV3Args.checkVoucher(normalisedCode: 'A'),
        AirdropV3Args.voucherKey(normalisedCode: 'A'),
        AirdropV3Args.viewMyBatches(),
        AirdropV3Args.viewBatch(batchId: BigInt.one),
        AirdropV3Args.cancelBatch(batchId: BigInt.one),
        AirdropV3Args.createBatch(
          assetId: 0,
          gasPerVoucher: kAirdropV3GasPerVoucher,
          entries: [AirdropV3SeedEntry(s1, BigInt.one)],
        ),
      ];
      for (final a in every) {
        expect(a, startsWith('role=user,'));
        expect(
          a,
          isNot(
            matches(
              RegExp('sponsor_gas|withdraw|set_gas_policy|pause|manager|fee='),
            ),
          ),
        );
        expect(a, contains(c));
      }
      for (final bad in ['ABCD-EFGH', 'abcd', '', 'A' * 65, 'A,B=C', 'ÄB']) {
        expect(
          () => AirdropV3Args.redeem(normalisedCode: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });

    test('the prepaid claim fee is 0 or exactly 0.022 BEAM; a batch is 1 '
        'to 100 distinct codes of positive value', () {
      expect(AirdropV3Args.gas(BigInt.zero), BigInt.zero);
      expect(AirdropV3Args.gas(g(2200000)), g(2200000));
      for (final x in [1, 2099999, 2100000, 2199999, 2200001, 10000000]) {
        expect(() => AirdropV3Args.gas(g(x)), throwsArgumentError);
      }
      AirdropV3SeedEntry e(int i, [int v = 1]) =>
          AirdropV3SeedEntry(AirdropV3Code.seed('CODE$i'), g(v));
      expect(
        AirdropV3Args.seedsBlob([for (var i = 0; i < 100; i++) e(i)]).length,
        4000,
      );
      expect(
        () => AirdropV3Args.seedsBlob([for (var i = 0; i < 101; i++) e(i)]),
        throwsArgumentError,
      );
      expect(() => AirdropV3Args.seedsBlob([]), throwsArgumentError);
      expect(() => AirdropV3Args.seedsBlob([e(1), e(1)]), throwsArgumentError);
      expect(() => e(1, 0), throwsArgumentError);
      expect(
        () => AirdropV3SeedEntry(List.filled(31, 0), BigInt.one),
        throwsArgumentError,
      );
    });
  });

  group('answers', () {
    Map<String, Object?> out(Object json) =>
        ShaderOutput.decode(jsonEncode(json));
    final key = _shaderKeys.first.$2;

    test('a voucher, my batches (truncated), one batch, voucher_key; '
        'anything malformed is refused', () {
      final v = AirdropV3VoucherInfo.fromOutput(
        ShaderOutput.decode(
          '{"voucher": {"key": "$key", "batch_id": 4, "asset_id": 36, '
          '"value": 100000, "gas": 2200000, "redeemed": 0, "pool_gas": 0, '
          '"claim_fee": 2100000}}',
        ),
      );
      expect(v.key, key);
      expect(v.batchId, g(4));
      expect(v.assetId, 36);
      expect(v.value, g(100000));
      expect(v.gas, g(2200000));
      expect(v.redeemed, isFalse);
      expect(v.redeemedAtHeight, isNull);
      final r = AirdropV3VoucherInfo.fromOutput(
        ShaderOutput.decode(
          '{"voucher": {"key": "$key", "batch_id": 4, "asset_id": 0, '
          '"value": 18446744073709551615, "gas": 0, "redeemed": 1, '
          '"redeemed_at": 4080000}}',
        ),
      );
      expect(r.value, (BigInt.one << 64) - BigInt.one);
      expect(r.redeemedAtHeight, g(4080000));
      for (final bad in [
        {
          'voucher': {
            'key': 'xyz',
            'batch_id': 1,
            'asset_id': 0,
            'value': 1,
            'gas': 0,
            'redeemed': 0,
          },
        },
        {
          'voucher': {
            'key': key,
            'batch_id': 1,
            'asset_id': 0,
            'value': 1,
            'gas': 0,
            'redeemed': 2,
          },
        },
        {
          'voucher': {
            'key': key,
            'batch_id': 1,
            'asset_id': 4294967296,
            'value': 1,
            'gas': 0,
            'redeemed': 0,
          },
        },
        <String, Object?>{},
      ]) {
        expect(
          () => AirdropV3VoucherInfo.fromOutput(out(bad)),
          throwsFormatException,
        );
      }
      final b = AirdropV3BatchList.fromOutput(
        out({
          'batches': [
            {
              'id': 7,
              'asset_id': 36,
              'created': 10,
              'unclaimed': 6,
              'redeemed': 3,
              'cancelled': 1,
              'value_unclaimed': 600000,
              'gas_per_voucher': 2200000,
              'created_at': 4079000,
            },
          ],
          'truncated': 1,
        }),
      );
      expect(b.truncated, isTrue);
      final row = b.batches.single;
      expect(
        (row.id, row.assetId, row.created, row.unclaimed, row.redeemed),
        (g(7), 36, 10, 6, 3),
      );
      expect(row.cancelled, 1);
      expect(row.valueUnclaimed, g(600000));
      expect(row.gasUnclaimed, g(6 * 2200000));
      expect(row.createdAtHeight, g(4079000));
      // The shader computes cancelled in 32 bits: a wrap is refused.
      expect(
        () => AirdropV3BatchList.fromOutput(
          out({
            'batches': [
              {
                'id': 7,
                'asset_id': 36,
                'created': 1,
                'unclaimed': 2,
                'redeemed': 0,
                'cancelled': 4294967295,
                'value_unclaimed': 1,
                'gas_per_voucher': 0,
                'created_at': 1,
              },
            ],
            'truncated': 0,
          }),
        ),
        throwsFormatException,
      );
      final one = AirdropV3BatchDetail.fromOutput(
        out({
          'batch': {
            'creator': v3Creator,
            'asset_id': 36,
            'created': 1,
            'gas_per_voucher': 0,
            'created_at': 5,
            'vouchers': [
              {
                'key': key,
                'batch_id': 7,
                'asset_id': 36,
                'value': 9,
                'gas': 0,
                'redeemed': 0,
              },
            ],
          },
        }),
        g(7),
      );
      expect(one.creator, v3Creator);
      expect(one.vouchers.single.key, key);
      // A voucher of another batch in the answer is refused.
      expect(
        () => AirdropV3BatchDetail.fromOutput(
          out({
            'batch': {
              'creator': v3Creator,
              'asset_id': 36,
              'created': 1,
              'gas_per_voucher': 0,
              'created_at': 5,
              'vouchers': [
                {
                  'key': key,
                  'batch_id': 8,
                  'asset_id': 36,
                  'value': 9,
                  'gas': 0,
                  'redeemed': 0,
                },
              ],
            },
          }),
          g(7),
        ),
        throwsFormatException,
      );
      final k = AirdropV3DerivedKey.fromOutput(
        out({'seed': _shaderSeeds['7'], 'key': _shaderKeys[2].$2}),
      );
      expect(k.key, _shaderKeys[2].$2);
      expect(k.toString(), isNot(contains(_shaderSeeds['7']!)));
      expect(
        () => AirdropV3DerivedKey.fromOutput(out({'seed': 'ab', 'key': key})),
        throwsFormatException,
      );
    });

    test('the shader\'s error texts become codes', () {
      const c = BeamAirdropV3Service.codeFor;
      expect(c('voucher not found'), AirdropErrorCode.voucherNotFound);
      expect(c('voucher already redeemed'), AirdropErrorCode.alreadyRedeemed);
      expect(c('batch not found'), AirdropErrorCode.batchNotFound);
      expect(
        c('this wallet did not create the batch'),
        AirdropErrorCode.notBatchCreator,
      );
      expect(
        c('no unclaimed vouchers in this batch'),
        AirdropErrorCode.nothingToCancel,
      );
      expect(c('contract is paused: no new batches'), AirdropErrorCode.paused);
      expect(
        c('code is longer than 64 letters and digits'),
        AirdropErrorCode.invalidCode,
      );
      expect(
        c('no Airdrop v3 contract at this cid (shader ID does not match)'),
        AirdropErrorCode.contractNotFound,
      );
      expect(
        c(
          'this cid is not derived from the Airdrop v3 shader ID and its '
          'owner: refusing',
        ),
        AirdropErrorCode.contractNotFound,
      );
      expect(c('something new'), AirdropErrorCode.shaderError);
    });

    test('what a claim costs: a code with its fee paid needs no BEAM; '
        'others say how much', () {
      AirdropSummary claim(int assetId, int value, int gas) {
        final receives = <int, BigInt>{};
        receives[assetId] = g(value);
        if (gas > 0) receives[0] = (receives[0] ?? BigInt.zero) + g(gas);
        return AirdropSummary(
          action: AirdropAction.redeem,
          contract: AirdropContract.v3,
          assetId: assetId,
          pays: const {},
          receives: receives,
          networkFee: AirdropV3Fee.claim,
          contractId: kAirdropV3ContractId,
          gas: g(gas),
        );
      }

      final paid = claim(36, 100000, 2200000);
      expect(paid.codePaysFee, isTrue);
      expect(paid.beamNeeded, BigInt.zero);
      expect(paid.beamChange, g(100000));
      expect(paid.assetAmount, g(100000));
      final unpaid = claim(36, 100000, 0);
      expect(unpaid.codePaysFee, isFalse);
      expect(unpaid.beamNeeded, g(2100000));
      expect(claim(0, 1000000, 0).beamNeeded, g(1100000));
      expect(claim(0, 50000000, 0).beamNeeded, BigInt.zero);
      final small = claim(0, 1, 2200000);
      expect(small.beamChange, g(100001));
      expect(small.assetAmount, BigInt.one);
      expect(small.claimCostsMoreThanItPays, isFalse);
      expect(claim(0, 1, 0).claimCostsMoreThanItPays, isTrue);
    });
  });

  group('the check before sharing', () {
    AirdropSavedBatch saved(
      int n, {
      int value = 100000,
      BigInt? gas,
      int assetId = 36,
      String? creatorKey = v3Creator,
    }) => AirdropSavedBatch(
      localId: 'b1',
      contractId: kAirdropV3ContractId,
      assetId: assetId,
      createdAt: DateTime.utc(2026, 10, 13),
      gasPerVoucher: gas ?? kAirdropV3GasPerVoucher,
      creatorKey: creatorKey,
      codes: [
        for (var i = 0; i < n; i++)
          () {
            final code =
                'AAAA-BBBB-CCCC-DD${String.fromCharCode(65 + i)}'
                '${String.fromCharCode(66 + i)}';
            return AirdropSavedCode(
              code: code,
              hashHex: AirdropVoucherCode.hashHex(code),
              value: g(value),
              key: AirdropV3Code.voucherKey(code),
            );
          }(),
      ],
    );

    _Chain chainFor(
      AirdropSavedBatch b, {
      BigInt? batchId,
      bool truncated = false,
      bool listed = true,
      String creator = v3Creator,
      List<(BigInt, String)> others = const [],
      AirdropV3VoucherInfo? Function(AirdropSavedCode c, int i)? override,
      int? listedCreated,
    }) {
      final id = batchId ?? g(9);
      final looked = <int>[];
      AirdropV3VoucherInfo info(AirdropSavedCode c, int i) =>
          override?.call(c, i) ??
          AirdropV3VoucherInfo(
            key: c.key!,
            batchId: id,
            assetId: b.assetId,
            value: c.value,
            gas: b.gasPerVoucher!,
            redeemed: false,
          );
      AirdropV3Batch row(BigInt rid, int assetId, int created, BigInt gas) =>
          AirdropV3Batch(
            id: rid,
            assetId: assetId,
            created: created,
            unclaimed: created,
            redeemed: 0,
            cancelled: 0,
            valueUnclaimed: BigInt.one,
            gasPerVoucher: gas,
            createdAtHeight: g(4080000),
          );
      return (
        looked: looked,
        lookup: (code) async {
          final i = b.codes.indexWhere((c) => c.code == code);
          looked.add(i);
          return i < 0 ? null : info(b.codes[i], i);
        },
        myBatches: () async => AirdropV3BatchList([
          if (listed)
            row(id, b.assetId, listedCreated ?? b.count, b.gasPerVoucher!),
          for (final (oid, _) in others) row(oid, 0, 1, BigInt.zero),
        ], truncated: truncated),
        viewBatch: (rid) async {
          if (rid == id) {
            return AirdropV3BatchDetail(
              id: id,
              creator: creator,
              assetId: b.assetId,
              created: b.count,
              gasPerVoucher: b.gasPerVoucher!,
              createdAtHeight: g(4080000),
              vouchers: const [],
            );
          }
          for (final (oid, oc) in others) {
            if (oid == rid) {
              return AirdropV3BatchDetail(
                id: oid,
                creator: oc,
                assetId: 0,
                created: 1,
                gasPerVoucher: BigInt.zero,
                createdAtHeight: BigInt.one,
                vouchers: const [],
              );
            }
          }
          throw const BeamAirdropException(
            AirdropErrorCode.batchNotFound,
            'batch not found',
          );
        },
      );
    }

    Future<AirdropSquatCheck> run(
      AirdropSavedBatch b,
      _Chain ch, {
      void Function(int, int)? onProgress,
    }) => airdropV3SquatCheck(
      batch: b,
      lookup: ch.lookup,
      myBatches: ch.myBatches,
      viewBatch: ch.viewBatch,
      onProgress: onProgress,
    );

    test('every code found with its key, value and fee, in one batch this '
        'wallet lists: ready; check_voucher on every code', () async {
      final b = saved(4);
      final ch = chainFor(b);
      final seen = <String>[];
      expect(
        await run(b, ch, onProgress: (d, t) => seen.add('$d/$t')),
        AirdropSquatCheck.ok(g(9)),
      );
      expect(ch.looked, [0, 1, 2, 3]);
      expect(seen, ['1/4', '2/4', '3/4', '4/4']);
      // A claimed code is still this batch's.
      expect(
        (await run(
          b,
          chainFor(
            b,
            override: (c, i) => AirdropV3VoucherInfo(
              key: c.key!,
              batchId: g(9),
              assetId: 36,
              value: c.value,
              gas: kAirdropV3GasPerVoucher,
              redeemed: true,
              redeemedAtHeight: g(4080001),
            ),
          ),
        )).ok,
        isTrue,
      );
    });

    test('a squatted batch, and every way a code can point elsewhere, fail '
        'with the reason', () async {
      final b = saved(3);
      AirdropV3VoucherInfo v(
        AirdropSavedCode c, {
        String? key,
        BigInt? batchId,
        int assetId = 36,
        BigInt? value,
        BigInt? gas,
      }) => AirdropV3VoucherInfo(
        key: key ?? c.key!,
        batchId: batchId ?? g(9),
        assetId: assetId,
        value: value ?? c.value,
        gas: gas ?? kAirdropV3GasPerVoucher,
        redeemed: false,
      );
      // The copycat's batch holds our keys with tiny values.
      expect(
        await run(
          b,
          chainFor(
            b,
            override: (c, i) =>
                v(c, batchId: g(12), value: BigInt.one, gas: BigInt.zero),
          ),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherValue, 0),
      );
      final missing = chainFor(b);
      expect(
        await airdropV3SquatCheck(
          batch: b,
          lookup: (code) async =>
              code == b.codes[1].code ? null : await missing.lookup(code),
          myBatches: missing.myBatches,
          viewBatch: missing.viewBatch,
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notFound, 1),
      );
      expect(
        await run(
          b,
          chainFor(b, override: (c, i) => i == 1 ? v(c, key: v3Other) : null),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherKey, 1),
      );
      expect(
        await run(
          b,
          chainFor(b, override: (c, i) => i == 2 ? v(c, assetId: 37) : null),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherValue, 2),
      );
      expect(
        await run(
          b,
          chainFor(
            b,
            override: (c, i) => i == 0 ? v(c, gas: BigInt.zero) : null,
          ),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherValue, 0),
        reason: 'the prepaid fee too',
      );
      expect(
        await run(
          b,
          chainFor(b, override: (c, i) => i == 2 ? v(c, batchId: g(10)) : null),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherBatch, 2),
      );
      expect(
        await run(b, chainFor(b, listed: false)),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notMine),
        reason: 'a batch view_my_batches does not list is not this wallet\'s',
      );
      // The listed batch must be the one made: its count, asset and fee.
      expect(
        await run(b, chainFor(b, listedCreated: 4)),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherBatch),
      );
      // A saved code without its key can never pass.
      final noKey = AirdropSavedBatch(
        localId: 'b2',
        contractId: kAirdropV3ContractId,
        assetId: 36,
        createdAt: DateTime.utc(2026, 10, 13),
        gasPerVoucher: kAirdropV3GasPerVoucher,
        codes: [
          AirdropSavedCode(
            code: b.codes.first.code,
            hashHex: b.codes.first.hashHex,
            value: b.codes.first.value,
          ),
        ],
      );
      expect(
        await run(noKey, chainFor(noKey, override: (c, i) => v(b.codes.first))),
        const AirdropSquatCheck.failed(AirdropCheckProblem.otherKey, 0),
      );
    });

    test('a truncated list is settled by view_batch and this wallet\'s '
        'creator key; a lookup that fails is not a verdict', () async {
      final b = saved(2);
      final mine = [(g(3), v3Creator)];
      expect(
        await run(b, chainFor(b, listed: false, truncated: true, others: mine)),
        AirdropSquatCheck.ok(g(9)),
      );
      expect(
        await run(
          b,
          chainFor(
            b,
            listed: false,
            truncated: true,
            others: mine,
            creator: v3Other,
          ),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notMine),
      );
      // The key comes from the build (saved), or from a listed batch.
      final noCreator = saved(2, creatorKey: null);
      expect(
        await run(
          noCreator,
          chainFor(noCreator, listed: false, truncated: true, others: mine),
        ),
        AirdropSquatCheck.ok(g(9)),
      );
      expect(
        await run(b, chainFor(b, listed: false, truncated: true)),
        AirdropSquatCheck.ok(g(9)),
      );
      expect(
        await run(
          noCreator,
          chainFor(noCreator, listed: false, truncated: true),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notMine),
        reason: 'no creator key to compare: not proven',
      );
      // The two sources disagree: not proven.
      expect(
        await run(
          b,
          chainFor(
            b,
            listed: false,
            truncated: true,
            others: [(g(3), v3Other)],
          ),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notMine),
      );
      final gone = chainFor(b, listed: false, truncated: true);
      expect(
        await airdropV3SquatCheck(
          batch: b,
          lookup: gone.lookup,
          myBatches: gone.myBatches,
          viewBatch: (_) async => throw const BeamAirdropException(
            AirdropErrorCode.batchNotFound,
            'batch not found',
          ),
        ),
        const AirdropSquatCheck.failed(AirdropCheckProblem.notMine),
      );
      // Listed when truncated: the list answers, view_batch is not asked.
      final listed = chainFor(b, truncated: true);
      expect(
        (await airdropV3SquatCheck(
          batch: b,
          lookup: listed.lookup,
          myBatches: listed.myBatches,
          viewBatch: (_) async => fail('not asked'),
        )).ok,
        isTrue,
      );
      // A lookup that fails throws.
      final down = chainFor(b);
      await expectLater(
        airdropV3SquatCheck(
          batch: b,
          lookup: (_) async => throw const SocketException('node down'),
          myBatches: down.myBatches,
          viewBatch: down.viewBatch,
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('saved v3 records', () {
    test('keep their keys, prepaid fee, creator key, batch and check '
        'through JSON; a bad key does not read; a bad check is no check', () {
      const code = 'ABCD-EFGH-JKLM-NPQR';
      final rec = AirdropSavedBatch(
        localId: 'b1',
        contractId: kAirdropV3ContractId,
        assetId: 36,
        createdAt: DateTime.utc(2026, 10, 13),
        txId: 'ab' * 16,
        txStatus: AirdropBatchTxStatus.broadcast,
        gasPerVoucher: kAirdropV3GasPerVoucher,
        creatorKey: v3Creator,
        codes: [
          AirdropSavedCode(
            code: code,
            hashHex: AirdropVoucherCode.hashHex(code),
            value: g(100000),
            key: AirdropV3Code.voucherKey(code),
          ),
        ],
      );
      expect(rec.isV3, isTrue);
      final checked = rec.copyWith(
        batchId: g(7),
        check: AirdropCodeCheck(
          state: AirdropCheckState.ok,
          at: DateTime.utc(2026, 10, 13, 0, 5),
        ),
      );
      Map<String, Object?> json(AirdropSavedBatch b) =>
          (jsonDecode(jsonEncode(b.toJson())) as Map).cast<String, Object?>();
      final back = AirdropSavedBatch.fromJson(json(checked));
      expect(back.gasPerVoucher, kAirdropV3GasPerVoucher);
      expect(back.creatorKey, v3Creator);
      expect(back.batchId, g(7));
      expect(back.check!.ok, isTrue);
      expect(back.codes.single.key, AirdropV3Code.voucherKey(code));
      // A copy keeps every v3 field (statuses change, nothing else).
      final again = back.copyWith(
        codes: [back.codes.single.withStatus(AirdropCodeStatus.claimed)],
      );
      expect(again.codes.single.key, back.codes.single.key);
      expect(again.creatorKey, v3Creator);
      // A voucher key that is not a key: unreadable (kept, never shown).
      final bad = json(rec);
      ((bad['codes']! as List).single as Map)['key'] = 'nope';
      expect(() => AirdropSavedBatch.fromJson(bad), throwsFormatException);
      // A check that does not read is no check: checked again, never ready.
      final weird = json(rec)..['check'] = {'state': 'maybe'};
      expect(AirdropSavedBatch.fromJson(weird).check, isNull);
      final failedNoReason = json(rec)
        ..['check'] = {'state': 'failed', 'at': '2026-10-13T00:00:00Z'};
      expect(AirdropSavedBatch.fromJson(failedNoReason).check, isNull);
      // An old record reads as before, without the v3 fields.
      final old = AirdropSavedBatch.fromJson(
        {...json(rec), 'contractId': kAirdropContractId}
          ..removeWhere((k, _) => ['gasPerVoucher', 'creatorKey'].contains(k)),
      );
      expect(old.isV3, isFalse);
      expect(old.check, isNull);
      expect(old.toJson().containsKey('gasPerVoucher'), isFalse);
      // Codes never reach a log line.
      expect(rec.toString(), isNot(contains('ABCD')));
      expect(rec.codes.single.toString(), isNot(contains('ABCD')));
    });
  });
}
