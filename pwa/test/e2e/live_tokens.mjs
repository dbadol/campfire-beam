// LIVE, read-only: a real wallet with many tokens and DEX liquidity tokens, on mainnet. Every
// token on Home opens its page; each page shows the balance the engine reports, a value line
// that is never a made-up 0, and exactly the payments that moved that token; Home's total is
// BEAM plus every visible token as lib/pricer.js values them on the pools just read.
//
//   npm run e2e:live:tokens      (its own port 8911 and build folder)
//
// The wallet is a COPY of LWTEST's wallet.db (path and password read from
// ~/.config/campfire-beam/test_wallets.env at run time, never printed). Nothing is sent or
// signed; the price question is answered "Not now", so nothing is asked of CoinGecko and the
// only parties are this origin and the BEAM node.
import { copyFileSync, chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { PWA, startServer, launch, recordedPage, waitScreen, shot, foreignHosts, sleep } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8911;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.LWTEST_WALLET_DB || !env.LWTEST_WALLET_PASS) throw new Error('LWTEST_WALLET_DB / LWTEST_WALLET_PASS missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-live-tokens-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.LWTEST_WALLET_DB, db);
chmodSync(db, 0o600);
execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA, stdio: 'inherit' });

const srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-US' });
const { page, rec } = await recordedPage(ctx, { label: 'live-tokens' });
const fail = (m) => {
  throw new Error(m);
};
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
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 300000 });
  log('imported and synced');
  // Let names, pools and statuses settle.
  await page.waitForFunction(() => /^(Total with tokens|Plus) /.test(document.querySelector('[data-testid="portfolio-total"]')?.textContent || ''), null, { timeout: 120000 });
  await page.waitForFunction(() => /^Total with tokens/.test(document.querySelector('[data-testid="portfolio-total"]')?.textContent || ''), null, { timeout: 120000 }).catch(() => {});
  await sleep(5000);
  if (await page.$(tid('price-ask'))) {
    await page.click(tid('price-refuse'));
    log('price question answered "Not now"');
  }

  const facts = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const { marketPricer } = await import('./lib/token_market.js');
    const { portfolio, heldTotal, tokenHistory, mergeTxs, beamEstimate, holdsAny } = await import('./lib/tokens.js');
    const pricer = marketPricer();
    // The token page reads further back than the wallet's latest 100 payments: the same read here.
    const all = (await wallet.session.call('tx_list', { count: 2000, skip: 0 })).filter((x) => [0, 7, 12].includes(Number(x.tx_type)));
    const txsAll = wallet.state.txs.length >= 100 ? mergeTxs(wallet.state.txs, all) : wallet.state.txs;
    const t = wallet.state.totals;
    let sum = heldTotal(t.get(0));
    const tokens = [];
    for (const [id, x] of t) {
      if (id === 0 || !holdsAny(x)) continue;
      const v = pricer ? pricer.valueInGroth(id, heldTotal(x)) : null;
      if (v != null) sum += v;
      const l = wallet.label(id);
      tokens.push({ id, name: l.name, pool: Boolean(l.pool), verified: l.verified, available: String(x.available), value: v == null ? null : String(v), sale: pricer ? pricer.isSaleValue(id) : false, history: tokenHistory(txsAll, id).map((tx) => tx.txId) });
    }
    const p = portfolio(t, { pricer });
    return { priced: Boolean(pricer), sum: String(sum), total: p && p.totalGroth != null ? String(p.totalGroth) : null, totalText: p && p.priced ? beamEstimate(p.totalGroth) : null, unpriced: p ? p.unpriced : 0, tokens, txs: wallet.state.txs.length, all: txsAll.length };
  });
  log(`${facts.tokens.length} tokens (${facts.tokens.filter((x) => x.pool).length} LP), ${facts.txs} recent / ${facts.all} transactions read; DEX read: ${facts.priced}; ${facts.unpriced} without a price`);
  if (!facts.priced) fail('the DEX pools were never read');
  if (facts.total !== facts.sum) fail(`total ${facts.total} != BEAM + tokens ${facts.sum}`);
  const totalShown = await page.textContent(tid('portfolio-total'));
  if (totalShown !== `Total with tokens ${facts.totalText}`) fail(`Home shows "${totalShown}", expected "Total with tokens ${facts.totalText}"`);
  log(`Home: "${totalShown}" = BEAM + ${facts.tokens.length - facts.unpriced} priced tokens`);
  await shot(page, 'live-tokens-01-home-light');
  await page.evaluate(() => document.querySelector('[data-testid="tokens"]').scrollIntoView({ block: 'start' }));
  await shot(page, 'live-tokens-02-list-light');

  for (const tk of facts.tokens) {
    await page.evaluate(() => window.scrollTo(0, 0));
    const row = `${tid('token-row')}[data-asset-id="${tk.id}"]`;
    await page.locator(row).scrollIntoViewIfNeeded();
    await page.click(row);
    await waitScreen(page, 'token');
    await page.waitForFunction(() => !/Getting the price/.test(document.querySelector('[data-testid="token-value"]').textContent) && !/Looking (through|for)/.test(document.body.textContent), null, { timeout: 120000 });
    const shown = await page.evaluate(() => ({
      title: document.querySelector('.topbar h1').textContent,
      available: document.querySelector('[data-testid="token-bal-available"]').textContent,
      value: document.querySelector('[data-testid="token-value"]').textContent,
      note: document.querySelector('[data-testid="token-note"]').textContent,
      history: [...document.querySelectorAll('[data-testid="token-history"] [data-txid]')].map((e) => e.dataset.txid),
      send: Boolean(document.querySelector('[data-testid="token-send"]')),
      width: document.scrollingElement.scrollWidth,
    }));
    const want = await page.evaluate(([a, v, sale]) => Promise.all([import('./lib/amount.js'), import('./lib/tokens.js')]).then(([am, t]) => ({ amount: am.formatAmount(BigInt(a)), value: v == null ? null : t.valueEstimate(BigInt(v), sale) })), [tk.available, tk.value, tk.sale]);
    if (!shown.available.startsWith(`${want.amount} `)) fail(`#${tk.id}: available "${shown.available}" vs ${want.amount}`);
    if (want.value == null ? !shown.value.startsWith('No price') : !shown.value.startsWith(want.value)) fail(`#${tk.id}: value "${shown.value}" vs ${want.value}`);
    if (/^≈ 0 |^0 BEAM/.test(shown.value)) fail(`#${tk.id}: a made-up 0`);
    if (JSON.stringify(shown.history) !== JSON.stringify(tk.history)) fail(`#${tk.id}: history ${shown.history.length} rows vs ${tk.history.length}`);
    if (shown.width > 390) fail(`#${tk.id}: page wider than the phone`);
    if (tk.pool && !/^Your share of the /.test(shown.note)) fail(`#${tk.id}: LP note "${shown.note}"`);
    log(`#${tk.id} ${shown.title}: ${shown.available} · ${shown.value} · ${shown.history.length} history rows`);
    if (tk.id === facts.tokens[0].id || tk.pool) {
      await shot(page, `live-tokens-page-${tk.id}-light`);
      if (shown.history.length) {
        // An older payment (beyond the wallet's latest 100) opens its details too.
        await page.click(`${tid('token-history')} [data-txid="${shown.history[shown.history.length - 1]}"]`);
        await page.waitForSelector(tid('tx-detail-title'));
        const title = await page.textContent(tid('tx-detail-title'));
        if (!title || /Payment$/.test(title)) fail(`#${tk.id}: the oldest row did not open its details`);
        await shot(page, `live-tokens-page-${tk.id}-detail-light`);
        await page.click('.sheet > .btn.btn-text:last-child');
        await page.waitForFunction(() => !document.querySelector('.overlay'));
      }
    }
    await page.click('.topbar .icon-btn');
    await waitScreen(page, 'home');
  }
  const consents = await page.evaluate(() => window.__campfire.consents());
  if (consents.length) fail(`a contract request reached consent: ${consents.length}`);
  const sent = await page.evaluate(() => window.__campfire.txs().filter((t) => Number(t.status) === 0 || Number(t.status) === 1).length);
  log(`payments under way after the run: ${sent} (nothing was sent from this page)`);
  const hosts = foreignHosts(rec, srv.url);
  if (hosts.length) fail(`asked someone else: ${hosts.join(', ')}`);
  if (rec.errors.length) fail(`page error: ${rec.errors[0].slice(0, 200)}`);
  log('PASS');
} catch (e) {
  exit = 1;
  log('LIVE TOKENS FAILED:', e.message);
  console.log(rec.console.filter((c) => !/Password field/.test(c.text) && !c.text.includes(env.LWTEST_WALLET_PASS)).slice(-30).map((c) => `[console] ${c.text.slice(0, 200)}`).join('\n'));
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);
