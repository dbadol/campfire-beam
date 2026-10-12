// A hand-over to another tab waits for a step whose parts must not be split (re-audit RE1-5,
// RE1-6): a new or imported wallet's file and its record, a deleted wallet's file and its keys.
// Before, "Use it here instead" landing between the two let go of the wallet in the middle: the
// record write was then refused, leaving a wallet file without a record (create, import) or a
// record without a file (delete).
//
// The real lib/session.js and lib/wallets.js, over a stand-in engine (in-memory file system) and
// an in-memory IndexedDB; the hand-over is this page's own OneTab letting go (lib/one_tab.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import { fakeIndexedDB, IDBKeyRangeStub } from './helpers/fake_idb.mjs';

const idb = fakeIndexedDB();
globalThis.crossOriginIsolated = true;
globalThis.indexedDB = idb;
globalThis.IDBKeyRange = IDBKeyRangeStub;

// The engine: an in-memory file system; a flush can be held back until the test lets it go.
const files = new Map();
const dirs = new Set(['/', '/beam_wallet']);
let flushGate = null;
let onFlush = null;
const DIR = 0o040000;
const children = (d) => [...dirs, ...files.keys()].filter((p) => p !== d && p.slice(0, p.lastIndexOf('/')) === d).map((p) => p.slice(d.length + 1));
const FS = {
  mkdir: (p) => void dirs.add(p),
  rmdir(p) {
    if (children(p).length) throw new Error('ENOTEMPTY');
    if (!dirs.delete(p)) throw new Error('ENOENT');
  },
  readdir(p) {
    if (!dirs.has(p)) throw new Error('ENOENT');
    return ['.', '..', ...children(p)];
  },
  stat(p) {
    if (dirs.has(p)) return { mode: DIR };
    if (files.has(p)) return { mode: 0 };
    throw new Error('ENOENT');
  },
  isDir: (m) => (m & DIR) === DIR,
  unlink(p) {
    if (!files.delete(p)) throw new Error('ENOENT');
  },
  rename(a, b) {
    files.set(b, files.get(a));
    files.delete(a);
  },
  syncfs(populate, cb) {
    if (typeof populate === 'function') [cb, populate] = [populate, false];
    if (onFlush) onFlush();
    Promise.resolve(flushGate).then(() => setImmediate(() => cb(null)));
  },
};
globalThis.BeamModule = async () => ({
  FS,
  WasmWalletClient: {
    MountFS: (cb) => setImmediate(() => cb(null)),
    IsInitialized: (p) => files.has(p),
    CreateWallet: (words, path) => void files.set(path, 'db'),
  },
});

const { oneTab } = await import('../../src/lib/one_tab.js');
const { createWallet, importWallet } = await import('../../src/lib/session.js');
const { removeWallet, listWallets } = await import('../../src/lib/wallets.js');
const { IMPORT_PATH } = await import('../../src/lib/engine.js');

const tab = oneTab();
const order = [];
tab.onLetGo(async () => {
  order.push('locked for the other tab');
});
/** This page holds the wallet again (each test hands it over once). */
function holdAgain() {
  Object.assign(tab, { state: 'held', spent: false, how: null });
  order.length = 0;
}
function fakeApp() {
  return {
    setup: { mode: 'create', words: 'abandon ability able about above absent absorb abstract absurd abuse access accident'.split(' ') },
    record: null,
    dbPass: null,
    wallet: { session: null, run: null, stop: async () => {} },
    nav: { clear() {} },
    runLockHooks() {},
    setPrefs: async () => ({}),
  };
}
/** The other tab asks while the step's first part (the flush) is under way. */
function askDuringFlush() {
  let release;
  flushGate = new Promise((r) => (release = r));
  let letGo = null;
  onFlush = () => {
    if (letGo) return;
    onFlush = null;
    letGo = tab.letGo();
    setTimeout(release, 20);
  };
  return () => {
    flushGate = null;
    return letGo;
  };
}
const records = () => idb.dump('beam-campfire-app', 'kv');

test('create: "Use it here instead" during the flush waits for the record; then the wallet is locked and handed over', async () => {
  holdAgain();
  const handOver = askDuringFlush();
  const record = await createWallet(fakeApp(), 'a long password 1');
  await handOver();
  assert.equal(tab.how, 'handed');
  assert.ok(files.has('/beam_wallet/wallet.db'), 'the file is there');
  assert.equal(records().wallet && records().wallet.id, record.id, 'and its record');
  assert.deepEqual(order, ['locked for the other tab'], 'the lock-and-save ran after the create had finished');
});

test('import: the hand-over waits for the adopted file and its record', async () => {
  holdAgain();
  files.set(IMPORT_PATH, 'picked file');
  const app = { ...fakeApp(), setup: { adding: true } };
  const handOver = askDuringFlush();
  const record = await importWallet(app, 'a long password 2');
  await handOver();
  assert.equal(tab.how, 'handed');
  const path = `/beam_wallet/${record.id}/wallet.db`;
  assert.ok(files.has(path), 'the imported file is there');
  assert.equal(records()[`w:${record.id}:wallet`] && records()[`w:${record.id}:wallet`].id, record.id, 'and its record');
});

test('delete: the hand-over waits for the wallet\'s keys to go with its file', async () => {
  holdAgain();
  const list = await listWallets();
  assert.equal(list.length, 2);
  const target = list.find((r) => !r.slot0);
  const app = { ...fakeApp(), record: list[0] };
  const handOver = askDuringFlush();
  await removeWallet(app, target);
  await handOver();
  assert.equal(tab.how, 'handed');
  assert.equal(files.has(`/beam_wallet/${target.id}/wallet.db`), false, 'the file is gone');
  assert.equal(records()[`w:${target.id}:wallet`], undefined, 'and its record');
  assert.deepEqual((await listWallets()).map((r) => r.id), [list[0].id]);
});

test('a step that outlasts the cap: the hand-over goes anyway, said as "capped" (it may not have saved its last seconds)', async () => {
  holdAgain();
  tab.capMs = 50;
  let finish;
  const step = tab.whileBusy(() => new Promise((r) => (finish = r)));
  const t0 = Date.now();
  await tab.letGo();
  assert.ok(Date.now() - t0 >= 45, 'it waited for the cap');
  assert.equal(tab.how, 'capped');
  assert.deepEqual(order, [], 'the wallet was not locked by the hand-over after the cap (the app stops it when told "capped")');
  finish();
  await step;
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(order, [], 'nor later');
});
