/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// "Your BEAM has arrived" rests on the wallet's own record of the
// transaction buybeam.my names, not on buybeam.my's word: what the wallet
// received (BEAM, a payment, completed) and at which of its addresses.
// Records are made the way the wallet makes them (BeamTxMapper over
// wallet-api's tx_list shape).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_deps.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_tx_mapper.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'buybeam_fakes.dart';

const _peer =
    '3333333333333333333333333333333333333333333333333333333333333333cc';

TransactionV2 _record(Map<String, Object?> json) => BeamTxMapper.map(
  BeamTransaction.fromJson(json),
  walletId: 'w1',
  ownAddresses: {kFakeBeamAddress},
);

void main() {
  test('a completed BEAM payment to the wallet: its amount and address', () {
    final r = BuyBeamReceipt.of(
      _record(
        txJson(
          txId: 'aa' * 16,
          status: 3,
          income: true,
          value: 1113201234567,
          sender: _peer,
          receiver: kFakeBeamAddress,
          height: 4100000,
        ),
      ),
    );
    expect(r, isNotNull);
    expect(r!.groth, BigInt.from(1113201234567));
    expect(r.address, kFakeBeamAddress);
    expect(r.isFor(kFakeBeamAddress), isTrue);
    expect(r.isFor(kFakeBeamAddress.toUpperCase()), isTrue);
    expect(r.isFor(kFakeBeamAddress2), isFalse, reason: 'another address');
  });

  test('nothing else is a receipt: still pending, another asset, sent, a '
      "contract's payout, no record", () {
    Map<String, Object?> incoming({int assetId = 0, int? height = 4100000}) =>
        txJson(
          txId: 'bb' * 16,
          status: height == null ? 5 : 3,
          income: true,
          value: 1000000,
          assetId: assetId,
          sender: _peer,
          receiver: kFakeBeamAddress,
          height: height,
        );
    expect(BuyBeamReceipt.of(_record(incoming(height: null))), isNull);
    expect(BuyBeamReceipt.of(_record(incoming(assetId: 174))), isNull);
    expect(
      BuyBeamReceipt.of(
        _record(
          txJson(
            txId: 'cc' * 16,
            status: 3,
            value: 1000000,
            sender: kFakeBeamAddress,
            receiver: _peer,
            height: 4100000,
          ),
        ),
      ),
      isNull,
    );
    expect(
      BuyBeamReceipt.of(
        _record(
          txJson(
            txId: 'dd' * 16,
            status: 3,
            txType: 12,
            fee: 12100000,
            height: 10,
            invokeData: [
              {
                'contract_id': '87' * 32,
                'amounts': [
                  {'asset_id': 0, 'amount_str': '-50000000'},
                ],
              },
            ],
          ),
        ),
      ),
      isNull,
    );
    expect(BuyBeamReceipt.of(null), isNull);
  });

  test('nothing received is not "arrived"', () {
    expect(
      BuyBeamReceipt(
        groth: BigInt.zero,
        address: kFakeBeamAddress,
      ).isFor(kFakeBeamAddress),
      isFalse,
    );
  });
}
