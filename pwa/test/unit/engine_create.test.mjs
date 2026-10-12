// Creating a wallet's database (lib/engine.js createWalletDb) checks that it reached IndexedDB, as
// adopting an imported one does (re-audit RE1-4). It used to drop the flush's answer: a flush that
// failed (storage refused it) was followed by the wallet's record being saved, so after the next
// load the wallet was listed but its file was not there to open. Now a failed flush undoes the
// file in the page's copy too, and the create fails: no record is written (lib/session.js).
//
// The engine is a stand-in: an in-memory file system and the few WasmWalletClient calls used.
import test from 'node:test';
import assert from 'node:assert/strict';

globalThis.crossOriginIsolated = true;
globalThis.indexedDB = globalThis.indexedDB || {};

function fakeEngine() {
  const dirs = new Set(['/', '/beam_wallet']);
  const files = new Map();
  const flushes = [];
  let failFlushes = 0;
  const DIR = 0o040000;
  const FILE = 0o100000;
  const enoent = () => Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
  const children = (d) => [...dirs, ...files.keys()].filter((p) => p !== d && p.slice(0, p.lastIndexOf('/')) === d).map((p) => p.slice(d.length + 1));
  const FS = {
    mkdir(p) {
      if (dirs.has(p)) throw new Error('EEXIST');
      dirs.add(p);
    },
    rmdir(p) {
      if (!dirs.has(p)) throw enoent();
      if (children(p).length) throw new Error('ENOTEMPTY');
      dirs.delete(p);
    },
    readdir(p) {
      if (!dirs.has(p)) throw enoent();
      return ['.', '..', ...children(p)];
    },
    stat(p) {
      if (dirs.has(p)) return { mode: DIR };
      if (files.has(p)) return { mode: FILE };
      throw enoent();
    },
    isDir: (mode) => (mode & DIR) === DIR,
    unlink(p) {
      if (!files.delete(p)) throw enoent();
    },
    rename(a, b) {
      files.set(b, files.get(a));
      files.delete(a);
    },
    syncfs(populate, cb) {
      if (typeof populate === 'function') [cb, populate] = [populate, false];
      flushes.push({ files: [...files.keys()].sort(), dirs: [...dirs].sort() });
      const fail = failFlushes > 0;
      if (fail) failFlushes--;
      setImmediate(() => cb(fail ? new Error('QuotaExceededError') : null));
    },
  };
  const WasmWalletClient = {
    MountFS: (cb) => setImmediate(() => cb(null)),
    IsInitialized: (p) => files.has(p),
    CreateWallet(words, path) {
      const dir = path.slice(0, path.lastIndexOf('/'));
      if (!dirs.has(dir)) throw new Error('no folder');
      files.set(path, words);
      files.set(`${path}-journal`, '');
    },
  };
  return { M: { FS, WasmWalletClient }, files, dirs, flushes, failNext: (n = 1) => (failFlushes = n) };
}

const engine = fakeEngine();
globalThis.BeamModule = async () => engine.M;
const { createWalletDb, EngineError, DB_PATH } = await import('../../src/lib/engine.js');
const WORDS = Array.from({ length: 12 }, (_, i) => `word${i}`);
const FOLDER = '/beam_wallet/0123456789abcdef/wallet.db';

test('a flush that fails: the create fails, and the new file is not left in the page (first slot)', async () => {
  engine.failNext(1);
  await assert.rejects(createWalletDb(WORDS, 'db-pass', DB_PATH), (e) => e instanceof EngineError && e.code === 'save');
  assert.equal(engine.files.has(DB_PATH), false, 'wallet.db removed from the page copy');
  assert.equal(engine.files.has(`${DB_PATH}-journal`), false, 'and its side file');
  assert.ok(engine.flushes.length >= 2, 'the removal is flushed too');
  assert.deepEqual(engine.flushes.at(-1).files, [], 'the last flush carries no file of the failed wallet');
});

test('a flush that fails: a folder wallet leaves no file and no folder behind', async () => {
  engine.failNext(1);
  await assert.rejects(createWalletDb(WORDS, 'db-pass', FOLDER), (e) => e instanceof EngineError && e.code === 'save');
  assert.equal(engine.files.has(FOLDER), false);
  assert.equal(engine.dirs.has('/beam_wallet/0123456789abcdef'), false);
});

test('the flush goes through: the wallet is created and stays', async () => {
  const n = engine.flushes.length;
  await createWalletDb(WORDS, 'db-pass', FOLDER);
  assert.equal(engine.files.has(FOLDER), true);
  assert.equal(engine.flushes.length, n + 1);
  assert.ok(engine.flushes.at(-1).files.includes(FOLDER));
});
