// Each token's own decimals: its metadata's NTH_RATIO ("1 unit = NTH_RATIO smallest units",
// BEAM's Asset Descriptor v1.0, 100,000,000 when missing). A user's CANDY (#31, NTH_RATIO=10)
// showed as 1,203.7557598 where a wallet reading NTH_RATIO shows 12,037,557,598.
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseAmount, formatAmount, toInputString, AmountError, DECIMALS } from '../../src/lib/amount.js';
import { decimalsFromMetadata, display, assetLabel, VERIFIED } from '../../src/lib/meta.js';
import { learnPool, resetLpTokens, SNAPSHOT } from '../../src/lib/lp_tokens.js';
import { parseUnits } from '../../src/lib/minter.js';
import { compact } from '../../src/lib/dex_liquidity.js';
import { buildCsv } from '../../src/lib/tx_csv.js';
import { shortAmount, approveLabel } from '../../src/screens/consent.js';

// Mainnet metadata, as the chain holds it.
const CANDY = 'STD:SCH_VER=1;N=CANDY;SN=EAT;UN=CANDY;NTHUN=BITE;NTH_RATIO=10;OPT_SHORT_DESC=Cannot be split into fractions;';
const DOGGY = 'STD:SCH_VER=1;N=Dogenero;UN=doggy;SN=XDG;NTHUN=pupper;NTH_RATIO=1000000000000;OPT_SHORT_DESC=Woof';
const DUNBAR = "STD:SCH_VER=1;N=Dunbar;UN=DUNBAR;SN=DUNBAR;NTHUN=DUNBAR;NTH_RATIO=1;OPT_SHORT_DESC=Dunbar's";
const meta = (ratio) => `STD:SCH_VER=1;N=Test;SN=TST;UN=TST;NTHUN=t${ratio == null ? '' : `;NTH_RATIO=${ratio}`}`;

test('decimals: NTH_RATIO as a power of ten gives the places; none gives BEAM\'s 8', () => {
  assert.equal(decimalsFromMetadata(CANDY), 1);
  assert.equal(decimalsFromMetadata(DOGGY), 12);
  assert.equal(decimalsFromMetadata(DUNBAR), 0);
  assert.equal(decimalsFromMetadata(meta(null)), 8);
  assert.equal(decimalsFromMetadata(meta('100000000')), 8);
  assert.equal(decimalsFromMetadata(meta('100')), 2);
  assert.equal(decimalsFromMetadata(meta(`1${'0'.repeat(38)}`)), 38);
});

test('decimals: a ratio that is not a power of ten, or two that disagree, reads as 8', () => {
  // On mainnet: Bean and MSR set 21000000, karma 0.
  for (const r of ['21000000', '0', '', '010', ' 10', '10 ', '1e3', '-10', '10.0', `1${'0'.repeat(39)}`]) assert.equal(decimalsFromMetadata(meta(r)), 8, JSON.stringify(r));
  assert.equal(decimalsFromMetadata(`${meta('10')};NTH_RATIO=1000`), 8, 'wallets keeping the first and the last would disagree');
  assert.equal(decimalsFromMetadata(`${meta('10')};NTH_RATIO=10`), 1, 'the same value twice is one value');
  assert.equal(decimalsFromMetadata('N=CANDY;NTH_RATIO=10'), 8, 'no STD: prefix, no standard fields');
  assert.equal(decimalsFromMetadata(''), 8);
  assert.equal(decimalsFromMetadata(null), 8);
});

test('decimals on labels: pinned for verified assets, read for others, unknown until the metadata arrives', () => {
  assert.equal(display(0, null).decimals, 8);
  // CROWN's metadata says NTH_RATIO=1000, and no node can change a verified asset's decimals.
  assert.equal(VERIFIED[4].decimals, 3);
  assert.equal(display(4, null).decimals, 3);
  assert.equal(display(4, meta('10')).decimals, 3);
  assert.equal(display(174, meta('10')).decimals, 8, 'FOMO: verified, 8 whatever a node says');
  assert.equal(display(31, null).decimals, null, 'not read yet: shown as 8, never typed');
  assert.equal(display(31, CANDY).decimals, 1);
  assert.equal(display(161, DOGGY).decimals, 12);
  assert.equal(display(999, '').decimals, 8, 'an asset with no metadata at all');
  const l = assetLabel(8031);
  assert.equal(l.decimals, null);
  assetLabel(8031, CANDY);
  assert.equal(l.decimals, 1, 'the live label learns them with the name');
});

test('decimals of pool shares: 8, as the DEX contract writes them', () => {
  resetLpTokens();
  const [lp] = Object.keys(SNAPSHOT).map(Number);
  assert.equal(display(lp, null).decimals, 8);
  learnPool({ aid1: 0, aid2: 31, kind: 2, lpToken: 9031 });
  assert.equal(display(9031, null).decimals, null, 'a learnt, unconfirmed share is an unverified asset');
  assert.equal(display(9031, meta('10')).decimals, 1);
  resetLpTokens();
});

test('amounts in a token\'s own decimals: the user\'s CANDY and doggy', () => {
  assert.equal(formatAmount(120375575985n, { decimals: 1 }), '12,037,557,598.5');
  assert.equal(formatAmount(120375575980n, { decimals: 1 }), '12,037,557,598');
  assert.equal(formatAmount(120375575980n), '1,203.7557598', 'BEAM\'s 8 by default');
  assert.equal(formatAmount(99980001n, { decimals: 12 }), '0.000099980001');
  assert.equal(formatAmount(150n, { decimals: 0 }), '150');
  assert.equal(formatAmount(150n, { decimals: 0, minDecimals: 2 }), '150', 'no places to pad');
  assert.equal(formatAmount(5n, { decimals: 1, minDecimals: 2 }), '0.5');
  assert.equal(formatAmount(123456n, { decimals: 3, maxDecimals: 2 }), '123.46');
  assert.equal(formatAmount(123456n, { decimals: 1, maxDecimals: 4 }), '12,345.6');
  assert.equal(formatAmount(-25n, { decimals: 1 }), '-2.5');
  assert.equal(formatAmount(150000000n, { decimals: null }), '1.5', 'not known yet: shown as 8');
  assert.equal(toInputString(120375575985n, 1), '12037557598.5');
  assert.equal(toInputString(150n, 0), '150');
});

test('typing an amount reads it in the token\'s decimals', () => {
  assert.equal(parseAmount('12037557598', { decimals: 1, unit: 'CANDY #31' }), 120375575980n);
  assert.equal(parseAmount('0,5', { decimals: 1, unit: 'CANDY #31' }), 5n);
  assert.equal(parseAmount('150', { decimals: 0, unit: 'DUNBAR #150' }), 150n);
  assert.equal(parseAmount('0.000099980001', { decimals: 12, unit: 'doggy #161' }), 99980001n);
  assert.equal(parseAmount('1.5'), 150000000n, 'BEAM by default');
  for (let d = 0; d <= 12; d++) {
    for (const g of [1n, 7n, 10n ** BigInt(d), 123456789n]) assert.equal(parseAmount(toInputString(g, d), { decimals: d, unit: 'X' }), g, `${g} at ${d}`);
  }
});

test('more decimals than the token has, or decimals not known yet, are refused with a reason', () => {
  const refused = (s, opts, code, text) =>
    assert.throws(() => parseAmount(s, opts), (e) => e instanceof AmountError && e.code === code && (!text || e.message === text), `${s} ${JSON.stringify(opts)}`);
  refused('1.25', { decimals: 1, unit: 'CANDY #31' }, 'precision', 'CANDY #31 has 1 decimal place at most.');
  refused('1.5', { decimals: 0, unit: 'DUNBAR #150' }, 'precision', 'DUNBAR #150 has no decimal places.');
  refused('0.001', { decimals: 2, unit: 'Rub. #22' }, 'precision', 'Rub. #22 has 2 decimal places at most.');
  refused('0.000000001', {}, 'precision', 'BEAM has 8 decimal places at most.');
  // Read as 8, "1" of DUNBAR would be 100,000,000 of it.
  refused('1', { decimals: null, unit: 'DUNBAR #150' }, 'unknown', 'The wallet is still reading DUNBAR #150 from the network. Try again in a moment.');
  refused('99999999999999999', { decimals: 0, unit: 'X' }, 'too_large');
});

test('mint and burn read amounts in the token\'s decimals', () => {
  assert.deepEqual(parseUnits('2.5', undefined, { decimals: 1, unit: 'CANDY #31' }), { value: 25n, error: null });
  assert.equal(parseUnits('2.55', undefined, { decimals: 1, unit: 'CANDY #31' }).error, 'CANDY #31 has 1 decimal place at most.');
  assert.deepEqual(parseUnits('3', undefined, { decimals: 0, unit: 'D' }), { value: 3n, error: null });
  assert.equal(parseUnits('3', undefined, { decimals: null, unit: 'D' }).value, null);
  assert.deepEqual(parseUnits('1.5'), { value: 150000000n, error: null }, 'this app\'s own tokens: 8');
  assert.equal(parseUnits('0.000000001').error, 'Tokens have 8 decimal places at most.');
});

test('the approve sheet and DEX lists write each token in its own decimals', () => {
  assert.equal(shortAmount(120375575985n, 1), '12,037,557,598.5');
  assert.equal(shortAmount(37176000000n), '371.76');
  assert.equal(shortAmount(5n, 0), '5');
  assert.equal(shortAmount(99980001n, 12), '0.000099980001', 'under a hundredth: every digit');
  assert.equal(shortAmount(1234567890000n, 12), '1.23');
  const req = { kind: 'send', spends: [{ assetId: 31, amount: 50n }], receives: [], fee: 100000n };
  assert.equal(approveLabel(req, () => 'CANDY #31', (id) => (id === 31 ? 1 : DECIMALS)), 'Send 5 CANDY #31');
  assert.equal(approveLabel(req, () => 'CANDY #31'), 'Send 0.0000005 CANDY #31', 'no decimals given: 8, as before');
  assert.equal(compact(120375575985n, 1), '12,037,557,598.5');
  assert.equal(compact(150n, 0), '150');
  assert.equal(compact(37176000000n), '371.76');
});

test('the payment history file writes each token in its own decimals', () => {
  const tx = { txId: 'a', tx_type: 0, income: true, status: 3, create_time: 1761955980, value: 120375575980, fee: 0, asset_id: 31, comment: '' };
  const csv = buildCsv([tx], { unit: (id) => (id === 31 ? 'CANDY #31' : 'BEAM'), decimals: (id) => (id === 31 ? 1 : 8) });
  assert.match(csv, /"?12037557598"?,"?CANDY #31"?/);
  assert.match(buildCsv([tx], { unit: () => 'CANDY #31' }), /1203\.7557598/, 'without decimals: 8, as BEAM writes it');
});

test('the 8-decimal figure other wallets show, under amounts of a token with its own decimals', async () => {
  const { otherWalletsText } = await import('../../src/lib/meta.js');
  const candy = { unit: 'CANDY #31', decimals: 1, pool: null };
  assert.equal(otherWalletsText(120375575980n, candy), 'In BEAM’s desktop wallet and explorer, which show every token with 8 decimal places, this is 1,203.7557598 CANDY #31.');
  assert.equal(otherWalletsText(5000000000000n, { unit: 'doggy #161', decimals: 12, pool: null }), 'In BEAM’s desktop wallet and explorer, which show every token with 8 decimal places, this is 50,000 doggy #161.', '"5 doggy" here is 50,000 there');
  assert.equal(otherWalletsText(1n, { unit: 'BEAM', decimals: 8, pool: null }), null);
  assert.equal(otherWalletsText(1n, { unit: 'X', decimals: null, pool: null }), null, 'not known yet: no figure');
  assert.equal(otherWalletsText(1n, { unit: 'LP', decimals: 1, pool: {} }), null);
  assert.equal(otherWalletsText(null, candy), null);
});

test('metadata that comes back with other decimals than first read makes them unknown for the session', () => {
  const l = assetLabel(8077, CANDY);
  assert.equal(l.decimals, 1);
  assetLabel(8077, CANDY.replace('NTH_RATIO=10', 'NTH_RATIO=10;OPT_COLOR=#ffffff'));
  assert.equal(l.decimals, 1, 'other metadata, same decimals: kept');
  assetLabel(8077, CANDY.replace('NTH_RATIO=10', 'NTH_RATIO=1000000'));
  assert.equal(l.decimals, null, 'an amount typed with 1 must not be sent read with 6');
  assert.equal(assetLabel(4, meta('10')).decimals, 3, 'a verified asset keeps its pinned decimals');
});

test('nothing is prefilled while a token\'s decimals are unknown; split advice counts its whole units', async () => {
  assert.equal(toInputString(120375575985n, null), '');
  assert.equal(toInputString(150000000n, undefined), '1.5', 'BEAM by default');
  const { countBySize } = await import('../../src/lib/coins.js');
  assert.equal(countBySize(100n * 100000000n), 10, '100 BEAM: one coin per 10');
  assert.equal(countBySize(100n * 10n, 1), 10, '100 CANDY at 1 decimal: the same advice');
  assert.equal(countBySize(100n * 10n), 3, 'read as 8 it was a dust amount');
});
