// Airdrop codes as a CSV file: the desktop app's columns and cells (AirdropCsv,
// test/beam/contracts/airdrop/voucher_code_store_test.dart), formula injection defused,
// separators quoted, the desktop's file name.
import test from 'node:test';
import assert from 'node:assert/strict';
import { CSV_HEADER, csvCell, airdropCsv, csvFileName, csvFile } from '../../src/lib/airdrop_csv.js';
import { formatAmount } from '../../src/lib/amount.js';

const batch = (n = 2, { assetId = 0, value = (i) => String(100000 * (i + 1)), status = 'unknown' } = {}) => ({
  localId: 'batch_1',
  contractId: '8737e0d39575d7015fdea259fa091e41fc293e6c3d54e80d529033c349b5b18e',
  assetId,
  createdAt: '2026-10-11T07:15:00.000Z',
  txId: null,
  txStatus: 'broadcast',
  codes: Array.from({ length: n }, (_, i) => ({ code: ['ABCD-EFGH-JKLM-NPQR', 'WXYZ-2345-6789-ABCD', 'QRST-UVWX-YZ23-4567'][i % 3], hash: 'ab'.repeat(32), value: value(i), status: typeof status === 'function' ? status(i) : status })),
});

test('the desktop columns, one row per code, CRLF line ends', () => {
  const csv = airdropCsv(batch(), { formatValue: (v) => formatAmount(v), assetLabel: 'BEAM' });
  assert.equal(CSV_HEADER, 'Number,Code,Value,Asset,Status');
  const rows = csv.split('\r\n');
  assert.equal(rows.pop(), '', 'ends with a line break');
  assert.deepEqual(rows, ['Number,Code,Value,Asset,Status', '1,ABCD-EFGH-JKLM-NPQR,0.001,BEAM,unknown', '2,WXYZ-2345-6789-ABCD,0.002,BEAM,unknown']);
  assert.ok(!/(^|[^\r])\n/.test(csv), 'no bare LF');
});

test('statuses as the desktop names them; grouped amounts are quoted, as the desktop writes them', () => {
  const csv = airdropCsv(batch(3, { assetId: 174, value: () => '123456700000000', status: (i) => ['available', 'claimed', 'notFound'][i] }), { formatValue: (v) => formatAmount(v), assetLabel: 'FOMO' });
  assert.deepEqual(csv.split('\r\n').slice(1, 4), ['1,ABCD-EFGH-JKLM-NPQR,"1,234,567",FOMO,available', '2,WXYZ-2345-6789-ABCD,"1,234,567",FOMO,claimed', '3,QRST-UVWX-YZ23-4567,"1,234,567",FOMO,notFound']);
});

test('a cell a spreadsheet would run is defused; separators are quoted (desktop vectors)', () => {
  assert.equal(csvCell('=HYPERLINK("x")'), '"\'=HYPERLINK(""x"")"');
  assert.equal(csvCell('+1'), "'+1");
  assert.equal(csvCell('-1'), "'-1");
  assert.equal(csvCell('@SUM(A1)'), "'@SUM(A1)");
  assert.equal(csvCell('\tx'), "'\tx");
  assert.equal(csvCell('\rx'), '"\'\rx"');
  assert.equal(csvCell('a,b'), '"a,b"');
  assert.equal(csvCell('line\nbreak'), '"line\nbreak"');
  assert.equal(csvCell('FOMO'), 'FOMO');
  assert.equal(csvCell(''), '');
  const csv = airdropCsv(batch(1), { formatValue: (v) => String(v), assetLabel: '=cmd|"/c calc"!A1' });
  assert.ok(csv.includes(',"\'=cmd|""/c calc""!A1",'));
});

test('the file: the desktop name, text/csv, the same text', async () => {
  const b = batch(10);
  assert.equal(csvFileName(b), 'airdrop-codes-2026-10-11-10.csv');
  assert.equal(csvFileName({ ...b, createdAt: 'garbage' }), 'airdrop-codes-batch-10.csv');
  const f = csvFile(b, { formatValue: (v) => formatAmount(v), assetLabel: 'BEAM' });
  assert.equal(f.name, 'airdrop-codes-2026-10-11-10.csv');
  assert.equal(f.type, 'text/csv');
  assert.equal(await f.text(), airdropCsv(b, { formatValue: (v) => formatAmount(v), assetLabel: 'BEAM' }));
});
