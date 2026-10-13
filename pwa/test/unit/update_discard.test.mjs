// Issue #78: "Delete this download" for an update that was downloaded and verified but not installed.
// The loader's own code (sw.js, assembled as the build assembles it) runs in the sandbox; the page's
// side (lib/update.js) talks to it through a stand-in service worker.
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { loadLoader } from './helpers/sw_sandbox.mjs';
import { lastCheckText } from '../../src/lib/update.js';
import { DISCARDED_TOAST } from '../../src/lib/update_ui.js';

async function testPub() {
  const k = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const j = await webcrypto.subtle.exportKey('jwk', k.publicKey);
  return { kty: j.kty, crv: j.crv, x: j.x, y: j.y };
}

const release = (version, cache) => ({ version, cache, files: { 'app.js': 'aa'.repeat(32) }, manifestSha: 'bb'.repeat(32), created: '2026-10-13T00:00:00Z' });

async function staged() {
  const sw = await loadLoader({ pub: await testPub(), fetch: async () => new Response('', { status: 404 }) });
  for (const name of ['campfire-0.2.14-1111', 'campfire-0.2.15-2222', 'campfire-0.2.16-3333']) {
    await (await sw.caches.open(name)).put('https://wallet.example/app.js', new Response('x'));
  }
  await sw.writeState({ current: release('0.2.14', 'campfire-0.2.14-1111'), pending: { ...release('0.2.15', 'campfire-0.2.15-2222'), from: { host: 'cdn.jsdelivr.net', own: false } }, staging: null, lastRefusal: null });
  return sw;
}

/** Sends a message to the loader the way a page does, and returns its answer. */
function ask(sw, data) {
  return new Promise((resolve, reject) => {
    const waits = [];
    sw.handlers.message({ data, ports: [{ postMessage: resolve }], waitUntil: (p) => waits.push(p.catch(reject)) });
  });
}

test('the loader forgets the staged release and deletes its cache; the installed copy stays', async () => {
  const sw = await staged();
  const r = await sw.discardUpdate();
  assert.deepEqual(r, { result: 'discarded', version: '0.2.15' });
  const st = await sw.readState();
  assert.equal(st.pending, null);
  assert.equal(st.staging, null);
  assert.equal(st.current.version, '0.2.14', 'the installed release is untouched');
  const caches = await sw.caches.keys();
  assert.ok(caches.includes('campfire-0.2.14-1111'), 'its files stay');
  assert.ok(!caches.includes('campfire-0.2.15-2222'), 'the download is gone');
  assert.ok(!caches.includes('campfire-0.2.16-3333'), 'and anything else not in use');
  assert.deepEqual(await sw.discardUpdate(), { result: 'none' }, 'nothing left to delete');
});

test('a half-downloaded release (staging) is deleted too; nothing is deleted while a check runs or before an install', async () => {
  const sw = await staged();
  const st = await sw.readState();
  await sw.writeState({ ...st, pending: null, staging: 'campfire-0.2.16-3333' });
  assert.deepEqual(await sw.discardUpdate(), { result: 'discarded', version: null });
  assert.ok(!(await sw.caches.keys()).includes('campfire-0.2.16-3333'));

  const busy = await staged();
  let finish;
  busy.setUpdateRun(new Promise((r) => (finish = r)));
  assert.deepEqual(await busy.discardUpdate(), { result: 'busy' }, 'a check may be staging this very release');
  assert.equal((await busy.readState()).pending.version, '0.2.15', 'kept');
  finish();
  busy.setUpdateRun(null);

  const fresh = await loadLoader({ pub: await testPub(), fetch: async () => new Response('', { status: 404 }) });
  assert.deepEqual(await fresh.discardUpdate(), { result: 'none' }, 'first install under way: never');
});

test('through the message a page sends; status says the loader can do it', async () => {
  const sw = await staged();
  const status = await ask(sw, { type: 'status' });
  assert.deepEqual(status.features, ['discard-update']);
  assert.equal(status.pending, '0.2.15');
  assert.equal(status.api, 3, 'LOADER_API is unchanged: a copy can still deliver this release');
  assert.deepEqual(await ask(sw, { type: 'discard-update' }), { result: 'discarded', version: '0.2.15' });
  const after = await ask(sw, { type: 'status' });
  assert.equal(after.pending, null);
  assert.equal(after.current, '0.2.14');
});

test('the page: Delete this download clears the offer and says so; an older loader is never asked', async () => {
  const prev = globalThis.navigator;
  const prevChannel = globalThis.MessageChannel;
  // A channel that keeps nothing open (a real one would keep Node running after the test).
  globalThis.MessageChannel = class {
    constructor() {
      this.port1 = { onmessage: null };
      this.port2 = { postMessage: (data) => this.port1.onmessage && this.port1.onmessage({ data }) };
    }
  };
  const sw = await staged();
  let features = ['discard-update'];
  const asked = [];
  const controller = {
    postMessage(msg, [port]) {
      asked.push(msg.type);
      const answer = msg.type === 'status' ? ask(sw, msg).then((s) => ({ ...s, features })) : ask(sw, msg);
      answer.then((a) => port.postMessage(a));
    },
  };
  Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: { controller } }, configurable: true, writable: true });
  try {
    const { updates } = await import('../../src/lib/update.js');
    updates.available = { version: '0.2.15', from: { host: 'cdn.jsdelivr.net', own: false } };
    updates.lastCheck = { at: 1000, result: 'ready', version: '0.2.15', host: 'cdn.jsdelivr.net' };
    let emitted = 0;
    const off = updates.onChange(() => emitted++);
    assert.equal(await updates.canDiscard(), true);
    const r = await updates.discard();
    off();
    assert.deepEqual(r, { result: 'discarded', version: '0.2.15' });
    assert.equal(updates.available, null, 'Home no longer offers Update');
    assert.deepEqual(updates.lastCheck, { at: 1000, result: 'discarded', version: '0.2.15', host: null });
    assert.equal(emitted, 1);
    features = undefined; // a loader from before this release
    assert.equal(await updates.canDiscard(), false, 'no button then');
    assert.deepEqual(asked, ['status', 'discard-update', 'status']);
  } finally {
    Object.defineProperty(globalThis, 'navigator', { value: prev, configurable: true, writable: true });
    globalThis.MessageChannel = prevChannel;
  }
});

test('the words: Settings / About after a delete, and the toast', () => {
  const now = 10 * 60000;
  assert.equal(lastCheckText({ at: now - 5 * 60000, result: 'discarded', version: '0.2.15' }, now), 'Last checked 5 min ago: you deleted the download of version 0.2.15. Check again to download it.');
  assert.equal(lastCheckText({ at: now, result: 'discarded', version: null }, now), 'Last checked just now: you deleted the download. Check again to download it.');
  assert.equal(DISCARDED_TOAST, 'Download deleted. Check for updates to download it again.');
});
