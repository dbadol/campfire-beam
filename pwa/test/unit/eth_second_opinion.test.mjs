// D-7: a Uniswap swap's minimum must not rest on one server's word. The chosen server's quote
// (eth_calls of Uniswap's quoters and the pools' state) sets the least the router accepts; a
// server that quotes low makes that minimum low, and the swap can then go through at that worse
// price. Before the review the same route (the same pools, the same shares) is priced on a second
// listed Ethereum server, and two prices more than 2% apart are said, with a tick to swap anyway
// (lib/eth/second_opinion.js, lib/eth/uniswap_app.js routeOutOn). Offline: the pretend chain of
// helpers/fake_uniswap.mjs, one honest and one that answers a shaded price.
import test from 'node:test';
import assert from 'node:assert/strict';
import { FakeChain } from './helpers/fake_uniswap.mjs';
import { UniswapService } from '../../src/lib/eth/uniswap/service.js';
import { UniToken, ETH_TOKEN } from '../../src/lib/eth/uniswap/models.js';
import { NATIVE_ETH } from '../../src/lib/eth/uniswap/constants.js';
import { privateKeyToAddress } from '../../src/lib/eth/crypto.js';
import { hexToBytes } from '../../src/lib/eth/hex.js';
import { ETH_RPC_HOSTS } from '../../src/lib/eth/hosts.js';
import { secondOpinion, secondOpinionWords, compareOut, otherServers, PRICE_GAP, SECOND_TRIES } from '../../src/lib/eth/second_opinion.js';
import { routeOutOn } from '../../src/lib/eth/uniswap_app.js';

const WBEAM = '0xe5acbb03d73267c03349c76ead672ee4d941f499';
const wbeam = new UniToken({ address: WBEAM, symbol: 'WBEAM', decimals: 8 });
const ETH = 10n ** 18n;
const WB = 10n ** 8n;
const OWNER = privateKeyToAddress(hexToBytes('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80')).toLowerCase();
const NOW_MS = 1791555000000;

/** A server for one ETH/WBEAM v4 pool; `shade` scales the WBEAM it says the pool holds (0.8: quotes about 20% low). */
function chainWith(shade = 1) {
  const chain = new FakeChain({ head: 26000100 });
  const p = chain.addV4({ c0: NATIVE_ETH, c1: WBEAM, fee: 3000, ts: 60, r0: 100n * ETH, r1: (32000000n * WB * BigInt(Math.round(shade * 1000))) / 1000n });
  chain.token(WBEAM, { symbol: 'WBEAM', decimals: 8 });
  chain.ethBalances.set(OWNER, 10n * ETH);
  return { chain, known: { block: 26000000, pools: [p.pool] } };
}

const service = ({ chain, known }) => new UniswapService({ rpc: chain.rpc, known, now: () => NOW_MS, sleep: async () => {} });

test('D-7 reproduced: the minimum the router enforces is whatever the chosen server quotes, less the protection', async () => {
  const honest = await service(chainWith(1)).quote({ tokenIn: ETH_TOKEN, tokenOut: wbeam, amountIn: ETH / 100n, owner: OWNER });
  const liar = chainWith(0.8);
  const svc = service(liar);
  const q = await svc.quote({ tokenIn: ETH_TOKEN, tokenOut: wbeam, amountIn: ETH / 100n, owner: OWNER });
  const review = await svc.reviewSwap({ quote: q, slippageBips: 100, owner: OWNER });
  assert.ok(review.minimumOut < (honest.amountOut * 81n) / 100n, 'a 20% low quote makes a minimum about 20% low, and nothing else looks');
});

test('the same route priced on a second server: a 20% low quote is caught and said, with both figures and a tick', async () => {
  const liar = chainWith(0.8);
  const honest = chainWith(1);
  const q = await service(liar).quote({ tokenIn: ETH_TOKEN, tokenOut: wbeam, amountIn: ETH / 100n, owner: OWNER });
  const theirs = await routeOutOn(honest.chain.rpc, q, honest.known);
  const fair = await service(honest).quote({ tokenIn: ETH_TOKEN, tokenOut: wbeam, amountIn: ETH / 100n, owner: OWNER });
  assert.equal(theirs, fair.amountOut, 'the route repriced on the honest server is what that server quotes');
  const asked = [];
  const check = await secondOpinion({
    chosenId: 'stackwallet',
    mine: q.amountOut,
    quoteOn: (rpc) => (asked.push(rpc.id), routeOutOn(honest.chain.rpc, q, honest.known)),
    makeRpc: (h) => ({ id: h.id }),
  });
  assert.equal(check.status, 'differ');
  assert.equal(check.host.id, 'publicnode', 'the next server of the list');
  assert.deepEqual(asked, ['publicnode'], 'never the chosen one');
  assert.ok(check.gap < -0.19 && check.gap > -0.21, String(check.gap));
  const words = secondOpinionWords(check, { server: 'Stack Wallet', amount: (v) => `${Number(v) / 1e8} WBEAM` });
  assert.equal(words.kind, 'warn');
  assert.match(words.text, /^Your server \(Stack Wallet\) prices this swap 20% lower than PublicNode does: [\d.]+ WBEAM against [\d.]+ WBEAM\. A price that is too low lowers your minimum/);
  assert.equal(words.ack, "Swap anyway at Stack Wallet's price");
  // Too high is said too (the swap would be refused, only the fee spent).
  const high = await secondOpinion({ chosenId: 'stackwallet', mine: (theirs * 105n) / 100n, quoteOn: async () => theirs, makeRpc: (h) => h });
  assert.equal(high.status, 'differ');
  assert.match(secondOpinionWords(high, { server: 'Stack Wallet', amount: String }).text, /5% higher than PublicNode/);
  // Honest, or a block apart (under 2%): one quiet line.
  const same = await secondOpinion({ chosenId: 'stackwallet', mine: fair.amountOut, quoteOn: () => routeOutOn(honest.chain.rpc, q, honest.known), makeRpc: (h) => h });
  assert.equal(same.status, 'agree');
  assert.deepEqual(secondOpinionWords(same, { server: 'Stack Wallet', amount: String }), { kind: 'ok', text: 'Price checked with a second server (PublicNode).', ack: null });
});

test('the second server is asked only the quoters and pools, never about this wallet', async () => {
  const honest = chainWith(1);
  const q = await service(chainWith(0.8)).quote({ tokenIn: ETH_TOKEN, tokenOut: wbeam, amountIn: ETH / 100n, owner: OWNER });
  const seen = [];
  const rpc = new Proxy(honest.chain.rpc, {
    get(t, k) {
      const v = t[k];
      return typeof v === 'function' ? (...a) => (seen.push(JSON.stringify(a, (_, x) => (typeof x === 'bigint' ? String(x) : x instanceof Uint8Array ? Buffer.from(x).toString('hex') : x))), v.apply(t, a)) : v;
    },
  });
  await routeOutOn(rpc, q, honest.known);
  assert.ok(seen.length > 0);
  for (const s of seen) assert.ok(!s.toLowerCase().includes(OWNER.slice(2)), `the wallet's address went to the second server: ${s.slice(0, 200)}`);
});

test('a second server that does not answer: the next one; none at all is "unchecked", and said', async () => {
  const byId = { publicnode: 'down', drpc: 'up' };
  const one = await secondOpinion({ chosenId: 'stackwallet', mine: 1000n, quoteOn: async (rpc) => (rpc === 'down' ? Promise.reject(new Error('could not be reached')) : 1000n), makeRpc: (h) => byId[h.id] });
  assert.equal(one.status, 'agree');
  assert.equal(one.host.id, 'drpc');
  const none = await secondOpinion({ chosenId: 'stackwallet', mine: 5n, quoteOn: async () => { throw new Error('refused'); }, makeRpc: () => ({}) });
  assert.equal(none.status, 'unchecked');
  assert.equal(none.host, null);
  const words = secondOpinionWords(none, { server: 'Stack Wallet', amount: String });
  assert.equal(words.kind, 'info');
  assert.match(words.text, /^Only your server \(Stack Wallet\) priced this swap: no second server answered/);
  // A server that never answers is given up on after the time allowed, and the next one asked.
  const hung = await secondOpinion({ chosenId: 'stackwallet', mine: 1000n, timeoutMs: 50, quoteOn: (rpc) => (rpc === 'down' ? new Promise(() => {}) : Promise.resolve(1000n)), makeRpc: (h) => byId[h.id] });
  assert.equal(hung.status, 'agree');
  assert.equal(hung.host.id, 'drpc');
  // At most SECOND_TRIES servers are asked, never the chosen one.
  const asked = [];
  await secondOpinion({ chosenId: 'publicnode', mine: 5n, quoteOn: async (rpc) => { asked.push(rpc.id); throw new Error('no'); }, makeRpc: (h) => ({ id: h.id }) });
  assert.deepEqual(asked, otherServers('publicnode').slice(0, SECOND_TRIES).map((h) => h.id));
  assert.equal(asked.length, 2);
  assert.ok(!asked.includes('publicnode'));
  assert.deepEqual(otherServers('stackwallet').map((h) => h.id), ETH_RPC_HOSTS.slice(1).map((h) => h.id));
});

test('the comparison is exact in integers and symmetric about the 2% line', () => {
  assert.equal(PRICE_GAP, 0.02);
  assert.deepEqual(compareOut(1000n, 1000n), { gap: 0, agree: true });
  assert.deepEqual(compareOut(1020n, 1000n), { gap: 0.02, agree: true });
  assert.deepEqual(compareOut(1021n, 1000n), { gap: 0.021, agree: false });
  assert.deepEqual(compareOut(980n, 1000n), { gap: -0.02, agree: true });
  assert.deepEqual(compareOut(979n, 1000n), { gap: -0.021, agree: false });
  assert.deepEqual(compareOut(0n, 5n), { gap: null, agree: false });
  // Amounts far past 2^53 (18-decimal tokens) are compared exactly.
  assert.equal(compareOut(10n ** 30n + 10n ** 28n, 10n ** 30n).gap, 0.01);
});
