// LIVE on BEAM mainnet, no money moves: a real private (max-privacy) coin in the coin list, the
// private balance on Home, and More ways to receive on a wallet that scans.
//
//   BEAM_RECOVERY_FILE=<mainnet_recovery.bin> npm run e2e:live:coins
//
// The throwaway MAXPRIV (words read at run time from ~/.config/campfire-beam/test_wallets.env,
// never printed or screenshotted) was paid 0.01 BEAM at a max-privacy address on 2026-10-11
// (kernel e6863141…, height 4,075,082; the project notes). Restored with BEAM's snapshot, it
// scans blocks, so:
//   1. the restore announces nothing (the first read of the payment list is history);
//   2. Home says the 0.01 BEAM arrived privately and when it can be spent, and Coins lists it as
//      a private coin BEAM still holds back (type shld, maturing);
//   3. More ways to receive is on: a max-privacy and an offline address are made (in this browser's
//      copy of the wallet only), and the engine reads them back as those types.
import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts, PWA } from './harness.mjs';
import { waitHome, waitSynced } from './flows.mjs';
import { tid, log, readEnv, restoreFunder } from './live_common.mjs';

const PORT = 8971;
const RECOVERY = process.env.BEAM_RECOVERY_FILE || null;
const password = `livecoins-${Math.random().toString(36).slice(2, 10)}`;

const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
const words = (env.MAXPRIV_WALLET_SEED || '').split(/[\s;]+/).filter(Boolean);
if (words.length !== 12) throw new Error('MAXPRIV_WALLET_SEED is missing or not 12 words (not printed)');

// Its own build and port, so it runs beside the other suites.
const tmp = mkdtempSync(join(tmpdir(), 'campfire-live-coins-'));
execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
const srv = await startServer({ root: join(tmp, 'dist'), port: PORT, extra: RECOVERY ? ['--recovery-file', RECOVERY] : [] });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
await ctx.addInitScript(() => {
  window.__notified = [];
  function FakeNotification(title) {
    window.__notified.push(title);
    this.close = () => {};
    this.addEventListener = () => {};
  }
  FakeNotification.permission = 'granted';
  FakeNotification.requestPermission = () => Promise.resolve('granted');
  Object.defineProperty(window, 'Notification', { value: FakeNotification, configurable: true, writable: true });
});
const { page, rec } = await recordedPage(ctx, { label: 'live-coins' });
const both = async (name) => {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
};
let exit = 0;
try {
  await page.goto(srv.url);
  const t0 = Date.now();
  await restoreFunder(page, words, password, 'live-coins');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  log(`restored and synced in ${Math.round((Date.now() - t0) / 1000)} s`);
  // Notifications on, as a person would have them: still nothing for history.
  await page.evaluate(async () => {
    const { app } = await import('./app.js');
    await app.setPrefs({ paymentNotifications: true });
  });

  // ---- 2. the private coin
  const t1 = Date.now();
  let coin = null;
  while (Date.now() - t1 < 10 * 60000) {
    coin = await page.evaluate(async () => {
      const { wallet } = await import('./lib/wallet.js');
      const { loadCoins } = await import('./lib/coins.js');
      const all = await loadCoins(wallet.session);
      const beam = all.get(0);
      const c = beam ? [...beam.available, ...beam.locked].find((x) => x.shielded) : null;
      const t = wallet.state.totals.get(0);
      return c ? { type: c.type, status: c.status, amount: String(c.amount), maturity: c.maturity, maturingMp: t ? String(t.maturingMp) : null, height: wallet.state.status.current_height } : null;
    });
    if (coin) break;
    await sleep(5000);
  }
  if (!coin) throw new Error('no private coin found after the restore');
  log(`private coin: ${JSON.stringify(coin)}`);
  if (coin.type !== 'shld' || coin.amount !== '1000000') throw new Error('not the 0.01 BEAM private coin');

  await page.evaluate(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  if (coin.status === 'maturing') {
    await page.waitForSelector(tid('private-maturing'), { timeout: 60000 });
    log(`Home: "${(await page.textContent(tid('private-maturing'))).trim()}"`);
  } else log(`the coin is ${coin.status} now: no private line expected`);
  await both('live-coins-01-home');
  const banners = await page.$$(tid('pay-banner'));
  const notified = await page.evaluate(() => window.__notified);
  log(`notices after the restore: ${banners.length} banner(s), ${notified.length} notification(s)`);
  if (banners.length || notified.length) throw new Error('the restore announced history as news');

  await page.evaluate(() => window.__campfire.go('coins'));
  await waitScreen(page, 'coins');
  await page.waitForSelector(tid('coin-row'), { timeout: 60000 });
  const rows = await page.$$eval(tid('coin-row'), (els) => els.map((e) => `${e.dataset.type}/${e.dataset.status}: ${e.textContent}`));
  log(`coin list: ${JSON.stringify(rows)}`);
  if (!rows.some((r) => r.startsWith('shld/'))) throw new Error('the coin list does not show the private coin');
  log(`split: "${(await page.textContent(tid('split-funds')).catch(() => '')).trim()}"`);
  await page.locator(tid('coin-list')).scrollIntoViewIfNeeded();
  await both('live-coins-02-coins');

  // ---- 3. More ways to receive, on
  await page.evaluate(() => window.__campfire.go('receive'));
  await waitScreen(page, 'receive');
  await page.waitForSelector(tid('receive-address'));
  await page.click(tid('more-ways-toggle'));
  await page.waitForFunction(() => !document.querySelector('[data-testid="receive-type-max_privacy"]').disabled, null, { timeout: 60000 });
  if (await page.isVisible(tid('more-ways-blocked'))) throw new Error('More ways shows a block on a scanning wallet');
  await page.locator(tid('more-ways')).scrollIntoViewIfNeeded();
  await both('live-coins-03-more-ways');
  for (const type of ['max_privacy', 'offline']) {
    await page.click(tid(`receive-type-${type}`));
    await page.waitForSelector(tid('private-address-title'), { timeout: 60000 });
    const address = await page.evaluate(async () => {
      const t = document.querySelector('[data-testid="private-address"]').textContent;
      return t;
    });
    const full = await page.evaluate(async (want) => {
      const { wallet } = await import('./lib/wallet.js');
      const list = await wallet.session.call('addr_list', { own: true });
      const a = list.filter((x) => x.type === want).sort((x, y) => y.create_time - x.create_time)[0];
      const v = await wallet.validateAddress(a.address);
      return { length: a.address.length, type: v.type, valid: v.is_valid, mine: v.is_mine };
    }, type);
    log(`${type}: shown ${address.length} chars (shortened), made ${full.length} chars; engine reads it as ${full.type}, valid ${full.valid}, mine ${full.mine}`);
    if (full.type !== type || !full.valid) throw new Error(`${type}: the engine reads it as ${full.type}`);
    if (type === 'max_privacy') await both('live-coins-04-max-privacy-sheet');
    await page.click(tid('private-done'));
    await page.waitForSelector('.sheet', { state: 'detached' });
  }

  // Past the 20 s after catching up (lib/payment_notice.js): still nothing announced for history.
  await sleep(30000);
  const later = { banners: (await page.$$(tid('pay-banner'))).length, notified: (await page.evaluate(() => window.__notified)).length };
  log(`notices 30 s later: ${later.banners} banner(s), ${later.notified} notification(s)`);
  if (later.banners || later.notified) throw new Error('history was announced after catching up');

  const foreign = foreignHosts(rec, srv.url);
  if (foreign.length) throw new Error(`foreign hosts: ${foreign.join(', ')}`);
  if (rec.errors.length) throw new Error(`page errors: ${rec.errors.join(' | ')}`);
  log('LIVE coins: all checks passed');
} catch (e) {
  exit = 1;
  console.error('LIVE coins FAILED:', e.message);
  await shot(page, 'live-coins-FAIL').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
  process.exit(exit);
}
