/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The route search without a network: a stand-in node answers Uniswap's
// quoter for v4 pools, and a stand-in discovery holds exactly the pools a
// case needs.
//
// A token whose only way to the token wanted is through ETH in two forms —
// a v4 pool into native ETH, then a pool from WETH — has a route: the swap
// wraps the ETH between the two. 4100b48b9 ("no pool on from the base
// tokens is no route") looked for the second pool on exactly the currency
// the first one paid out, and answered "no route" for it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_discovery.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_quoter.dart';

/// A token that trades only against native ETH, in a v4 pool.
const _x = UniToken(
  address: '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  symbol: 'XTK',
  decimals: 18,
);

/// A token that trades only against WETH, in a v2 pool.
const _y = UniToken(
  address: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  symbol: 'YTK',
  decimals: 18,
);

final _v4XEth = UniV4Pool.key(
  currency0: UniswapAddresses.nativeEth,
  currency1: _x.address,
  fee: 3000,
  tickSpacing: 60,
  hooks: UniswapAddresses.nativeEth,
);

/// Y sorts before WETH (0xbb… < 0xc0…).
const _v2YWeth = UniV2Pool(
  pair: '0x1234567890123456789012345678901234567890',
  currency0: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  currency1: UniswapAddresses.weth,
);

final BigInt _e18 = BigInt.from(10).pow(18);

/// Answers the v4 quoter: one ETH for every thousand X, 120,000 gas.
class _Node implements EthRpc {
  int quoterCalls = 0;

  @override
  Future<int> blockNumber() async => 21000000;

  @override
  Future<List<EthCallResult>> multicall(
    List<EthCall> calls, {
    int chunk = 40,
    int parallel = 4,
  }) async => [
    for (final c in calls)
      if (c.to == UniswapAddresses.v4Quoter) _quoteV4(c.data) else _fail,
  ];

  static final _fail = EthCallResult(false, Uint8List(0));

  EthCallResult _quoteV4(Uint8List data) {
    quoterCalls++;
    final args = abiDecode(
      '((address,address,uint24,int24,address),bool,uint128,bytes)',
      Uint8List.sublistView(data, 4),
    );
    final params = args.single as List<Object>;
    final zeroForOne = params[1] as bool;
    final amount = params[2] as BigInt;
    // currency0 is ETH: only X → ETH (not zero for one) is priced.
    if (zeroForOne) return _fail;
    return EthCallResult(
      true,
      abiEncode('uint256,uint256', [
        amount ~/ BigInt.from(1000),
        BigInt.from(120000),
      ]),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Knows [pools] and nothing else.
class _Pools implements UniswapDiscovery {
  _Pools(this.pools);

  final List<UniPool> pools;

  @override
  Future<List<UniPool>> poolsBetween(String a, String b, {int? head}) async => [
    for (final p in pools)
      if ({p.currency0, p.currency1}.containsAll({a, b})) p,
  ];

  @override
  Future<Map<String, UniPoolState>> liveState(List<UniPool> pools) async => {
    for (final p in pools)
      p.id: switch (p) {
        UniV2Pool() => UniPoolState(
          // 2,000,000 Y and 1,000 WETH.
          reserve0: BigInt.from(2000000) * _e18,
          reserve1: BigInt.from(1000) * _e18,
        ),
        _ => UniPoolState(
          sqrtPriceX96: BigInt.one << 96,
          liquidity: BigInt.from(10).pow(24),
          lpFee: 3000,
        ),
      },
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test('X → native ETH (v4) → WETH → Y is a route, not "no route"', () async {
    final node = _Node();
    final quoter = UniswapQuoter(
      rpc: node,
      discovery: _Pools([_v4XEth, _v2YWeth]),
    );
    final q = await quoter.bestQuote(
      tokenIn: _x,
      tokenOut: _y,
      amountIn: BigInt.from(1000) * _e18,
      gasPriceWei: BigInt.one,
    );
    expect(node.quoterCalls, greaterThan(0));
    expect(q.parts, hasLength(1));
    final hops = q.parts.single.route.hops;
    expect(hops, hasLength(2));
    expect(hops[0].pool, _v4XEth);
    expect(hops[0].currencyIn, _x.address);
    expect(hops[0].currencyOut, UniswapAddresses.nativeEth);
    expect(hops[1].pool, _v2YWeth);
    expect(hops[1].currencyIn, UniswapAddresses.weth);
    expect(hops[1].currencyOut, _y.address);
    // One ETH from the v4 pool, then v2's own formula for 1 WETH.
    expect(q.parts.single.hopOutputs.first, _e18);
    expect(
      q.amountOut,
      v2AmountOut(_e18, BigInt.from(1000) * _e18, BigInt.from(2000000) * _e18),
    );
  });

  test('a first pool with nothing on from either form of ETH is still '
      '"no route"', () async {
    final quoter = UniswapQuoter(rpc: _Node(), discovery: _Pools([_v4XEth]));
    await expectLater(
      quoter.bestQuote(
        tokenIn: _x,
        tokenOut: _y,
        amountIn: BigInt.from(1000) * _e18,
        gasPriceWei: BigInt.one,
      ),
      throwsA(
        isA<UniswapNoRoute>().having((e) => e.reason, 'reason', 'noPool'),
      ),
    );
  });
}
