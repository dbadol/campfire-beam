// Token values, the total, a token's history and the hidden list: lib/pricer.js
// (the desktop's beam_asset_pricer.dart, its tests ported case by case, on the
// same recorded mainnet pools), lib/tokens.js, lib/fiat.js, lib/hidden_tokens.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AssetPricer, MIN_UNVERIFIED_BEAM_RESERVE, ratio, floor } from '../../src/lib/pricer.js';
import { parsePools } from '../../src/lib/dex.js';
import { parseShaderJson } from '../../src/lib/contracts.js';
import { parseHidden, withHidden, holdings, portfolio, heldTotal, tokenHistory, txMovesAsset, mergeTxs, beamEstimate, valueEstimate, tokensWord } from '../../src/lib/tokens.js';
import { FIAT_CURRENCIES, DEFAULT_CURRENCY, FiatPrice, fiatPriceUrl, parsePrice, fiatText, fiatValue, fiatEstimate, fiatAllowed, fiatUnasked, currencyOf, PRICE_MAX_AGE_MS, BUSY_BACKOFF_MS } from '../../src/lib/fiat.js';
import { connectSources } from '../../src/lib/eth/hosts.js';
import { CSP } from '../../tools/headers.mjs';
import { store } from '../../src/lib/store.js';
import { hiddenKey, loadHidden, hiddenIds, setTokenHidden, hiddenLoaded } from '../../src/lib/hidden_tokens.js';

const here = dirname(fileURLToPath(import.meta.url));
const BEAM = 100000000n;
const pool = (aid1, aid2, tok1, tok2, { ctl = 1000n, lp = 900, kind = 2 } = {}) => ({ aid1, aid2, kind, tok1: BigInt(tok1), tok2: BigInt(tok2), ctl: BigInt(ctl), lpToken: lp });

// ------------------------------------------------------------------ the pricer, on mainnet's pools

// The desktop's own recording (test/beam/contracts/dex/fixtures/pools_view.json, height 4,068,104).
const recordedFile = JSON.parse(readFileSync(join(here, '..', '..', '..', 'test', 'beam', 'contracts', 'dex', 'fixtures', 'pools_view.json'), 'utf8'));
const recorded = parsePools(parseShaderJson(recordedFile.result.output));

test('recorded mainnet pools: each asset is priced from its deepest BEAM pool, whatever its kind', () => {
  // The 1,000 BEAM floor for unverified assets lowered to 1 BEAM so mainnet's smaller pools take part (as the desktop test).
  const pricer = new AssetPricer(recorded, { minUnverifiedBeamReserve: BEAM });
  const deepest = (aid) => recorded.filter((p) => p.aid1 === 0 && p.aid2 === aid && p.ctl > 0n && p.tok1 > 0n && p.tok2 > 0n).reduce((a, b) => (a.tok1 >= b.tok1 ? a : b));
  for (const aid of [7, 9, 37, 116, 141]) assert.equal(pricer.pricingPool(aid), deepest(aid), `asset ${aid}`);
  const tiny = recorded.find((p) => p.aid2 === 37 && p.tok1 === 5n);
  assert.ok(tiny, 'mainnet has a 5-groth pool for asset 37');
  assert.notEqual(pricer.pricingPool(37), tiny);
  // Asset 141: kind 0 holds 2.25 BEAM, kind 2 holds 0.065.
  assert.equal(pricer.pricingPool(141).tok1, 225496566n);
});

test('recorded mainnet pools: a holding is valued without its decimals; BEAM is worth itself; no pool is unpriced, not 0', () => {
  const pricer = new AssetPricer(recorded, { minUnverifiedBeamReserve: BEAM });
  const p = pricer.pricingPool(174);
  const amount = 80368764n; // what 0.1 BEAM bought in the desktop's DEX test
  assert.equal(pricer.valueInGroth(174, amount), (amount * p.tok1) / p.tok2);
  assert.equal(pricer.valueInGroth(0, BEAM), BEAM);
  assert.deepEqual(pricer.grothPerUnit(0), ratio(1n));
  const v = pricer.portfolio(new Map([[0, BEAM], [999999, 5n]]));
  assert.equal(v.totalGroth, BEAM);
  assert.deepEqual(v.unpriced, [999999]);
  assert.equal(v.values.has(999999), false);
});

test('recorded mainnet pools: the BEAM/FOMO LP token is its share of both reserves', () => {
  const pricer = new AssetPricer(recorded);
  const lp = recorded.find((x) => x.lpToken === 175);
  // FOMO is verified: each side at spot, so the whole pool is worth twice its BEAM (to the groth, rounded down).
  const whole = pricer.valueInGroth(175, lp.ctl);
  assert.ok(whole === 2n * lp.tok1 || whole === 2n * lp.tok1 - 1n, `${whole} vs ${2n * lp.tok1}`);
  assert.equal(pricer.isSaleValue(175), false);
  // Half the supply, half the value (within a groth).
  const half = pricer.valueInGroth(175, lp.ctl / 2n);
  assert.ok(half <= whole / 2n + 1n && half >= whole / 2n - 2n);
});

// ------------------------------------------------------------------ the pricer's rules (the desktop's tests)

test('pools below the minimum BEAM reserve never set a price', () => {
  const pricer = new AssetPricer([pool(0, 7, 1000, 1)]);
  assert.equal(pricer.grothPerUnit(7), null);
  assert.equal(pricer.valueInGroth(7, 10n), null);
});

test('the deepest pool wins over a shallower, pricier one', () => {
  const pricer = new AssetPricer([pool(0, 7, 2n * BEAM, 1000, { kind: 0 }), pool(0, 7, 50n * BEAM, 100000, { lp: 901 })]);
  assert.deepEqual(pricer.grothPerUnit(7), ratio(50n * BEAM, 100000n));
});

test('values round down, never up', () => {
  const pricer = new AssetPricer([pool(0, 7, 3n * BEAM, 7)]);
  assert.equal(pricer.valueInGroth(7, 1n), 42857142n); // 300000000/7 = 42857142.857…
});

test('an LP token is its share of both reserves; with an unpriced side it is unpriced', () => {
  // Asset 7: 1 unit = 1,000,000 groth: 10 BEAM + 10 BEAM of asset 7 = 20 BEAM; a quarter of the LP supply is 5 BEAM.
  assert.equal(new AssetPricer([pool(0, 7, 10n * BEAM, 1000, { ctl: 400, lp: 900 })]).valueInGroth(900, 100n), 5n * BEAM);
  assert.equal(new AssetPricer([pool(7, 8, 1000, 1000, { ctl: 10, lp: 905 })]).valueInGroth(905, 5n), null);
});

test('empty and zero holdings are worth zero', () => {
  assert.equal(new AssetPricer([]).valueInGroth(7, 0n), 0n);
});

test('1 BEAM against 1 groth no longer makes an airdrop worth 100,000,000 BEAM', () => {
  const spam = 999;
  const pricer = new AssetPricer([pool(0, spam, BEAM, 1)]);
  assert.equal(pricer.valueInGroth(spam, BEAM), null);
  const p = pricer.portfolio(new Map([[0, BEAM], [spam, BEAM]]));
  assert.equal(p.totalGroth, BEAM);
  assert.deepEqual(p.unpriced, [spam]);
});

test('an unverified asset needs a pool of 1,000 BEAM; a verified one does not', () => {
  const spam = 999;
  const pricer = new AssetPricer([pool(0, spam, 999n * BEAM, 1000), pool(0, 7, 2n * BEAM, 1000, { lp: 901 })]);
  assert.equal(MIN_UNVERIFIED_BEAM_RESERVE, 1000n * BEAM);
  assert.equal(pricer.pricingPool(spam), null);
  assert.equal(pricer.valueInGroth(spam, 10n), null);
  assert.equal(pricer.valueInGroth(7, 10n), (2n * BEAM * 10n) / 1000n);
});

test('an unverified asset is valued at what its pool would pay: never more than its BEAM, and marked', () => {
  const spam = 999;
  const p = pool(0, spam, 1000n * BEAM, 1);
  const pricer = new AssetPricer([p]);
  const v = pricer.valueInGroth(spam, BEAM);
  assert.equal(v, (p.tok1 * BEAM) / (p.tok2 + BEAM));
  assert.ok(v < p.tok1);
  assert.equal(pricer.isSaleValue(spam), true);
  assert.equal(new AssetPricer([pool(0, 7, 5n * BEAM, 10)]).isSaleValue(7), false);
  assert.equal(pricer.isSaleValue(0), false);
  // A deep, honest pool: 10,000 BEAM against 1,000,000 units; 100 units are 0.9999 BEAM when sold.
  assert.equal(new AssetPricer([pool(0, spam, 10000n * BEAM, 1000000n * BEAM)]).valueInGroth(spam, 100n * BEAM), 99990000n);
});

test("a pool share of a spam pool is worth at most the pool's BEAM, and is a sale value", () => {
  const pricer = new AssetPricer([pool(0, 999, 1000n * BEAM, 1, { ctl: 100, lp: 950 })]);
  const whole = pricer.valueInGroth(950, 100n);
  assert.ok(whole <= 2n * 1000n * BEAM && whole >= 1000n * BEAM, String(whole));
  assert.equal(pricer.isSaleValue(950), true);
});

test('an LP token of a pool of two tokens values each side through its own BEAM pool', () => {
  // FOMO (174) and BeamX (7) both verified; a 7/174 pool's LP token 910.
  const pricer = new AssetPricer([pool(0, 7, 100n * BEAM, 50n * BEAM, { lp: 50 }), pool(0, 174, 10n * BEAM, 1000n * BEAM, { lp: 175 }), pool(7, 174, 2n * BEAM, 300n * BEAM, { ctl: 1000, lp: 910 })]);
  // Whole pool: 2 BEAMX = 4 BEAM, 300 FOMO = 3 BEAM.
  assert.equal(pricer.valueInGroth(910, 1000n), 7n * BEAM);
  assert.equal(pricer.valueInGroth(910, 5000n), 7n * BEAM, 'never more than the whole pool');
});

test('fractions: exact and floored toward minus infinity', () => {
  assert.deepEqual(ratio(6n, -4n), { n: -3n, d: 2n });
  assert.equal(floor(ratio(-3n, 2n)), -2n);
  assert.equal(floor(ratio(7n, 2n)), 3n);
});

// ------------------------------------------------------------------ holdings and the total

const T = (available, receiving = 0n, sending = 0n, maturing = 0n) => ({ available, receiving, sending, maturing });
const verifiedLabel = (id) => ({ verified: [0, 7, 174, 175].includes(id) });

test('holdings: every token held in any way, verified first then by number; hidden ones flagged, values of the total', () => {
  const pricer = new AssetPricer([pool(0, 174, 10000n * BEAM, 1000000n * BEAM, { lp: 175 }), pool(0, 999, 5000n * BEAM, 1n, { lp: 1000 })]);
  const totals = new Map([[0, T(5n * BEAM)], [999, T(BEAM)], [777, T(0n, 5n * BEAM)], [174, T(10n * BEAM, 0n, 0n, 2n * BEAM)], [55, T(0n, 0n, BEAM)], [56, T(0n)]]);
  const list = holdings(totals, { label: verifiedLabel, hidden: new Set([777]), pricer });
  assert.deepEqual(list.map((x) => x.id), [174, 55, 777, 999], 'nothing of #56: not listed; BEAM is not a token');
  const fomo = list[0];
  assert.equal(fomo.total, 12n * BEAM, 'available + maturing');
  assert.equal(fomo.value, (12n * BEAM * 10000n * BEAM) / (1000000n * BEAM));
  assert.equal(fomo.sale, false);
  assert.equal(list[2].hidden, true);
  assert.equal(list[2].value, null, 'no pool: no price');
  const spam = list[3];
  assert.ok(spam.value < 5000n * BEAM && spam.sale, 'worth no more than the BEAM in its pool, and marked');
  assert.equal(heldTotal(T(1n, 2n, 4n, 8n)), 11n, 'sending is leaving: not counted');
  assert.deepEqual(holdings(totals, { label: verifiedLabel }).map((x) => x.value), [null, null, null, null], 'no pools read yet: no values');
});

test('the total: BEAM plus the tokens on Wallet; hidden ones and unpriced ones left out, unpriced ones counted', () => {
  const pricer = new AssetPricer([pool(0, 174, 10000n * BEAM, 1000000n * BEAM, { lp: 175 })]);
  const totals = new Map([[0, T(5n * BEAM, BEAM)], [174, T(100n * BEAM)], [888, T(7n * BEAM)], [999, T(3n * BEAM)]]);
  assert.equal(portfolio(new Map([[0, T(5n * BEAM)]]), { pricer }), null, 'only BEAM: no total line');
  assert.deepEqual(portfolio(totals, { pricer: null }), { tokens: 3, priced: false, unpriced: 0 }, 'prices not read yet');
  const p = portfolio(totals, { pricer, hidden: new Set([999]) });
  assert.equal(p.tokens, 2);
  assert.equal(p.unpriced, 1, '#888 has no pool');
  assert.equal(p.priced, true);
  assert.equal(p.beamGroth, 6n * BEAM, 'BEAM available + receiving');
  assert.equal(p.totalGroth, 6n * BEAM + BEAM, '100 FOMO at 0.01 BEAM');
  // Every visible token unpriced: no BEAM-only "total".
  assert.deepEqual(portfolio(new Map([[0, T(BEAM)], [888, T(BEAM)]]), { pricer }), { tokens: 1, priced: false, unpriced: 1 });
  // Everything hidden: nothing to add.
  assert.equal(portfolio(totals, { pricer, hidden: new Set([174, 888, 999]) }), null);
});

// ------------------------------------------------------------------ a token's history

const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const swap = (txId, t, pay, get) => ({ txId, tx_type: 12, status: 3, create_time: t, invoke_data: [{ contract_id: DEX, amounts: [{ asset_id: pay[0], amount: pay[1] }, { asset_id: get[0], amount: -get[1] }] }] });

test("a token's history: its payments and the contract calls that moved it, newest first", () => {
  const txs = [
    { txId: 'a', tx_type: 0, asset_id: 174, value: 5, income: true, create_time: 100 },
    { txId: 'b', tx_type: 0, value: 5, create_time: 300 }, // BEAM
    swap('c', 200, [0, 1000], [174, 50]), // BEAM -> FOMO
    swap('d', 400, [174, 10], [0, 1]), // FOMO -> BEAM
    swap('e', 500, [0, 1000], [7, 50]), // BEAM -> BEAMX
    { txId: 'f', tx_type: 7, asset_id: 174, value: 1, create_time: 50 },
    { txId: 'g', tx_type: 12, create_time: 600, invoke_data: [{ contract_id: DEX, amounts: [{ asset_id: 0, amount: '100' }, { asset_id: 174, amount: '100' }, { asset_id: 175, amount: '-9' }] }] }, // added to a pool
  ];
  assert.deepEqual(tokenHistory(txs, 174).map((t) => t.txId), ['g', 'd', 'c', 'a', 'f']);
  assert.deepEqual(tokenHistory(txs, 175).map((t) => t.txId), ['g'], 'the LP token received');
  assert.deepEqual(tokenHistory(txs, 7).map((t) => t.txId), ['e']);
  assert.deepEqual(tokenHistory(txs, 0).map((t) => t.txId), ['g', 'e', 'd', 'b', 'c']);
  assert.equal(txMovesAsset({ tx_type: 12, invoke_data: [] }, 174), false);
  // The wallet keeps its latest 100; an older read adds the rest, the recent entry (newer status) winning.
  const older = [{ ...txs[0], status: 1 }, { txId: 'old', tx_type: 0, asset_id: 174, value: 1, create_time: 10 }];
  const merged = mergeTxs(txs, older);
  assert.equal(merged.length, txs.length + 1);
  assert.equal(merged.find((t) => t.txId === 'a').status, undefined, 'the recent entry wins');
  assert.deepEqual(tokenHistory(merged, 174).map((t) => t.txId), ['g', 'd', 'c', 'a', 'f', 'old']);
  assert.deepEqual(mergeTxs(null, older), older);
  assert.deepEqual(tokenHistory(null, 174), []);
});

// ------------------------------------------------------------------ words

test('values as people read them: rounded down, "if sold now" for a sale value', () => {
  assert.equal(beamEstimate(0n), '0 BEAM');
  assert.equal(beamEstimate(1n), '< 0.0001 BEAM');
  assert.equal(beamEstimate(12345678n), '≈ 0.1234 BEAM');
  assert.equal(beamEstimate(321499999n), '≈ 3.214 BEAM');
  assert.equal(beamEstimate(123456_78999999n), '≈ 123,456.78 BEAM');
  assert.equal(valueEstimate(BEAM, false), '≈ 1 BEAM');
  assert.equal(valueEstimate(1250000000n, true), '≈ 12.5 BEAM if sold now');
  assert.equal(tokensWord(1), '1 token');
  assert.equal(tokensWord(3), '3 tokens');
});

// ------------------------------------------------------------------ the hidden list

test('the hidden list: positive whole ids, sorted, BEAM never', () => {
  assert.deepEqual(parseHidden([5, 3, 3, 0, -1, 1.5, '7', null, 2]), [2, 3, 5]);
  assert.deepEqual(parseHidden('nope'), []);
  assert.deepEqual(withHidden([5], 3, true), [3, 5]);
  assert.deepEqual(withHidden([3, 5], 3, false), [5]);
  assert.deepEqual(withHidden([3], 0, true), [3], 'BEAM is the wallet itself');
  assert.deepEqual(withHidden(undefined, 'x', true), []);
});

test('the hidden list is kept per wallet, under w:<wallet id>:hiddenTokens', async () => {
  const kv = new Map();
  const realGet = store.get;
  const realSet = store.set;
  store.get = async (k) => kv.get(k);
  store.set = async (k, v) => void kv.set(k, v);
  try {
    assert.equal(hiddenKey('a1a1a1a1a1a1a1a1'), 'w:a1a1a1a1a1a1a1a1:hiddenTokens');
    const a = { record: { id: 'a1a1a1a1a1a1a1a1' } };
    const b = { record: { id: 'b2b2b2b2b2b2b2b2' } };
    kv.set('w:a1a1a1a1a1a1a1a1:hiddenTokens', [174, 0, 'x']);
    assert.deepEqual([...(await loadHidden(a))], [174]);
    assert.equal(hiddenLoaded(a), true);
    await setTokenHidden(a, 999, true);
    assert.deepEqual(kv.get('w:a1a1a1a1a1a1a1a1:hiddenTokens'), [174, 999]);
    assert.deepEqual([...hiddenIds(a)], [174, 999]);
    // Another wallet on this device has its own list.
    await loadHidden(b);
    assert.deepEqual([...hiddenIds(b)], []);
    await setTokenHidden(b, 7, true);
    assert.deepEqual(kv.get('w:b2b2b2b2b2b2b2b2:hiddenTokens'), [7]);
    assert.deepEqual(kv.get('w:a1a1a1a1a1a1a1a1:hiddenTokens'), [174, 999], 'untouched');
    await setTokenHidden(b, 7, false);
    assert.deepEqual(kv.get('w:b2b2b2b2b2b2b2b2:hiddenTokens'), []);
    assert.deepEqual([...hiddenIds({ record: null })], [], 'no wallet open: nothing hidden');
  } finally {
    store.get = realGet;
    store.set = realSet;
  }
});

// ------------------------------------------------------------------ BEAM's price

test("prices: CoinGecko's simple/price for BEAM only, a path the CSP already allows; national currencies", () => {
  assert.equal(fiatPriceUrl('USD'), 'https://api.coingecko.com/api/v3/simple/price?ids=beam&vs_currencies=usd');
  assert.ok(fiatPriceUrl('EUR').startsWith(connectSources().find((s) => s.includes('coingecko'))));
  assert.ok(CSP.includes('https://api.coingecko.com/api/v3/simple/price'), 'no CSP change needed');
  for (const bad of ['usd', 'BTC', 'XAU', '', 'USD&x=1', null]) assert.throws(() => fiatPriceUrl(bad), String(bad));
  assert.equal(DEFAULT_CURRENCY, 'USD');
  assert.equal(new Set(FIAT_CURRENCIES.map(([c]) => c)).size, FIAT_CURRENCIES.length);
  for (const [code] of FIAT_CURRENCIES) assert.doesNotThrow(() => new Intl.NumberFormat('en-US', { style: 'currency', currency: code }), code);
  assert.equal(parsePrice({ beam: { usd: 0.0312 } }, 'USD'), 0.0312);
  for (const bad of [{ beam: { usd: 0 } }, { beam: { usd: -1 } }, { beam: { usd: '0.03' } }, { beam: { eur: 1 } }, { 'beam-2': { usd: 1 } }, [], null]) assert.equal(parsePrice(bad, 'USD'), null, JSON.stringify(bad));
  assert.equal(currencyOf({ fiatCurrency: 'EUR' }), 'EUR');
  assert.equal(currencyOf({ fiatCurrency: 'XYZ' }), 'USD');
  assert.equal(fiatAllowed({ fiatPrices: true }), true);
  for (const p of [{}, { fiatPrices: 'yes' }, { fiatPrices: false }, null]) assert.equal(fiatAllowed(p), false);
  assert.equal(fiatUnasked({}), true);
  assert.equal(fiatUnasked({ fiatPrices: false }), false);
});

function fakeFetch(answers) {
  const calls = [];
  const fn = async (url, opts) => {
    calls.push({ url, opts });
    const a = answers.length > 1 ? answers.shift() : answers[0];
    if (a instanceof Error) throw a;
    return { status: a.status ?? 200, text: async () => JSON.stringify(a.body ?? {}) };
  };
  fn.calls = calls;
  return fn;
}

test('prices: nothing is asked until the person says yes; then one request, kept two minutes', async () => {
  const prefs = {};
  let now = 1_000_000;
  const fetch = fakeFetch([{ body: { beam: { usd: 0.04 } } }]);
  const f = new FiatPrice({ prefs: () => prefs, fetch, clock: () => now });
  assert.equal(f.get(), null);
  await f.refresh({ force: true });
  prefs.fiatPrices = false;
  await f.refresh({ force: true });
  assert.equal(fetch.calls.length, 0, 'not asked, and "Not now": CoinGecko never asked');
  prefs.fiatPrices = true;
  let heard = 0;
  f.onChange(() => heard++);
  assert.deepEqual(await f.refresh(), { price: 0.04, currency: 'USD', at: now });
  assert.equal(heard, 1);
  assert.equal(fetch.calls.length, 1);
  const o = fetch.calls[0].opts;
  assert.equal(o.credentials, 'omit');
  assert.equal(o.referrerPolicy, 'no-referrer');
  assert.equal(o.redirect, 'error');
  now += PRICE_MAX_AGE_MS - 1;
  f.get();
  await f.refresh();
  assert.equal(fetch.calls.length, 1, 'fresh: not asked again');
  now += 2;
  await f.refresh();
  assert.equal(fetch.calls.length, 2, 'two minutes on: asked again');
  // Another currency: asked for that one; the dollar price is not shown as euros.
  prefs.fiatCurrency = 'EUR';
  assert.equal(f.current(), null);
  fetch.calls.length = 0;
  await f.refresh();
  assert.match(fetch.calls[0].url, /vs_currencies=eur$/);
  // Off again: nothing shown, nothing asked.
  prefs.fiatPrices = false;
  assert.equal(f.get(), null);
  await f.refresh({ force: true });
  assert.equal(fetch.calls.length, 1);
});

test('prices: CoinGecko busy or down keeps the last price for a while and never shows a made-up one', async () => {
  const prefs = { fiatPrices: true };
  let now = 5_000_000;
  const fetch = fakeFetch([{ body: { beam: { usd: 0.05 } } }, { status: 429 }, new Error('offline'), { body: { beam: {} } }]);
  const f = new FiatPrice({ prefs: () => prefs, fetch, clock: () => now });
  await f.refresh();
  now += PRICE_MAX_AGE_MS + 1;
  assert.equal((await f.refresh()).price, 0.05, '429: the last price stays');
  assert.match(f.error.message, /busy/);
  now += 60000;
  await f.refresh();
  assert.equal(fetch.calls.length, 2, 'busy: no new request for five minutes');
  now += BUSY_BACKOFF_MS;
  assert.equal((await f.refresh()).price, 0.05, 'offline: the last price stays');
  now += 30001;
  await f.refresh();
  assert.match(f.error.message, /no price/);
  now += 30 * 60000;
  assert.equal(f.current(), null, 'too old to show');
  const g = new FiatPrice({ prefs: () => prefs, fetch: fakeFetch([{ status: 500 }]), clock: () => now });
  assert.equal(await g.refresh(), null, 'no answer, no price: nothing shown, never 0');
});

test('money as people read it, rounded down', () => {
  assert.equal(fiatText(1234.567, 'USD', 'en-US'), '$1,234');
  assert.equal(fiatText(12.349, 'USD', 'en-US'), '$12.34');
  assert.equal(fiatText(0.004, 'USD', 'en-US'), '< $0.01');
  assert.equal(fiatText(0, 'USD', 'en-US'), '$0.00');
  assert.equal(fiatText(12.5, 'EUR', 'en-US'), '€12.50');
  assert.equal(fiatText(12.9, 'JPY', 'en-US'), '¥12');
  assert.equal(fiatText(5, 'CAD', 'en-US'), 'CA$5.00', 'only USD is a bare $');
  assert.equal(fiatValue(250000000n, 0.04), 0.1);
  assert.equal(fiatEstimate(250000000n, { price: 0.04, currency: 'USD' }, 'en-US'), '≈ $0.10');
  assert.equal(fiatEstimate(5000000n, { price: 0.05, currency: 'USD' }, 'en-US'), '< $0.01', 'not "≈ < $0.01"');
  assert.equal(fiatEstimate(250000000n, null), null);
  assert.equal(fiatEstimate(null, { price: 1, currency: 'USD' }), null);
});
