// The airdrop code vault's key (audit B1 / A-1). The codes are the only key to the locked funds, so
// the record must never be lost; and for a wallet imported from a wallet.db, app.dbPass is the
// person's own password (also the wallet.db key), so a record sealed with one HKDF over it was a
// one-hash-per-guess check for that password. Imported: PBKDF2-SHA256, at least 600,000 rounds, as
// every other vault (eth/vault.js, contacts.js, bridge/store.js, buy/store.js). Random secret: HKDF.
// The KDF and its rounds are in the record and its additional data; a wrong one is refused, never
// overwritten. An HKDF record an imported wallet already has is sealed again with PBKDF2 the next
// time it is opened (and at unlock), every code kept, read back before the old one goes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { codeVault, resealCodeVault, codeHash, AIRDROP_CID, CODE_VAULT_KDF } from '../../src/lib/airdrop.js';
import { PBKDF2_MIN_ITERATIONS } from '../../src/lib/envelope.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const enc = new TextEncoder();
const PASSWORD = 'my wallet.db password';
const RANDOM = 'ab'.repeat(32);

const memoryKv = () => {
  const m = new Map();
  return { m, writes: 0, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), async set(k, v) { this.writes++; m.set(k, structuredClone(v)); } };
};

const b64 = (u8) => btoa(String.fromCharCode(...u8));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/** Exactly what the vault wrote before this fix: v1, HKDF-SHA256 over the secret's UTF-8 bytes. */
async function sealV1(walletId, secret, list) {
  const salt = b64(crypto.getRandomValues(new Uint8Array(16)));
  const base = await crypto.subtle.importKey('raw', enc.encode(secret), 'HKDF', false, ['deriveKey']);
  const key = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: unb64(salt), info: enc.encode('beam-campfire-airdrop-codes-v1') }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(JSON.stringify([1, walletId, salt])) }, key, enc.encode(JSON.stringify(list)));
  return { v: 1, walletId, salt, iv: b64(iv), ct: b64(new Uint8Array(ct)) };
}

/** Whether one HKDF over `secret` (the old derivation, the cheap guess) opens the record. */
async function hkdfOpens(env, secret) {
  try {
    const base = await crypto.subtle.importKey('raw', enc.encode(secret), 'HKDF', false, ['deriveKey']);
    for (const info of ['beam-campfire-airdrop-codes-v1', 'beam-campfire-airdrop-codes-v2']) {
      const key = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: unb64(env.salt), info: enc.encode(info) }, base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
      for (const aad of [[1, env.walletId, env.salt], [env.v, env.walletId, env.kdf, env.iterations || 0, env.salt]]) {
        try {
          await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(env.iv), additionalData: enc.encode(JSON.stringify(aad)) }, key, unb64(env.ct));
          return true;
        } catch {
          /* not this one */
        }
      }
    }
  } catch {
    /* no */
  }
  return false;
}

/** Opens a v2 PBKDF2 record the way the spec says (rounds and KDF in the additional data), independently of the vault. */
async function openPbkdf2(env, secret) {
  const base = await crypto.subtle.importKey('raw', enc.encode(secret.normalize('NFC')), 'PBKDF2', false, ['deriveKey']);
  const key = await crypto.subtle.deriveKey({ name: 'PBKDF2', hash: 'SHA-256', salt: unb64(env.salt), iterations: env.iterations }, base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
  const aad = enc.encode(JSON.stringify([env.v, env.walletId, env.kdf, env.iterations, env.salt]));
  return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(env.iv), additionalData: aad }, key, unb64(env.ct))));
}

async function batch(localId, codes) {
  return {
    localId,
    contractId: AIRDROP_CID,
    assetId: 0,
    createdAt: `2026-10-1${localId.length % 9}T00:00:00.000Z`,
    txId: null,
    txStatus: 'broadcast',
    codes: await Promise.all(codes.map(async (code) => ({ code, hash: await codeHash(code), value: '100000', status: 'unknown' }))),
  };
}

test('imported wallet: PBKDF2-SHA256 at 600,000+ rounds, named in the record; one HKDF over the password opens nothing', async () => {
  const kv = memoryKv();
  const v = codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true });
  await v.put(await batch('b1', ['ABCD-EFGH-JKLM-NPQR']));
  const env = kv.m.get('airdropCodes');
  assert.equal(env.kdf, CODE_VAULT_KDF.pbkdf2);
  assert.ok(env.iterations >= PBKDF2_MIN_ITERATIONS, `rounds: ${env.iterations}`);
  assert.equal(await hkdfOpens(env, PASSWORD), false, 'not a fast password check any more');
  assert.equal((await codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }).all())[0].codes[0].code, 'ABCD-EFGH-JKLM-NPQR');
  await assert.rejects(codeVault({ kv, walletId: 'w1', secret: 'another password', imported: true }).all(), (e) => e.code === 'noCodeStore');
});

test('random secret: HKDF (a 64-hex secret only); a person-chosen password never goes through HKDF', async () => {
  const kv = memoryKv();
  await codeVault({ kv, walletId: 'w1', secret: RANDOM, imported: false }).put(await batch('b1', ['ABCD-EFGH-JKLM-NPQR']));
  const env = kv.m.get('airdropCodes');
  assert.equal(env.kdf, CODE_VAULT_KDF.hkdf);
  assert.equal(env.iterations, undefined);
  // The imported flag missing or wrong: a password is refused rather than sealed under HKDF.
  const kv2 = memoryKv();
  await assert.rejects(codeVault({ kv: kv2, walletId: 'w1', secret: PASSWORD, imported: false }).put(await batch('b1', ['ABCD-EFGH-JKLM-NPQR'])), (e) => e.code === 'noCodeStore');
  await assert.rejects(codeVault({ kv: kv2, walletId: 'w1', secret: PASSWORD }).put(await batch('b1', ['ABCD-EFGH-JKLM-NPQR'])), (e) => e.code === 'noCodeStore');
  assert.equal(kv2.m.size, 0, 'nothing written');
});

test('the KDF and its rounds are bound: a swapped KDF, lowered or absurd rounds are refused and the record left as it was', async () => {
  const kv = memoryKv();
  await codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }).put(await batch('b1', ['ABCD-EFGH-JKLM-NPQR']));
  const good = kv.m.get('airdropCodes');
  const tries = [
    { ...good, iterations: good.iterations + 1 },
    { ...good, iterations: 1000 },
    { ...good, iterations: 1e12 },
    { ...good, kdf: CODE_VAULT_KDF.hkdf, iterations: undefined },
    { ...good, kdf: 'scrypt' },
  ];
  for (const bad of tries) {
    kv.m.set('airdropCodes', bad);
    const t0 = Date.now();
    await assert.rejects(codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }).put(await batch('b2', ['BCDE-FGHJ-KLMN-PQRS'])), (e) => e.code === 'noCodeStore', JSON.stringify(bad.kdf) + bad.iterations);
    assert.ok(Date.now() - t0 < 5000, 'an absurd round count is refused, not run');
    assert.deepEqual(kv.m.get('airdropCodes'), bad, 'untouched');
  }
  // A PBKDF2 record for a wallet with a random secret is refused too (it never writes one).
  kv.m.set('airdropCodes', good);
  await assert.rejects(codeVault({ kv, walletId: 'w1', secret: RANDOM, imported: false }).all(), (e) => e.code === 'noCodeStore');
});

test('migration: an imported wallet\'s old HKDF record is sealed again with PBKDF2 on the next open, every record kept byte for byte', async () => {
  const kv = memoryKv();
  const b1 = await batch('b1', ['ABCD-EFGH-JKLM-NPQR', 'BCDE-FGHJ-KLMN-PQRS']);
  const b2 = await batch('b22', ['CDEF-GHJK-LMNP-QRST']);
  // A record this version cannot show (its code does not match its hash) is still a record: kept.
  const odd = { ...b1, localId: 'odd', codes: [{ ...b1.codes[0], hash: 'ab'.repeat(32) }] };
  const list = [b1, odd, b2];
  const old = await sealV1('w1', PASSWORD, list);
  assert.equal(await hkdfOpens(old, PASSWORD), true, 'the old record is the fast check the audit found');
  kv.m.set('airdropCodes', old);

  assert.equal(await resealCodeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }), true, 'sealed again');
  const env = kv.m.get('airdropCodes');
  assert.equal(env.v, 2);
  assert.equal(env.kdf, CODE_VAULT_KDF.pbkdf2);
  assert.ok(env.iterations >= PBKDF2_MIN_ITERATIONS);
  assert.notEqual(env.salt, old.salt, 'a fresh salt');
  assert.equal(await hkdfOpens(env, PASSWORD), false);
  const v = codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true });
  assert.deepEqual((await v.all()).map((b) => b.localId).sort(), ['b1', 'b22']);
  assert.deepEqual(await openPbkdf2(env, PASSWORD), JSON.parse(JSON.stringify(list)), 'every record, the unreadable one too, in order');
  // Nothing more to do the second time.
  assert.equal(await resealCodeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }), false);
  // No record at all: nothing written.
  const empty = memoryKv();
  assert.equal(await resealCodeVault({ kv: empty, walletId: 'w1', secret: PASSWORD, imported: true }), false);
  assert.equal(empty.writes, 0);
});

test('migration through all() or put(): the codes come back, and a put adds to them', async () => {
  for (const first of ['all', 'put']) {
    const kv = memoryKv();
    const b1 = await batch('b1', ['ABCD-EFGH-JKLM-NPQR']);
    kv.m.set('airdropCodes', await sealV1('w1', PASSWORD, [b1]));
    const v = codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true });
    if (first === 'put') await v.put(await batch('b2', ['BCDE-FGHJ-KLMN-PQRS']));
    const got = await v.all();
    assert.deepEqual(got.map((b) => b.localId).sort(), first === 'put' ? ['b1', 'b2'] : ['b1'], first);
    assert.equal(kv.m.get('airdropCodes').kdf, CODE_VAULT_KDF.pbkdf2, first);
  }
});

test('migration: a failed write keeps the old record; a write that does not read back is undone', async () => {
  const b1 = await batch('b1', ['ABCD-EFGH-JKLM-NPQR']);
  // The write fails: the old record stays, and the codes still show.
  const kv = memoryKv();
  const old = await sealV1('w1', PASSWORD, [b1]);
  kv.m.set('airdropCodes', old);
  const set = kv.set;
  kv.set = async () => {
    throw new Error('QuotaExceededError');
  };
  assert.deepEqual((await codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }).all()).map((b) => b.localId), ['b1']);
  assert.deepEqual(kv.m.get('airdropCodes'), old);
  await assert.rejects(resealCodeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }));
  assert.deepEqual(kv.m.get('airdropCodes'), old);
  // The storage keeps something else than was written (a damaged write): the old record is put back.
  kv.set = async function (k, v) {
    if (v.v === 2) v = { ...v, ct: b64(unb64(v.ct).map((x, i) => (i === 0 ? x ^ 1 : x))) };
    return set.call(this, k, v);
  };
  await assert.rejects(resealCodeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }), (e) => e.code === 'noCodeStore');
  assert.deepEqual(kv.m.get('airdropCodes'), old, 'the old record is back');
  kv.set = set;
  assert.equal(await resealCodeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }), true);
  assert.deepEqual((await codeVault({ kv, walletId: 'w1', secret: PASSWORD, imported: true }).all()).map((b) => b.localId), ['b1']);
});

test('a wallet with a random secret still opens its old v1 record, and its next write is v2 with every code', async () => {
  const kv = memoryKv();
  const b1 = await batch('b1', ['ABCD-EFGH-JKLM-NPQR']);
  kv.m.set('airdropCodes', await sealV1('w1', RANDOM, [b1]));
  const v = codeVault({ kv, walletId: 'w1', secret: RANDOM, imported: false });
  assert.deepEqual((await v.all()).map((b) => b.localId), ['b1']);
  assert.equal(kv.m.get('airdropCodes').v, 1, 'reading alone changes nothing for it');
  assert.equal(await resealCodeVault({ kv, walletId: 'w1', secret: RANDOM, imported: false }), false);
  await v.put(await batch('b2', ['BCDE-FGHJ-KLMN-PQRS']));
  assert.equal(kv.m.get('airdropCodes').v, 2);
  assert.equal(kv.m.get('airdropCodes').kdf, CODE_VAULT_KDF.hkdf);
  assert.deepEqual((await v.all()).map((b) => b.localId).sort(), ['b1', 'b2']);
});

test('two vaults over the same wallet at once (the unlock re-seal and a new batch): no batch is lost', async () => {
  const kv = memoryKv();
  // Slow storage, so the two would interleave without one queue per wallet.
  const get = kv.get;
  kv.get = async (k) => {
    await new Promise((r) => setTimeout(r, 5));
    return get(k);
  };
  kv.m.set('airdropCodes', await sealV1('w7', PASSWORD, [await batch('b1', ['ABCD-EFGH-JKLM-NPQR'])]));
  const opts = { kv, walletId: 'w7', secret: PASSWORD, imported: true };
  const b2 = await batch('b2', ['BCDE-FGHJ-KLMN-PQRS']);
  const b3 = await batch('b33', ['CDEF-GHJK-LMNP-QRST']);
  await Promise.all([resealCodeVault(opts), codeVault(opts).put(b2), codeVault(opts).put(b3), resealCodeVault(opts)]);
  assert.deepEqual((await codeVault(opts).all()).map((b) => b.localId).sort(), ['b1', 'b2', 'b33']);
});

test('the wiring: the screen passes the imported flag, and every unlock re-seals an imported wallet\'s codes', () => {
  const screen = readFileSync(join(src, 'screens', 'airdrop.js'), 'utf8');
  assert.match(screen, /codeVault\(\{[^}]*imported: Boolean\(app\.record\.imported\)/);
  const unlock = readFileSync(join(src, 'screens', 'unlock.js'), 'utf8');
  assert.match(unlock, /resealAirdropCodes\(app\)/);
  assert.match(screen, /export function resealAirdropCodes\(app\)[\s\S]*resealCodeVault\(\{[^}]*imported: true/);
});
