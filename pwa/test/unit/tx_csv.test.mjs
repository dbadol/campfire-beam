// Payment history as CSV (lib/tx_csv.js), as BEAM core's ExportTxHistoryToCsv writes it (issue #51).
import test from 'node:test';
import assert from 'node:assert/strict';
import { CSV_HEADER, csvField, csvDate, convertAmount, rateOf, buildCsv, csvFileName, readAllTxs, readProofs, isCsvPayment } from '../../src/lib/tx_csv.js';

const tx = (txId, extra = {}) => ({ txId, tx_type: 0, income: true, status: 3, status_string: 'received', value: 50000000, fee: 100000, asset_id: 0, comment: '', kernel: 'ab'.repeat(32), sender: 's1', receiver: 'r1', create_time: 1760000000, ...extra });

test("BEAM's columns, in BEAM's order", () => {
  assert.deepEqual(CSV_HEADER, ['Type', 'Date | Time', 'Amount', 'Unit name', 'Amount, USD', 'Amount, BTC', 'Transaction fee, BEAM', 'Status', 'Comment', 'Transaction ID', 'Kernel ID', 'Sending address', "Sending wallet's signature", 'Receiving address', "Receiving wallet's signature", 'Token', 'Payment proof']);
});

test('fields are quoted only when they need it', () => {
  assert.equal(csvField('plain'), 'plain');
  assert.equal(csvField('a, b'), '"a, b"');
  assert.equal(csvField('say "hi"'), '"say ""hi"""');
  assert.equal(csvField('two\nlines'), '"two\nlines"');
  assert.equal(csvField(' lead'), '" lead"');
  assert.equal(csvField(null), '');
  assert.equal(csvField('Amount, USD'), '"Amount, USD"', 'as BEAM writes its header');
});

test("dates as BEAM's kTimeStampFormatCsv, in this device's time zone", () => {
  const t = 1760184480; // a fixed moment
  const d = new Date(t * 1000);
  const p = (n) => String(n).padStart(2, '0');
  const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getMonth()];
  assert.equal(csvDate(t), `${p(d.getDate())} ${mon} ${d.getFullYear()} | ${p(d.getHours())}:${p(d.getMinutes())}`);
  assert.match(csvDate(t), /^\d\d [A-Z][a-z]{2} \d{4} \| \d\d:\d\d$/);
});

test("USD and BTC from the rate recorded with a payment, as BEAM's convertAmount; empty without one", () => {
  // 1.5 BEAM at 0.0423 USD (groth units: 4230000) = 0.06345 -> 0.06
  assert.equal(convertAmount(150000000, 4230000, 2), '0.06');
  assert.equal(convertAmount(250000000000, 4230000, 2), '105.75');
  assert.equal(convertAmount(150000000, 37, 8), '0.00000056', '8 places for BTC, rounded');
  assert.equal(convertAmount(150000000, 0, 2), '');
  assert.equal(convertAmount(150000000, undefined, 2), '');
  assert.equal(rateOf({ rates: [{ from: 0, to: 'usd', rate: 4230000 }] }, 'usd'), 4230000, 'as the engine writes it: BEAM is asset 0');
  assert.equal(rateOf({ rates: [{ from: 'beam', to: 'usd', rate: 4230000 }] }, 'usd'), 4230000);
  assert.equal(rateOf({ asset_id: 174, rates: [{ from: 0, to: 'usd', rate: 4230000 }, { from: 174, to: 'usd', rate: 9 }] }, 'usd'), 9, "a token payment: the token's own rate");
  assert.equal(rateOf({ asset_id: 174, rates: [{ from: 0, to: 'usd', rate: 4230000 }] }, 'usd'), 0, "never BEAM's rate for a token");
  assert.equal(rateOf({}, 'usd'), 0);
});

test('the file: payments only, newest first, proofs, quoted comments, a BOM and CRLF', () => {
  const txs = [
    tx('old', { create_time: 1700000000 }),
    tx('new', { income: false, status_string: 'sent', value: 120000000, fee: 1100000, tx_type: 7, comment: 'rent, October', sender_identity: 'id-s', receiver_identity: 'id-r', token: 'tok', create_time: 1760000000, rates: [{ from: 0, to: 'usd', rate: 4230000 }] }),
    tx('swap', { tx_type: 12 }),
    tx('fomo', { asset_id: 174, value: 56812970000, create_time: 1750000000, kernel: '0'.repeat(64) }),
  ];
  const text = buildCsv(txs, { unit: (id) => (id === 0 ? 'BEAM' : `FOMO #${id}`), proofs: new Map([['new', 'cafe']]) });
  assert.ok(text.startsWith('\ufeff'), 'UTF-8 byte order mark for Excel');
  assert.ok(text.endsWith('\r\n'));
  const lines = text.slice(1).split('\r\n').filter(Boolean);
  assert.equal(lines.length, 4, 'header + three payments; the contract call is not a payment');
  assert.equal(lines[0], 'Type,Date | Time,Amount,Unit name,"Amount, USD","Amount, BTC","Transaction fee, BEAM",Status,Comment,Transaction ID,Kernel ID,Sending address,Sending wallet\'s signature,Receiving address,Receiving wallet\'s signature,Token,Payment proof');
  assert.match(lines[1], /^Send,[^,]+,1\.2,BEAM,0\.05,,0\.011,sent,"rent, October",new,a{0}[ab]+,s1,id-s,r1,id-r,tok,cafe$/);
  assert.match(lines[2], /^Receive,[^,]+,568\.1297,FOMO #174,,,0\.001,received,,fomo,,s1,,r1,,,$/, 'no kernel yet: empty, never zeros');
  assert.match(lines[3], /^Receive,.*,old,/);
  assert.equal(isCsvPayment({ tx_type: 12 }), false);
});

test('file name: the date, and the wallet when there are several', () => {
  const d = new Date(2026, 9, 11);
  assert.equal(csvFileName(d), 'beam-campfire-payments-2026-10-11.csv');
  assert.equal(csvFileName(d, 'My Savings / 2'), 'beam-campfire-payments-My-Savings-2-2026-10-11.csv');
});

test('every page of the history, nothing twice; proofs only for completed payments sent to someone else', async () => {
  const all = Array.from({ length: 1203 }, (_, i) => tx(`t${i}`, { income: i % 2 === 0, status: i % 5 === 0 ? 4 : 3 }));
  const calls = [];
  const session = {
    call: async (method, p) => {
      calls.push([method, p.skip, p.count]);
      return all.slice(p.skip, p.skip + p.count);
    },
  };
  const got = await readAllTxs(session);
  assert.equal(got.length, 1203);
  assert.deepEqual(calls.map((c) => c[1]), [0, 500, 1000]);
  const progress = [];
  const asked = [];
  const proofs = await readProofs(session, got.slice(0, 20), async (_s, id) => (asked.push(id), id === 't3' ? '' : `p-${id}`), (d, n) => progress.push(`${d}/${n}`));
  assert.deepEqual(asked, ['t1', 't3', 't7', 't9', 't11', 't13', 't17', 't19'], 'sent (odd), completed (not every fifth)');
  assert.equal(proofs.has('t3'), false, 'an empty answer is no proof');
  assert.equal(proofs.get('t1'), 'p-t1');
  assert.equal(progress.at(-1), '8/8');
});
