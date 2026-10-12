// Deleting a wallet takes with it the only record of coins still under way (release audit BM-4,
// BC-6): its open bridge moves, airdrop batches whose codes may not all be claimed, and buys at
// buybeam.my still in progress. lib/in_flight.js reads them from the wallet's own sealed storage so
// the delete screen can list them first: counted for the open wallet, only "there are some" for a
// wallet that is locked or not the open one (nothing can be opened without its password).
import test from 'node:test';
import assert from 'node:assert/strict';
import { inFlight } from '../../src/lib/in_flight.js';
import { bridgeStoreFor, makeCrossing, STATES } from '../../src/lib/bridge/store.js';
import { codeVault, codeHash, AIRDROP_CID } from '../../src/lib/airdrop.js';
import { sealedBuyStore, makeOrder } from '../../src/lib/buy/store.js';
import { BEAM_ADDRESS, BTC_REFUND, DEPOSIT, BTC } from './buy_fakes.mjs';

const DB = 'cd'.repeat(32);
const memKv = () => {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), set: async (k, v) => void m.set(k, structuredClone(v)) };
};
const app = (over = {}) => ({ record: { id: 'w1', imported: false }, dbPass: DB, ...over });
const T = Date.UTC(2026, 9, 12, 12);

const crossing = (id, state, over = {}) =>
  makeCrossing({
    id,
    route: 'eth',
    direction: 'toBeam',
    state,
    amount: 10n ** 16n,
    receives: 1000000n,
    relayerFee: 3000000000000n,
    beamNetworkFee: 12100000n,
    beamWalletId: 'w1',
    ethWalletId: 'e1',
    ethAddress: '0x7a3e5b1c2d4f6e8a9b0c1d2e3f4a5b6c7d8e91c4',
    msgId: state === STATES.delivered || state === STATES.claimed ? Number(id.slice(1)) : null,
    createdAt: T,
    updatedAt: T,
    ...over,
  });

let seed = 0;
async function batch(localId, statuses, txStatus = 'confirmed') {
  seed++;
  return {
    localId,
    contractId: AIRDROP_CID,
    assetId: 0,
    createdAt: `2026-10-1${seed}T00:00:00.000Z`,
    txId: null,
    txStatus,
    codes: await Promise.all(
      statuses.map(async (status, i) => {
        const code = `ABCD-EFGH-JKLM-N${'PQRSTUVWXYZ'[seed]}${String.fromCharCode(65 + i)}${seed + 1}`;
        return { code, hash: await codeHash(code), value: '100000', status };
      }),
    ),
  };
}

const order = (n, over = {}) =>
  makeOrder({
    depositAddress: `${DEPOSIT}${n}`,
    assetId: BTC,
    symbol: 'BTC',
    chain: 'btc',
    decimals: 8,
    sendAmount: '0.0123',
    sendAmountRaw: 1230000n,
    beamAddress: BEAM_ADDRESS,
    beamWalletId: 'w1',
    refundAddress: BTC_REFUND,
    createdAt: T + n,
    lastState: 'awaiting_deposit',
    ...over,
  });

test('nothing kept: nothing listed', async () => {
  assert.deepEqual(await inFlight(app(), { id: 'w1' }, { kv: memKv() }), []);
  assert.deepEqual(await inFlight(app({ dbPass: null }), { id: 'w1' }, { kv: memKv() }), []);
});

test('the open wallet: open moves, batches whose codes may be unclaimed and buys under way, counted; what is done is not', async () => {
  const kv = memKv();
  const a = app();
  const moves = bridgeStoreFor(a, kv);
  await moves.save(crossing('x1', STATES.locking, { lockHash: `0x${'1'.repeat(64)}` }));
  await moves.save(crossing('x2', STATES.delivered));
  await moves.save(crossing('x3', STATES.claimed));
  await moves.save(crossing('x4', STATES.lockFailed));
  const codes = codeVault({ kv, walletId: 'w1', secret: DB, imported: false });
  await codes.put(await batch('one', ['available', 'claimed'])); // one code nobody claimed yet
  await codes.put(await batch('two', ['claimed', 'claimed'])); // every code claimed
  await codes.put(await batch('three', ['unknown'], 'broadcast')); // not checked yet: may still be claimable
  await codes.put(await batch('four', ['unknown'], 'failed')); // never on chain
  await codes.put(await batch('fives', ['notFound'])); // taken back
  const buys = sealedBuyStore(a, { kv });
  await buys.save(order(1));
  await buys.save(order(2, { terminal: true, lastState: 'completed' }));
  assert.deepEqual(await inFlight(a, { id: 'w1' }, { kv }), [
    { kind: 'bridge', count: 2 },
    { kind: 'airdrop', count: 2 },
    { kind: 'buy', count: 1 },
  ]);
  // Locked (Forgot your password?) or another wallet: their records cannot be opened, only seen.
  assert.deepEqual(await inFlight(app({ dbPass: null }), { id: 'w1' }, { kv }), [
    { kind: 'bridge', count: null },
    { kind: 'airdrop', count: null },
    { kind: 'buy', count: null },
  ]);
  assert.deepEqual(await inFlight(app({ record: { id: 'w2', imported: false } }), { id: 'w1' }, { kv }), [
    { kind: 'bridge', count: null },
    { kind: 'airdrop', count: null },
    { kind: 'buy', count: null },
  ]);
});

test('records that do not open are said to be there, never counted as none', async () => {
  const kv = memKv();
  await bridgeStoreFor(app(), kv).save(crossing('x1', STATES.claimed)); // only a finished one
  const other = app({ dbPass: 'ef'.repeat(32) }); // the same wallet id, another secret: nothing opens
  assert.deepEqual(await inFlight(other, { id: 'w1' }, { kv }), [{ kind: 'bridge', count: null }]);
  assert.deepEqual(await inFlight(app(), { id: 'w1' }, { kv }), [], 'opened: nothing under way');
});
