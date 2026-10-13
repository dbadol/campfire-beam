// A payment that fails because the same wallet already spent its coins elsewhere, end to end on the
// screens: the installed Google Chrome (headless), its own build and port, a throwaway mainnet wallet
// that holds nothing. Such a refusal needs coins spent twice, which a wallet holding nothing cannot
// make; so the test checks the shape of the lines the running engine prints, then gives the page one
// refused payment as the engine reports it (its two log lines, its failed status) and looks at what
// the screens say and where Rescan leads.
//
//   npm run e2e:spent-elsewhere   (port CAMPFIRE_SPENT_PORT, default 8839)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_SPENT_PORT || 8839);
const tid = (id) => `[data-testid="${id}"]`;
const TXID = randomBytes(16).toString('hex');
const WORDS = "These coins were already spent from this wallet somewhere else, in another browser or on another device with the same wallet. Nothing more was sent from here. Rescan (in Settings) brings this wallet's balance up to date.";

let tmp, srv, browser, page, rec;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-spent-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: 'light' });
  ({ page, rec } = await recordedPage(ctx, { label: 'spent' }));
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function shots(name) {
  for (const [w, h] of [[390, 844], [1280, 800]]) {
    await page.setViewportSize({ width: w, height: h });
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(200);
      await shot(page, `${name}-${w}-${scheme}`);
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

test('the engine prints its log lines in the shape the app reads (level, date, then the text)', { timeout: 10 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: `spent-${randomBytes(6).toString('hex')}` });
  await waitHome(page);
  const lines = await page.evaluate(async () => (await import('./lib/engine.js')).engineLog.lines());
  const stamped = lines.filter((l) => /^(E )?[IWE] \d{4}-\d\d-\d\d\.\d\d:\d\d:\d\d\.\d{3} /.test(l));
  assert.ok(stamped.length > 0, `stamped lines: ${JSON.stringify(lines.slice(0, 4).map((l) => l.slice(0, 60)))}`);
});

test('a payment refused for missing coins: the payment screen says what happened, and Rescan is one tap', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(async (txId) => {
    const { noteEngineLine } = await import('./lib/engine.js');
    const { wallet } = await import('./lib/wallet.js');
    // What a release engine prints: the node's answer to its registration, then the failure.
    noteEngineLine('W 2026-10-13.10:15:02.118 Extra info: Inputs missing');
    noteEngineLine(`E 2026-10-13.10:15:05.300 [${txId}] Failed. Failed to register transaction with the blockchain, see node logs for details`);
    // ...and the payment as tx_list then lists it. The list is not read again meanwhile.
    wallet.refreshTxs = async () => {};
    wallet.state.txs = [{ txId, tx_type: 0, status: 4, status_string: 'failed', failure_reason: 'Failed to register transaction with the blockchain, see node logs for details', income: false, value: 1000000, fee: 100000, asset_id: 0, create_time: Math.floor(Date.now() / 1000), receiver: '1b6c2e3f4a5d6e7f8091a2b3c4d5e6f70819a2b3c4d5e6f708192a3b4c5d6e7f8a9', sender: '' }, ...wallet.state.txs];
    window.__campfire.go('txStatus', { txId, amount: 1000000n, fee: 100000n, address: '1b6c2e3f4a5d6e7f8091a2b3c4d5e6f70819a2b3c4d5e6f708192a3b4c5d6e7f8a9', assetId: 0 });
    wallet.emit();
  }, TXID);
  await waitScreen(page, 'txStatus');
  await page.waitForSelector(tid('tx-spent-elsewhere'));
  assert.equal(await page.textContent(tid('tx-title')), 'Payment failed');
  assert.equal(await page.textContent(`${tid('tx-spent-elsewhere')} .grow`), `${WORDS}Rescan now`);
  assert.ok(!/Failed to register/.test(await page.textContent('main')), "the engine's words are not shown");
  await shots('spent-01-payment-failed');
  await page.click(tid('tx-spent-rescan'));
  await waitScreen(page, 'fastStart');
  await page.waitForFunction(() => /and rescan$/.test(document.querySelector('[data-testid="fast-download"]')?.textContent || ''), null, { timeout: 60000 });
  await page.click(tid('fast-cancel'));
  await waitScreen(page, 'settings', 60000);
});

test('Activity: the payment says why it failed, in a word in its details and in full under them, with Rescan', { timeout: 5 * 60000 }, async () => {
  await page.evaluate((txId) => window.__campfire.go('activity', { txId }), TXID);
  await waitScreen(page, 'activity');
  await page.waitForSelector(`.sheet ${tid('tx-spent-elsewhere')}`);
  const reason = await page.evaluate(() => [...document.querySelectorAll('.sheet .kv')].map((k) => [k.querySelector('.k').textContent, k.querySelector('.v').textContent]).find(([k]) => k === 'Reason'));
  assert.deepEqual(reason, ['Reason', 'Its coins were already spent elsewhere']);
  assert.equal(await page.textContent(`.sheet ${tid('tx-spent-elsewhere')} .grow`), `${WORDS}Rescan now`);
  await shots('spent-02-activity-detail');
  await page.click(`.sheet ${tid('tx-spent-rescan')}`);
  await waitScreen(page, 'fastStart');
  assert.equal(await page.$('.sheet'), null, 'the sheet closed on the way');
  await page.click(tid('fast-cancel'));
  await waitScreen(page, 'settings', 60000);
});

test('privacy: no host but this one and BEAM nodes; no CSP violation; no page error', async () => {
  await sleep(200);
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
});
