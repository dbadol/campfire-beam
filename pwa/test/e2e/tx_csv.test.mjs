// Activity -> Save payment history as CSV (issue #51), end to end: the installed Google Chrome
// (headless), its own build and port, a throwaway mainnet wallet that holds nothing.
//
//   npm run e2e:tx-csv   (own build folder and port 8829)
//
// The empty wallet's real answer first; then the engine's tx_list and export_payment_proof answers are
// replaced in the page with a recorded-shape history (3 payments, a contract call, one with a comma in
// its comment), and the downloaded file is read back.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = 8829;
const tid = (id) => `[data-testid="${id}"]`;

let tmp, srv, browser, ctx, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-csv-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, acceptDownloads: true });
  // A computer without a share sheet for files: the file is downloaded.
  await ctx.addInitScript(() => {
    Object.defineProperty(navigator, 'share', { configurable: true, value: undefined });
    Object.defineProperty(navigator, 'canShare', { configurable: true, value: undefined });
  });
  ({ page, rec } = await recordedPage(ctx, { label: 'csv' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function both(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

test('an empty wallet: one tap from Activity, and a plain answer, never a dead end', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: `csv-${Math.random().toString(36).slice(2, 10)}` });
  await waitHome(page);
  await waitSynced(page);
  await page.evaluate(() => window.__campfire.go('activity'));
  await waitScreen(page, 'activity');
  await page.click(tid('activity-csv'));
  await page.waitForSelector(tid('csv-prepare'));
  // The way on is on screen on a 375 x 667 phone.
  await page.setViewportSize({ width: 375, height: 667 });
  const box = await page.locator(tid('csv-prepare')).boundingBox();
  assert.ok(box && box.y + box.height <= 667, 'Get my payment history fits a small phone');
  await page.setViewportSize({ width: 390, height: 844 });
  await both('csv-01-sheet');
  await page.click(tid('csv-prepare'));
  await page.waitForFunction(() => /No payments to save yet/.test(document.querySelector('[data-testid="csv-msg"]')?.textContent || ''));
  await page.click('.sheet button:text-is("Cancel")');
  await page.waitForSelector('.sheet', { state: 'detached' });
});

test('a history: every payment, newest first, proofs for payments sent, the file read back', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const now = Math.floor(Date.now() / 1000);
    const k = (c) => c.repeat(64);
    const txs = [
      { txId: 'a1'.repeat(16), tx_type: 0, income: true, status: 3, status_string: 'received', value: 50000000, fee: 100000, asset_id: 0, comment: 'from Ann', kernel: k('1'), sender: 'aa', receiver: 'bb', create_time: now - 300 },
      { txId: 'b2'.repeat(16), tx_type: 0, income: false, status: 3, status_string: 'sent', value: 20000000, fee: 100000, asset_id: 0, comment: 'rent, October', kernel: k('2'), sender: 'bb', receiver: 'cc', sender_identity: 'id1', receiver_identity: 'id2', create_time: now - 200 },
      { txId: 'c3'.repeat(16), tx_type: 12, income: false, status: 3, status_string: 'completed', value: 0, fee: 1100000, asset_id: 0, comment: '', kernel: k('3'), sender: '', receiver: '', create_time: now - 100 },
      { txId: 'd4'.repeat(16), tx_type: 7, income: true, status: 3, status_string: 'received', value: 1000000, fee: 0, asset_id: 0, comment: '', kernel: k('4'), sender: 'dd', receiver: 'ee', create_time: now - 50 },
    ];
    const real = wallet.session.call.bind(wallet.session);
    window.__csvCalls = [];
    wallet.session.call = async (method, params, opts) => {
      if (method === 'tx_list') {
        window.__csvCalls.push(`tx_list ${params.skip}`);
        return txs.slice(params.skip, params.skip + params.count);
      }
      if (method === 'export_payment_proof') {
        window.__csvCalls.push(`proof ${params.txId.slice(0, 4)}`);
        return { payment_proof: 'cafe01' };
      }
      return real(method, params, opts);
    };
  });
  await page.click(tid('activity-csv'));
  await page.click(tid('csv-prepare'));
  await page.waitForSelector(tid('csv-ready'));
  assert.match(await page.textContent(tid('csv-ready')), /^3 payments in beam-campfire-payments-\d{4}-\d\d-\d\d\.csv\.$/);
  assert.deepEqual(await page.evaluate(() => window.__csvCalls), ['tx_list 0', 'proof b2b2'], 'one page; a proof only for the payment sent');
  await both('csv-02-ready');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click(tid('csv-save'))]);
  const file = join(tmp, dl.suggestedFilename());
  await dl.saveAs(file);
  const text = readFileSync(file, 'utf8');
  assert.ok(text.startsWith('﻿'));
  const lines = text.slice(1).split('\r\n').filter(Boolean);
  assert.equal(lines.length, 4, 'header + 3 payments (the contract call is not a payment)');
  assert.match(lines[0], /^Type,Date \| Time,Amount,Unit name,"Amount, USD"/);
  assert.match(lines[1], /^Receive,[^,]+,0\.01,BEAM,,,0,received,,d4d4/);
  assert.match(lines[2], /^Send,[^,]+,0\.2,BEAM,,,0\.001,sent,"rent, October",b2b2[0-9a-f]*,2{64},bb,id1,cc,id2,,cafe01$/);
  assert.match(lines[3], /^Receive,[^,]+,0\.5,BEAM,,,0\.001,received,from Ann,a1a1/);
  await page.waitForSelector('.sheet', { state: 'detached' });
});

test('privacy: nothing leaves the device; no host but the origin and BEAM nodes; no CSP violation; no page error', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});
