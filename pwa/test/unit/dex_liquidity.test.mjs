// DEX pools: adding and withdrawing liquidity, creating a pool (lib/dex_liquidity.js),
// and the approve sheet's words for them (screens/consent.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  METHOD, KERNEL, LIQUIDITY_FEE, POOL_CREATE_DEPOSIT, POOL_CREATE_FEE, POOL_CREATE_CHARGE, KIND_CHOICES,
  addLiquidityArgs, withdrawArgs, createPoolArgs, poolViewArgs, parseAddQuote, parseWithdrawQuote, liquidityErrorFor,
  findPool, poolOfLp, shareOf, positionAmounts, shareAfterAdd, lpForPercent, maxDeposit, valueOf, poolSize, arrangePools,
  poolMatches, creatableAssets, ratioText, compact, percentText, beamWorth, movedBps, poolIdBytes,
  checkAddBuilt, checkWithdrawBuilt, checkCreateBuilt, builtExpectation, createLiquidity, LiquidityError,
} from '../../src/lib/dex_liquidity.js';
import { DEX_CID, DexError } from '../../src/lib/dex.js';
import { readContractTx } from '../../src/lib/contract_tx.js';
import { approveLabel, intentExtras } from '../../src/screens/consent.js';
import { invokeEntry, invokeData, FLAG_SAVE_APP_INVOKE } from './helpers/invoke_builder.mjs';

const pool = (aid1, aid2, kind, tok1, tok2, ctl, lp) => ({ aid1, aid2, kind, tok1: BigInt(tok1), tok2: BigInt(tok2), ctl: BigInt(ctl), lpToken: lp });
// BEAM/FOMO 1%: mainnet-like reserves.
const FOMO_POOL = pool(0, 174, 2, 8120504552105n, 66136536898747n, 27125190867423n, 175);
const verified = (id) => [0, 7, 174].includes(Number(id));
const le = (v, n) => {
  const out = [];
  let x = BigInt(v);
  for (let i = 0; i < n; i++) {
    out.push(Number(x & 0xffn));
    x >>= 8n;
  }
  return out;
};
const pid = (p) => [...le(p.aid1, 4), ...le(p.aid2, 4), p.kind];

/** A raw_data of one DEX call, as the engine builds it. */
function built({ method, args, spend, comment, charge = 0, contractId = DEX_CID, sigs = [], appArgs = null }) {
  const entry = invokeEntry({ contractId, method, args, spend, comment, charge, sigs, flags: appArgs ? FLAG_SAVE_APP_INVOKE : 0 });
  return Uint8Array.from(invokeData([entry], appArgs ? { firstFlags: FLAG_SAVE_APP_INVOKE, appArgs } : {}));
}

const argsMap = (s) => Object.fromEntries(s.split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));

test('args: every parameter the shader reads, pool order, canonical numbers', () => {
  assert.equal(
    addLiquidityArgs({ aid1: 0, aid2: 174, kind: 2, amount1: 1000000n, predictOnly: true }),
    `action=pool_add_liquidity,cid=${DEX_CID},aid1=0,aid2=174,kind=2,val1=1000000,val2=0,bPredictOnly=1`,
  );
  assert.equal(addLiquidityArgs({ aid1: 0, aid2: 174, kind: 2, amount2: 5n, predictOnly: false }).endsWith('val1=0,val2=5,bPredictOnly=0'), true);
  assert.equal(withdrawArgs({ aid1: 0, aid2: 174, kind: 2, ctl: 123n, predictOnly: true }), `action=pool_withdraw,cid=${DEX_CID},aid1=0,aid2=174,kind=2,ctl=123,bPredictOnly=1`);
  assert.equal(createPoolArgs({ aidA: 174, aidB: 0, kind: 0 }), `action=pool_create,cid=${DEX_CID},aid1=0,aid2=174,kind=0`, 'written in pool order');
  assert.equal(poolViewArgs({ aidA: 174, aidB: 0, kind: 1 }), `action=pool_view,cid=${DEX_CID},aid1=0,aid2=174,kind=1`);
  assert.throws(() => addLiquidityArgs({ aid1: 174, aid2: 0, kind: 2, amount1: 1n, predictOnly: true }), DexError, 'not in pool order');
  assert.throws(() => addLiquidityArgs({ aid1: 0, aid2: 174, kind: 2, predictOnly: true }), DexError, 'no amount');
  assert.throws(() => addLiquidityArgs({ aid1: 0, aid2: 174, kind: 2, amount1: 0n, predictOnly: true }), DexError);
  assert.throws(() => withdrawArgs({ aid1: 0, aid2: 174, kind: 2, ctl: 0n, predictOnly: true }), DexError);
  assert.throws(() => withdrawArgs({ aid1: 0, aid2: 174, kind: 3, ctl: 1n, predictOnly: true }), DexError);
  assert.throws(() => createPoolArgs({ aidA: 5, aidB: 5, kind: 2 }), DexError);
  assert.throws(() => withdrawArgs({ aid1: 0, aid2: 174, kind: 2, ctl: 1n << 63n, predictOnly: true }), DexError);
});

test('fees and the deposit: 0.011 BEAM per add or withdraw, 10 BEAM locked + 0.01471 BEAM to create', () => {
  assert.equal(LIQUIDITY_FEE, 1100000n);
  assert.equal(POOL_CREATE_DEPOSIT, 1000000000n);
  assert.equal(POOL_CREATE_CHARGE, 137100);
  assert.equal(POOL_CREATE_FEE, 1471000n);
  assert.deepEqual(KIND_CHOICES.map((c) => c.kind), [2, 1, 0], '1% first, as recommended');
  assert.match(KIND_CHOICES[0].title, /recommended/);
});

test('predictions parsed exactly (large numbers as strings); refusals named', () => {
  const q = parseAddQuote({ res: { tok1: '1000000', tok2: '8144385190123456', ctl: 3340 } }, FOMO_POOL);
  assert.deepEqual([q.amount1, q.amount2, q.lpMinted], [1000000n, 8144385190123456n, 3340n]);
  const w = parseWithdrawQuote({ res: { ctl: 3340, tok1: 999999, tok2: 8144385 } }, FOMO_POOL);
  assert.deepEqual([w.lpBurned, w.amount1, w.amount2], [3340n, 999999n, 8144385n]);
  assert.throws(() => parseAddQuote({ res: { tok1: -1, tok2: 1, ctl: 1 } }, FOMO_POOL), LiquidityError);
  assert.throws(() => parseWithdrawQuote({}, FOMO_POOL), LiquidityError);
  assert.equal(liquidityErrorFor('val1 too large').code, 'ratioMismatch');
  assert.equal(liquidityErrorFor('val2 too large').code, 'ratioMismatch');
  assert.equal(liquidityErrorFor('pool already exists').code, 'poolExists');
  assert.equal(liquidityErrorFor('no such pool').code, 'noPool');
  assert.equal(liquidityErrorFor('pool empty - both tokens must be specified').code, 'needBoth');
  assert.equal(liquidityErrorFor('something else').code, 'shader');
});

test('positions: share, what it takes out, share after a deposit, percent steps', () => {
  const p = pool(0, 174, 2, 1000n, 8000n, 400n, 175);
  assert.deepEqual(shareOf(p, 100n), { num: 100n, den: 400n });
  assert.deepEqual(shareOf(p, 0n), { num: 0n, den: 1n });
  assert.deepEqual(shareOf(p, 999n), { num: 400n, den: 400n }, 'never more than the whole pool');
  assert.deepEqual(positionAmounts(p, 100n), { amount1: 250n, amount2: 2000n });
  assert.deepEqual(positionAmounts(p, 400n), { amount1: 1000n, amount2: 8000n }, 'the last provider takes everything');
  assert.deepEqual(positionAmounts(p, 3n), { amount1: 7n, amount2: 60n }, 'rounded down');
  assert.deepEqual(positionAmounts(p, 401n), { amount1: 0n, amount2: 0n }, 'more than exists: nothing');
  assert.deepEqual(shareAfterAdd(p, 100n), { num: 100n, den: 500n });
  assert.deepEqual(shareAfterAdd(p, 100n, 50n), { num: 150n, den: 500n }, 'what is already held counts');
  assert.equal(lpForPercent(1001n, 25), 250n);
  assert.equal(lpForPercent(1001n, 100), 1001n, '100% leaves nothing behind');
  assert.equal(lpForPercent(1001n, 0), 0n);
});

test('Max fits both balances at the pool ratio', () => {
  const p = pool(0, 174, 2, 1000n, 8000n, 400n, 175);
  // 100 BEAM-groth spendable, 400 FOMO-groth: FOMO allows only (400-2)*1000/8000 = 49 BEAM-groth.
  assert.equal(maxDeposit(p, 1, 100n, 400n), 49n);
  assert.equal(maxDeposit(p, 2, 100n, 400n), 400n);
  assert.equal(maxDeposit(p, 2, 10n, 400000n), 64n, '(10-2)*8000/1000');
  assert.equal(maxDeposit(p, 1, -5n, 400n), 0n);
  const empty = pool(0, 9, 2, 0n, 0n, 0n, 500);
  assert.equal(maxDeposit(empty, 1, 77n, 3n), 77n, 'an empty pool: each side on its own');
});

test('values: BEAM, a verified asset at spot, LP tokens as what a withdrawal pays out', () => {
  const pools = [FOMO_POOL, pool(0, 900, 2, 2000n * 100000000n, 1000n, 50n, 901), pool(174, 900, 0, 100n, 100n, 10n, 902)];
  assert.equal(valueOf(pools, 0, 5n, verified), 5n);
  // FOMO at the BEAM/FOMO spot price.
  assert.equal(valueOf(pools, 174, 66136536898747n, verified), 8120504552105n);
  // The whole LP supply of BEAM/FOMO: both sides, the FOMO side at spot = 2 × the BEAM reserve.
  assert.equal(valueOf(pools, 175, FOMO_POOL.ctl, verified), 2n * 8120504552105n);
  // Half the supply: half of that, rounded down.
  assert.equal(valueOf(pools, 175, FOMO_POOL.ctl / 2n, verified), 8120504552105n - 1n);
  // An unverified asset priced by its own pool: sold back into what the withdrawal leaves (never more than the BEAM in it).
  const v = valueOf(pools, 901, 25n, verified);
  assert.ok(v < 2000n * 100000000n && v > 0n);
  assert.equal(poolSize(pools, FOMO_POOL, verified), 2n * 8120504552105n);
  assert.equal(poolSize(pools, pool(0, 77, 2, 0n, 0n, 0n, 78), verified), null, 'an empty pool has no size');
  assert.equal(valueOf(pools, 555, 10n, verified), null, 'nothing prices it');
});

test('the list: your pools first, then the deepest; empty pools only when you hold a share; search', () => {
  const big = pool(0, 174, 2, 900n * 100000000n, 900n, 10n, 175);
  const small = pool(0, 7, 2, 2n * 100000000n, 10n, 10n, 50);
  const emptyMine = pool(0, 9, 0, 0n, 0n, 0n, 52);
  const emptyOther = pool(0, 9, 2, 0n, 0n, 0n, 53);
  const pools = [small, emptyOther, big, emptyMine];
  const held = (lp) => (lp === 50 || lp === 52 ? 1n : 0n);
  const { mine, rest } = arrangePools(pools, { held, isVerified: verified });
  assert.deepEqual(mine.map((p) => p.lpToken), [50, 52]);
  assert.deepEqual(rest.map((p) => p.lpToken), [175]);
  const labels = { 0: { unit: 'BEAM', name: 'BEAM', symbol: 'BEAM' }, 174: { unit: 'FOMO', name: 'FOMO', symbol: 'FOMO' }, 7: { unit: 'BEAMX', name: 'BeamX', symbol: 'BEAMX' }, 9: { unit: 'TICO', name: 'Tico', symbol: 'TICO' } };
  const lab = (id) => labels[id];
  assert.equal(poolMatches(big, 'fomo', lab), true);
  assert.equal(poolMatches(big, '#174', lab), true);
  assert.equal(poolMatches(big, '17', lab), false, 'a number matches exactly');
  assert.equal(poolMatches(big, 'beamx', lab), false);
  assert.equal(poolMatches(big, '', lab), true);
  assert.equal(findPool(pools, { aid1: 174, aid2: 0, kind: 2 }), big, 'either order');
  assert.equal(findPool(pools, { aid1: 0, aid2: 174, kind: 1 }), null);
  assert.equal(poolOfLp(pools, 52), emptyMine);
});

test('assets a pool can be created from: BEAM first, tradable and held ones, never an LP token', () => {
  const pools = [FOMO_POOL, pool(0, 7, 2, 10n, 10n, 10n, 50), pool(0, 9, 2, 0n, 0n, 0n, 53)];
  assert.deepEqual(creatableAssets(pools, [175, 300, 0, 50]), [0, 7, 174, 300]);
});

test('numbers as people read them (the desktop DexFormat)', () => {
  assert.equal(ratioText(66136536898747n, 8120504552105n), '8.1443');
  assert.equal(ratioText(8120504552105n, 66136536898747n), '0.1227');
  assert.equal(ratioText(1n, 37176n), '0.00002689', 'four significant digits, rounded down');
  assert.equal(ratioText(123456789n, 1000n), '123,456.78');
  assert.equal(ratioText(0n, 5n), '0');
  assert.equal(compact(8120504552105n), '81,205.04');
  assert.equal(compact(1100000n), '0.011');
  assert.equal(compact(1n), '0.00000001');
  assert.equal(percentText(1n, 3n), '33.3%');
  assert.equal(percentText(1n, 8n), '12.5%');
  assert.equal(percentText(13n, 10000n), '0.13%');
  assert.equal(percentText(1n, 100000n), '< 0.01%');
  assert.equal(percentText(0n, 5n), '0%');
  assert.equal(percentText(5n, 5n), '100%');
  assert.equal(beamWorth(123456789n), '≈ 1.2345 BEAM');
  assert.equal(beamWorth(0n), 'under 0.00000001 BEAM');
  assert.equal(beamWorth(null), 'No price');
  assert.equal(movedBps(1000n, 990n), 100n);
  assert.equal(movedBps(1000n, 1010n), 100n);
  assert.equal(movedBps(0n, 0n), 0n);
});

// ---------------------------------------------------------------- built transactions

const ADD_ARGS = addLiquidityArgs({ aid1: 0, aid2: 174, kind: 2, amount1: 1000000n, predictOnly: false });
const addQuote = { pool: FOMO_POOL, amount1: 1000000n, amount2: 8144385n, lpMinted: 3340n };
const addRaw = ({ tok1 = 1000000n, tok2 = 8144385n, lp = 3340n, spend = null, ...o } = {}) =>
  built({ method: METHOD.add, comment: KERNEL.add, args: [...pid(FOMO_POOL), ...le(tok1, 8), ...le(tok2, 8)], spend: spend || { 0: tok1, 174: tok2, 175: -lp }, appArgs: argsMap(ADD_ARGS), ...o });

test('a deposit is checked byte for byte before anyone is asked', () => {
  const d = checkAddBuilt(addRaw(), { pool: FOMO_POOL, amount1: 1000000n, quote: addQuote, args: ADD_ARGS });
  assert.deepEqual([...d.pays], [[0, 1000000n], [174, 8144385n]]);
  assert.deepEqual([...d.receives], [[175, 3340n]]);
  assert.equal(d.fee, LIQUIDITY_FEE);
  const refuse = (raw, code = 'unexpected', extra = {}) => assert.throws(() => checkAddBuilt(raw, { pool: FOMO_POOL, amount1: 1000000n, quote: addQuote, args: ADD_ARGS, ...extra }), (e) => e instanceof LiquidityError && e.code === code);
  refuse(addRaw({ contractId: 'ab'.repeat(32) }));
  refuse(addRaw({ method: METHOD.trade }));
  refuse(addRaw({ comment: 'Amm withdraw' }));
  refuse(addRaw({ charge: 5 }));
  refuse(addRaw({ sigs: ['11'.repeat(32)] }));
  refuse(addRaw({ tok1: 1000001n }), 'unexpected', {}, 'the amount given changed');
  refuse(addRaw({ spend: { 0: 1000000n, 174: 8144385n, 176: -3340n } }), 'unexpected');
  refuse(addRaw({ spend: { 0: 1000000n, 174: 8144385n, 175: -3340n, 7: 1n } }), 'unexpected');
  refuse(addRaw({ spend: { 0: 1000001n, 174: 8144385n, 175: -3340n } }), 'unexpected', {}, 'funds differ from the args');
  refuse(addRaw({ appArgs: { ...argsMap(ADD_ARGS), val1: '2000000' } }), 'unexpected');
  refuse(built({ method: METHOD.add, comment: KERNEL.add, args: [...pid({ ...FOMO_POOL, kind: 1 }), ...le(1000000n, 8), ...le(8144385n, 8)], spend: { 0: 1000000n, 174: 8144385n, 175: -3340n } }));
  // The computed side moved: within 1% passes, beyond it stops as priceMoved.
  assert.ok(checkAddBuilt(addRaw({ tok2: 8200000n }), { pool: FOMO_POOL, amount1: 1000000n, quote: addQuote, args: ADD_ARGS }));
  refuse(addRaw({ tok2: 8300000n }), 'priceMoved');
  refuse(addRaw({ tok2: 8000000n }), 'priceMoved');
  refuse(addRaw({ lp: 3000n }), 'priceMoved');
  // Stricter protection, as chosen.
  refuse(addRaw({ tok2: 8200000n }), 'priceMoved', { bps: 10n });
});

const WD_ARGS = withdrawArgs({ aid1: 0, aid2: 174, kind: 2, ctl: 3340n, predictOnly: false });
const wdQuote = { pool: FOMO_POOL, lpBurned: 3340n, amount1: 999999n, amount2: 8144380n };
const wdRaw = ({ ctl = 3340n, spend = null, ...o } = {}) => built({ method: METHOD.withdraw, comment: KERNEL.withdraw, args: [...pid(FOMO_POOL), ...le(ctl, 8)], spend: spend || { 0: -999999n, 174: -8144380n, 175: ctl }, appArgs: argsMap(WD_ARGS), ...o });

test('a withdrawal: exactly the LP asked for out, only the pool\'s two assets back, at most 1% below the quote', () => {
  const d = checkWithdrawBuilt(wdRaw(), { pool: FOMO_POOL, ctl: 3340n, quote: wdQuote, args: WD_ARGS });
  assert.deepEqual([...d.pays], [[175, 3340n]]);
  assert.deepEqual([...d.receives].sort((a, b) => a[0] - b[0]), [[0, 999999n], [174, 8144380n]]);
  const refuse = (raw, code = 'unexpected', extra = {}) => assert.throws(() => checkWithdrawBuilt(raw, { pool: FOMO_POOL, ctl: 3340n, quote: wdQuote, args: WD_ARGS, ...extra }), (e) => e instanceof LiquidityError && e.code === code);
  refuse(wdRaw({ ctl: 3341n }));
  refuse(wdRaw({ spend: { 0: -999999n, 174: -8144380n, 175: 3341n } }));
  refuse(wdRaw({ spend: { 0: -999999n, 7: -5n, 175: 3340n } }));
  refuse(wdRaw({ spend: { 0: 5n, 174: -8144380n, 175: 3340n } }), 'unexpected', {}, 'pays BEAM instead of receiving it');
  refuse(wdRaw({ method: METHOD.add }));
  refuse(wdRaw({ comment: 'Amm add' }));
  refuse(wdRaw({ spend: { 0: -999999n * 98n / 100n, 174: -8144380n, 175: 3340n } }), 'priceMoved');
  // More back than quoted is fine.
  assert.ok(checkWithdrawBuilt(wdRaw({ spend: { 0: -1100000n, 174: -8144380n, 175: 3340n } }), { pool: FOMO_POOL, ctl: 3340n, quote: wdQuote, args: WD_ARGS }));
});

const CREATE_ARGS = createPoolArgs({ aidA: 300, aidB: 0, kind: 2 });
const createRaw = ({ spend = { 0: POOL_CREATE_DEPOSIT }, kind = 2, ...o } = {}) =>
  built({ method: METHOD.create, comment: KERNEL.create, charge: POOL_CREATE_CHARGE, args: [...pid({ aid1: 0, aid2: 300, kind }), ...new Array(33).fill(7)], spend, appArgs: argsMap(CREATE_ARGS), ...o });

test('a new pool: the 10 BEAM deposit and nothing else; its fee is the one the screen states', () => {
  const d = checkCreateBuilt(createRaw(), { aidA: 300, aidB: 0, kind: 2, args: CREATE_ARGS });
  assert.equal(d.fee, POOL_CREATE_FEE);
  assert.deepEqual([...d.pays], [[0, POOL_CREATE_DEPOSIT]]);
  const refuse = (raw) => assert.throws(() => checkCreateBuilt(raw, { aidA: 300, aidB: 0, kind: 2, args: CREATE_ARGS }), (e) => e.code === 'unexpected');
  refuse(createRaw({ spend: { 0: POOL_CREATE_DEPOSIT + 1n } }));
  refuse(createRaw({ spend: { 0: POOL_CREATE_DEPOSIT, 300: 5n } }));
  refuse(createRaw({ kind: 1 }));
  refuse(createRaw({ charge: 100 }));
  refuse(createRaw({ method: METHOD.destroy }));
});

test('the approve sheet must ask for exactly what was decoded, fee included', () => {
  const d = readContractTx(addRaw());
  const ex = builtExpectation(() => d);
  const req = (o = {}) => ({ kind: 'contract', fee: LIQUIDITY_FEE, spends: [{ assetId: 0, amount: 1000000n }, { assetId: 174, amount: 8144385n }], receives: [{ assetId: 175, amount: 3340n }], ...o });
  assert.equal(ex(req()), null);
  assert.equal(ex(req({ fee: 1200000n })).code, 'unexpected');
  assert.equal(ex(req({ receives: [{ assetId: 175, amount: 3341n }] })).code, 'unexpected');
  assert.equal(ex(req({ spends: [{ assetId: 0, amount: 1000000n }] })).code, 'unexpected');
  assert.equal(ex(req({ kind: 'send' })).code, 'unexpected');
  assert.equal(builtExpectation(() => null)(req()).code, 'unexpected', 'nothing inspected: refused');
});

test('the service: quotes, one move at a time, a shader refusal named, inspect and expect wired', async () => {
  const calls = [];
  let release;
  const gate = new Promise((r) => (release = r));
  const deps = {
    view: async (a) => {
      calls.push(a);
      const m = argsMap(a);
      if (m.action === 'pool_add_liquidity') {
        if (m.val1 === '7') throw Object.assign(new Error('val1 too large'), { code: 'shader' });
        return { res: { tok1: m.val1 === '0' ? 123 : Number(m.val1), tok2: m.val2 === '0' ? 8144385 : Number(m.val2), ctl: 3340 } };
      }
      if (m.action === 'pool_withdraw') return { res: { ctl: Number(m.ctl), tok1: 999999, tok2: m.ctl === '1' ? 0 : 8144380 } };
      if (m.action === 'pool_view') return { res: { tok1: 5, tok2: 6, ctl: 7, 'lp-token': 175 } };
      throw new Error('unexpected view');
    },
    transact: async (a, opts) => {
      await gate;
      const m = argsMap(a);
      const raw = m.action === 'pool_add_liquidity' ? addRaw() : m.action === 'pool_withdraw' ? wdRaw() : createRaw();
      await opts.inspect(raw, {});
      const d = readContractTx(raw);
      const problem = opts.expect({ kind: 'contract', fee: d.fee, spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })) });
      if (problem) throw Object.assign(new Error(problem.message), { code: problem.code });
      return 'f'.repeat(32);
    },
  };
  const liq = createLiquidity(deps);
  const q = await liq.quoteAdd(FOMO_POOL, { amount1: 1000000n });
  assert.equal(q.amount2, 8144385n);
  await assert.rejects(liq.quoteAdd(FOMO_POOL, { amount1: 7n }), (e) => e.code === 'ratioMismatch');
  await assert.rejects(liq.quoteWithdraw(FOMO_POOL, 1n), (e) => e.code === 'tooSmall', 'one side would come back as nothing');
  const w = await liq.quoteWithdraw(FOMO_POOL, 3340n);
  assert.equal(w.amount2, 8144380n);
  assert.deepEqual(await liq.poolView({ aid1: 174, aid2: 0, kind: 2 }), { aid1: 0, aid2: 174, kind: 2, ctl: 7n, tok1: 5n, tok2: 6n, lpToken: 175 });

  const first = liq.add(FOMO_POOL, { amount1: 1000000n, quote: addQuote, intent: { rows: [['Pool', 'BEAM/FOMO · 1% fee']] } });
  assert.equal(liq.busy, true);
  await assert.rejects(liq.withdraw(FOMO_POOL, { lp: 3340n, quote: wdQuote }), (e) => e.code === 'busy', 'a second tap is refused');
  release();
  const r = await first;
  assert.equal(r.txId, 'f'.repeat(32));
  assert.deepEqual([...r.built.receives], [[175, 3340n]]);
  assert.equal(liq.busy, false);
  const r2 = await liq.withdraw(FOMO_POOL, { lp: 3340n, quote: wdQuote });
  assert.deepEqual([...r2.built.pays], [[175, 3340n]]);
  const r3 = await liq.create({ aidA: 0, aidB: 300, kind: 2 });
  assert.equal(r3.built.fee, POOL_CREATE_FEE);
  // An inspect refusal comes back as itself, not as a generic error.
  await assert.rejects(liq.add(FOMO_POOL, { amount1: 1000000n, quote: { ...addQuote, amount2: 9000000n } }), (e) => e.code === 'priceMoved');
});

test('the approve sheet words a pool move: titles, buttons, rows, the tick for a new pool', () => {
  const unit = (id) => ({ 0: 'BEAM', 174: 'FOMO', 175: 'BEAM/FOMO LP' })[id];
  const base = { kind: 'contract', native: true, fee: LIQUIDITY_FEE };
  assert.equal(approveLabel({ ...base, spends: [{ assetId: 0, amount: 1000000n }, { assetId: 174, amount: 37176000000n }], receives: [{ assetId: 175, amount: 3340n }], intent: { action: 'poolAdd' } }, unit), 'Add 0.01 BEAM + 371.76 FOMO to the pool');
  assert.equal(approveLabel({ ...base, spends: [{ assetId: 175, amount: 3340n }], receives: [{ assetId: 0, amount: 1000000n }, { assetId: 174, amount: 37176000000n }], intent: { action: 'poolWithdraw' } }, unit), 'Withdraw 0.01 BEAM + 371.76 FOMO');
  assert.equal(approveLabel({ ...base, spends: [{ assetId: 0, amount: POOL_CREATE_DEPOSIT }], receives: [], intent: { action: 'poolCreate' } }, unit), 'Lock 10 BEAM and create the pool');
  const ex = intentExtras({ native: true, intent: { action: 'poolCreate', rows: [['New pool', 'BEAM/XYZ · 1% fee'], ['bad'], [1, 2]], warn: 'locked', ack: 'I understand' } });
  assert.deepEqual(ex, { rows: [['New pool', 'BEAM/XYZ · 1% fee']], warn: 'locked', ack: 'I understand' });
  assert.deepEqual(intentExtras({ native: false, intent: { rows: [['x', 'y']], ack: 'z' } }), { rows: [], warn: null, ack: null }, 'a dApp cannot add rows or a tick');
});
