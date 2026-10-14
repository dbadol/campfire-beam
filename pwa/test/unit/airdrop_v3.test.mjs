// Airdrop v3 (lib/airdrop_v3.js): seeds and voucher keys exactly as the pinned app shader derives
// them (vectors printed by the real shader in the wallet engine on mainnet, 2026-10-13), the
// network fees from the declared charges, argument builders, answer parsing, the check before a new
// batch's codes are shared (truncated lists included), v3-then-old lookups, and the service over a
// fake v3 contract: every built transaction checked byte for byte, tampered builds never signed.
import test, { before } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import {
  V3_CID, V3_SHADER_ID, V3_METHOD, V3_CHARGE, V3_KERNEL, V3_MAX_VOUCHERS, V3_CLAIM_FEE, GAS_PER_VOUCHER, CONFIRMATIONS_BEFORE_CHECK, CHECK_PROBLEM_TEXT,
  feeForUnits, createFee, cancelFee, createCharge, cancelCharge, v3CreationFee, claimCost, normaliseV3, isV3Code, seedOf, secretOf, voucherKeyOf, seedsBlob, gasArg,
  v3args, parseV3Voucher, parseV3Batches, parseV3Batch, parseVoucherKey, v3CodeFor, mapV3Error, squatCheck, createAirdropV3, createAirdrops, cryptoReady } from '../../src/lib/airdrop_v3.js';
import { AIRDROP_CID, CALL_FEE, creationFee, MAX_TOTAL, normaliseCode, codeHash, codeVault, createAirdrop, airdropLock, readSavedBatch, TX_STATUS, CODE_STATUS, CHECK_STATE } from '../../src/lib/airdrop.js';
import { SHADERS } from '../../src/lib/shaders.js';
import { entryFee, readContractTx, toHex, fromHex, le } from '../../src/lib/contract_tx.js';
import { parseShaderJson } from '../../src/lib/contracts.js';
import { invokeData, invokeEntry } from './helpers/invoke_builder.mjs';

// The curve code loads on first use (lib/airdrop_v3.js cryptoReady); the synchronous helpers below need it.
before(cryptoReady);

test('the curve code never comes with the first paint: lib/airdrop_v3.js imports it only on first use', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../../src/lib/airdrop_v3.js', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /^import [^;]*vendor\/noble/m, 'no static import of the noble code');
});

const TXID = 'ab'.repeat(16);
const CREATOR = '7c'.repeat(32) + '01';
const OTHER = '5b'.repeat(32) + '00';
const REDEEMER = '3d'.repeat(32) + '00';
const hex = (b) => Buffer.from(b).toString('hex');

// ---------------------------------------------------------------- facts

test('the v3 contract and its app shader are pinned as the README states', () => {
  assert.equal(V3_CID, 'ac85d74b88aca36a8033f19b00b89df55e9c75a45c8a567c0ee158e9c11aeffe');
  assert.equal(V3_SHADER_ID, '3ed14be85bb30ae3755d9df426283612142265e978813d2ed9fabaf741515070');
  assert.equal(SHADERS.airdropV3.sha256, 'a61a8577bd450e33d01f1f0a788bea943b95836cb2b3e899353bc3b2c5ee69b8');
  assert.equal(SHADERS.airdropV3.size, 20019);
  const bytes = readFileSync(new URL('../../../assets/beam/shaders/airdrop_v3_app.wasm', import.meta.url));
  assert.equal(createHash('sha256').update(bytes).digest('hex'), SHADERS.airdropV3.sha256);
  // The old contract keeps its own shader.
  assert.equal(SHADERS.airdrop.sha256.slice(0, 8), 'cddf4a63');
  assert.notEqual(V3_CID, AIRDROP_CID);
  assert.deepEqual(V3_METHOD, { createBatch: 2, redeem: 3, cancelBatch: 4 });
  assert.equal(V3_MAX_VOUCHERS, 100);
});

test('network fees: claim 0.021, create and cancel by the README formulas, equal to what the core charges', () => {
  assert.equal(V3_CLAIM_FEE, 2100000n);
  const readme = (base, per, n) => {
    const v = 100000n + 10n * BigInt(base + per * n);
    return v > 1100000n ? v : 1100000n;
  };
  for (let n = 1; n <= 100; n++) {
    assert.equal(createFee(n), readme(115000, 30000, n), `create ${n}`);
    assert.equal(cancelFee(n), readme(35000, 28000, n), `cancel ${n}`);
    // lib/contract_tx.js entryFee is the core's get_FeeMin: the fee process_invoke_data pays.
    for (const spendAssets of [[0], [36, 0], [36]]) {
      assert.equal(createFee(n), entryFee({ argsBytes: 49 + 41 * n, spendAssets, charge: createCharge(n) }), `create ${n} ${spendAssets}`);
      assert.equal(cancelFee(n), entryFee({ argsBytes: 45 + 33 * n, spendAssets, charge: cancelCharge(n) }), `cancel ${n} ${spendAssets}`);
    }
  }
  assert.equal(V3_CLAIM_FEE, entryFee({ argsBytes: 139, spendAssets: [36, 0], charge: V3_CHARGE.redeem }));
  // The README's table.
  assert.equal(createFee(1), 1550000n);
  assert.equal(createFee(100), 31250000n);
  assert.equal(cancelFee(1), 1100000n);
  assert.equal(cancelFee(2), 1100000n);
  assert.equal(cancelFee(3), 1290000n);
  assert.equal(cancelFee(100), 28450000n);
  assert.equal(feeForUnits(100000), 1100000n);
  assert.equal(GAS_PER_VOUCHER, 2200000n);
  assert.ok(GAS_PER_VOUCHER >= V3_CLAIM_FEE, 'a prepaid fee covers the claim');
});

test('the 1% creation fee: v3 never wraps around; equal to the old rule wherever that one does not', () => {
  const U64 = (1n << 64n) - 1n;
  for (const t of [1n, 99n, 100n, 101n, 9999n, 10000n, 123456789n, 200000n, MAX_TOTAL]) assert.equal(v3CreationFee(t), creationFee(t), String(t));
  assert.equal(v3CreationFee(1n), 1n, 'never below 1 groth');
  assert.equal(v3CreationFee(U64), U64 / 100n, 'no overflow at 2^64 - 1');
  assert.throws(() => v3CreationFee(-1n), RangeError);
  assert.throws(() => v3CreationFee(U64 + 1n), RangeError);
});

// ---------------------------------------------------------------- seeds and keys

test('the seed: SHA-256("BeamAirdropV3:" || normalised code), the README test vector', () => {
  const v = '722f480abe6a26a479b9bdd177c979d320254787b2f24c11b618689c613ff8f3';
  assert.equal(hex(seedOf('ABCD-EFGH-JKLM-NPQR')), v);
  assert.equal(hex(seedOf('abcd efgh jklm npqr')), v);
  assert.equal(hex(seedOf(' Abcd_efgh.JKLM-npqr ')), v);
  assert.equal(hex(seedOf('ABCD-EFGH-JKLM-NPQR')), createHash('sha256').update('BeamAirdropV3:ABCDEFGHJKLMNPQR').digest('hex'));
  // Not the old contract's key for the same code (that hash is public on chain).
  assert.notEqual(hex(seedOf('ABCD-EFGH-JKLM-NPQR')), createHash('sha256').update('ABCDEFGHJKLMNPQR').digest('hex'));
});

test('normalising: as the v3 shader, refused and never truncated past 64 letters and digits', () => {
  assert.equal(normaliseV3('abcd-efgh jklm_npqr'), 'ABCDEFGHJKLMNPQR');
  assert.equal(normaliseV3('aßb'), 'AB', 'non-ASCII bytes are dropped');
  assert.equal(normaliseV3('A'.repeat(65)), 'A'.repeat(65), 'not cut');
  assert.equal(normaliseCode('A'.repeat(65)), 'A'.repeat(64), 'the old contract cuts at 64');
  assert.ok(isV3Code('A'.repeat(64)));
  assert.ok(!isV3Code('A'.repeat(65)));
  assert.ok(!isV3Code('----'));
  assert.ok(isV3Code('7'));
  assert.throws(() => seedOf('A'.repeat(65)), (e) => e.code === 'invalidCode');
  assert.throws(() => seedOf('- -'), (e) => e.code === 'invalidCode');
});

// Printed by the pinned v3 app shader (role=user,action=voucher_key) in the wallet engine, against
// mainnet, on 2026-10-13: the same seeds and keys this module derives. Both Y parities.
const SHADER_KEYS = [
  ['ABCD-EFGH-JKLM-NPQR', '2342225dbd5417975dd1d8b813abe5b9e5239c39f780ee6d4d113fed24c7a2ef01'],
  ['abcd efgh jklm npqr', '2342225dbd5417975dd1d8b813abe5b9e5239c39f780ee6d4d113fed24c7a2ef01'],
  ['7', 'bca7cab8c0518ea59df5726191fbd165076556dddeafe7b130787bfd721f422e01'],
  ['ZZZZ-ZZZZ-ZZZZ-ZZZZ', '221176133c612973a7721d85f99bc4355f205af81a481e52914ed17d8ff0404d01'],
  ['A2B3-C4D5-E6F7-G8H9', '07f09729a570295b57cabaa3ae21491f837b3044f41eb960e7846636df4dd22e01'],
  ['BBBB-BBBB-BBBB-BBBB', 'c0171b79e33b7fd9ea848261cd6eb614bbed9e22dbc28ed342a392792d0e735100'],
  ['CCCC-CCCC-CCCC-CCCC', '55d4cb0a7938ec2872081f9775775da1cd3034c92c0be362818c31254d93d65c00'],
  ['HHHH-HHHH-HHHH-HHHH', 'cc4d0ad546c5410ce65583d51e9ab956dbdd969ecf31e39543aae37266fcb97000'],
  ['DDDD-DDDD-DDDD-DDDD', '365daa3a9228e38233e0db97e94c87c23964e8bc927b78ff76ebbb69dbf9d91501'],
];
const SHADER_SEEDS = { '7': '74f16d9c8a33bd9c3f03cba97b9b11f86bc2105a1a10d3fcb9ed9d7785b961eb', 'ZZZZ-ZZZZ-ZZZZ-ZZZZ': '93e9ea885d30f00f6d152d742c99a1c232299efda350d45b0f21bfdca3a9f5c3', 'A2B3-C4D5-E6F7-G8H9': '29b5cb24aa9009a001439892f87ead3521f548f57ece53533ae5ce2463c4d3ba' };

test('voucher keys: the same as the pinned shader derives, for both Y parities; bound to the contract id', () => {
  for (const [code, key] of SHADER_KEYS) assert.equal(voucherKeyOf(code), key, code);
  for (const [code, seed] of Object.entries(SHADER_SEEDS)) assert.equal(hex(seedOf(code)), seed, code);
  assert.deepEqual(new Set(SHADER_KEYS.map(([, k]) => k.slice(-2))), new Set(['00', '01']));
  // Another deployment, another key for the same code.
  assert.notEqual(voucherKeyOf('ABCD-EFGH-JKLM-NPQR', AIRDROP_CID), SHADER_KEYS[0][1]);
  // The secret is SHA-256(tag || cid || seed) when that is a valid scalar (practically always).
  const seed = seedOf('ABCD-EFGH-JKLM-NPQR');
  const want = createHash('sha256').update(Buffer.concat([Buffer.from('BeamAirdropV3.key'), Buffer.from(V3_CID, 'hex'), Buffer.from(seed)])).digest('hex');
  assert.equal(hex(secretOf(seed)), want);
  assert.throws(() => secretOf(new Uint8Array(31)), RangeError);
});

// ---------------------------------------------------------------- args

test('arguments: every action names v3 and every argument; the pool is never asked; no fee is passed', () => {
  const c = `cid=${V3_CID}`;
  assert.equal(v3args.redeem({ normalised: 'ABCDEFGHJKLMNPQR' }), `role=user,action=redeem,${c},code=ABCDEFGHJKLMNPQR,use_gas_pool=0`);
  assert.equal(v3args.checkVoucher({ normalised: 'ABCDEFGHJKLMNPQR' }), `role=user,action=check_voucher,${c},code=ABCDEFGHJKLMNPQR`);
  assert.equal(v3args.voucherKey({ normalised: '7' }), `role=user,action=voucher_key,${c},code=7`);
  assert.equal(v3args.viewMyBatches(), `role=user,action=view_my_batches,${c}`);
  assert.equal(v3args.viewBatch({ batchId: 12n }), `role=user,action=view_batch,${c},batch_id=12`);
  assert.equal(v3args.cancelBatch({ batchId: 5n }), `role=user,action=cancel_batch,${c},batch_id=5`);
  const s1 = seedOf('ABCD-EFGH-JKLM-NPQR');
  const s2 = seedOf('ZZZZ-ZZZZ-ZZZZ-ZZZZ');
  assert.equal(
    v3args.createBatch({ assetId: 36, gasPerVoucher: GAS_PER_VOUCHER, entries: [{ seed: s1, value: 100000n }, { seed: s2, value: 100000n }] }),
    `role=user,action=create_batch,${c},asset_id=36,count=2,gas_per_voucher=2200000,seeds=${hex(s1)}a086010000000000${hex(s2)}a086010000000000`,
  );
  assert.match(v3args.createBatch({ assetId: 0, gasPerVoucher: 0n, entries: [{ seed: s1, value: 1n }] }), /,gas_per_voucher=0,/);
  for (const a of Object.values(v3args)) assert.doesNotMatch(String(a.toString()), /sponsor_gas|withdraw|set_gas_policy|pause|role=manager/);
  for (const bad of ['ABCD-EFGH', 'abcd', '', 'A'.repeat(65), 'A,B=C', 'ÄB']) assert.throws(() => v3args.redeem({ normalised: bad }), RangeError, bad);
});

test('the prepaid claim fee is 0 or exactly 0.022 BEAM; a batch is 1 to 100 distinct codes', () => {
  assert.equal(gasArg(0n), 0n);
  assert.equal(gasArg(2200000n), 2200000n);
  for (const g of [1n, 2099999n, 2100000n, 2199999n, 2200001n, 10000000n]) assert.throws(() => gasArg(g), RangeError, String(g));
  const e = (i, v = 1n) => ({ seed: seedOf(`CODE${i}`), value: v });
  assert.equal(seedsBlob(Array.from({ length: 100 }, (_, i) => e(i))).length, 4000);
  assert.throws(() => seedsBlob(Array.from({ length: 101 }, (_, i) => e(i))), RangeError);
  assert.throws(() => seedsBlob([]), RangeError);
  assert.throws(() => seedsBlob([e(1), e(1)]), RangeError, 'repeated code');
  assert.throws(() => seedsBlob([e(1, 0n)]), RangeError, 'zero value');
  assert.throws(() => seedsBlob([{ seed: new Uint8Array(31), value: 1n }]), RangeError);
});

// ---------------------------------------------------------------- answers

test('answers: a voucher, my batches (truncated), one batch, voucher_key; anything malformed is refused', () => {
  const key = SHADER_KEYS[0][1];
  const v = parseV3Voucher(parseShaderJson(`{"voucher": {"key": "${key}", "batch_id": 4, "asset_id": 36, "value": 100000, "gas": 2200000, "redeemed": 0, "pool_gas": 0, "claim_fee": 2100000}}`));
  assert.deepEqual(v, { contract: 'v3', key, batchId: 4n, assetId: 36, value: 100000n, gas: 2200000n, redeemed: false, redeemedAtHeight: null });
  const r = parseV3Voucher({ voucher: { key, batch_id: 4, asset_id: 0, value: '18446744073709551615', gas: 0, redeemed: 1, redeemed_at: 4080000 } });
  assert.equal(r.value, (1n << 64n) - 1n);
  assert.equal(r.redeemedAtHeight, 4080000n);
  for (const bad of [{ voucher: { ...v, key: 'xyz', batch_id: 1, asset_id: 0, value: 1, gas: 0, redeemed: 0 } }, { voucher: { key, batch_id: 1, asset_id: 0, value: 1, gas: 0, redeemed: 2 } }, { voucher: { key, batch_id: 1, asset_id: 2 ** 32, value: 1, gas: 0, redeemed: 0 } }, {}]) {
    assert.throws(() => parseV3Voucher(bad), (e) => e.code === 'unexpected');
  }
  const b = parseV3Batches({ batches: [{ id: 7, asset_id: 36, created: 10, unclaimed: 6, redeemed: 3, cancelled: 1, value_unclaimed: 600000, gas_per_voucher: 2200000, created_at: 4079000 }], truncated: 1 });
  assert.equal(b.truncated, true);
  assert.deepEqual(b.batches[0], { id: 7n, assetId: 36, created: 10, unclaimed: 6, redeemed: 3, cancelled: 1, valueUnclaimed: 600000n, gasPerVoucher: 2200000n, createdAtHeight: 4079000n });
  // The shader computes cancelled = created - unclaimed - redeemed in 32 bits: a wrap is refused.
  assert.throws(() => parseV3Batches({ batches: [{ id: 7, asset_id: 36, created: 1, unclaimed: 2, redeemed: 0, cancelled: 4294967295, value_unclaimed: 1, gas_per_voucher: 0, created_at: 1 }], truncated: 0 }), (e) => e.code === 'unexpected');
  const one = parseV3Batch({ batch: { creator: CREATOR, asset_id: 36, created: 1, gas_per_voucher: 0, created_at: 5, vouchers: [{ key, batch_id: 7, asset_id: 36, value: 9, gas: 0, redeemed: 0 }] } });
  assert.equal(one.creator, CREATOR);
  assert.equal(one.vouchers[0].key, key);
  assert.deepEqual(parseVoucherKey({ seed: SHADER_SEEDS['7'], key: SHADER_KEYS[2][1] }), { seed: SHADER_SEEDS['7'], key: SHADER_KEYS[2][1] });
  assert.throws(() => parseVoucherKey({ seed: 'ab', key }), (e) => e.code === 'unexpected');
});

test('the shader\'s error texts become codes and plain words', () => {
  assert.equal(v3CodeFor('voucher not found'), 'voucherNotFound');
  assert.equal(v3CodeFor('voucher already redeemed'), 'alreadyRedeemed');
  assert.equal(v3CodeFor('this wallet did not create the batch'), 'notBatchCreator');
  assert.equal(v3CodeFor('no unclaimed vouchers in this batch'), 'nothingToCancel');
  assert.equal(v3CodeFor('contract is paused: no new batches'), 'paused');
  assert.equal(v3CodeFor('code is longer than 64 letters and digits'), 'invalidCode');
  assert.equal(v3CodeFor('no Airdrop v3 contract at this cid (shader ID does not match)'), 'contractNotFound');
  assert.equal(v3CodeFor('this cid is not derived from the Airdrop v3 shader ID and its owner: refusing'), 'contractNotFound');
  assert.equal(v3CodeFor('something new'), 'shaderError');
  const m = mapV3Error(Object.assign(new Error('contract is paused: no new batches'), { code: 'shader' }));
  assert.equal(m.code, 'paused');
  assert.match(m.message, /Claims and take-backs still work/);
});

test('what a claim costs: a code with its fee paid needs no BEAM; others say how much', () => {
  const token = { contract: 'v3', assetId: 36, value: 100000n };
  assert.deepEqual(claimCost({ ...token, gas: 2200000n }), { fee: 2100000n, gas: 2200000n, beamIn: 2200000n, need: 0n, beamChange: 100000n, codePaysFee: true });
  assert.deepEqual(claimCost({ ...token, gas: 0n }), { fee: 2100000n, gas: 0n, beamIn: 0n, need: 2100000n, beamChange: -2100000n, codePaysFee: false });
  assert.equal(claimCost({ contract: 'v3', assetId: 0, value: 1000000n, gas: 0n }).need, 1100000n, 'a small BEAM code needs the rest');
  assert.equal(claimCost({ contract: 'v3', assetId: 0, value: 50000000n, gas: 0n }).need, 0n, 'a BEAM code worth more than the fee pays it');
  assert.equal(claimCost({ contract: 'v3', assetId: 0, value: 1n, gas: 2200000n }).beamChange, 100001n);
  assert.equal(claimCost({ contract: 'v2', assetId: 174, value: 1n, gas: 0n }).fee, CALL_FEE, 'the old contract: 0.121');
});

// ---------------------------------------------------------------- the check before sharing

/** A saved v3 batch of `n` codes of `value` with `gas` prepaid, as the service writes it. */
function savedV3(n = 3, { value = '100000', gas = '2200000', assetId = 36, creatorKey = CREATOR } = {}) {
  const codes = Array.from({ length: n }, (_, i) => {
    const code = `AAAA-BBBB-CCCC-DD${String.fromCharCode(65 + i)}${String.fromCharCode(66 + i)}`;
    return { code, key: voucherKeyOf(code), value, status: 'unknown' };
  });
  return { assetId, gasPerVoucher: gas, creatorKey, codes };
}
/** The chain as check_voucher / view_my_batches / view_batch would answer for that batch under `batchId`. */
function chainFor(batch, { batchId = 9n, truncated = false, listed = true, creator = CREATOR, others = [], override = () => null } = {}) {
  const info = (c, i) => override(c, i) || { contract: 'v3', key: c.key, batchId, assetId: batch.assetId, value: BigInt(c.value), gas: BigInt(batch.gasPerVoucher), redeemed: false };
  const looked = [];
  return {
    looked,
    lookup: async (code) => {
      const i = batch.codes.findIndex((c) => c.code === code);
      looked.push(i);
      return i < 0 ? null : info(batch.codes[i], i);
    },
    // others: [id, creator] of batches the list does show (this wallet's, so their creator is its key).
    myBatches: async () => ({ batches: [...(listed ? [{ id: batchId, assetId: batch.assetId, created: batch.codes.length, unclaimed: batch.codes.length, redeemed: 0, cancelled: 0, valueUnclaimed: 0n, gasPerVoucher: BigInt(batch.gasPerVoucher), createdAtHeight: 4080000n }] : []), ...others.map(([id]) => ({ id, assetId: 0, created: 1, unclaimed: 1, redeemed: 0, cancelled: 0, valueUnclaimed: 1n, gasPerVoucher: 0n, createdAtHeight: 1n }))], truncated }),
    viewBatch: async (id) => {
      if (id === batchId) return { creator, assetId: batch.assetId, created: batch.codes.length, gasPerVoucher: BigInt(batch.gasPerVoucher), createdAtHeight: 4080000n, vouchers: [] };
      const o = others.find(([x]) => x === id);
      if (o) return { creator: o[1], assetId: 0, created: 1, gasPerVoucher: 0n, createdAtHeight: 1n, vouchers: [] };
      throw Object.assign(new Error('batch not found'), { code: 'batchNotFound' });
    },
  };
}

test('check before sharing: every code found with its key, value and fee, in one batch this wallet lists', async () => {
  const batch = savedV3(4);
  const ch = chainFor(batch);
  const seen = [];
  assert.deepEqual(await squatCheck({ batch, ...ch, onProgress: (d, t) => seen.push(`${d}/${t}`) }), { ok: true, batchId: 9n });
  assert.deepEqual(ch.looked, [0, 1, 2, 3], 'check_voucher on every code');
  assert.deepEqual(seen, ['1/4', '2/4', '3/4', '4/4']);
  // A claimed code is still this batch's.
  assert.equal((await squatCheck({ batch, ...chainFor(batch, { override: (c) => ({ contract: 'v3', key: c.key, batchId: 9n, assetId: 36, value: 100000n, gas: 2200000n, redeemed: true }) }) })).ok, true);
});

test('check before sharing: a squatted batch, and every way a code can point elsewhere, fail with the reason', async () => {
  const batch = savedV3(3);
  const run = (opts) => squatCheck({ batch, ...chainFor(batch, opts) });
  // The copycat's batch holds our keys with tiny values: the real create failed, the codes point there.
  assert.deepEqual(await run({ override: (c) => ({ contract: 'v3', key: c.key, batchId: 12n, assetId: 36, value: 1n, gas: 0n, redeemed: false }) }), { ok: false, problem: 'otherValue', index: 0 });
  const missing = chainFor(batch);
  missing.lookup = async (code) => (code === batch.codes[1].code ? null : { contract: 'v3', key: batch.codes.find((c) => c.code === code).key, batchId: 9n, assetId: 36, value: 100000n, gas: 2200000n, redeemed: false });
  assert.deepEqual(await squatCheck({ batch, ...missing }), { ok: false, problem: 'notFound', index: 1 });
  assert.deepEqual(await run({ override: (c, i) => (i === 1 ? { contract: 'v3', key: OTHER, batchId: 9n, assetId: 36, value: 100000n, gas: 2200000n, redeemed: false } : null) }), { ok: false, problem: 'otherKey', index: 1 });
  assert.deepEqual(await run({ override: (c, i) => (i === 2 ? { contract: 'v3', key: c.key, batchId: 9n, assetId: 37, value: 100000n, gas: 2200000n, redeemed: false } : null) }), { ok: false, problem: 'otherValue', index: 2 });
  assert.deepEqual(await run({ override: (c, i) => (i === 0 ? { contract: 'v3', key: c.key, batchId: 9n, assetId: 36, value: 100000n, gas: 0n, redeemed: false } : null) }), { ok: false, problem: 'otherValue', index: 0 }, 'the prepaid fee too');
  assert.deepEqual(await run({ override: (c, i) => (i === 2 ? { contract: 'v3', key: c.key, batchId: 10n, assetId: 36, value: 100000n, gas: 2200000n, redeemed: false } : null) }), { ok: false, problem: 'otherBatch', index: 2 });
  assert.deepEqual(await run({ listed: false }), { ok: false, problem: 'notMine', index: null }, 'a batch view_my_batches does not list is not this wallet\'s');
  // The listed batch must be the one made: its count, asset and prepaid fee.
  const ch = chainFor(batch);
  const real = ch.myBatches;
  ch.myBatches = async () => {
    const m = await real();
    return { ...m, batches: [{ ...m.batches[0], created: 4 }] };
  };
  assert.deepEqual(await squatCheck({ batch, ...ch }), { ok: false, problem: 'otherBatch', index: null });
  for (const k of ['notFound', 'otherKey', 'otherValue', 'otherBatch', 'notMine']) assert.ok(CHECK_PROBLEM_TEXT[k], k);
});

test('check before sharing: a truncated list is settled by view_batch and this wallet\'s creator key', async () => {
  const batch = savedV3(2);
  const mineListed = [[3n, CREATOR]];
  // view_my_batches lists 200 of this wallet's batches, not this one: view_batch must name this wallet.
  assert.deepEqual(await squatCheck({ batch, ...chainFor(batch, { listed: false, truncated: true, others: mineListed }) }), { ok: true, batchId: 9n });
  assert.deepEqual(await squatCheck({ batch, ...chainFor(batch, { listed: false, truncated: true, others: mineListed, creator: OTHER }) }), { ok: false, problem: 'notMine', index: null });
  // The key comes from the build (saved with the batch), or from a batch the list shows (README checklist 11).
  assert.deepEqual(await squatCheck({ batch: { ...batch, creatorKey: null }, ...chainFor(batch, { listed: false, truncated: true, others: mineListed }) }), { ok: true, batchId: 9n });
  assert.deepEqual(await squatCheck({ batch, ...chainFor(batch, { listed: false, truncated: true }) }), { ok: true, batchId: 9n });
  assert.deepEqual(await squatCheck({ batch: { ...batch, creatorKey: null }, ...chainFor(batch, { listed: false, truncated: true }) }), { ok: false, problem: 'notMine', index: null }, 'no creator key to compare: not proven');
  // The two sources disagree: not proven.
  assert.deepEqual(await squatCheck({ batch, ...chainFor(batch, { listed: false, truncated: true, others: [[3n, OTHER]] }) }), { ok: false, problem: 'notMine', index: null });
  const gone = chainFor(batch, { listed: false, truncated: true });
  gone.viewBatch = async () => Promise.reject(Object.assign(new Error('batch not found'), { code: 'batchNotFound' }));
  assert.deepEqual(await squatCheck({ batch, ...gone }), { ok: false, problem: 'notMine', index: null });
  // Listed when truncated: the list answers, view_batch is not needed.
  const listed = chainFor(batch, { truncated: true });
  listed.viewBatch = async () => assert.fail('not asked');
  assert.equal((await squatCheck({ batch, ...listed })).ok, true);
  // A lookup that fails is not a verdict: it throws.
  const down = chainFor(batch);
  down.lookup = async () => Promise.reject(Object.assign(new Error('node down'), { code: 'timeout' }));
  await assert.rejects(squatCheck({ batch, ...down }), (e) => e.code === 'timeout');
});

// ---------------------------------------------------------------- a fake v3 contract

/** Answers like the pinned v3 app shader, from an in-memory contract. */
function fakeV3({ creator = CREATOR } = {}) {
  const st = { vouchers: new Map(), batches: new Map(), next: 1n, seen: [], tamper: null, signed: 0, truncated: false, outputTamper: null, pool: 0n };
  const parse = (a) => Object.fromEntries(a.split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
  const built = (e) => (st.tamper ? st.tamper(e) : e);
  const raw = (e) => invokeData([invokeEntry({ contractId: e.cid || V3_CID, method: e.method, args: e.args, sigs: Array(e.sigs || 1).fill('11'.repeat(32)), charge: e.charge, comment: e.comment, spend: Object.fromEntries([...e.funds].map(([k, v]) => [k, v])) })], {});
  const funds = (aid, value, gas, sign) => {
    const m = new Map();
    const add = (k, v) => v && m.set(k, (m.get(k) || 0n) + sign * v);
    add(aid, value);
    add(0, gas);
    return m;
  };
  const voucherOut = (key, v) => ({ voucher: { key, batch_id: Number(v.batchId), asset_id: v.assetId, value: Number(v.value), gas: Number(v.gas), redeemed: v.redeemed ? 1 : 0, ...(v.redeemed ? { redeemed_at: 4080001 } : { pool_gas: 0, claim_fee: 2100000 }) } });
  /** What a mined create does: the vouchers exist, under a new batch of this creator. */
  st.mine = (pending) => {
    const id = st.next++;
    st.batches.set(id, { creator: pending.creator, assetId: pending.aid, created: pending.entries.length, gas: pending.gas });
    for (const e of pending.entries) st.vouchers.set(e.key, { batchId: id, assetId: pending.aid, value: e.value, gas: pending.gas, redeemed: false });
    return id;
  };
  st.answer = async (a) => {
    st.seen.push(a);
    const p = parse(a);
    if (p.cid !== V3_CID) return { output: '{"error": "no Airdrop v3 contract at this cid (shader ID does not match)"}' };
    switch (`${p.role}:${p.action}`) {
      case 'user:check_voucher': {
        const key = voucherKeyOf(p.code);
        const v = st.vouchers.get(key);
        return { output: JSON.stringify(v ? voucherOut(key, v) : { error: 'voucher not found' }) };
      }
      case 'user:voucher_key':
        return { output: JSON.stringify({ seed: hex(seedOf(p.code)), key: voucherKeyOf(p.code) }) };
      case 'user:view_my_batches': {
        const rows = [...st.batches].filter(([, b]) => b.creator === creator).map(([id, b]) => {
          const of = [...st.vouchers.values()].filter((v) => v.batchId === id);
          const open = of.filter((v) => !v.redeemed);
          const redeemed = of.length - open.length;
          return { id: Number(id), asset_id: b.assetId, created: b.created, unclaimed: open.length, redeemed, cancelled: b.created - open.length - redeemed, value_unclaimed: Number(open.reduce((s, v) => s + v.value, 0n)), gas_per_voucher: Number(b.gas), created_at: 4080000 };
        });
        return { output: JSON.stringify({ batches: rows, truncated: st.truncated ? 1 : 0 }) };
      }
      case 'user:view_batch': {
        const b = st.batches.get(BigInt(p.batch_id));
        if (!b) return { output: '{"error": "batch not found"}' };
        return { output: JSON.stringify({ batch: { creator: b.creator, asset_id: b.assetId, created: b.created, gas_per_voucher: Number(b.gas), created_at: 4080000, vouchers: [...st.vouchers].filter(([, v]) => v.batchId === BigInt(p.batch_id)).map(([k, v]) => voucherOut(k, v).voucher) } }) };
      }
      case 'user:create_batch': {
        const aid = Number(p.asset_id);
        const n = Number(p.count);
        const gas = BigInt(p.gas_per_voucher);
        const blob = fromHex(p.seeds);
        const entries = [];
        for (let i = 0; i < n; i++) {
          const seed = blob.subarray(40 * i, 40 * i + 32);
          let v = 0n;
          for (let j = 7; j >= 0; j--) v = (v << 8n) | BigInt(blob[40 * i + 32 + j]);
          const x = secretOf(seed);
          const { secp256k1 } = await import('../../src/vendor/noble/noble-curves/secp256k1.js');
          const pub = secp256k1.getPublicKey(x, true);
          entries.push({ key: hex(pub.subarray(1)) + (pub[0] === 3 ? '01' : '00'), value: v });
        }
        const total = entries.reduce((s, e) => s + e.value, 0n);
        const fee = v3CreationFee(total);
        st.pending = { creator, aid, gas, entries };
        const args = [...fromHex(creator), ...le(aid, 4), ...le(n, 4), ...le(gas, 8), ...entries.flatMap((e) => [...fromHex(e.key), ...le(e.value, 8)])];
        const out = { total: Number(total), fee: Number(fee), gas_total: Number(gas * BigInt(n)) };
        return { output: JSON.stringify(st.outputTamper ? st.outputTamper(out) : out), raw_data: raw(built({ method: 2, args, funds: funds(aid, total + fee, gas * BigInt(n), 1n), comment: V3_KERNEL.createBatch, charge: createCharge(n) })) };
      }
      case 'user:redeem': {
        const key = voucherKeyOf(p.code);
        const v = st.vouchers.get(key);
        if (!v) return { output: '{"error": "voucher not found"}' };
        if (v.redeemed) return { output: '{"error": "voucher already redeemed"}' };
        const args = [...fromHex(key), ...fromHex(REDEEMER), ...le(st.pool, 8), ...Array(65).fill(0x42)];
        return { output: JSON.stringify({ asset_id: v.assetId, value: Number(v.value), gas: Number(v.gas), gas_source: v.gas ? 'voucher' : 'none' }), raw_data: raw(built({ method: 3, args, funds: funds(v.assetId, v.value, v.gas, -1n), comment: V3_KERNEL.redeem, charge: V3_CHARGE.redeem, code: p.code })) };
      }
      case 'user:cancel_batch': {
        const id = BigInt(p.batch_id);
        const b = st.batches.get(id);
        if (!b) return { output: '{"error": "batch not found"}' };
        if (b.creator !== creator) return { output: '{"error": "this wallet did not create the batch"}' };
        const open = [...st.vouchers].filter(([, v]) => v.batchId === id && !v.redeemed);
        if (!open.length) return { output: '{"error": "no unclaimed vouchers in this batch"}' };
        const value = open.reduce((s, [, v]) => s + v.value, 0n);
        const gas = open.reduce((s, [, v]) => s + v.gas, 0n);
        const args = [...fromHex(creator), ...le(id, 8), ...le(open.length, 4), ...open.flatMap(([k]) => [...fromHex(k)])];
        return { output: JSON.stringify({ cancelled: open.length, value: Number(value), gas: Number(gas) }), raw_data: raw(built({ method: 4, args, funds: funds(b.assetId, value, gas, -1n), comment: V3_KERNEL.cancelBatch, charge: cancelCharge(open.length) })) };
      }
      default:
        return { output: '{"error": "unknown role or action"}' };
    }
  };
  return st;
}

const memoryKv = () => {
  const m = new Map();
  return { m, get: async (k) => (m.has(k) ? structuredClone(m.get(k)) : undefined), set: async (k, v) => void m.set(k, structuredClone(v)) };
};

/** The v3 service over a fake contract, as lib/contracts.js would run it: inspect, then the sheet's request. */
function service(st, { vault = null, consent = null, sendError = null, beforeSign = null, txStatus = null, lock = null, tipHeight = null } = {}) {
  const v = vault || codeVault({ kv: memoryKv(), walletId: 'w1', secret: 'ab'.repeat(32) });
  const shaderErr = (o) => {
    if (o && typeof o === 'object' && 'error' in o) throw Object.assign(new Error(String(o.error)), { code: 'shader' });
    return o;
  };
  const transacted = [];
  const svc = createAirdropV3({
    view: async (a) => {
      const r = await st.answer(a);
      if (r.raw_data) throw Object.assign(new Error('A read-only call produced a transaction.'), { code: 'unexpected' });
      return shaderErr(parseShaderJson(r.output));
    },
    transact: async (a, { inspect, expect, intent }) => {
      const r = await st.answer(a);
      const output = shaderErr(parseShaderJson(r.output));
      let refused = null;
      try {
        refused = await inspect(Uint8Array.from(r.raw_data), output);
      } catch (e) {
        throw Object.assign(new Error(e.message), { code: 'unexpected' });
      }
      if (refused) throw Object.assign(new Error(refused.message || String(refused)), { code: refused.code || 'refused' });
      const d = readContractTx(r.raw_data);
      const req = consent ? consent(d) : { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
      const problem = expect(req);
      if (problem) throw Object.assign(new Error(problem.message), { code: problem.code });
      if (beforeSign) await beforeSign();
      if (sendError) throw sendError;
      st.signed++;
      transacted.push({ args: a, intent, raw: r.raw_data, d });
      return TXID;
    },
    vault: async () => v,
    txStatus,
    lock,
    tipHeight,
  });
  return { svc, vault: v, transacted };
}

// ---------------------------------------------------------------- create

test('create: v3 only, keys derived here equal the built ones, prepaid fees locked, codes saved first with the creator key', async () => {
  const st = fakeV3();
  let atSign = null;
  const { svc, vault, transacted } = service(st, { beforeSign: async () => (atSign = await vault.all()) });
  const r = await svc.createBatch({ assetId: 36, values: [100000n, 100000n, 100000n], gas: true });
  assert.equal(r.txId, TXID);
  assert.equal(r.total, 300000n);
  assert.equal(r.fee, 3000n);
  assert.equal(r.gasTotal, 6600000n);
  assert.deepEqual([...r.built.pays], [[0, 6600000n], [36, 303000n]].sort((a, b) => a[0] - b[0]));
  assert.equal(r.built.fee, createFee(3));
  assert.equal(r.built.entries[0].contractId, V3_CID);
  assert.equal(atSign.length, 1, 'saved before the wallet signed');
  assert.equal(atSign[0].creatorKey, CREATOR, 'with the creator key the batch was built with');
  const saved = (await vault.all())[0];
  assert.equal(saved.contractId, V3_CID);
  assert.equal(saved.gasPerVoucher, '2200000');
  assert.equal(saved.txStatus, TX_STATUS.broadcast);
  assert.equal(saved.check, null);
  for (const c of saved.codes) {
    assert.match(c.code, /^([A-HJ-NP-Z2-9]{4}-){3}[A-HJ-NP-Z2-9]{4}$/, '16 symbols, 80 bits');
    assert.equal(c.key, voucherKeyOf(c.code));
    assert.equal(c.hash, await codeHash(c.code));
  }
  // The shader got seeds, never the codes; the transaction carries keys, never seeds or codes.
  const sent = transacted[0].args;
  const rawHex = hex(transacted[0].raw);
  for (const c of saved.codes) {
    assert.ok(!sent.includes(normaliseCode(c.code)));
    assert.ok(sent.includes(hex(seedOf(c.code))));
    assert.ok(!rawHex.includes(hex(seedOf(c.code))), 'no seed on chain');
    assert.ok(rawHex.includes(c.key), 'its key on chain');
  }
  assert.match(transacted[0].intent.notes[0], /^0\.066 BEAM of this pays the claim fee of each code/);
});

test('create: without prepaid fees no BEAM is locked for a token; a BEAM batch locks one sum; 1 to 100 codes', async () => {
  const st = fakeV3();
  const { svc } = service(st);
  const off = await svc.createBatch({ assetId: 36, values: [5n], gas: false });
  assert.deepEqual([...off.built.pays], [[36, 6n]]);
  const beam = await svc.createBatch({ assetId: 0, values: [1000000n, 1000000n], gas: true });
  assert.deepEqual([...beam.built.pays], [[0, 2000000n + 20000n + 4400000n]]);
  const hundred = await svc.createBatch({ assetId: 36, values: Array(100).fill(1n), gas: true });
  assert.equal(hundred.batch.codes.length, 100);
  assert.equal(new Set(hundred.batch.codes.map((c) => c.key)).size, 100);
  assert.equal(hundred.built.fee, 31250000n);
  await assert.rejects(svc.createBatch({ assetId: 36, values: Array(101).fill(1n) }), RangeError);
  await assert.rejects(svc.createBatch({ assetId: 36, values: [] }), RangeError);
  await assert.rejects(svc.createBatch({ assetId: 0, values: [(1n << 63n) - 1n] }), RangeError, 'more than the engine can carry');
});

test('create: a build that differs from the request in any way is never signed, and nothing is saved', async () => {
  const keyAt = 49;
  const cases = {
    'another contract': (e) => ({ ...e, cid: 'ee'.repeat(32) }),
    'another method': (e) => ({ ...e, method: 3 }),
    'another voucher key': (e) => ({ ...e, args: [...e.args.slice(0, keyAt), ...fromHex(OTHER), ...e.args.slice(keyAt + 33)] }),
    'another value': (e) => ({ ...e, args: [...e.args.slice(0, keyAt + 33), ...le(100001n, 8), ...e.args.slice(keyAt + 41)] }),
    'no prepaid fee in the args': (e) => ({ ...e, args: [...e.args.slice(0, 41), ...le(0n, 8), ...e.args.slice(49)] }),
    'another asset in the args': (e) => ({ ...e, args: [...e.args.slice(0, 33), ...le(37, 4), ...e.args.slice(37)] }),
    'more locked': (e) => ({ ...e, funds: new Map([...e.funds].map(([k, v]) => [k, v + 1n])) }),
    'the prepaid fees not locked': (e) => ({ ...e, funds: new Map([...e.funds].filter(([k]) => k !== 0)) }),
    'another asset as well': (e) => ({ ...e, funds: new Map([...e.funds, [7, 1n]]) }),
    'a different BVM charge': (e) => ({ ...e, charge: e.charge + 1 }),
    'the old contract\'s charge': (e) => ({ ...e, charge: 1200000 }),
    'another kernel comment': (e) => ({ ...e, comment: 'Redeem airdrop voucher' }),
    'two signing keys': (e) => ({ ...e, sigs: 2 }),
  };
  for (const [what, tamper] of Object.entries(cases)) {
    const st = fakeV3();
    st.tamper = tamper;
    const { svc, vault } = service(st);
    await assert.rejects(svc.createBatch({ assetId: 36, values: [100000n, 100000n], gas: true }), (e) => e.code === 'unexpected', what);
    assert.equal(st.signed, 0, what);
    assert.equal((await vault.all()).length, 0, `${what}: nothing saved for a transaction never shown`);
  }
  const st = fakeV3();
  st.outputTamper = (o) => ({ ...o, gas_total: 0 });
  await assert.rejects(service(st).svc.createBatch({ assetId: 36, values: [100000n], gas: true }), (e) => e.code === 'unexpected', 'the shader says other totals');
});

test('create: the sheet must show the built figures; declined keeps the codes as never sent; a timeout keeps them unconfirmed', async () => {
  const wrongFee = (d) => ({ kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [], fee: d.fee + 1n });
  let s = service(fakeV3(), { consent: wrongFee });
  await assert.rejects(s.svc.createBatch({ assetId: 36, values: [1n] }), (e) => e.code === 'unexpected');
  assert.equal((await s.vault.all())[0].txStatus, TX_STATUS.failed);
  s = service(fakeV3(), { sendError: Object.assign(new Error('Cancelled. Nothing was sent.'), { code: 'rejected' }) });
  await assert.rejects(s.svc.createBatch({ assetId: 36, values: [1n] }), (e) => e.code === 'rejected');
  assert.equal((await s.vault.all())[0].txStatus, TX_STATUS.failed);
  s = service(fakeV3(), { sendError: Object.assign(new Error('The wallet did not answer in time.'), { code: 'timeout' }) });
  await assert.rejects(s.svc.createBatch({ assetId: 36, values: [1n] }), (e) => e.code === 'timeout');
  assert.equal((await s.vault.all())[0].txStatus, TX_STATUS.unconfirmed);
});

// ---------------------------------------------------------------- the check, through the service

test('verify: waits for 3 confirmations, then checks every code and saves the verdict once', async () => {
  const st = fakeV3();
  let tx = { status: 1 };
  const { svc, vault } = service(st, { txStatus: async () => tx });
  const { batch } = await svc.createBatch({ assetId: 36, values: [100000n, 100000n], gas: true });
  assert.deepEqual(await stateOf(svc.verifyBatch(batch.localId)), { state: 'waiting', confirmations: 0 });
  st.mine(st.pending);
  tx = { status: 3, confirmations: CONFIRMATIONS_BEFORE_CHECK - 1 };
  assert.deepEqual(await stateOf(svc.verifyBatch(batch.localId)), { state: 'waiting', confirmations: 2 });
  assert.equal(st.seen.filter((a) => a.includes('check_voucher')).length, 0, 'no lookups before the batch is confirmed enough');
  tx = { status: 3, confirmations: CONFIRMATIONS_BEFORE_CHECK };
  const progress = [];
  const r = await svc.verifyBatch(batch.localId, { onProgress: (d, t) => progress.push(`${d}/${t}`) });
  assert.equal(r.state, 'ready');
  assert.deepEqual(progress, ['0/2', '1/2', '2/2']);
  assert.equal(st.seen.filter((a) => a.includes('check_voucher')).length, 2, 'check_voucher on every code');
  const saved = (await vault.all())[0];
  assert.equal(saved.check.state, CHECK_STATE.ok);
  assert.equal(saved.batchId, '1');
  assert.equal(saved.txStatus, TX_STATUS.confirmed);
  assert.ok(saved.codes.every((c) => c.status === CODE_STATUS.available));
  const n = st.seen.length;
  assert.equal((await svc.verifyBatch(batch.localId)).state, 'ready');
  assert.deepEqual(st.seen.slice(n).map((a) => a.match(/action=(\w+)/)[1]), ['view_batch'], 'a checked batch is not checked again: one read of where its codes stand');
});

test('a checked batch shows its codes as the network has them now: claimed, taken back, still claimable (release audit 0.2.16)', async () => {
  const st = fakeV3();
  const { svc, vault } = service(st, { txStatus: async () => ({ status: 3, confirmations: CONFIRMATIONS_BEFORE_CHECK }) });
  const { batch } = await svc.createBatch({ assetId: 36, values: [100000n, 100000n, 100000n], gas: true });
  st.mine(st.pending);
  assert.equal((await svc.verifyBatch(batch.localId)).state, 'ready');
  const [k0, k1] = (await vault.all())[0].codes.map((c) => c.key);
  st.vouchers.get(k0).redeemed = true;
  st.vouchers.delete(k1);
  const r = await svc.verifyBatch(batch.localId);
  assert.equal(r.state, 'ready');
  assert.deepEqual(r.batch.codes.map((c) => c.status), [CODE_STATUS.claimed, CODE_STATUS.takenBack, CODE_STATUS.available]);
  assert.deepEqual((await vault.all())[0].codes.map((c) => c.status), [CODE_STATUS.claimed, CODE_STATUS.takenBack, CODE_STATUS.available], 'saved');
  // A read that fails keeps what was saved; it never turns a batch into "not ready" or loses its codes.
  const real = st.answer;
  st.answer = async (a) => (a.includes('view_batch') ? Promise.reject(Object.assign(new Error('node down'), { code: 'timeout' })) : real(a));
  const again = await svc.verifyBatch(batch.localId);
  assert.equal(again.state, 'ready');
  assert.deepEqual(again.batch.codes.map((c) => c.status), [CODE_STATUS.claimed, CODE_STATUS.takenBack, CODE_STATUS.available]);
  st.answer = real;
});

test('a batch found without its transaction id still waits its confirmations, counted from its block (release audit 0.2.16)', async () => {
  const st = fakeV3();
  let tip = 4080001; // the fake records created_at 4080000: the kernel's block is 4080001
  const s = service(st, { sendError: Object.assign(new Error('The wallet did not answer in time.'), { code: 'timeout' }), txStatus: async () => assert.fail('no tx id to ask about'), tipHeight: async () => tip });
  await assert.rejects(s.svc.createBatch({ assetId: 36, values: [100000n] }));
  st.mine(st.pending);
  const rec = (await s.vault.all())[0];
  assert.equal(rec.txId, null);
  assert.deepEqual(await stateOf(s.svc.verifyBatch(rec.localId)), { state: 'waiting', confirmations: 0 });
  tip = 4080001 + CONFIRMATIONS_BEFORE_CHECK - 1;
  assert.deepEqual(await stateOf(s.svc.verifyBatch(rec.localId)), { state: 'waiting', confirmations: CONFIRMATIONS_BEFORE_CHECK - 1 });
  assert.equal((await s.vault.all())[0].check, null, 'nothing saved while it waits');
  tip = 4080001 + CONFIRMATIONS_BEFORE_CHECK;
  assert.equal((await s.svc.verifyBatch(rec.localId)).state, 'ready');
});

const stateOf = async (p) => {
  const r = await p;
  return { state: r.state, confirmations: r.confirmations };
};

test('verify: a create the network turned down holds nothing; a squatted batch fails the check and stays failed', async () => {
  let st = fakeV3();
  let s = service(st, { txStatus: async () => ({ status: 4 }) });
  let { batch } = await s.svc.createBatch({ assetId: 36, values: [100000n] });
  let r = await s.svc.verifyBatch(batch.localId);
  assert.equal(r.state, 'notSent');
  assert.equal(r.onChain, true);
  assert.equal((await s.vault.all())[0].txStatus, TX_STATUS.failed);
  // Squatted: the copycat's batch, made of our keys with 1 groth each, was mined first. Say our own
  // was mined too (a node that lies about it): the codes still point at the copy.
  st = fakeV3();
  s = service(st, { txStatus: async () => ({ status: 3, confirmations: 5 }) });
  ({ batch } = await s.svc.createBatch({ assetId: 36, values: [100000n, 100000n], gas: true }));
  st.mine({ ...st.pending, creator: OTHER, gas: 0n, entries: st.pending.entries.map((e) => ({ ...e, value: 1n })) });
  r = await s.svc.verifyBatch(batch.localId);
  assert.equal(r.state, 'failed');
  assert.equal(r.problem, 'otherValue');
  assert.equal(r.mined, true);
  const saved = (await s.vault.all())[0];
  assert.equal(saved.check.state, CHECK_STATE.failed);
  assert.equal(saved.check.problem, 'otherValue');
  assert.equal((await s.svc.verifyBatch(batch.localId)).state, 'failed', 'never shown as ready afterwards');
  // The copy with the right values but another creator: not this wallet's.
  st = fakeV3();
  s = service(st, { txStatus: async () => ({ status: 3, confirmations: 5 }) });
  ({ batch } = await s.svc.createBatch({ assetId: 36, values: [100000n], gas: true }));
  st.mine({ ...st.pending, creator: OTHER });
  assert.equal((await s.svc.verifyBatch(batch.localId)).problem, 'notMine');
});

test('verify: a lookup that fails saves nothing and can be tried again; without a tx id, not found yet means waiting', async () => {
  const st = fakeV3();
  const { svc, vault } = service(st, { txStatus: async () => ({ status: 3, confirmations: 9 }) });
  const { batch } = await svc.createBatch({ assetId: 36, values: [100000n] });
  st.mine(st.pending);
  const real = st.answer;
  st.answer = async (a) => (a.includes('check_voucher') ? Promise.reject(Object.assign(new Error('node down'), { code: 'timeout' })) : real(a));
  await assert.rejects(svc.verifyBatch(batch.localId));
  assert.equal((await vault.all())[0].check, null);
  st.answer = real;
  assert.equal((await svc.verifyBatch(batch.localId)).state, 'ready');
  // A record whose send timed out: no tx id. Not on the network yet is not a verdict.
  const st2 = fakeV3();
  const s2 = service(st2, { sendError: Object.assign(new Error('The wallet did not answer in time.'), { code: 'timeout' }), txStatus: async () => assert.fail('no tx id to ask about') });
  await assert.rejects(s2.svc.createBatch({ assetId: 36, values: [100000n] }));
  const rec = (await s2.vault.all())[0];
  assert.equal(rec.txId, null);
  assert.equal((await s2.svc.verifyBatch(rec.localId)).state, 'waiting');
  assert.equal((await s2.vault.all())[0].check, null);
});

// ---------------------------------------------------------------- claim

test('claim: the voucher key, a fresh receiving key and a signature; never the code, its seed or its secret; the exact funds and fee', async () => {
  const st = fakeV3();
  const code = 'WXYZ-2345-6789-ABCD';
  st.mine({ creator: OTHER, aid: 36, gas: GAS_PER_VOUCHER, entries: [{ key: voucherKeyOf(code), value: 500000000n }] });
  const { svc, transacted } = service(st);
  const r = await svc.redeem('wxyz 2345 6789 abcd');
  assert.equal(r.txId, TXID);
  assert.deepEqual([...r.built.receives].sort(), [[0, GAS_PER_VOUCHER], [36, 500000000n]]);
  assert.equal(r.built.pays.size, 0);
  assert.equal(r.built.fee, V3_CLAIM_FEE);
  const t = transacted[0];
  assert.match(t.args, /,code=WXYZ23456789ABCD,use_gas_pool=0$/);
  assert.doesNotMatch(t.args, /fee/);
  const raw = hex(t.raw);
  assert.ok(!raw.includes(hex(new TextEncoder().encode('WXYZ23456789ABCD'))), 'the code is not in the transaction');
  assert.ok(!raw.includes(hex(seedOf(code))));
  assert.ok(!raw.includes(hex(secretOf(seedOf(code)))));
  assert.deepEqual(t.intent, { action: 'airdropClaim', assetId: 36, notes: ['This code brings 0.022 BEAM that pays the network fee, so no BEAM leaves your wallet.'] });
  st.vouchers.get(voucherKeyOf(code)).redeemed = true;
  await assert.rejects(svc.redeem(code), (e) => e.code === 'alreadyRedeemed');
  await assert.rejects(svc.redeem('ZZZZ-ZZZZ-ZZZZ-ZZZZ'), (e) => e.code === 'voucherNotFound');
  await assert.rejects(svc.redeem('----'), (e) => e.code === 'invalidCode');
});

test('claim: a build that asks the pool, names another voucher, carries the code or moves other funds is never signed', async () => {
  const code = 'WXYZ-2345-6789-ABCD';
  const codeBytes = [...new TextEncoder().encode('WXYZ23456789ABCD')];
  const cases = {
    'pool gas': (st) => (st.pool = 2500000n),
    'another voucher key': (st) => (st.tamper = (e) => ({ ...e, args: [...fromHex(OTHER), ...e.args.slice(33)] })),
    'the code in the args': (st) => (st.tamper = (e) => ({ ...e, args: [...e.args.slice(0, 74), ...codeBytes, ...e.args.slice(74 + codeBytes.length)] })),
    'more paid out': (st) => (st.tamper = (e) => ({ ...e, funds: new Map([...e.funds].map(([k, v]) => [k, v - 1n])) })),
    'the prepaid fee kept back': (st) => (st.tamper = (e) => ({ ...e, funds: new Map([...e.funds].filter(([k]) => k !== 0)) })),
    'the pool charge': (st) => (st.tamper = (e) => ({ ...e, charge: 240000 })),
    'the old contract': (st) => (st.tamper = (e) => ({ ...e, cid: AIRDROP_CID })),
  };
  for (const [what, set] of Object.entries(cases)) {
    const st = fakeV3();
    st.mine({ creator: OTHER, aid: 36, gas: GAS_PER_VOUCHER, entries: [{ key: voucherKeyOf(code), value: 500000000n }] });
    set(st);
    const { svc } = service(st);
    await assert.rejects(svc.redeem(code), (e) => e.code === 'unexpected', what);
    assert.equal(st.signed, 0, what);
  }
  // The node answers for another voucher than this code's: refused before anything is built.
  const st = fakeV3();
  st.mine({ creator: OTHER, aid: 36, gas: 0n, entries: [{ key: voucherKeyOf(code), value: 1n }] });
  const real = st.answer;
  st.answer = async (a) => (a.includes('check_voucher') ? { output: JSON.stringify({ voucher: { key: OTHER, batch_id: 1, asset_id: 36, value: 1, gas: 0, redeemed: 0 } }) } : real(a));
  await assert.rejects(service(st).svc.redeem(code), (e) => e.code === 'unexpected');
  assert.ok(!st.seen.some((a) => a.includes('action=redeem')), 'never built');
});

// ---------------------------------------------------------------- cancel

test('cancel: exactly the unclaimed codes, their values and prepaid fees back, the fee for that many', async () => {
  const st = fakeV3();
  const { svc, vault } = service(st, { txStatus: async () => ({ status: 3, confirmations: 9 }) });
  const { batch } = await svc.createBatch({ assetId: 36, values: [100000n, 100000n, 100000n], gas: true });
  const id = st.mine(st.pending);
  await svc.verifyBatch(batch.localId);
  st.vouchers.get(batch.codes[0].key).redeemed = true;
  const r = await svc.cancelBatch(id);
  assert.equal(r.count, 2);
  assert.equal(r.total, 200000n);
  assert.equal(r.gas, 4400000n);
  assert.deepEqual([...r.built.receives].sort(), [[0, 4400000n], [36, 200000n]]);
  assert.equal(r.built.fee, cancelFee(2));
  // A claim lands while it is prepared: the shader lists one code fewer than the screen read.
  const real = st.answer;
  st.answer = async (a) => {
    if (a.includes('cancel_batch')) st.vouchers.get(batch.codes[1].key).redeemed = true;
    return real(a);
  };
  await assert.rejects(svc.cancelBatch(id), (e) => e.code === 'changed' && /take back what is left/.test(e.message));
  st.answer = real;
  // Another creator key than the batch was built with, or a voucher that is not one of its codes.
  st.vouchers.get(batch.codes[1].key).redeemed = false;
  st.tamper = (e) => ({ ...e, args: [...fromHex(OTHER), ...e.args.slice(33)] });
  await assert.rejects(svc.cancelBatch(id), (e) => e.code === 'unexpected');
  st.tamper = (e) => ({ ...e, args: [...e.args.slice(0, 45), ...fromHex(OTHER), ...e.args.slice(78)] });
  await assert.rejects(svc.cancelBatch(id), (e) => e.code === 'unexpected');
  st.tamper = (e) => ({ ...e, funds: new Map([[36, -200000n]]) });
  await assert.rejects(svc.cancelBatch(id), (e) => e.code === 'unexpected', 'the prepaid fees must come back too');
  st.tamper = null;
  assert.equal(st.signed, 2, 'the create and one take-back');
  await assert.rejects(svc.cancelBatch(99n), (e) => e.code === 'batchNotFound');
  for (const c of batch.codes) st.vouchers.get(c.key).redeemed = true;
  await assert.rejects(svc.cancelBatch(id), (e) => e.code === 'nothingToCancel');
  assert.equal((await vault.all()).length, 1);
});

// ---------------------------------------------------------------- both contracts

test('lookups: v3 first, then the old contract; an error on v3 is never taken for "not there"', async () => {
  const asked = [];
  const v3 = { busy: false, checkVoucher: async (c) => (asked.push(['v3', c]), c === 'V3-CODE' ? { contract: 'v3', key: OTHER, batchId: 1n, assetId: 36, value: 5n, gas: 0n, redeemed: false } : c === 'BROKEN' ? Promise.reject(Object.assign(new Error('no Airdrop v3 contract'), { code: 'contractNotFound' })) : null), redeem: async (c) => ({ txId: 'v3', info: { contract: 'v3' } }), createBatch: async () => 'v3 batch' };
  const old = { busy: false, checkVoucher: async (c) => (asked.push(['v2', c]), c === 'OLD-CODE' ? { hash: 'ab'.repeat(32), batchId: 2n, assetId: 174, value: 7n, redeemed: false } : null), redeem: async () => (asked.push(['redeem-v2']), { txId: 'v2', info: {} }), createBatch: async () => assert.fail('never on the old contract') };
  const both = createAirdrops({ v3, old });
  assert.equal((await both.checkVoucher('V3-CODE')).contract, 'v3');
  assert.deepEqual(asked.splice(0), [['v3', 'V3-CODE']], 'found on v3: the old contract is not asked');
  const o = await both.checkVoucher('OLD-CODE');
  assert.deepEqual({ contract: o.contract, gas: o.gas }, { contract: 'v2', gas: 0n });
  assert.deepEqual(asked.splice(0), [['v3', 'OLD-CODE'], ['v2', 'OLD-CODE']]);
  assert.equal(await both.checkVoucher('NOWHERE'), null);
  asked.splice(0);
  await assert.rejects(both.checkVoucher('BROKEN'), (e) => e.code === 'contractNotFound');
  assert.deepEqual(asked.splice(0), [['v3', 'BROKEN']], 'not asked on the old contract after a v3 error');
  assert.equal((await both.redeem('V3-CODE')).txId, 'v3');
  // The old contract's claim shows the code to the network: refused unless the person agreed (audit 1.3.0, B2).
  const asksBefore = asked.length;
  await assert.rejects(both.redeem('OLD-CODE'), (e) => e.code === 'oldNeedsConsent');
  await assert.rejects(both.redeem('OLD-CODE', { oldConsent: 'yes' }), (e) => e.code === 'oldNeedsConsent', 'only true agrees');
  assert.ok(!asked.slice(asksBefore).some((a) => a[0] === 'redeem-v2'), 'the old contract is never asked to claim');
  assert.equal((await both.redeem('OLD-CODE', { oldConsent: true })).txId, 'v2');
  await assert.rejects(both.redeem('NOWHERE'), (e) => e.code === 'voucherNotFound');
  assert.equal(await both.createBatch({}), 'v3 batch', 'new codes are made on v3 only');
});

test('lookups: a code longer than 64 letters is not a v3 code; the real services, one transaction at a time across both', async () => {
  const st = fakeV3();
  const lock = airdropLock();
  const { svc: v3 } = service(st, { lock });
  const oldAsked = [];
  const old = createAirdrop({ view: async (a) => (oldAsked.push(a), Promise.reject(Object.assign(new Error('Voucher not found'), { code: 'shader' }))), transact: async () => assert.fail('no old transaction'), vault: async () => assert.fail('no vault'), lock });
  const both = createAirdrops({ v3, old });
  assert.equal(await both.checkVoucher('A'.repeat(65)), null);
  assert.ok(!st.seen.some((a) => a.includes('check_voucher')), 'v3 never asked for a code it cannot hold');
  assert.equal(oldAsked.length, 1);
  // A v3 create in progress: a claim on either contract is refused at once.
  let release;
  const { svc: slow } = service(st, { lock, beforeSign: () => new Promise((r) => (release = r)) });
  const creating = slow.createBatch({ assetId: 36, values: [1n] });
  assert.equal(both.busy, true);
  await assert.rejects(both.redeem('ABCD-EFGH-JKLM-NPQR'), (e) => e.code === 'busy');
  await assert.rejects(old.redeem('ABCD-EFGH-JKLM-NPQR'), (e) => e.code === 'busy');
  while (!release) await new Promise((r) => setTimeout(r, 1));
  release();
  await creating;
  assert.equal(both.busy, false);
});

test('saved v3 records keep their keys, prepaid fee, creator key, batch and check through every rewrite', async () => {
  const kv = memoryKv();
  const vault = codeVault({ kv, walletId: 'w1', secret: 'cd'.repeat(32) });
  const code = 'ABCD-EFGH-JKLM-NPQR';
  const rec = { localId: 'b1', contractId: V3_CID, assetId: 36, createdAt: '2026-10-13T00:00:00.000Z', txId: TXID, txStatus: 'broadcast', gasPerVoucher: '2200000', creatorKey: CREATOR, batchId: null, check: null, codes: [{ code, hash: await codeHash(code), key: voucherKeyOf(code), value: '100000', status: 'unknown' }] };
  await vault.put(rec);
  await vault.put({ ...(await vault.all())[0], batchId: '7', check: { state: 'ok', at: '2026-10-13T00:05:00.000Z', problem: null, index: null } });
  const back = (await vault.all())[0];
  assert.deepEqual({ gas: back.gasPerVoucher, creator: back.creatorKey, batch: back.batchId, check: back.check.state, key: back.codes[0].key }, { gas: '2200000', creator: CREATOR, batch: '7', check: 'ok', key: voucherKeyOf(code) });
  // A record whose voucher key is not a key does not read (it is kept, never shown as if fine).
  await assert.rejects(readSavedBatch({ ...rec, codes: [{ ...rec.codes[0], key: 'nope' }] }), (e) => e.code === 'unexpected');
  // A check result that does not read is no result: checked again, never ready.
  assert.equal((await readSavedBatch({ ...rec, check: { state: 'maybe' } })).check, null);
  // An old record reads as before, without the v3 fields.
  const old = await readSavedBatch({ ...rec, contractId: AIRDROP_CID, gasPerVoucher: undefined, creatorKey: undefined, batchId: undefined, check: undefined, codes: [{ code, hash: await codeHash(code), value: '1', status: 'available' }] });
  assert.equal('check' in old, false);
  assert.equal('key' in old.codes[0], false);
});
