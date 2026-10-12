// The payment snapshot for "While you were away" is sealed (audit A-4). 'w:<id>:notify-snapshot'
// kept the ids and states of the last 200 payments in the clear: anyone with a copy of the
// browser's data read the wallet's activity. It is now AES-256-GCM under a key made from the
// wallet's secret (lib/envelope.js dbPassKey: HKDF for a random secret, PBKDF2 >= 600,000 rounds for
// an imported wallet's password, never HKDF over a password), written and read only while the
// wallet is open. Old plaintext snapshots go at start; old reminders are rewritten to name nothing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { sealSnapshot, openSnapshot, forgetPlainNotes, forgetSnapshotKeys, NOTIFY_INFO } from '../../src/lib/notify.js';
import { dbPassKey, KDF_HKDF, KDF_PBKDF2, PBKDF2_MIN_ITERATIONS } from '../../src/lib/envelope.js';

const SECRET = 'ab'.repeat(32);
const PASSWORD = 'my wallet.db password';
const W = '0123456789abcdef';
const snap = { at: 1_700_000_000_000, txs: { ['c1'.repeat(16)]: 3, ['d2'.repeat(16)]: 1 } };

test('random secret: HKDF; nothing readable in the record; opens only for its wallet and secret; edits refused', async () => {
  const env = await sealSnapshot(SECRET, { walletId: W, imported: false }, snap);
  assert.equal(env.kdf, KDF_HKDF);
  assert.equal(env.iterations, undefined);
  const stored = JSON.stringify(env);
  for (const id of Object.keys(snap.txs)) assert.ok(!stored.includes(id), 'no payment id in the clear');
  assert.ok(!stored.includes('"txs"'));
  assert.deepEqual(await openSnapshot(SECRET, { walletId: W, imported: false }, env), snap);
  forgetSnapshotKeys();
  assert.deepEqual(await openSnapshot(SECRET, { walletId: W, imported: false }, env), snap, 'after a lock the key is made again');
  assert.equal(await openSnapshot('cd'.repeat(32), { walletId: W, imported: false }, env), null, 'another secret');
  assert.equal(await openSnapshot(SECRET, { walletId: 'fedcba9876543210', imported: false }, env), null, 'another wallet');
  assert.deepEqual(await openSnapshot(SECRET, { walletId: W, imported: false }, { ...env, at: 1 }), snap, 'unbound extra fields change nothing');
  const flip = (b) => btoa(String.fromCharCode(...Uint8Array.from(atob(b), (c) => c.charCodeAt(0)).map((x, i) => (i === 0 ? x ^ 1 : x))));
  assert.equal(await openSnapshot(SECRET, { walletId: W, imported: false }, { ...env, ct: flip(env.ct) }), null);
  assert.equal(await openSnapshot(SECRET, { walletId: W, imported: false }, { ...env, salt: flip(env.salt) }), null);
  assert.equal(await openSnapshot(null, { walletId: W, imported: false }, env), null, 'locked');
});

test('imported wallet: PBKDF2 at 600,000+ rounds; one HKDF over its password is refused; rounds bound', async () => {
  const env = await sealSnapshot(PASSWORD, { walletId: W, imported: true }, snap);
  assert.equal(env.kdf, KDF_PBKDF2);
  assert.ok(env.iterations >= PBKDF2_MIN_ITERATIONS);
  assert.deepEqual(await openSnapshot(PASSWORD, { walletId: W, imported: true }, env), snap);
  assert.equal(await openSnapshot(PASSWORD, { walletId: W, imported: true }, { ...env, iterations: env.iterations + 1 }), null, 'rounds are additional data');
  assert.equal(await openSnapshot(PASSWORD, { walletId: W, imported: true }, { ...env, iterations: 1e12 }), null, 'absurd rounds refused, not run');
  // A record claiming HKDF for an imported wallet is not opened (that would be the fast check).
  assert.equal(await openSnapshot(PASSWORD, { walletId: W, imported: true }, { ...env, kdf: KDF_HKDF }), null);
  await assert.rejects(dbPassKey({ kdf: KDF_HKDF, salt: env.salt }, PASSWORD, NOTIFY_INFO), (e) => e.code === 'malformed', 'HKDF over a password is refused outright');
  // The salt is kept between writes (the key is made once per unlock).
  const again = await sealSnapshot(PASSWORD, { walletId: W, imported: true }, snap, env);
  assert.equal(again.salt, env.salt);
  assert.notEqual(again.iv, env.iv);
  // A stored record asking for absurd rounds is not reused (it would block every later save).
  const fresh = await sealSnapshot(PASSWORD, { walletId: W, imported: true }, snap, { ...env, iterations: 1e12 });
  assert.equal(fresh.iterations, PBKDF2_MIN_ITERATIONS);
  assert.notEqual(fresh.salt, env.salt);
});

test('at start: plaintext snapshots go, sealed ones stay; old reminders rewritten to name nothing', async () => {
  const m = new Map();
  const kv = { get: async (k) => structuredClone(m.get(k)), set: async (k, v) => void m.set(k, structuredClone(v)), del: async (k) => void m.delete(k), keys: async (p) => [...m.keys()].filter((k) => k.startsWith(p)) };
  const sealed = await sealSnapshot(SECRET, { walletId: W, imported: false }, snap);
  m.set(`w:${W}:notify-snapshot`, sealed);
  m.set('w:fedcba9876543210:notify-snapshot', snap);
  m.set(`w:${W}:notify-reminders`, [{ id: 'rem-name-alice-7', wallet: W, kind: 'contracts', at: 5, title: 'alice.beam expires in 7 days', body: 'Renew it in BEAM names so it stays yours. In Savings.', url: '#open=names' }]);
  m.set(`w:${W}:balance`, { available: '1', at: 1 });
  assert.equal(await forgetPlainNotes(kv), 2);
  assert.deepEqual(m.get(`w:${W}:notify-snapshot`), sealed);
  assert.equal(m.has('w:fedcba9876543210:notify-snapshot'), false);
  assert.deepEqual(m.get(`w:${W}:notify-reminders`), [{ id: 'rem-name-5', kind: 'contracts', at: 5, title: 'A BEAM name of yours expires in 7 days', body: 'Renew it in BEAM names so it stays yours.', url: '#open=names' }]);
  assert.equal(await forgetPlainNotes(kv), 0, 'nothing more the second time');
});
