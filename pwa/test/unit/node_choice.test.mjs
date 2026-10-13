// "Use this one" on the BEAM node screen: which pool node a wallet starts on and moves to, how the
// choice is kept in prefs, that the wallet still moves on by itself from a picked node, and that a
// check or a pick can reach no host beyond BEAM's pool (the CSP's connect-src does not change).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// The browser's WebSocket as engine.js finds it at load: a stand-in that only records what was asked.
const made = [];
globalThis.WebSocket = class FakeSocket {
  constructor(url) {
    this.url = url;
    made.push(url);
  }
  addEventListener() {}
  close() {}
};

const { NODES, POOL, RANDOM_NODE, poolOrder, walletNode, nodeName, isPoolNode } = await import('../../src/lib/nodes.js');
const { getPrefs, setPrefs, DEFAULT_PREFS } = await import('../../src/lib/store.js');
const { openPoolSocket, nodeGuard } = await import('../../src/lib/engine.js');
const { wallet } = await import('../../src/lib/wallet.js');
const { CSP, securityHeaders, SECURITY_HEADERS, NODES: HEADER_NODES } = await import('../../tools/headers.mjs');

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const N02 = 'eu-node02.mainnet.beam.mw:8200';
const N03 = 'eu-node03.mainnet.beam.mw:8200';
const N01 = 'eu-node01.mainnet.beam.mw:8200';
const NS = 'eu-nodes.mainnet.beam.mw:8200';
const FULL = [N02, N03, 'eu-node04.mainnet.beam.mw:8200'];

/** An in-memory stand-in for the app store's get/set. */
function kvWith(prefs) {
  const m = new Map(prefs === undefined ? [] : [['prefs', prefs]]);
  return { get: async (k) => m.get(k), set: async (k, v) => void m.set(k, v), raw: m };
}

test('prefs: poolNode is null by default; a pool node is kept; anything else reads as no pick (a random start)', async () => {
  assert.equal(DEFAULT_PREFS.poolNode, null);
  assert.equal(DEFAULT_PREFS.node, RANDOM_NODE);
  assert.equal((await getPrefs(kvWith())).poolNode, null, 'a fresh install');
  assert.equal((await getPrefs(kvWith({ node: 'random' }))).poolNode, null, 'prefs written before the key existed');
  assert.equal((await getPrefs(kvWith({ node: 'random', poolNode: N03 }))).poolNode, N03);
  for (const odd of ['evil.example:8200', 'eu-node03.mainnet.beam.mw:8100', 'us-node01.mainnet.beam.mw:8200', 'EU-NODE03.mainnet.beam.mw:8200', 'random', '', 42, {}, ['x'], true]) {
    const p = await getPrefs(kvWith({ node: 'random', poolNode: odd }));
    assert.equal(p.poolNode, null, `poolNode ${JSON.stringify(odd)}`);
    assert.equal(walletNode(p), RANDOM_NODE);
  }
  // The single node an early version kept in prefs.node is the pool now, and not a pick.
  const early = await getPrefs(kvWith({ node: N01 }));
  assert.equal(early.node, RANDOM_NODE);
  assert.equal(early.poolNode, null);
  // Saving keeps it beside the rest; an own node keeps its own value.
  const kv = kvWith({ node: 'random', autoLockMin: 15 });
  await setPrefs({ poolNode: N02 }, kv);
  assert.deepEqual(kv.raw.get('prefs'), { ...DEFAULT_PREFS, node: 'random', autoLockMin: 15, poolNode: N02 });
});

test('the node a wallet starts with: own node > picked pool node > random', () => {
  assert.equal(walletNode({ node: RANDOM_NODE, poolNode: null }), RANDOM_NODE);
  assert.equal(walletNode({ node: RANDOM_NODE, poolNode: N03 }), N03);
  assert.equal(walletNode({ node: 'node.example.com:8200', poolNode: N03 }), 'node.example.com:8200', 'an own node wins: nothing else is ever dialled');
  assert.equal(walletNode({ node: '127.0.0.1:9443' }), '127.0.0.1:9443');
  assert.equal(walletNode({ node: N02, poolNode: null }), RANDOM_NODE, 'a pool address in prefs.node is the pool, not an own node');
  assert.equal(walletNode({}), RANDOM_NODE);
  assert.equal(walletNode(null), RANDOM_NODE);
  assert.equal(nodeName(N03), 'eu-node03');
  assert.equal(nodeName(NS), 'eu-nodes');
});

test('connection order: a picked node first, every other pool node behind it in the usual order; no pick, the usual order', () => {
  for (const first of NODES) {
    for (let k = 0; k < 50; k++) {
      const o = poolOrder(Math.random, first);
      assert.equal(o[0], first);
      assert.deepEqual([...o].sort(), [...NODES].sort(), 'all five, once each');
      const rest = o.slice(1);
      // eu-nodes then eu-node01 stay last (eu-node01 sends no full chain), whatever was picked.
      assert.deepEqual(rest.filter((a) => a === NS || a === N01), [NS, N01].filter((a) => a !== first));
      if (first !== NS && first !== N01) assert.deepEqual(rest.slice(-2), [NS, N01]);
    }
  }
  const seq = (...xs) => {
    let i = 0;
    return () => xs[i++ % xs.length];
  };
  assert.deepEqual(poolOrder(seq(0, 0), N01), [N01, N03, 'eu-node04.mainnet.beam.mw:8200', N02, NS]);
  assert.deepEqual(poolOrder(seq(0, 0), null), [N03, 'eu-node04.mainnet.beam.mw:8200', N02, NS, N01]);
  assert.deepEqual(poolOrder(seq(0, 0), 'evil.example:8200'), poolOrder(seq(0, 0)), 'not a pool node: ignored');
  // Automatic is today's order exactly.
  for (let k = 0; k < 50; k++) assert.deepEqual([...poolOrder().slice(0, 3)].sort(), [...FULL].sort());
});

/** wallet.js with the engine left out: what useNode and hop decide, and where they move. */
function stage({ order, node, random = true }) {
  const moves = [];
  wallet.state = wallet.emptyState();
  wallet.state.node = node;
  wallet.plan = { random, order: [...order], bestHeight: 0, emptyHops: 2, staleHops: 1, lastHopAt: 0 };
  wallet.session = {};
  wallet.hopping = false;
  wallet.nodeWatch = { answered: false };
  wallet.moveTo = async (to, reason) => {
    moves.push([to, reason]);
    wallet.state.node = to;
  };
  return moves;
}

test('"Use this one" moves a pool wallet now, puts that node first and keeps failover behind it', async () => {
  const moves = stage({ order: poolOrder(), node: N02 });
  await wallet.useNode(N01);
  assert.deepEqual(moves, [[N01, 'chosen']]);
  assert.equal(wallet.plan.order[0], N01);
  assert.equal(wallet.plan.order.length, 5);
  assert.equal(wallet.plan.emptyHops, 0, 'a pick starts the failover counts afresh');
  assert.equal(wallet.plan.staleHops, 0);
  // The picked node stops answering: the wallet still moves on by itself, to the next in the order.
  await wallet.hop('unreachable');
  assert.deepEqual(moves[1], [wallet.plan.order[1], 'unreachable']);
  assert.notEqual(moves[1][0], N01);
  // Picking the node already in use restarts nothing.
  const again = stage({ order: poolOrder(), node: N03 });
  await wallet.useNode(N03);
  assert.deepEqual(again, []);
  assert.equal(wallet.plan.order[0], N03);
});

test('"Use this one" is refused for anything that is not a pool node, for an own-node wallet, mid-import and mid-hop', async () => {
  let moves = stage({ order: poolOrder(), node: N02 });
  for (const bad of ['evil.example:8200', 'us-node01.mainnet.beam.mw:8200', 'eu-node03.mainnet.beam.mw:8100', '', null]) {
    await assert.rejects(wallet.useNode(bad), /not one of BEAM's public nodes/, String(bad));
  }
  moves = stage({ order: ['node.example.com:8200'], node: 'node.example.com:8200', random: false });
  await assert.rejects(wallet.useNode(N03), /not running on BEAM's public nodes/);
  moves = stage({ order: poolOrder(), node: N02 });
  wallet.state.importing = true;
  await assert.rejects(wallet.useNode(N03), /getting ready/);
  wallet.state.importing = false;
  wallet.hopping = true;
  await assert.rejects(wallet.useNode(N03), /moving to another node/);
  wallet.hopping = false;
  wallet.session = null;
  await assert.rejects(wallet.useNode(N03), /not running/);
  assert.deepEqual(moves, [], 'nothing moved');
});

test('automatic failover is unchanged: the next node in the order, the same counts', async () => {
  const order = poolOrder();
  const moves = stage({ order, node: order[0] });
  wallet.plan.emptyHops = 0;
  wallet.plan.staleHops = 0;
  await wallet.hop('unreachable');
  await wallet.hop('silent');
  wallet.nodeWatch = { answered: true };
  await wallet.hop('stalled');
  assert.deepEqual(moves, [[order[1], 'unreachable'], [order[2], 'silent'], [order[3], 'stalled']]);
  assert.equal(wallet.plan.emptyHops, 0, 'the node that answered resets the empty-round count');
  assert.equal(wallet.plan.staleHops, 1);
});

test('no new hosts: a check or a pick reaches only BEAM pool nodes, every one already in connect-src', () => {
  const connect = CSP.split('; ').find((d) => d.startsWith('connect-src ')).split(' ').slice(1);
  const wss = connect.filter((s) => s.startsWith('wss:'));
  assert.deepEqual(wss, NODES.map((a) => `wss://${a}`), 'the wss sources are the pool, exactly');
  assert.deepEqual(HEADER_NODES, NODES);
  // A check opens the browser's own WebSocket to a pool node, and only to one.
  made.length = 0;
  const before = nodeGuard.state;
  for (const a of NODES) assert.equal(openPoolSocket(a).url, `wss://${a}/`);
  assert.deepEqual(made, NODES.map((a) => `wss://${a}/`));
  for (const bad of ['evil.example:8200', 'us-node01.mainnet.beam.mw:8200', '127.0.0.1:9443', 'eu-node03.mainnet.beam.mw:8200/x', 'eu-node03.mainnet.beam.mw:8200@evil.example', ' eu-node03.mainnet.beam.mw:8200', undefined]) {
    assert.throws(() => openPoolSocket(bad), (e) => e.name === 'SecurityError', String(bad));
  }
  assert.equal(made.length, NODES.length, 'a refused address never gets a socket');
  assert.deepEqual(nodeGuard.state, before, 'checks are not the wallet connection: the guard counts nothing');
  // A pick changes no header: the page policy depends on the own node alone, and a pool node adds nothing.
  for (const a of NODES) {
    assert.ok(connect.includes(`wss://${walletNode({ node: RANDOM_NODE, poolNode: a })}`));
    assert.equal(securityHeaders(a)['Content-Security-Policy'], CSP);
  }
  assert.deepEqual(securityHeaders(null), SECURITY_HEADERS);
  // Nothing on the node screen or in the check makes a socket of its own.
  for (const f of ['src/screens/node.js', 'src/lib/node_tip.js', 'src/lib/own_node.js']) {
    const src = readFileSync(join(pwa, f), 'utf8');
    assert.ok(!/new\s+(Native)?WebSocket\b|\bWebSocket\s*\(/.test(src), `${f} opens no WebSocket itself`);
  }
  assert.ok(isPoolNode(POOL[0].address));
});

test('node rows: in use, connecting, not checked, checking, not answering, answering, behind', async () => {
  const { nodeRowState, took } = await import('../../src/lib/node_rows.js');
  const st = (o) => ({ node: N02, nodeConnected: true, status: { current_height: 4078390 }, ...o });
  const nb = (t) => t.replace(/ /g, ' ');
  const v = (...a) => {
    const r = nodeRowState(...a);
    return { ...r, text: nb(r.text) };
  };
  assert.deepEqual(v(N02, st(), false, undefined, 4078390), { cls: 'ok', text: 'Block 4,078,390', inUse: true, canUse: false });
  assert.deepEqual(v(N02, st({ nodeConnected: false }), false, undefined, 0), { cls: 'wait', text: 'Connecting…', inUse: true, canUse: false });
  assert.deepEqual(v(N02, st({ nodeConnected: false }), false, { state: 'down' }, 0), { cls: 'bad', text: 'Not answering', inUse: true, canUse: false }, 'the node in use, checked because it does not answer');
  assert.deepEqual(v(N03, st(), false, undefined, 4078390), { cls: 'wait', text: 'Not checked yet', inUse: false, canUse: false });
  assert.deepEqual(v(N03, st({ node: '127.0.0.1:9443' }), true, undefined, 0), { cls: 'wait', text: 'Not checked: you use your own node', inUse: false, canUse: false });
  assert.deepEqual(v(N03, st(), false, { state: 'checking' }, 4078390), { cls: 'wait', text: 'Checking…', inUse: false, canUse: false });
  assert.deepEqual(v(N03, st(), false, { state: 'down' }, 4078390), { cls: 'bad', text: 'Not answering', inUse: false, canUse: false });
  assert.deepEqual(v(N03, st(), false, { state: 'ok', height: 4078388, ms: 183 }, 4078390), { cls: 'ok', text: 'Block 4,078,388 · 183 ms', inUse: false, canUse: true });
  assert.deepEqual(v(N03, st(), false, { state: 'ok', height: 4078300, ms: 1420 }, 4078390), { cls: 'bad', text: 'Behind: block 4,078,300 · 1.4 s', inUse: false, canUse: false });
  // A node claiming a far higher block does not make the others behind: only the wallet's own block counts.
  assert.equal(v(N03, st(), false, { state: 'ok', height: 4078390, ms: 200 }, 4078390).cls, 'ok');
  assert.equal(v(N03, st({ nodeConnected: false, status: null }), false, { state: 'ok', height: 10, ms: 200 }, 0).cls, 'ok', 'no own block: nothing is called behind');
  assert.equal(took(999), '999 ms');
  assert.equal(took(1000), '1.0 s');
});
