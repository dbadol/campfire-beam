// What a scanned code is (lib/scan_recognize.js), against the cases both apps share
// (test/beam/scan/scan_vectors.json at the repository root).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { recognize, weiOf } from '../../src/lib/scan_recognize.js';

const { vectors } = JSON.parse(readFileSync(new URL('../../../test/beam/scan/scan_vectors.json', import.meta.url), 'utf8'));

test('every shared case', () => {
  for (const v of vectors) assert.deepEqual(recognize(v.in), v.out, JSON.stringify(v.in));
  assert.ok(vectors.length >= 20);
});

test('wei: whole numbers only, scientific notation as EIP-681 writes it', () => {
  assert.equal(weiOf('1000'), '1000');
  assert.equal(weiOf('2.014e18'), '2014000000000000000');
  assert.equal(weiOf('1.5'), null);
  assert.equal(weiOf('1.50e1'), '15');
  assert.equal(weiOf('0'), null);
  assert.equal(weiOf('-1'), null);
});

test('a beam: link amount with a comma is refused, the address kept', () => {
  const A = '3f25d94eac4a95f4ff2b764f844aa588254982c6bcc83e02f157218d698c9df9477';
  assert.equal(recognize(`beam:${A}?amount=1.5`).amount, '1.5');
  for (const a of ['1,000', '1,25', '%2C5', '1%2C000']) {
    const r = recognize(`beam:${A}?amount=${a}`);
    assert.equal(r.kind, 'beam', a);
    assert.equal(r.address, A, a);
    assert.equal(r.amount, undefined, a);
  }
});
