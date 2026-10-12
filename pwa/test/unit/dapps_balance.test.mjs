// A dApp installed from a file sees the wallet's balance only after the person says so, once per
// dApp: wallet_status (BEAM gives every app the totals without asking) and calc_change (whose coin
// selection gives the coins away) wait for that answer. It can send what it sees to any server
// (a preconnect or dns-prefetch link reaches any host; no CSP or header stops it).
import test from 'node:test';
import assert from 'node:assert/strict';
import { DappSession } from '../../src/lib/dapps/session.js';

function fakeApp() {
  const calls = [];
  return { calls, async call(method) { calls.push(method); return { ok: method }; } };
}
const req = (id, method, params = {}) => JSON.stringify({ jsonrpc: '2.0', id, method, params });
const parse = (s) => JSON.parse(s);

test('wallet_status and calc_change wait for the answer, asked once even when the dApp asks many times', async () => {
  const app = fakeApp();
  const asked = [];
  let answer;
  const s = new DappSession({ appName: 'Tiny dApp', app, confirmSign: async () => true, confirmBalance: (q) => (asked.push(q), new Promise((r) => (answer = r))) });
  const pending = [s.handle(req(1, 'wallet_status')), s.handle(req(2, 'wallet_status')), s.handle(req(3, 'calc_change', { amount: 5 }))];
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(asked, [{ appName: 'Tiny dApp' }]);
  assert.deepEqual(app.calls, [], 'nothing reaches the wallet while the question is open');
  answer(true);
  const out = (await Promise.all(pending)).map(parse);
  assert.deepEqual(out.map((r) => r.result.ok), ['wallet_status', 'wallet_status', 'calc_change']);
  assert.equal(parse(await s.handle(req(4, 'wallet_status'))).result.ok, 'wallet_status');
  assert.equal(asked.length, 1, 'the answer holds for the session');
  // Methods that show nothing of the balance never ask.
  assert.equal(parse(await s.handle(req(5, 'get_version'))).result.ok, 'get_version');
});

test('a no is refused as BEAM refuses a call the person rejected (-32021), and the wallet is never asked', async () => {
  const app = fakeApp();
  let n = 0;
  const s = new DappSession({ appName: 'Tiny dApp', app, confirmSign: async () => true, confirmBalance: async () => (n++, false) });
  const r = parse(await s.handle(req(1, 'wallet_status')));
  assert.equal(r.error.code, -32021);
  assert.match(r.error.data, /balance/);
  assert.equal(parse(await s.handle(req(2, 'calc_change', { amount: 1 }))).error.code, -32021);
  assert.equal(n, 1);
  assert.deepEqual(app.calls, []);
});

test('a question that could not be put is a no for that call, and is put again next time', async () => {
  const app = fakeApp();
  let n = 0;
  const s = new DappSession({ appName: 'x', app, confirmSign: async () => true, confirmBalance: async () => { n++; if (n === 1) throw new Error('screen gone'); return true; } });
  assert.equal(parse(await s.handle(req(1, 'wallet_status'))).error.code, -32021);
  assert.equal(parse(await s.handle(req(2, 'wallet_status'))).result.ok, 'wallet_status');
  assert.equal(n, 2);
});

test("BEAM's own dApps and the DApp Store's keep today's behaviour: no question", async () => {
  const app = fakeApp();
  const s = new DappSession({ appName: 'Beam DEX', app, confirmSign: async () => true });
  assert.equal(parse(await s.handle(req(1, 'wallet_status'))).result.ok, 'wallet_status');
  assert.deepEqual(app.calls, ['wallet_status']);
});
