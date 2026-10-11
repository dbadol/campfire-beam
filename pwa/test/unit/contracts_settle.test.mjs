// Before the engine stops, what an app already asked it is answered first (lib/contracts.js
// settleApps): a handle released with a request still running in the engine made the answer
// reach a freed handle, and the next unlock never synced.
import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { fakeEngine } from './helpers/fake_engine.mjs';
import { bindSession, unbindSession, openApp, nativeApp, settleApps, setConsentPresenter, contractsState } from '../../src/lib/contracts.js';

const tick = () => new Promise((r) => setImmediate(r));

let engine;
beforeEach(() => {
  engine = fakeEngine();
  bindSession(engine.session);
});
afterEach(() => unbindSession());

test('settleApps waits for the engine to answer what an app sent, refuses new calls, then the handle goes', async () => {
  const held = [];
  engine.respond = (req, api) => held.push({ req, api });
  const app = await nativeApp();
  const quote = app.view('action=pool_trade,bPredictOnly=1', [0]);
  await tick();
  let settled = false;
  const s = settleApps({ timeoutMs: 5000 }).then(() => (settled = true));
  await tick();
  assert.equal(settled, false, 'waits while the engine still runs the request');
  await assert.rejects(app.call('get_version'), (e) => e.code === 'locked', 'no new call once the engine is about to stop');
  await assert.rejects(openApp({ appName: 'Late' }), (e) => e.code === 'locked');
  held[0].api.reply(held[0].req.id, { output: '{"res": {"buy": 1}}' });
  await s;
  assert.deepEqual(await quote, { res: { buy: 1 } }, 'the caller still gets its answer');
  assert.equal(engine.deleted, 0);
  unbindSession();
  assert.equal(engine.deleted, 1, 'released after the answer, never before');
});

test('a pending consent is withdrawn (the engine hears No), so settling does not wait on a person', async () => {
  let shown = 0;
  const unset = setConsentPresenter(() => {
    shown++;
    return new Promise(() => {}); // never answers
  });
  const app = await nativeApp();
  const sent = app.call('process_invoke_data', { data: [1, 2, 3] }).then(() => null, (e) => e);
  for (let i = 0; i < 5 && !shown; i++) await tick();
  assert.equal(shown, 1);
  await settleApps({ timeoutMs: 2000 });
  assert.equal((await sent).code, 'rejected');
  assert.deepEqual(engine.answers, ['rejected']);
  assert.equal(contractsState().consents, 0);
  unset();
});

test('an engine that never answers: settling gives up after the timeout', async () => {
  engine.respond = () => {};
  const app = await openApp({ appName: 'Stuck' });
  app.call('invoke_contract', { args: 'a=b', create_tx: false }).catch(() => {});
  await tick();
  const t0 = Date.now();
  await settleApps({ timeoutMs: 150 });
  assert.ok(Date.now() - t0 >= 140 && Date.now() - t0 < 2000);
});

test('nothing bound, nothing pending: settling returns at once', async () => {
  unbindSession();
  await settleApps();
  bindSession(engine.session);
  const t0 = Date.now();
  await settleApps();
  assert.ok(Date.now() - t0 < 100);
});
