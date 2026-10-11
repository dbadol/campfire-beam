// Tokens end to end: a page per token, values and the total, hiding a token, and BEAM's price
// in dollars only after the person says yes. The installed Google Chrome (headless), a build of
// this tree in its own folder, BEAM mainnet (the DEX's real pools, read through the node).
// Spends nothing: a throwaway wallet that holds nothing; the page is shown token balances and
// payments it does not have (the page's state only), as asset_icons.test.mjs does. CoinGecko is
// never contacted: its one URL is answered by the test, and recorded.
//
//   npm run e2e:tokens        (its own port 8910 and build folder: runs beside the other suites)
//
// Checks: no request to anyone but this origin and the node before the price question is
// answered; the question is asked once ("Not now" is remembered; Settings turns prices on);
// Home's rows carry values and open the token's page; the total adds BEAM and the visible tokens
// up exactly as lib/pricer.js values them; a token's page shows its balance, value, verified state
// or copy warning, and only its own history (contract calls that moved it included), tappable for
// details without leaving; Send and Swap open with the token chosen; an LP token says whose pool
// it is a share of; Hide takes a token off Home, its total and Send's picker, and Show (on its
// page, or in Settings -> Hidden tokens) brings it back; the hidden list is kept per wallet.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PWA, startServer, launch, recordedPage, shot, foreignHosts, sleep, waitScreen, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8910);
const PASSWORD = `tokens-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;
const GECKO = 'api.coingecko.com';
const USD = 0.05;
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'GET, OPTIONS' };
const geckoAsked = [];

// BEAM, FOMO (verified), its LP token, BeamX, PEPE #94 (unverified) and a copy of FOMO (#173).
const HOLD = { 0: 12_50000000n, 174: 568_12970000n, 175: 2_50000000n, 7: 1_20000000n, 94: 42_00000000n, 173: 5_00000000n };
const PENDING = { 174: { receiving: 5_00000000n, maturing: 1_00000000n } };
const DEX = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const now = Math.floor(Date.now() / 1000);
const TXS = [
  { txId: 'fake-fomo-in', tx_type: 0, status: 3, income: true, asset_id: 174, value: 500000000, fee: 100000, create_time: now - 4000, kernel: '00' },
  { txId: 'fake-beam-in', tx_type: 0, status: 3, income: true, asset_id: 0, value: 100000000, fee: 100000, create_time: now - 3000, kernel: '00' },
  { txId: 'fake-swap', tx_type: 12, status: 3, income: false, fee: 1100000, create_time: now - 2000, kernel: '00', invoke_data: [{ contract_id: DEX, amounts: [{ asset_id: 0, amount: 10000000 }, { asset_id: 174, amount: -80000000 }] }] },
  { txId: 'fake-beamx-out', tx_type: 0, status: 3, income: false, asset_id: 7, value: 10000000, fee: 100000, create_time: now - 1000, kernel: '00' },
  { txId: 'fake-fomo-out', tx_type: 0, status: 1, income: false, asset_id: 174, value: 100000000, fee: 100000, create_time: now - 500, kernel: '00' },
];

let tmp, srv, browser, ctx, page, rec;

async function geckoRoute(route) {
  const req = route.request();
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
  geckoAsked.push(req.url());
  return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify({ beam: { usd: USD } }) });
}

/** The page is told it holds HOLD and made TXS (its state only; nothing exists on chain). */
async function pretend() {
  await page.evaluate(
    async ({ hold, pending, txs }) => {
      const { wallet } = await import('./lib/wallet.js');
      wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await this.__realRefresh();
        for (const [id, v] of Object.entries(hold)) {
          const p = pending[id] || {};
          this.state.totals.set(Number(id), { available: BigInt(v), receiving: BigInt(p.receiving || 0), sending: 0n, maturing: BigInt(p.maturing || 0) });
        }
        this.emit();
      };
      wallet.__realTxs = wallet.refreshTxs.bind(wallet);
      wallet.refreshTxs = async function () {
        await this.__realTxs();
        const real = this.state.txs.filter((t) => !String(t.txId).startsWith('fake-'));
        this.state.txs = [...txs, ...real].sort((a, b) => (b.create_time || 0) - (a.create_time || 0));
        this.emit();
      };
      await wallet.refreshStatus();
      await wallet.refreshTxs();
    },
    {
      hold: Object.fromEntries(Object.entries(HOLD).map(([k, v]) => [k, String(v)])),
      pending: Object.fromEntries(Object.entries(PENDING).map(([k, v]) => [k, { receiving: String(v.receiving), maturing: String(v.maturing) }])),
      txs: TXS,
    },
  );
}

async function shots(name, { scroll = null } = {}) {
  await page.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(250);
    if (scroll) await page.evaluate((s) => document.querySelector(s)?.scrollIntoView({ block: 'start' }), scroll);
    else await page.evaluate(() => window.scrollTo(0, 0));
    await sleep(150);
    await shot(page, `tokens-${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.evaluate(() => window.scrollTo(0, 0));
}

/** The primary button is on screen without scrolling on a 375x667 phone. */
async function primaryVisibleOnSmallPhone(selector) {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await sleep(200);
  const box = await page.locator(selector).boundingBox();
  await page.setViewportSize({ width: 390, height: 844 });
  return box && box.y >= 0 && box.y + box.height <= 667;
}

const text = (sel) => page.textContent(sel);
const rowSel = (id) => `${tid('token-row')}[data-asset-id="${id}"]`;
const foreign = () => foreignHosts(rec, srv.url);

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-tokens-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA, stdio: 'inherit' });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-US' });
  await ctx.route((u) => u.hostname === GECKO, geckoRoute);
  ({ page, rec } = await recordedPage(ctx, { label: 'tokens' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('Home: values from the DEX, a total, and the price question before anything is asked of CoinGecko', { timeout: 20 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  // An empty wallet has nothing to value: no question yet.
  await sleep(1500);
  assert.equal(await page.$(tid('price-ask')), null, 'nothing held: no question');
  await pretend();
  await page.waitForSelector(rowSel(174));
  await page.waitForSelector(tid('price-ask'));
  assert.match(await text(tid('price-ask')), /Show values in dollars\?.*CoinGecko for BEAM's price; it sees your IP address/);
  // Values come from the DEX's pools, read through the node: no outside party.
  await page.waitForFunction(() => /^Total with tokens ≈ [\d,.]+ BEAM$/.test(document.querySelector('[data-testid="portfolio-total"]')?.textContent || ''), null, { timeout: 120000, polling: 500 });
  await page.waitForFunction(() => /BEAM/.test(document.querySelector('[data-testid="token-row"][data-asset-id="174"] [data-testid="token-value"]')?.textContent || ''), null, { timeout: 30000 });
  assert.equal(geckoAsked.length, 0, 'not asked before the question is answered');
  assert.deepEqual(foreign(), [], 'only this origin and the node so far');
  assert.equal(await page.$(tid('balance-fiat')), null, 'no dollar value without a price');

  // The total adds up: BEAM plus every visible token, valued exactly as lib/pricer.js values them.
  const sums = await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const { marketPricer } = await import('./lib/token_market.js');
    const { portfolio, beamEstimate, heldTotal } = await import('./lib/tokens.js');
    const pricer = marketPricer();
    const t = wallet.state.totals;
    let sum = heldTotal(t.get(0));
    const rows = {};
    for (const [id, x] of t) {
      if (id === 0) continue;
      const v = pricer.valueInGroth(id, heldTotal(x));
      rows[id] = v == null ? null : String(v);
      if (v != null) sum += v;
    }
    const p = portfolio(t, { pricer });
    return { sum: String(sum), total: String(p.totalGroth), unpriced: p.unpriced, text: beamEstimate(p.totalGroth), rows, sale: { 94: pricer.isSaleValue(94), 173: pricer.isSaleValue(173) } };
  });
  console.log(`# values: ${JSON.stringify(sums)}`);
  assert.equal(sums.sum, sums.total, 'the total is BEAM plus each token value');
  assert.equal(await text(tid('portfolio-total')), `Total with tokens ${sums.text}`);
  assert.ok(sums.rows[174] && sums.rows[175] && sums.rows[7], 'FOMO, its LP token and BeamX have DEX prices');
  if (sums.unpriced) assert.match(await text(tid('portfolio-note')), new RegExp(`^${sums.unpriced} tokens? (has|have) no price and (is|are) not counted\\.$`));
  for (const [id, v] of Object.entries(sums.rows)) {
    const shown = await page.textContent(`${rowSel(id)} ${tid('token-value')}`);
    assert.equal(shown, v == null ? 'No price' : await page.evaluate(([g, sale]) => import('./lib/tokens.js').then((m) => m.valueEstimate(BigInt(g), sale)), [v, sums.sale[id] || false]), `#${id} row value`);
  }
  await page.waitForFunction(() => [...document.querySelectorAll('[data-testid="tokens"] img')].every((i) => i.complete));
  await shots('01-home-question');
  await shots('02-home-list', { scroll: '[data-testid="tokens"]' });
  assert.ok(await primaryVisibleOnSmallPhone(tid('send')), 'Send is visible on a 375x667 phone');

  // "Not now": remembered; nothing asked, and the question does not come back.
  await page.click(tid('price-refuse'));
  await page.waitForFunction(() => !document.querySelector('[data-testid="price-ask"]'));
  assert.equal((await page.evaluate(() => import('./lib/store.js').then((m) => m.getPrefs()))).fiatPrices, false);
  await page.evaluate(() => window.__campfire.go('activity'));
  await page.evaluate(() => window.__campfire.go('home'));
  await page.waitForSelector(rowSel(174));
  await sleep(1000);
  assert.equal(await page.$(tid('price-ask')), null, 'asked once');
  assert.equal(geckoAsked.length, 0, '"Not now": CoinGecko never asked');
  assert.deepEqual(foreign(), []);
});

test('Settings turns dollar values on; then one request to CoinGecko, for BEAM only', { timeout: 5 * 60000 }, async () => {
  await page.evaluate(() => window.__campfire.go('settings'));
  await page.waitForSelector(tid('price-switch'));
  assert.equal(await page.isChecked(tid('price-switch')), false);
  assert.equal(await page.$(tid('currency-select')), null, 'no currency to pick while off');
  await page.locator(tid('price-switch')).scrollIntoViewIfNeeded();
  await shots('03-settings-off', { scroll: tid('price-switch') });
  await page.click(tid('price-switch'));
  await page.waitForSelector(tid('currency-select'));
  for (let i = 0; i < 50 && !geckoAsked.length; i++) await sleep(100);
  await sleep(500);
  assert.equal(geckoAsked.length, 1, 'one request once allowed');
  assert.equal(geckoAsked[0], 'https://api.coingecko.com/api/v3/simple/price?ids=beam&vs_currencies=usd');
  assert.deepEqual(foreign(), [`https://${GECKO}`], 'CoinGecko, and only after the yes');
  await shots('04-settings-on', { scroll: tid('price-switch') });

  await page.evaluate(() => window.__campfire.go('home'));
  await page.waitForSelector(tid('balance-fiat'));
  // 12.5 BEAM at $0.05.
  assert.equal(await text(tid('balance-fiat')), '≈ $0.62');
  await page.waitForFunction(() => /^Total with tokens ≈ [\d,.]+ BEAM · (≈ \$[\d,.]+|< \$0\.01)$/.test(document.querySelector('[data-testid="portfolio-total"]').textContent));
  assert.match(await text(`${rowSel(174)} ${tid('token-value')}`), /^≈ \$[\d,.]+$|^< \$0\.01$/);
  await shots('05-home-dollars');
  // Moving between screens does not ask again (two minutes).
  await page.evaluate(() => window.__campfire.go('activity'));
  await page.evaluate(() => window.__campfire.go('home'));
  await page.waitForSelector(tid('balance-fiat'));
  assert.equal(geckoAsked.length, 1);

  // The question's other answer: cleared, it is asked again on Home, and "Show in dollars" asks CoinGecko once.
  await page.evaluate(async () => {
    const { app } = await import('./app.js');
    await app.setPrefs({ fiatPrices: null });
    app.go('home');
  });
  await page.waitForSelector(tid('price-ask'));
  assert.equal(await page.$(tid('balance-fiat')), null, 'no answer: no dollar value');
  const before = geckoAsked.length;
  await page.click(tid('price-allow'));
  await page.waitForSelector(tid('balance-fiat'));
  await page.waitForFunction(() => !document.querySelector('[data-testid="price-ask"]'));
  assert.equal(geckoAsked.length, before + 1);
  assert.equal((await page.evaluate(() => import('./lib/store.js').then((m) => m.getPrefs()))).fiatPrices, true);
});

test("a token's page: balance, value, verified, its own history; Send and Swap open with it", { timeout: 5 * 60000 }, async () => {
  await page.waitForSelector(rowSel(174));
  await page.click(rowSel(174));
  await waitScreen(page, 'token');
  await page.waitForFunction(() => /BEAM · (≈ \$|< \$)/.test(document.querySelector('[data-testid="token-value"]')?.textContent || ''), null, { timeout: 60000 });
  assert.equal(await page.textContent('.topbar h1'), 'FOMO');
  assert.equal(await text(tid('token-available')), '568.1297FOMO');
  assert.equal(await text(tid('token-note')), 'Verified asset #174.');
  assert.equal(await text(tid('token-bal-incoming')), '+5 FOMO');
  assert.equal(await text(tid('token-bal-maturing')), '1 FOMO');
  assert.equal(await text(tid('token-bal-outgoing')), '0');
  assert.equal(await page.$(tid('token-copy-warning')), null);
  // Its own history: the FOMO payments and the swap that bought FOMO, newest first; not BEAM's, not BeamX's.
  const ids = await page.$$eval(`${tid('token-history')} [data-txid]`, (els) => els.map((e) => e.dataset.txid));
  assert.deepEqual(ids, ['fake-fomo-out', 'fake-swap', 'fake-fomo-in']);
  assert.ok(await primaryVisibleOnSmallPhone(tid('token-send')), 'Send is visible on a 375x667 phone');
  assert.match(await page.getAttribute(tid('token-send'), 'class'), /btn-primary/);
  await shots('06-token-fomo');
  await shots('07-token-fomo-history', { scroll: tid('token-history') });
  // A row opens its details here, as in Activity, and closing leaves the token's page.
  await page.click(`${tid('token-history')} [data-txid="fake-swap"]`);
  await page.waitForSelector(tid('tx-detail-title'));
  assert.equal(await text(tid('tx-detail-title')), 'DEX swap');
  assert.equal(await page.evaluate(() => window.__campfire.screen()), 'token');
  await shot(page, 'tokens-08-token-detail-light');
  await page.click('.sheet > .btn.btn-text:last-child');
  await page.waitForFunction(() => !document.querySelector('.overlay'));

  await page.click(tid('token-send'));
  await waitScreen(page, 'send');
  assert.equal(await page.inputValue(tid('send-asset')), '174', 'Send opens with FOMO chosen');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'token');
  await page.click(tid('token-swap'));
  await waitScreen(page, 'swap');
  await page.waitForFunction(() => /FOMO/.test(document.querySelector('[data-testid="swap-pay-asset"]')?.textContent || ''));
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'token');
  await page.click(tid('token-receive'));
  await waitScreen(page, 'receive');
  assert.equal(await page.textContent('.topbar h1'), 'Receive FOMO');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'token');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
});

test('an LP token names its pool; a copy of FOMO carries the warning; an unverified token says so', { timeout: 5 * 60000 }, async () => {
  await page.click(rowSel(175));
  await waitScreen(page, 'token');
  assert.equal(await page.textContent('.topbar h1'), 'BEAM/FOMO LP');
  assert.equal(await text(tid('token-note')), 'Your share of the BEAM/FOMO pool (1% fee).');
  assert.equal(await page.$(tid('token-swap')), null, 'no Swap for a pool share');
  const hasPoolScreen = await page.evaluate(() => import('./app.js').then((m) => m.app.has('dexPool')));
  assert.equal(Boolean(await page.$(tid('token-pool'))), hasPoolScreen, 'Pool only when this release has the pool screen');
  await page.waitForFunction(() => /≈/.test(document.querySelector('[data-testid="token-value"]').textContent));
  await shots('09-token-lp');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');

  await page.click(rowSel(173));
  await waitScreen(page, 'token');
  assert.equal(await page.textContent('.topbar h1'), 'FOMO #173');
  assert.equal(await text(tid('token-copy-warning')), 'Not the verified FOMO (#174). Anyone can create an asset with any name.');
  assert.match(await text(tid('token-note')), /^Unverified asset #173\. Anyone can create an asset with any name/);
  await shots('10-token-copy');
  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
});

test('Hide: off Home, its total and Send; one tap back on its page or in Settings; kept per wallet', { timeout: 5 * 60000 }, async () => {
  const noteCount = async () => Number(((await page.$(tid('portfolio-note'))) ? await text(tid('portfolio-note')) : '0').match(/^\d+/)?.[0] || 0);
  const totalBefore = await text(tid('portfolio-total'));
  const notesBefore = await noteCount();
  const pepePriced = await page.evaluate(() => import('./lib/token_market.js').then((m) => m.marketPricer().valueInGroth(94, 100000000n) != null));
  await page.click(rowSel(94));
  await waitScreen(page, 'token');
  await page.waitForFunction(() => /PEPE|Asset/.test(document.querySelector('.topbar h1').textContent));
  await page.click(tid('token-hide'));
  await page.waitForSelector(tid('token-hidden-note'));
  await shots('11-token-hidden');
  const rid = await page.evaluate(() => import('./lib/store.js').then((m) => m.getWalletRecord()).then((r) => r.id));
  const stored = await page.evaluate((k) => import('./lib/store.js').then((m) => m.store.get(k)), `hiddenTokens:${rid}`);
  assert.deepEqual(stored, [94], 'kept under hiddenTokens:<wallet id>');
  assert.equal((await page.evaluate(() => import('./lib/store.js').then((m) => m.getPrefs()))).hiddenAssets, undefined, 'not app-wide');

  await page.click('.topbar .icon-btn');
  await waitScreen(page, 'home');
  await page.waitForSelector(tid('show-hidden-tokens'));
  assert.equal(await page.$(rowSel(94)), null, 'gone from Home');
  assert.equal(await text(tid('show-hidden-tokens')), 'Show 1 hidden token');
  // Hidden tokens leave the total: an unpriced PEPE leaves the "no price" count, a priced one the sum.
  if (pepePriced) assert.notEqual(await text(tid('portfolio-total')), totalBefore);
  else assert.equal(await noteCount(), notesBefore - 1, 'one token fewer without a price');
  await page.click(tid('show-hidden-tokens'));
  await page.waitForSelector(`${rowSel(94)}[data-hidden="1"]`);
  assert.match(await text(`${rowSel(94)} ${tid('token-sub')}`), /^Hidden · /);
  await shots('12-home-hidden-shown', { scroll: '[data-testid="tokens"]' });

  // Send's picker leaves it out.
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  const options = await page.$$eval(`${tid('send-asset')} option`, (o) => o.map((x) => x.value));
  assert.ok(!options.includes('94') && options.includes('174'), options.join(','));

  // Settings -> Hidden tokens -> Show.
  await page.evaluate(() => window.__campfire.go('settings'));
  await page.waitForSelector(tid('hidden-tokens-row'));
  assert.match(await text(tid('hidden-tokens-row')), /1 token hidden from Wallet/);
  await page.click(tid('hidden-tokens-row'));
  await waitScreen(page, 'hiddenTokens');
  await page.waitForSelector(`${tid('hidden-token-row')}[data-asset-id="94"]`);
  await shots('13-hidden-tokens');
  await page.click(tid('hidden-token-show'));
  await page.waitForSelector(tid('hidden-tokens-empty'));
  await shots('14-hidden-tokens-empty');
  assert.deepEqual(await page.evaluate((k) => import('./lib/store.js').then((m) => m.store.get(k)), `hiddenTokens:${rid}`), []);
  await page.click(tid('hidden-tokens-home'));
  await waitScreen(page, 'home');
  await page.waitForSelector(rowSel(94));
  assert.equal(await page.$(tid('show-hidden-tokens')), null);

  // Nothing but this origin, the node, and CoinGecko's one URL after the yes.
  assert.deepEqual(foreign(), [`https://${GECKO}`]);
  for (const u of geckoAsked) assert.equal(u, 'https://api.coingecko.com/api/v3/simple/price?ids=beam&vs_currencies=usd');
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  assert.equal(await page.evaluate(() => document.scrollingElement.scrollWidth), 390, 'nothing wider than the phone');
});
