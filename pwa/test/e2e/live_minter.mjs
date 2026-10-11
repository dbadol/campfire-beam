// LIVE on mainnet, nothing sent: the token screens with a wallet that really created tokens.
// A COPY of LWTEST's wallet.db (it created GIGA #186 and CHAD #187 with BEAM's Minter) is
// imported into a fresh browser profile; My tokens and a token's page read the Minter itself;
// Mint more, Burn and Create a token each go up to the engine's approve sheet - which, the wallet
// holding the BEAM, shows its approve button - and are cancelled there. The approve button is
// never pressed (and would still ask for the password). Before and after, the engine's own
// transaction list and balances are compared: nothing may have changed.
//
//   npm run e2e:live:minter      (or: node test/e2e/live_minter.mjs, after a build is staged)
//
// The wallet file's path and password are read from ~/.config/campfire-beam/test_wallets.env at
// run time and never printed. Screenshots go to CAMPFIRE_SHOTS.
import assert from 'node:assert/strict';
import { copyFileSync, chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8933;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.LWTEST_WALLET_DB || !env.LWTEST_WALLET_PASS) throw new Error('LWTEST_WALLET_DB / LWTEST_WALLET_PASS missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-live-minter-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.LWTEST_WALLET_DB, db);
chmodSync(db, 0o600);
execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });

const srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
const { page, rec } = await recordedPage(ctx, { label: 'live-minter' });

async function shots(name) {
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(200);
    await shot(page, `minter-live-${name}-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The engine's own view: every transaction and the balances, to compare before and after. */
const truth = () =>
  page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 1000, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    const totals = Object.fromEntries((st.totals || []).map((t) => [t.asset_id, `${t.available_str}|${t.sending_str}|${t.receiving_str}`]));
    return { txs: txs.length, ids: txs.map((t) => t.txId).sort().join(','), totals };
  });

async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return { title: (await page.textContent('.consent h2')).trim(), pay: await text('consent-pay-0'), get: await text('consent-get-0'), fee: await text('consent-fee'), total: await text('consent-total'), short: await text('consent-not-enough'), approve: await text('consent-approve') };
}

/** Cancel on the approve sheet, never approve; then the screen's own notice says so. */
async function cancelSheet(resultTestid) {
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid(resultTestid)}[data-code="rejected"]`, { timeout: 30000 });
  const last = (await page.evaluate(() => window.__campfire.consents())).at(-1);
  assert.equal(last.decision, 'rejected');
  return last;
}

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
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 240000 });
  await sleep(3000);
  const before = await truth();
  const beam = await page.evaluate(() => window.__campfire.totals()[0]);
  log(`synced; ${before.txs} transactions; BEAM available ${Number(beam.available) / 1e8}`);

  // My tokens: the Minter's own list for this wallet.
  await page.click(tid('tokens-entry'));
  await page.click(tid('tokens-mine'));
  await waitScreen(page, 'minterTokens');
  await page.waitForSelector(tid('token-card'), { timeout: 120000 });
  const cards = await page.$$eval(tid('token-card'), (els) => els.map((e) => ({ id: e.dataset.assetId, name: e.querySelector('[data-testid="token-title-name"]').textContent, minted: e.querySelector('[data-testid="token-minted"]').textContent })));
  log(`My tokens: ${JSON.stringify(cards)}`);
  assert.deepEqual(cards.map((c) => c.id), ['186', '187']);
  await shots('01-my-tokens');

  // A token's page, then Mint more 1 GIGA up to the approve sheet.
  await page.click(tid('token-open-186'));
  await waitScreen(page, 'minterToken');
  await page.waitForSelector(tid('token-facts'), { timeout: 120000 });
  const facts = await page.$eval(tid('token-facts'), (el) => [...el.querySelectorAll('.kv')].map((r) => `${r.querySelector('.k').textContent}: ${r.querySelector('.v').textContent}`));
  log(`GIGA #186: ${JSON.stringify(facts)}`);
  assert.ok(facts.includes('Who can mint it: This wallet'));
  await shots('02-token-page');
  await page.click(tid('token-mint'));
  await waitScreen(page, 'minterMint');
  await page.waitForFunction(() => /You can still mint/.test(document.querySelector('.minter-mint .token-title')?.textContent || ''), null, { timeout: 120000 });
  await page.fill(tid('mint-more-amount'), '1');
  await page.waitForFunction(() => !document.querySelector('[data-testid="mint-more-cta"]').disabled, null, { timeout: 30000 });
  await page.click(tid('mint-more-cta'));
  const mint = await readSheet();
  log(`mint sheet: ${JSON.stringify(mint)}`);
  await shots('03-mint-consent');
  assert.equal(mint.title, 'Confirm the mint');
  assert.equal(mint.get, '1 GIGA');
  assert.equal(mint.fee, '0.011 BEAM');
  assert.equal(mint.approve, 'Mint 1 GIGA', 'the wallet can pay: the approve button is there (and is not pressed)');
  const mintLog = await cancelSheet('mint-more-result');
  assert.deepEqual(mintLog.receives, [{ assetId: 186, amount: '1' }]);

  // Burn 0.00000001 GIGA from the token's page, typed confirmation, up to the approve sheet.
  await page.evaluate(() => window.__campfire.go('minterToken', { assetId: 186 }));
  await page.waitForSelector(tid('token-burn'), { timeout: 120000 });
  await page.click(tid('token-burn'));
  await waitScreen(page, 'burn');
  await page.fill(tid('burn-amount'), '0.00000001');
  await page.click(tid('burn-cta'));
  await page.fill(tid('burn-type'), 'giga');
  await page.click(tid('burn-confirm-cta'));
  const burn = await readSheet();
  log(`burn sheet: ${JSON.stringify(burn)}`);
  await shots('04-burn-consent');
  assert.equal(burn.title, 'Burn for good');
  assert.equal(burn.pay, '0.00000001 GIGA');
  assert.equal(burn.fee, '0.011 BEAM');
  assert.equal(burn.approve, 'Burn 0.00000001 GIGA forever');
  const burnLog = await cancelSheet('burn-confirm-result');
  assert.deepEqual(burnLog.spends, [{ assetId: 186, amount: '0.00000001' }]);

  // Create a token, up to the approve sheet.
  await page.evaluate(() => window.__campfire.go('minterCreate'));
  await page.waitForFunction(() => /BEAM$/.test(document.querySelector('[data-testid="mint-cost-dao"]')?.textContent || ''), null, { timeout: 120000 });
  await page.fill(tid('mint-name'), 'Campfire build check');
  await page.fill(tid('mint-ticker'), 'cfbc');
  await page.fill(tid('mint-supply'), '1000');
  await page.fill(tid('mint-short-desc'), 'Built and decoded by a test, never sent.');
  const canCreate = !(await page.isDisabled(tid('mint-cta')));
  log(`create: ${canCreate ? 'the wallet holds enough BEAM' : `not enough: ${await page.textContent(tid('mint-reason'))}`}`);
  if (canCreate) {
    await page.click(tid('mint-cta'));
    await page.click(tid('review-cta'));
    const create = await readSheet();
    log(`create sheet: ${JSON.stringify(create)}`);
    await shots('05-create-consent');
    assert.equal(create.title, 'Confirm your new token');
    assert.equal(create.pay, '60 BEAM');
    assert.equal(create.fee, '0.0167 BEAM');
    assert.equal(create.total, '60.0167 BEAM');
    assert.equal(create.approve, 'Pay 60 BEAM and create CFBC');
    await cancelSheet('review-result');
  }

  await sleep(3000);
  const afterAll = await truth();
  log(`after: ${afterAll.txs} transactions`);
  assert.equal(afterAll.txs, before.txs, 'no new transaction');
  assert.equal(afterAll.ids, before.ids);
  assert.deepEqual(afterAll.totals, before.totals, 'balances unchanged');
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.errors, []);
  log('PASS: nothing was sent');
} catch (e) {
  exit = 1;
  log('LIVE MINTER FAILED:', e.message);
  await shot(page, 'minter-live-fail').catch(() => {});
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);
