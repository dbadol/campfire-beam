// A payment that fails because the same wallet already spent its coins somewhere else (another
// browser or device with its words or file): the node refuses it with "Inputs missing"
// (proto::TxStatus::InvalidInput, node/processor.cpp), and the engine's status says only "Failed to
// register transaction with the blockchain, see node logs for details". A release engine logs the
// node's words as a warning without the transaction's id, then the failure with it; the app matches
// the two, so the screens can say what happened and point to Rescan.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { noteEngineLine, engineLog, INPUTS_MISSING_WINDOW_MS } from '../../src/lib/engine.js';
import { SPENT_ELSEWHERE, spentElsewhere, txFailureText } from '../../src/lib/wallet.js';

const id = (c) => c.repeat(32);
// As a release engine prints them: the node's answer (wallet.cpp OnRequestComplete, a warning), then
// the failure (BaseTransaction::OnFailed: the TxContext as [txid], or [txid][sub tx], an error line).
const missing = 'W 2026-10-13.10:15:02.118 Extra info: Inputs missing';
const failed = (txId, sub = '') => `E 2026-10-13.10:15:05.300 [${txId}]${sub} Failed. Failed to register transaction with the blockchain, see node logs for details`;

test('the engine log: "Inputs missing" is matched to the next transaction that fails to register, once', () => {
  let t = 1_000_000;
  noteEngineLine(failed(id('1')), t);
  assert.equal(engineLog.inputsMissing(id('1')), false, 'a failure with no such warning before it: something else');
  noteEngineLine(missing, t);
  noteEngineLine('E 2026-10-13.10:15:04.000 [' + id('2') + '] Failed. Transaction timed out', (t += 1000));
  assert.equal(engineLog.inputsMissing(id('2')), false, 'another failure reason does not take it');
  noteEngineLine(failed(id('a')), (t += 3000));
  assert.equal(engineLog.inputsMissing(id('a')), true);
  assert.equal(engineLog.inputsMissing(id('a').toUpperCase()), true, 'any case');
  noteEngineLine(failed(id('b')), (t += 1000));
  assert.equal(engineLog.inputsMissing(id('b')), false, 'one warning names one transaction');
  noteEngineLine(missing, t);
  noteEngineLine(failed(id('c'), '[2]'), (t += 2000));
  assert.equal(engineLog.inputsMissing(id('c')), true, 'a sub-transaction too');
  noteEngineLine(missing, t);
  noteEngineLine(failed(id('d')), t + INPUTS_MISSING_WINDOW_MS + 1);
  assert.equal(engineLog.inputsMissing(id('d')), false, 'a warning from more than ten minutes before is not this one');
  assert.equal(engineLog.inputsMissing(undefined), false);
});

test('the words, only for a failed transaction the node refused that way', () => {
  assert.equal(SPENT_ELSEWHERE, "These coins were already spent from this wallet somewhere else, in another browser or on another device with the same wallet. Nothing more was sent from here. Rescan (in Settings) brings this wallet's balance up to date.");
  const refused = (txId) => txId === id('f');
  const failed = { txId: id('f'), status: 4, failure_reason: 'Failed to register transaction with the blockchain, see node logs for details' };
  assert.equal(spentElsewhere(failed, { inputsMissing: refused }), true);
  assert.equal(txFailureText(failed, { inputsMissing: refused }), SPENT_ELSEWHERE);
  assert.equal(txFailureText({ ...failed, txId: id('9') }, { inputsMissing: refused }), failed.failure_reason, 'any other failure: the engine\'s reason');
  assert.equal(spentElsewhere({ ...failed, status: 2 }, { inputsMissing: refused }), false, 'cancelled is not failed');
  assert.equal(txFailureText({ ...failed, status: 3 }, { inputsMissing: refused }), null);
});

test('the engine module reads every printed line for it; the screens show it with Rescan', () => {
  const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');
  assert.match(src('lib/engine.js'), /if \(s\.includes\('Inputs missing'\) \|\| s\.includes\('Failed to register'\)\) noteEngineLine\(s\);/);
  assert.match(src('screens/tx_status.js'), /app\.go\('fastStart', \{ rescan: true \}\)/);
  for (const f of ['screens/tx_status.js', 'screens/pool_status.js', 'screens/activity.js']) assert.match(src(f), /spentElsewhere\((tx|t)\)\s*\?\s*spentElsewhereNotice\(app/, f);
});
