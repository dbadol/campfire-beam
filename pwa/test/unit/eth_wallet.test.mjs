// The Ethereum wallet's own logic, offline: the sealed data store, the outbox
// (written before anything is broadcast), the history index parser and merge,
// recipient checks, preparing a payment with its fees, signing and sending,
// and following a transaction to its receipt (or to "replaced").
import test from 'node:test';
import assert from 'node:assert/strict';
import { sealData, openData, forgetDataKeys, ETH_DATA_INFO } from '../../src/lib/eth/sealed.js';
import { loadOutbox, addToOutbox, updateOutbox, clearOutbox, validEntry, trimOutbox, OUTBOX_MAX } from '../../src/lib/eth/outbox.js';
import { parseTransactions, parseTokenTransfers, mergeActivity, fetchHistory, HistoryError, PAGE } from '../../src/lib/eth/history.js';
import { recipientProblem, transferCall, prepareSend, signAndSend, followOnce, classify, findNonceTaker, maxSendable, costRose, entryFee, SendError, BRIDGE_PIPES, ETH_TRANSFER_GAS, NONCE_LOOK_MS, REFUSAL_WATCH_MS } from '../../src/lib/eth/send.js';
import { ethWallet, removeEthWallet, ethPrefs, forgetEthWallet } from '../../src/lib/eth/wallet.js';
import { saveEthKey, getEthRecord, VaultError } from '../../src/lib/eth/vault.js';
import { hasEthWallet, ETH_OUTBOX_KEY, ETH_RECORD_KEY } from '../../src/lib/eth/record.js';
import { ethKeyFromMnemonic, toChecksumAddress } from '../../src/lib/eth/crypto.js';
import { EthRpc } from '../../src/lib/eth/rpc.js';
import { parseSignedTransaction, transactionHash, signTransaction } from '../../src/lib/eth/tx.js';
import { decodeCall, abiEncode } from '../../src/lib/eth/abi.js';
import { bytesToHex } from '../../src/lib/eth/hex.js';
import { ETH, WBEAM, TOKENS, tokenBySymbol } from '../../src/lib/eth/tokens.js';
import { ROUTES } from '../../src/lib/bridge/routes.js';
import { newDbPassword, PBKDF2_MIN_ITERATIONS } from '../../src/lib/envelope.js';
import * as F from './fixtures/eth/history_export.mjs';

const JUNK = 'test test test test test test test test test test test junk';
const ME = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const ALICE = toChecksumAddress(F.ALICE);
const GWEI = 10n ** 9n;
const ETHER = 10n ** 18n;

const memoryKv = () => {
  const m = new Map();
  return { m, get: async (k) => structuredClone(m.get(k)), set: async (k, v) => void m.set(k, structuredClone(v)), del: async (k) => void m.delete(k) };
};
const newApp = (over = {}) => ({ record: { id: 'w-1', imported: false }, dbPass: newDbPassword(), prefs: {}, ...over });

async function walletWithKey({ imported = false } = {}) {
  const kv = memoryKv();
  const app = newApp({ record: { id: 'w-1', imported }, dbPass: imported ? 'file password' : newDbPassword() });
  const { sk, address } = await ethKeyFromMnemonic(JUNK);
  const record = await saveEthKey(app, { sk, address, words: 12 }, { kv });
  return { app, kv, record, ethId: record.id };
}

function entry(over = {}) {
  return {
    hash: `0x${'11'.repeat(32)}`,
    raw: '0x02f8aa',
    nonce: '0',
    from: ME,
    to: ALICE,
    asset: 'ETH',
    token: null,
    amount: '10000000000000000',
    gasLimit: '21000',
    maxFeePerGas: '3000000000',
    maxPriorityFeePerGas: '1000000000',
    createdAt: 1000,
    sentAt: null,
    state: 'signed',
    receipt: null,
    error: null,
    ...over,
  };
}

// ---------------------------------------------------------------- sealed

test('sealed data: round trip under the BEAM database password; nothing in the clear; bound to its wallet and name', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const value = [{ hash: '0xabc', to: ALICE }];
  const env = await sealData(app, 'eth-test', value, { ethId, kv });
  assert.equal(env.kind, 'eth-data');
  assert.equal(env.kdf, 'hkdf-sha256');
  assert.equal(ETH_DATA_INFO, 'beam-campfire-eth-data-v1');
  assert.ok(!JSON.stringify(env).toLowerCase().includes(F.ALICE.slice(2)), 'the address is only inside');
  assert.deepEqual(await openData(app, 'eth-test', { ethId, kv }), value);
  // The salt (and so the derived key) is kept across rewrites; the iv is not.
  const env2 = await sealData(app, 'eth-test', [...value, { hash: '0xdef' }], { ethId, kv });
  assert.equal(env2.salt, env.salt);
  assert.notEqual(env2.iv, env.iv);
  forgetDataKeys();
  assert.equal((await openData(app, 'eth-test', { ethId, kv })).length, 2, 'opens again after the keys are forgotten');
  // Another dbPass, another wallet, another Ethereum wallet, a renamed record.
  await assert.rejects(openData({ ...app, dbPass: newDbPassword() }, 'eth-test', { ethId, kv }), (e) => e instanceof VaultError && e.code === 'wrong_secret');
  await assert.rejects(openData({ ...app, record: { id: 'w-2', imported: false } }, 'eth-test', { ethId, kv }), (e) => e.code === 'mismatch');
  assert.equal(await openData(app, 'eth-test', { ethId: 'other', kv }), null, "a removed Ethereum wallet's data is not shown for a new one");
  kv.m.set('eth-other', { ...kv.m.get('eth-test'), name: 'eth-other' });
  await assert.rejects(openData(app, 'eth-other', { ethId, kv }), (e) => e.code === 'wrong_secret', 'the name is bound');
  assert.equal(await openData(app, 'nothing-here', { ethId, kv }), null);
  await assert.rejects(openData({ ...app, dbPass: null }, 'eth-test', { ethId, kv }), (e) => e.code === 'locked');
});

test('sealed data: an imported wallet uses PBKDF2 at 600,000 rounds or more, and refuses fewer or a swapped KDF', async () => {
  const { app, kv, ethId } = await walletWithKey({ imported: true });
  const env = await sealData(app, 'eth-test', { a: 1 }, { ethId, kv });
  assert.equal(env.kdf, 'pbkdf2-sha256');
  assert.equal(env.iterations, PBKDF2_MIN_ITERATIONS);
  assert.ok(env.iterations >= 600000);
  assert.deepEqual(await openData(app, 'eth-test', { ethId, kv }), { a: 1 });
  kv.m.set('eth-test', { ...env, iterations: 1000 });
  await assert.rejects(openData(app, 'eth-test', { ethId, kv }), (e) => e.code === 'weak');
  await assert.rejects(sealData(app, 'eth-test', { a: 2 }, { ethId, kv }), (e) => e.code === 'weak', 'a lowered count is not carried into the next write');
  kv.m.set('eth-test', { ...env, kdf: 'hkdf-sha256', iterations: undefined });
  await assert.rejects(openData(app, 'eth-test', { ethId, kv }), (e) => e.code === 'weak');
});

// ---------------------------------------------------------------- outbox

test('outbox: add, update, newest first; checked entries only; hash, raw, nonce and sender cannot be changed', async () => {
  const { app, kv, ethId } = await walletWithKey();
  assert.deepEqual(await loadOutbox(app, { ethId, kv }), []);
  await addToOutbox(app, entry(), { ethId, kv });
  await addToOutbox(app, entry({ hash: `0x${'22'.repeat(32)}`, createdAt: 2000 }), { ethId, kv });
  let list = await loadOutbox(app, { ethId, kv });
  assert.deepEqual(list.map((e) => e.hash.slice(0, 4)), ['0x22', '0x11']);
  const u = await updateOutbox(app, `0x${'11'.repeat(32)}`, { state: 'pending', sentAt: 5, raw: '0x02ff', nonce: '9' }, { ethId, kv });
  assert.equal(u.state, 'pending');
  assert.equal(u.raw, '0x02f8aa');
  assert.equal(u.nonce, '0');
  await assert.rejects(updateOutbox(app, `0x${'11'.repeat(32)}`, { state: 'lost' }, { ethId, kv }));
  assert.equal(await updateOutbox(app, `0x${'33'.repeat(32)}`, { state: 'pending' }, { ethId, kv }), null);
  await assert.rejects(addToOutbox(app, { ...entry(), hash: 'nope' }, { ethId, kv }));
  for (const bad of [null, {}, entry({ raw: '0x01aa' }), entry({ amount: '-1' }), entry({ to: 'bob' }), entry({ state: 'done' })]) assert.equal(validEntry(bad), false);
  // Two quick updates do not lose each other.
  await Promise.all([updateOutbox(app, `0x${'11'.repeat(32)}`, { error: 'x' }, { ethId, kv }), updateOutbox(app, `0x${'22'.repeat(32)}`, { state: 'pending' }, { ethId, kv })]);
  list = await loadOutbox(app, { ethId, kv });
  assert.equal(list.find((e) => e.hash.startsWith('0x11')).error, 'x');
  assert.equal(list.find((e) => e.hash.startsWith('0x22')).state, 'pending');
  assert.ok(!JSON.stringify([...kv.m.values()]).toLowerCase().includes(F.ALICE.slice(2)), 'nothing readable in storage');
  await clearOutbox(kv);
  assert.equal(kv.m.has(ETH_OUTBOX_KEY), false);
});

test('outbox: trimming keeps every open transaction and the newest closed ones', () => {
  const list = [];
  for (let i = 0; i < OUTBOX_MAX + 20; i++) list.push(entry({ hash: `0x${i.toString(16).padStart(64, '0')}`, state: i % 30 === 29 ? 'pending' : 'confirmed', createdAt: 10000 - i }));
  const t = trimOutbox(list);
  assert.equal(t.length, OUTBOX_MAX);
  assert.equal(t.filter((e) => e.state === 'pending').length, list.filter((e) => e.state === 'pending').length);
  assert.equal(t[0].hash, list[0].hash);
});

// ---------------------------------------------------------------- history

test('history index: transactions parsed exactly, junk dropped, fee from gasUsed x effectiveGasPrice', () => {
  const txs = parseTransactions(F.txs(), ME);
  assert.deepEqual(txs.map((t) => t.hash), [F.h(1), F.h(2), F.h(3), F.h(4)]);
  assert.equal(txs[0].value, ETHER);
  assert.equal(txs[0].from, F.ALICE);
  assert.equal(txs[1].fee, 21000n * 12345678901n, 'not the gasCost number');
  assert.equal(txs[2].contractCall, true);
  assert.equal(txs[3].failed, true);
  assert.throws(() => parseTransactions({ message: 'nope' }, ME), HistoryError);
});

test('history index: only Transfer events of the token itself, naming this address', () => {
  const xs = parseTokenTransfers(F.wbeamLogs(), ME, WBEAM);
  assert.deepEqual(xs.map((x) => [x.hash, x.from, x.to, x.amount]), [
    [F.h(3), F.ME, F.BOB, 1250000000n],
    [F.h(7), F.ALICE, F.ME, 10000000000n],
  ]);
});

test('activity: one row per movement, token transfers instead of their 0-ETH call, what this device sent wins, open ones first', () => {
  const txs = parseTransactions(F.txs(), ME);
  const transfers = parseTokenTransfers(F.wbeamLogs(), ME, WBEAM);
  const sentHere = entry({ hash: F.h(2), state: 'confirmed', amount: '250000000000000000', to: toChecksumAddress(F.BOB), receipt: { blockNumber: 200, status: 1, gasUsed: '21000', effectiveGasPrice: '12345678901' } });
  const open = entry({ hash: `0x${'aa'.repeat(32)}`, state: 'pending', createdAt: 1 });
  const items = mergeActivity({ address: ME, outbox: [sentHere, open], txs, transfers });
  assert.equal(items[0].hash, open.hash, 'open first');
  assert.equal(items[0].state, 'pending');
  const rows = items.map((i) => [i.hash, i.asset.symbol, i.direction, i.amount, i.state]);
  assert.deepEqual(rows.slice(1), [
    [F.h(7), 'WBEAM', 'in', 10000000000n, 'confirmed'],
    [F.h(4), 'ETH', 'out', 5n, 'failed'],
    [F.h(3), 'WBEAM', 'out', 1250000000n, 'confirmed'],
    [F.h(2), 'ETH', 'out', 250000000000000000n, 'confirmed'],
    [F.h(1), 'ETH', 'in', ETHER, 'confirmed'],
  ]);
  assert.equal(items.find((i) => i.hash === F.h(3)).fee, 51000n * 2000000000n, "the token transfer carries its call's fee");
  assert.equal(items.find((i) => i.hash === F.h(2)).local, true);
  assert.equal(items.find((i) => i.hash === F.h(1)).fee, null, 'nothing paid on what came in');
});

test('history fetch: Stack Wallet only, no credentials, pages by firstBlock, an empty body is an empty history', async () => {
  const seen = [];
  // Page 2 starts at the last block of page 1, so that block's transaction comes again.
  const page = (from, n) => ({ data: Array.from({ length: n }, (_, i) => ({ hash: F.h(from + i), from: F.ALICE, to: F.ME, value: '1', blockNumber: from + i, timestamp: 1 })) });
  const fetch = async (url, init) => {
    seen.push({ url, init });
    const u = new URL(url);
    let body;
    if (u.searchParams.get('emitter')) body = u.searchParams.get('emitter') === F.WBEAM_ADDR ? JSON.stringify(F.wbeamLogs()) : '';
    else body = JSON.stringify(Number(u.searchParams.get('firstBlock')) === 0 ? page(1, PAGE) : page(PAGE, 3));
    return { ok: true, status: 200, text: async () => body };
  };
  const { txs, transfers } = await fetchHistory(ME, { fetch });
  assert.equal(txs.length, PAGE + 2, 'the overlapping block is not counted twice');
  assert.equal(transfers.length, 2);
  for (const s of seen) {
    assert.match(s.url, /^https:\/\/eth2\.stackwallet\.com\/export\?addrs=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266&/);
    assert.equal(s.init.credentials, 'omit');
    assert.equal(s.init.referrerPolicy, 'no-referrer');
    assert.equal(s.init.redirect, 'error');
  }
  assert.equal(seen.filter((s) => s.url.includes('emitter=')).length, TOKENS.length);
  await assert.rejects(fetchHistory(ME, { fetch: async () => ({ ok: false, status: 502, text: async () => '' }) }), (e) => e instanceof HistoryError && e.code === 'http');
  await assert.rejects(fetchHistory(ME, { fetch: async () => { throw new TypeError('x'); } }), (e) => e.code === 'network');
});

// ---------------------------------------------------------------- recipients

test('recipients: format, checksum, own, zero, the bridge pipes and token contracts are refused in words', () => {
  assert.equal(recipientProblem(ALICE, { own: ME }), null);
  assert.equal(recipientProblem(F.ALICE, { own: ME }), null, 'all lowercase carries no checksum and is fine');
  assert.equal(recipientProblem('').code, 'empty');
  assert.equal(recipientProblem('0x123').code, 'format');
  assert.equal(recipientProblem(F.ALICE.slice(2)).code, 'format');
  assert.match(recipientProblem(F.ALICE.slice(2)).message, /starts with 0x/);
  const typo = ALICE.slice(0, -1) + (ALICE.at(-1) === 'C' ? 'c' : 'C');
  assert.equal(recipientProblem(typo === ALICE ? ALICE.replace('9', 'a') : typo).code, 'checksum');
  assert.equal(recipientProblem(ME.toLowerCase(), { own: ME }).code, 'own');
  assert.equal(recipientProblem('0x0000000000000000000000000000000000000000').code, 'zero');
  assert.equal(BRIDGE_PIPES.length, ROUTES.length);
  for (const r of ROUTES) assert.equal(recipientProblem(r.ethPipe).code, 'bridge', r.id);
  for (const t of TOKENS) assert.equal(recipientProblem(toChecksumAddress(t.address)).code, 'token', t.symbol);
  assert.match(recipientProblem(WBEAM.address).message, /WBEAM token's own contract/);
});

test('transfer calls: ETH goes to the person; a token goes to its contract as transfer(to, amount)', () => {
  assert.deepEqual(transferCall(ETH, F.ALICE, 5n), { to: ALICE, value: 5n, data: '0x' });
  const t = transferCall(WBEAM, F.ALICE, 7n);
  assert.equal(t.to, toChecksumAddress(WBEAM.address));
  assert.equal(t.value, 0n);
  assert.deepEqual(decodeCall('transfer(address,uint256)', t.data), [ALICE, 7n]);
  assert.throws(() => transferCall({ symbol: 'FAKE', address: F.BOB, decimals: 18 }, F.ALICE, 1n), SendError);
});

// ---------------------------------------------------------------- a fake chain

const word = (n) => `0x${BigInt(n).toString(16).padStart(64, '0')}`;
const q = (n) => `0x${BigInt(n).toString(16)}`;

/** A signed transaction as a server's JSON shows it (eth_getTransactionByHash, a full block). */
function txJson(raw, blockNumber = null) {
  const p = parseSignedTransaction(raw);
  const t = p.tx;
  return {
    type: '0x2',
    chainId: q(t.chainId),
    nonce: q(t.nonce),
    maxPriorityFeePerGas: q(t.maxPriorityFeePerGas),
    maxFeePerGas: q(t.maxFeePerGas),
    gas: q(t.gasLimit),
    to: t.to.toLowerCase(),
    value: q(t.value),
    input: t.data,
    accessList: [],
    v: q(p.yParity),
    yParity: q(p.yParity),
    r: q(p.r),
    s: q(p.s),
    hash: p.hash,
    from: p.from.toLowerCase(),
    blockHash: blockNumber === null ? null : F.h(0xb000 + blockNumber),
    blockNumber: blockNumber === null ? null : q(blockNumber),
  };
}

/**
 * A tiny chain behind EthRpc's own fetch: one account, a pool, receipts on demand, blocks from
 * 100 on with the transactions mined in them, and the account's count at each block. st.latest
 * is what 'latest' answers (a test sets it to lie); st.lieAll makes every block's count lie too;
 * st.noOldState refuses counts at past blocks, as a server without old state does; st.relayOnRefuse
 * keeps refused bytes (a server that passed them on and then said no).
 */
function fakeChain({ eth = ETHER, nonce = 0n, transferReturns = word(1), estimate = null, codeAt = {}, onSend = null } = {}) {
  const st = { eth, latest: nonce, pending: nonce, pool: new Map(), mined: new Map(), byHash: new Map(), blocks: new Map(), own: [], head: 100, sends: [], calls: [], down: false, refuse: null, relayed: new Map(), relayOnRefuse: false, lieAll: false, noOldState: false };
  const countAt = (n) => {
    if (st.lieAll) return st.latest;
    if (st.noOldState && n < st.head) throw Object.assign(new Error('missing trie node'), { code: -32000 });
    return nonce + BigInt(st.own.filter((b) => b <= n).length);
  };
  const handle = async (method, params) => {
    st.calls.push(method);
    switch (method) {
      case 'eth_chainId':
        return '0x1';
      case 'eth_blockNumber':
        return q(st.head);
      case 'eth_getBlockByNumber': {
        const n = Number(BigInt(params[0]));
        if (n > st.head) return null;
        return { number: q(n), hash: F.h(0xb000 + n), transactions: st.blocks.get(n) || [] };
      }
      case 'eth_feeHistory':
        // base fee 10 gwei (next block), tips 1..5 gwei -> median 3
        return { oldestBlock: '0x60', baseFeePerGas: Array(6).fill(q(10n * GWEI)), reward: [1, 2, 3, 4, 5].map((g) => [q(BigInt(g) * GWEI)]) };
      case 'eth_estimateGas': {
        if (estimate instanceof Error) throw estimate;
        if (estimate != null) return q(estimate);
        return params[0].data && params[0].data !== '0x' ? q(51000) : q(21000);
      }
      case 'eth_getCode':
        return codeAt[params[0]] || '0x';
      case 'eth_call':
        if (transferReturns instanceof Error) throw transferReturns;
        return transferReturns;
      case 'eth_getBalance':
        return q(st.eth);
      case 'eth_getTransactionCount':
        if (params[1] === 'pending') return q(st.pending);
        if (params[1] === 'latest') return q(st.latest);
        return q(countAt(Number(BigInt(params[1]))));
      case 'eth_sendRawTransaction': {
        if (onSend) await onSend(params[0]);
        if (st.refuse) {
          if (st.relayOnRefuse) st.relayed.set(transactionHash(params[0]), params[0]);
          throw st.refuse;
        }
        const hash = transactionHash(params[0]);
        st.sends.push(params[0]);
        st.pool.set(hash, params[0]);
        st.pending += 1n;
        return hash;
      }
      case 'eth_getTransactionReceipt':
        return st.mined.get(params[0]) || null;
      case 'eth_getTransactionByHash': {
        const h = params[0];
        if (st.byHash.has(h)) return st.byHash.get(h);
        if (st.mined.has(h)) return { hash: h, blockHash: F.h(0xbb) };
        if (st.pool.has(h)) return { hash: h, blockHash: null };
        return null;
      }
      default:
        throw Object.assign(new Error(`unexpected ${method}`), { code: -32601 });
    }
  };
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (st.down === true || (st.down && body.method === st.down)) throw new TypeError('Failed to fetch');
    const one = async (r) => {
      try {
        return { jsonrpc: '2.0', id: r.id, result: await handle(r.method, r.params) };
      } catch (e) {
        return { jsonrpc: '2.0', id: r.id, error: { code: e.code ?? -32000, message: e.message } };
      }
    };
    const out = Array.isArray(body) ? await Promise.all(body.map(one)) : await one(body);
    return { status: 200, text: async () => JSON.stringify(out) };
  };
  const receiptOf = (hash, n, status) => ({ transactionHash: hash, status: q(status), blockNumber: q(n), blockHash: F.h(0xb000 + n), from: ME.toLowerCase(), to: F.ALICE, gasUsed: q(21000), effectiveGasPrice: q(13n * GWEI), logs: [] });
  const mine = (hash, status = 1) => {
    const raw = st.pool.get(hash) || st.relayed.get(hash);
    st.pool.delete(hash);
    st.relayed.delete(hash);
    st.latest += 1n;
    const n = ++st.head;
    st.own.push(n);
    if (raw) st.blocks.set(n, [txJson(raw, n)]);
    st.mined.set(hash, receiptOf(hash, n, status));
  };
  /** Mines signed bytes this server never had in its pool (sent elsewhere); `json` as the block shows it. */
  const mineRaw = (raw, { json = txJson(raw, st.head + 1), receipt = true } = {}) => {
    const n = ++st.head;
    st.latest += 1n;
    st.own.push(n);
    st.blocks.set(n, [json]);
    st.byHash.set(json.hash, json);
    if (receipt) st.mined.set(json.hash, receiptOf(json.hash, n, 1));
    return n;
  };
  return { st, rpc: new EthRpc('stackwallet', { fetch }), mine, mineRaw };
}

// ---------------------------------------------------------------- prepare

test('prepare ETH: 21,000 gas for a plain account; "likely" and "up to" fees; refuses what the fee leaves no room for', async () => {
  const { rpc } = fakeChain();
  const balances = { eth: ETHER };
  const p = await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 10n ** 16n, balances });
  assert.equal(p.tx.gasLimit, ETH_TRANSFER_GAS);
  assert.equal(p.tx.maxPriorityFeePerGas, 3n * GWEI, 'the median tip');
  assert.equal(p.tx.maxFeePerGas, 23n * GWEI, '2 x base + tip');
  assert.equal(p.fees.upTo, 21000n * 23n * GWEI);
  assert.equal(p.fees.likely, 21000n * 13n * GWEI);
  assert.equal(p.recipient, ALICE);
  assert.equal(p.tx.to, ALICE);
  assert.equal(p.tx.value, 10n ** 16n);
  const max = maxSendable(ETH, balances, p.fees.upTo);
  assert.equal(max, ETHER - p.fees.upTo);
  await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: max, balances });
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: max + 1n, balances }), (e) => e.code === 'not_enough' && /You can send up to/.test(e.message));
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: ME, amount: 1n, balances }), (e) => e.code === 'recipient');
  await assert.rejects(prepareSend(rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 0n, balances }), (e) => e.code === 'not_enough');
});

test('prepare ETH to a contract: the estimate with headroom; a refusing contract is said plainly', async () => {
  const { rpc } = fakeChain({ estimate: 30000n, codeAt: { [F.BOB]: '0x6080' } });
  const p = await prepareSend(rpc, { from: ME, asset: ETH, recipient: F.BOB, amount: 1n, balances: { eth: ETHER } });
  assert.equal(p.tx.gasLimit, 50000n, '+20,000 at least');
  const refusing = fakeChain({ estimate: Object.assign(new Error('execution reverted: no thanks'), { code: 3 }), codeAt: { [F.BOB]: '0x6080' } });
  await assert.rejects(prepareSend(refusing.rpc, { from: ME, asset: ETH, recipient: F.BOB, amount: 1n, balances: { eth: ETHER } }), (e) => e.code === 'would_fail' && /no thanks/.test(e.message));
  const plain = fakeChain({ estimate: Object.assign(new Error('some node quirk'), { code: -32000 }) });
  assert.equal((await prepareSend(plain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } })).tx.gasLimit, 21000n, 'an account without code cannot refuse ETH');
});

test('prepare a token: transfer() to the token, simulated first; the fee must be there in ETH', async () => {
  const { rpc } = fakeChain();
  const balances = { eth: ETHER, WBEAM: 5n * 10n ** 8n };
  const p = await prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 10n ** 8n, balances });
  assert.equal(p.tx.to, toChecksumAddress(WBEAM.address));
  assert.equal(p.tx.value, 0n);
  assert.deepEqual(decodeCall('transfer(address,uint256)', p.tx.data), [ALICE, 10n ** 8n]);
  assert.equal(p.tx.gasLimit, 71000n, '51,000 + 20,000');
  assert.equal(maxSendable(WBEAM, balances, p.fees.upTo), 5n * 10n ** 8n);
  await assert.rejects(prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 6n * 10n ** 8n, balances }), (e) => e.code === 'not_enough');
  await assert.rejects(prepareSend(rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances: { eth: 1000n, WBEAM: 10n } }), (e) => e.code === 'no_gas' && /paid in ETH/.test(e.message));
  const no = fakeChain({ transferReturns: word(0) });
  await assert.rejects(prepareSend(no.rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances }), (e) => e.code === 'would_fail');
  const usdt = fakeChain({ transferReturns: '0x' });
  const usdtToken = tokenBySymbol('USDT');
  await prepareSend(usdt.rpc, { from: ME, asset: usdtToken, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER, USDT: 1n } }); // returns nothing, like USDT
  const reverts = fakeChain({ transferReturns: Object.assign(new Error('execution reverted: blacklisted'), { code: 3 }) });
  await assert.rejects(prepareSend(reverts.rpc, { from: ME, asset: WBEAM, recipient: F.ALICE, amount: 1n, balances }), (e) => e.code === 'would_fail' && /blacklisted/.test(e.message));
});

test('a fresh preparation that costs more than the reviewed one is noticed', () => {
  const a = { fees: { upTo: 100n }, tx: { gasLimit: 21000n, to: ALICE, value: 1n } };
  assert.equal(costRose(a, a), false);
  assert.equal(costRose(a, { ...a, fees: { upTo: 101n } }), true);
  assert.equal(costRose(a, { ...a, fees: { upTo: 99n } }), false);
  assert.equal(costRose(a, { ...a, tx: { ...a.tx, value: 2n } }), true);
});

// ---------------------------------------------------------------- sign, save, send, follow

test('send: signed with a fresh nonce, saved BEFORE it is broadcast, then pending; the key opens only with the wallet unlocked', async () => {
  const { app, kv, ethId } = await walletWithKey();
  let savedBeforeSend = null;
  const chain = fakeChain({
    nonce: 4n,
    onSend: async (raw) => {
      const list = await loadOutbox(app, { ethId, kv });
      savedBeforeSend = list.find((e) => e.raw === raw) || null;
    },
  });
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 10n ** 16n, balances: { eth: ETHER } });
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => 42 });
  assert.equal(r.sent, true);
  assert.ok(savedBeforeSend, 'the outbox held the bytes when they were broadcast');
  assert.equal(savedBeforeSend.state, 'signed');
  assert.equal(r.entry.state, 'pending');
  const parsed = parseSignedTransaction(r.entry.raw);
  assert.equal(parsed.from, ME);
  assert.equal(parsed.tx.nonce, 4n);
  assert.equal(parsed.tx.chainId, 1n);
  assert.equal(parsed.tx.to, ALICE);
  assert.equal(parsed.tx.value, 10n ** 16n);
  assert.equal(parsed.tx.gasLimit, p.tx.gasLimit);
  assert.equal(parsed.tx.maxFeePerGas, p.tx.maxFeePerGas, 'exactly what was reviewed');
  assert.equal(r.entry.hash, parsed.hash);
  assert.equal(chain.st.calls.filter((m) => m === 'eth_chainId').length, 1, 'chain id checked right before signing');
  // Followed: pending, then mined.
  assert.equal((await followOnce(app, chain.rpc, r.entry, { ethId, kv })).state, 'pending');
  chain.mine(r.entry.hash);
  const done = await followOnce(app, chain.rpc, r.entry, { ethId, kv });
  assert.equal(done.state, 'confirmed');
  assert.equal(entryFee(done).wei, 21000n * 13n * GWEI);
  assert.equal(entryFee(done).final, true);
  await assert.rejects(signAndSend({ ...app, dbPass: null }, chain.rpc, p, { ethId, kv }), (e) => e.code === 'locked');
});

test('send: a network error leaves it signed; following sends the identical bytes again, never re-signed', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.down = 'eth_sendRawTransaction';
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv });
  assert.equal(r.sent, false);
  assert.equal(r.entry.state, 'signed');
  assert.equal(r.error.code, 'network');
  chain.st.down = null;
  const again = await followOnce(app, chain.rpc, r.entry, { ethId, kv });
  assert.equal(again.state, 'pending');
  assert.deepEqual(chain.st.sends, [r.entry.raw], 'the saved bytes, once they could go');
  assert.equal((await loadOutbox(app, { ethId, kv })).length, 1);
});

test('send (D-3): bytes the server refuses stay open and checked; "never sent" only after 30 minutes of refusals', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.refuse = Object.assign(new Error('insufficient funds for gas * price + value'), { code: -32000 });
  let now = 1000;
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => now });
  assert.equal(r.sent, false);
  assert.equal(r.entry.state, 'signed', 'not "Nothing was spent": the server may have passed it on');
  assert.equal(r.entry.refusedAt, 1000);
  assert.match(r.entry.error, /insufficient funds/);
  assert.equal((await loadOutbox(app, { ethId, kv }))[0].refusedAt, 1000, 'kept with the entry');
  // Followed: its hash asked, its bytes offered again, still refused: still open.
  now += REFUSAL_WATCH_MS - 1;
  let e = await followOnce(app, chain.rpc, r.entry, { ethId, kv, now: () => now });
  assert.equal(e.state, 'signed');
  assert.equal(e.refusedAt, 1000, 'since the first refusal');
  assert.ok(chain.st.calls.includes('eth_getTransactionByHash'));
  assert.equal(chain.st.calls.filter((m) => m === 'eth_sendRawTransaction').length, 2, 'the same bytes, again');
  // Half an hour of refusals with the hash unknown and the nonce free: never sent.
  now += 1;
  e = await followOnce(app, chain.rpc, e, { ethId, kv, now: () => now });
  assert.equal(e.state, 'rejected');
  assert.equal((await followOnce(app, chain.rpc, e, { ethId, kv })).state, 'rejected', 'not followed any more');
});

test('send (D-3): a server that refused the bytes but had passed them on: the payment is followed to its receipt', async () => {
  const { app, kv, ethId } = await walletWithKey();
  const chain = fakeChain();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  chain.st.refuse = Object.assign(new Error('transaction underpriced'), { code: -32000 });
  chain.st.relayOnRefuse = true;
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv, now: () => 5 });
  assert.equal(r.entry.state, 'signed');
  // Another node mined it.
  chain.mine(r.entry.hash);
  const e = await followOnce(app, chain.rpc, r.entry, { ethId, kv, now: () => 5 + REFUSAL_WATCH_MS * 2 });
  assert.equal(e.state, 'confirmed', 'mined, whatever the server said when it was sent');
  assert.equal(e.refusedAt, null);
  // And a server that takes the bytes on a later try clears the doubt.
  const { app: app2, kv: kv2, ethId: id2 } = await walletWithKey();
  const c2 = fakeChain();
  const p2 = await prepareSend(c2.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 2n, balances: { eth: ETHER } });
  c2.st.refuse = Object.assign(new Error('txpool is full'), { code: -32000 });
  const r2 = await signAndSend(app2, c2.rpc, p2, { ethId: id2, kv: kv2 });
  c2.st.refuse = null;
  const e2 = await followOnce(app2, c2.rpc, r2.entry, { ethId: id2, kv: kv2 });
  assert.equal(e2.state, 'pending');
  assert.equal(e2.refusedAt, null);
});

test('follow: a used-up nonce alone is "unsure", never "replaced"; mined, or in a block, wins', () => {
  assert.equal(classify({ receipt: { status: 1 }, minedNonce: 9n, nonce: '0', known: true }), 'confirmed');
  assert.equal(classify({ receipt: { status: 0 }, minedNonce: 9n, nonce: '0', known: true }), 'failed');
  assert.equal(classify({ receipt: null, minedNonce: 1n, nonce: '0', known: false }), 'unsure');
  assert.equal(classify({ receipt: null, minedNonce: 8n, nonce: '7', known: false }), 'unsure', 'the audit\'s PoC: a mined payment seen through a lagging backend');
  assert.equal(classify({ receipt: null, minedNonce: 1n, nonce: '0', known: true, inBlock: true }), 'pending', 'mined, the receipt is on its way');
  assert.equal(classify({ receipt: null, minedNonce: 0n, nonce: '0', known: false }), 'unknown');
  assert.equal(classify({ receipt: null, minedNonce: 0n, nonce: '0', known: true }), 'pending');
});

// followOnce looks into a used-up nonce at most once a minute per transaction, and the test key
// signs the same bytes in every test: one clock for all of them, moved past that minute each time.
let clock = 10 ** 9;
const later = () => (clock += NONCE_LOOK_MS);

/** A wallet with one 1-wei payment sent and waiting on `chain`. */
async function sentOne(chain = fakeChain()) {
  const { app, kv, ethId } = await walletWithKey();
  const p = await prepareSend(chain.rpc, { from: ME, asset: ETH, recipient: F.ALICE, amount: 1n, balances: { eth: ETHER } });
  const r = await signAndSend(app, chain.rpc, p, { ethId, kv });
  assert.equal(r.entry.state, 'pending');
  return { app, kv, ethId, chain, entry: r.entry, p };
}

/** Another transaction from this wallet with `entry`'s nonce (what another device with the same words would send). */
async function sameNonce(entry, { chainId = 1n, to = F.BOB, words = JUNK } = {}) {
  const { sk } = await ethKeyFromMnemonic(words);
  if (chainId === 1n) return signTransaction({ chainId, nonce: BigInt(entry.nonce), to: toChecksumAddress(to), value: 5n, gasLimit: 21000n, maxFeePerGas: 40n * GWEI, maxPriorityFeePerGas: 2n * GWEI }, sk);
  // This wallet signs for Ethereum only: another chain's transaction is built here by hand.
  const { rlpEncode } = await import('../../src/lib/eth/rlp.js');
  const { signDigest, keccak256 } = await import('../../src/lib/eth/crypto.js');
  const { hexToBytes, concatBytes } = await import('../../src/lib/eth/hex.js');
  const fields = [chainId, BigInt(entry.nonce), 2n * GWEI, 40n * GWEI, 21000n, hexToBytes(to), 5n, new Uint8Array(0), []];
  const sig = signDigest(keccak256(concatBytes(Uint8Array.of(2), rlpEncode(fields))), sk);
  const raw = bytesToHex(concatBytes(Uint8Array.of(2), rlpEncode([...fields, sig.yParity, sig.r, sig.s])));
  return { raw, hash: transactionHash(raw) };
}

test('follow (D-3): one server saying the nonce is used up cannot turn a waiting payment into "replaced"', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  // The PoC: the server still holds the payment, waiting, but says the account's nonce moved on.
  chain.st.latest = 1n;
  let now = later();
  const first = now;
  const look = () => followOnce(app, chain.rpc, entry, { ethId, kv, now: () => now });
  let e = await look();
  assert.equal(e.state, 'pending', 'still open: it may yet be mined');
  assert.equal(e.unsureSince, first, 'the screens are told not to send it again yet');
  assert.deepEqual(chain.st.sends, [entry.raw, entry.raw], 'the same bytes offered again, never re-signed');
  assert.equal((await loadOutbox(app, { ethId, kv }))[0].unsureSince, first, 'kept with the entry');
  // A server that lies about every block too, and forgets the payment: still no evidence, still not replaced.
  chain.st.lieAll = true;
  chain.st.pool.delete(entry.hash);
  const counts = () => chain.st.calls.filter((m) => m === 'eth_getTransactionCount').length;
  now += 1000;
  const before = counts();
  e = await look();
  assert.equal(e.state, 'pending');
  assert.equal(counts() - before, 1, 'looked into a moment ago: only the nonce is asked, no search');
  for (let i = 0; i < 5; i++) {
    now += NONCE_LOOK_MS;
    e = await look();
    assert.equal(e.state, 'pending', `look ${i}: never replaced on the server's word`);
    assert.equal(e.unsureSince, first, 'since the first time');
  }
  clock = now;
  // The payment was in fact still out there: it is mined, and that is what counts.
  chain.st.lieAll = false;
  chain.st.latest = 0n;
  chain.st.pool.set(entry.hash, entry.raw);
  chain.mine(entry.hash);
  e = await look();
  assert.equal(e.state, 'confirmed');
  assert.equal(e.unsureSince, null, 'no longer in doubt');
});

test('follow (D-3): "replaced" only once the server shows the transaction that took the nonce, signed by this wallet, with a receipt', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  const other = await sameNonce(entry);
  chain.st.pool.delete(entry.hash);
  const block = chain.mineRaw(other.raw);
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
  assert.equal(e.state, 'replaced');
  assert.equal(e.replacedBy, other.hash);
  assert.equal(e.replacedIn, block);
  assert.equal(e.unsureSince, null);
  assert.ok(chain.st.calls.includes('eth_getBlockByNumber'), 'found in the block where the count passed the nonce');
});

test('follow (D-3): made-up, altered, foreign-chain or unmined "replacements" are not evidence', async () => {
  const STRANGER = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
  const cases = {
    'signed by another key, labelled as this wallet': async (entry) => ({ ...txJson((await sameNonce(entry, { words: STRANGER })).raw), from: ME.toLowerCase() }),
    'a real one of ours with its amount changed': async (entry) => ({ ...txJson((await sameNonce(entry)).raw), value: q(10n ** 18n) }),
    'ours, but signed for another chain': async (entry) => txJson((await sameNonce(entry, { chainId: 56n })).raw),
  };
  for (const [name, make] of Object.entries(cases)) {
    const { app, kv, ethId, chain, entry } = await sentOne();
    chain.st.pool.delete(entry.hash);
    const json = await make(entry);
    chain.mineRaw(null, { json: { ...json, blockHash: F.h(0xb065), blockNumber: q(chain.st.head + 1) } });
    const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
    assert.equal(e.state, 'pending', name);
    assert.ok(e.unsureSince, name);
  }
  // Genuinely ours and in the block, but the server serves no receipt for it: not yet evidence.
  const { app, kv, ethId, chain, entry } = await sentOne();
  chain.st.pool.delete(entry.hash);
  chain.mineRaw((await sameNonce(entry)).raw, { receipt: false });
  assert.equal((await followOnce(app, chain.rpc, entry, { ethId, kv, now: later })).state, 'pending');
});

test('follow (D-3): our own payment found in the block (its receipt not served yet) is waiting, not replaced', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  // A server whose receipt lags its blocks: the count moved, the block holds our bytes, no receipt yet.
  const json = txJson(entry.raw, chain.st.head + 1);
  chain.st.pool.delete(entry.hash);
  chain.mineRaw(entry.raw, { json, receipt: false });
  chain.st.byHash.delete(entry.hash); // and it says it does not know the hash
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, now: later });
  assert.equal(e.state, 'pending');
  assert.ok(!e.unsureSince);
});

test('follow (D-3): a hash the wallet already knows proves it where the server keeps no old state', async () => {
  const { app, kv, ethId, chain, entry } = await sentOne();
  const other = await sameNonce(entry);
  chain.st.pool.delete(entry.hash);
  chain.mineRaw(other.raw);
  chain.st.head += 500; // long ago
  chain.st.noOldState = true;
  assert.equal(await findNonceTaker(chain.rpc, entry).catch((err) => err.code), -32000, 'the block search needs old state');
  assert.equal((await followOnce(app, chain.rpc, entry, { ethId, kv, now: later })).state, 'pending');
  const e = await followOnce(app, chain.rpc, entry, { ethId, kv, candidates: [F.h(0xdead), other.hash], now: later });
  assert.equal(e.state, 'replaced');
  assert.equal(e.replacedBy, other.hash);
  // The wallet offers its outbox's same-nonce entries and the history index's as candidates.
  const w = await ethWallet(app, { kv });
  w.state.history = { txs: [{ hash: other.hash, from: ME.toLowerCase(), nonce: Number(entry.nonce) }, { hash: F.h(7), from: ME.toLowerCase(), nonce: 99 }], transfers: [], error: null, at: 1 };
  assert.deepEqual(w.nonceTwins(entry), [other.hash]);
  w.state.history = { txs: [], transfers: [], error: null, at: null };
  forgetEthWallet();
});

// ---------------------------------------------------------------- the wallet object

test('wallet: the address comes from the sealed key; prefs default to Stack Wallet and history on; removal forgets everything', async () => {
  const { app, kv, ethId } = await walletWithKey();
  assert.deepEqual(ethPrefs(app).rpcId, 'stackwallet');
  assert.equal(ethPrefs(app).history, true);
  assert.equal(ethPrefs({ prefs: { ethRpc: 'publicnode', ethHistory: false } }).rpcId, 'publicnode');
  assert.equal(ethPrefs({ prefs: { ethRpc: 'evil.example' } }).rpcId, 'stackwallet', 'only listed servers');
  assert.equal(ethPrefs({ prefs: { ethHistory: false } }).history, false);
  const w = await ethWallet(app, { kv });
  assert.equal(w.state.address, ME);
  assert.equal(w.ethId, ethId);
  assert.equal(await ethWallet(app, { kv }), w, 'one object per unlocked wallet');
  await addToOutbox(app, entry(), { ethId, kv });
  assert.equal(await hasEthWallet(kv), true);
  await removeEthWallet(kv);
  assert.equal(await hasEthWallet(kv), false);
  assert.equal(kv.m.has(ETH_OUTBOX_KEY), false);
  assert.equal(kv.m.has(ETH_RECORD_KEY), false);
  assert.equal(await ethWallet(app, { kv }), null);
  await assert.rejects(ethWallet({ ...app, dbPass: null }, { kv }), (e) => e.code === 'locked');
  forgetEthWallet();
});
