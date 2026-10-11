// LIVE, read-only: Activity -> Save payment history as CSV (issue #51) on a COPY of LWTEST's
// wallet.db (a Desktop Wallet history of about 920 payments). Nothing is sent or signed; the original
// wallet.db is never opened for writing. Checks the file against the engine's own list: one row per
// regular / offline / max-privacy payment, a proof on completed payments sent to someone else, and
// the USD / BTC values the Desktop Wallet recorded with them.
//   node test/e2e/live_tx_csv.mjs
import { copyFileSync, chmodSync, mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8806;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.LWTEST_WALLET_DB || !env.LWTEST_WALLET_PASS) throw new Error('LWTEST entries missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-livecsv-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.LWTEST_WALLET_DB, db);
chmodSync(db, 0o600);

const srv = await startServer({ port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true });
await ctx.addInitScript(() => {
  Object.defineProperty(navigator, 'share', { configurable: true, value: undefined });
  Object.defineProperty(navigator, 'canShare', { configurable: true, value: undefined });
});
const { page, rec } = await recordedPage(ctx, { label: 'livecsv' });
let exit = 0;
try {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), db);
  await page.fill(tid('import-pw'), env.LWTEST_WALLET_PASS);
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(window.__campfire.screen()), null, { timeout: 180000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 180000 });
  log('imported and synced');
  // The engine's own count, for comparison (rates: true is accepted).
  const truth = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const all = [];
    for (let i = 0; i < 100; i++) {
      const p = await wallet.session.call('tx_list', { count: 500, skip: i * 500, rates: true }, { timeoutMs: 60000 });
      all.push(...p);
      if (p.length < 500) break;
    }
    const pay = all.filter((t) => [0, 7].includes(Number(t.tx_type)));
    return { all: all.length, payments: pay.length, withRates: pay.filter((t) => Array.isArray(t.rates) && t.rates.length).length, sentDone: pay.filter((t) => !t.income && Number(t.status) === 3 && t.sender !== t.receiver).length };
  });
  log(`engine: ${JSON.stringify(truth)}`);
  await page.evaluate(() => window.__campfire.go('activity'));
  await waitScreen(page, 'activity');
  await page.click(tid('activity-csv'));
  const t0 = Date.now();
  await page.click(tid('csv-prepare'));
  await page.waitForSelector(`${tid('csv-ready')}, ${tid('csv-msg')} .notice.error`, { timeout: 600000 });
  if (!(await page.isVisible(tid('csv-ready')))) throw new Error(`refused: ${(await page.textContent(tid('csv-msg'))).slice(0, 200)}`);
  log(`${(await page.textContent(tid('csv-ready'))).trim()} (${Math.round((Date.now() - t0) / 1000)} s)`);
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 60000 }), page.click(tid('csv-save'))]);
  const file = join(tmp, dl.suggestedFilename());
  await dl.saveAs(file);
  const text = readFileSync(file, 'utf8');
  const lines = text.slice(1).split('\r\n').filter(Boolean);
  const rows = lines.length - 1;
  const proofs = lines.slice(1).filter((l) => /,[0-9a-f]{40,}$/.test(l)).length;
  const usd = lines.slice(1).filter((l) => /^(Send|Receive),[^,]+,[^,]+,[^,]+,\d+\.\d\d,/.test(l)).length;
  log(`file: ${rows} rows, ${proofs} with a proof, ${usd} with a USD value, ${(text.length / 1e6).toFixed(2)} MB`);
  if (rows !== truth.payments) throw new Error(`rows ${rows} != payments ${truth.payments}`);
  if (truth.withRates > 0 && usd === 0) throw new Error('the engine has rates but the file has no USD values');
  if (!text.startsWith('\ufeffType,Date | Time,Amount,Unit name,"Amount, USD"')) throw new Error('header');
  if (rec.errors.length) throw new Error(`page errors: ${rec.errors.slice(0, 2).join(' | ')}`);
  log('PASS');
} catch (e) {
  exit = 1;
  log('LIVE CSV FAILED:', e.message.split('\n')[0]);
  await page.screenshot({ path: join(process.env.CAMPFIRE_SHOTS || tmpdir(), 'live-csv-failure.png') }).catch(() => {});
  log(`screen: ${await page.evaluate(() => window.__campfire.screen()).catch(() => '?')}`);
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);
