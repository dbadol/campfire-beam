// LIVE MONEY TEST on BEAM mainnet, tiny amounts only: a token with its own decimals.
//
//   npm run e2e:live:decimals
//
// CROWN (#4) sets NTH_RATIO=1000 in its metadata: 3 decimals, so "1 CROWN" is 1,000 of its
// smallest units (0.00001 CROWN where every token is read with 8). Test wallet FUNDER2, restored
// through the real Restore screen:
//   1. swaps 0.01 BEAM for CROWN through the Swap screen and the approve sheet (as live_swap.mjs);
//   2. sends "1" CROWN to B, a fresh throwaway wallet open at the same time (a regular payment is
//      interactive), through Send and Review, which must say 1 CROWN and, for other wallets,
//      0.00001 CROWN;
//   3. the payment must complete carrying exactly 1,000 smallest units, and B must hold 1 CROWN.
// B's 12 words are kept in test_wallets.env as DECB_WALLET_SEED (never printed). Costs about 0.022
// BEAM: the 0.011 swap fee, the 0.001 payment fee, and 0.01 BEAM that stays as CROWN (A and B).
//
// Hard limits: refuses a sheet that pays more than 0.02 BEAM or charges another fee; refuses a
// payment that is not exactly 1,000 units of CROWN; refuses to start under 0.03 BEAM available.
import { startServer, launch, recordedPage, shot, waitScreen, sleep, foreignHosts } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';
import { tid, log, funderWords, restoreFunder, total, waitTx, keepThrowaway } from './live_common.mjs';

const CROWN = 4;
const ONE_CROWN = 1000n; // NTH_RATIO=1000
const MAX_PAY_GROTH = 2000000n; // 0.02 BEAM
const FEE_GROTH = 1100000n; // 0.011 BEAM, one contract call
const PORT = Number(process.env.LIVE_PORT || 8798);
const password = `live-d-${Math.random().toString(36).slice(2, 10)}`;
const passwordB = `live-db-${Math.random().toString(36).slice(2, 10)}`;
/** "1,066.5 CROWN" → smallest units, read with `decimals`. */
const units = (text, decimals) => {
  const m = /^([0-9]+)(?:\.([0-9]+))?\b/.exec(String(text).replace(/[,+−-]/g, '').trim());
  if (!m || (m[2] || '').length > decimals) throw new Error(`not an amount with ${decimals} decimals: ${text}`);
  return BigInt(m[1]) * 10n ** BigInt(decimals) + BigInt((m[2] || '').padEnd(decimals, '0') || '0');
};

const extra = process.env.BEAM_RECOVERY_FILE ? ['--recovery-file', process.env.BEAM_RECOVERY_FILE] : [];
const srv = await startServer({ port: PORT, extra });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'D' });
const B = await recordedPage(await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }), { label: 'DB' });
// A regular payment needs both wallets online, and a page nobody touches locks itself (Settings →
// Auto-lock): 2026-11-02 the sender locked while its payment registered, and the run timed out
// though the payment reached the chain. Both pages are kept in use.
let awake = true;
(async () => {
  while (awake) {
    for (const p of [page, B.page]) await p.mouse.move(100 + Math.random() * 50, 300).catch(() => {});
    await sleep(20000);
  }
})();
let exit = 0;
try {
  log('restoring FUNDER2 through the Restore screen + recovery snapshot');
  await page.goto(srv.url);
  await restoreFunder(page, funderWords(), password, 'live-decimals');
  await waitHome(page, { timeout: 20 * 60000 });
  await waitSynced(page, 15 * 60000);
  await page.waitForFunction(() => window.__campfire.sync().canSend, null, { timeout: 300000 });
  await sleep(8000);
  const beam0 = await total(page, 0);
  const crown0 = await total(page, CROWN);
  log('before: BEAM', JSON.stringify(beam0), 'CROWN units', JSON.stringify(crown0));
  if (BigInt(beam0.available) < 3000000n) throw new Error(`FUNDER2 has ${beam0.available} groth available; need at least 0.03 BEAM`);
  const txs0 = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));

  // ---- 1. BEAM for CROWN, through Swap and the approve sheet
  await page.click(tid('swap'));
  await waitScreen(page, 'swap');
  await page.waitForFunction(() => !/Loading prices/.test(document.querySelector('[data-testid="swap-reason"]').textContent), null, { timeout: 120000 });
  await page.click(tid('swap-get-asset'));
  await page.waitForSelector(`.sheet [data-asset-id="${CROWN}"]`);
  await page.click(`.sheet [data-asset-id="${CROWN}"]`);
  await page.fill(tid('swap-pay-amount'), '0.01');
  await page.waitForSelector(tid('swap-rate'), { timeout: 60000 });
  await page.waitForFunction(() => !document.querySelector('[data-testid="swap-cta"]').disabled, null, { timeout: 60000 });
  const quote = { get: await page.textContent(tid('swap-get-exact')), rate: await page.textContent(tid('swap-rate')), cta: await page.textContent(tid('swap-cta')) };
  log('quote:', JSON.stringify(quote));
  await shot(page, 'live-decimals-01-quote');
  await page.click(tid('swap-cta'));
  await page.waitForSelector(tid('consent'), { timeout: 90000 });
  await page.waitForFunction(() => !document.querySelector('[data-testid="consent-approve"]').disabled, null, { timeout: 60000 });
  const sheet = {
    pay: await page.textContent(tid('consent-pay-0')),
    get: await page.textContent(tid('consent-get-0')),
    fee: await page.textContent(tid('consent-fee')),
    other: await page.textContent(tid('consent-other-wallets-0')).catch(() => null),
  };
  log('sheet:', JSON.stringify(sheet));
  await shot(page, 'live-decimals-02-sheet');
  if (!/BEAM/.test(sheet.pay) || units(sheet.pay, 8) > MAX_PAY_GROTH) throw new Error(`refusing: the sheet pays ${sheet.pay}`);
  if (units(sheet.fee, 8) !== FEE_GROTH) throw new Error(`refusing: the sheet charges ${sheet.fee}`);
  if (!/CROWN/.test(sheet.get)) throw new Error(`refusing: the sheet gives ${sheet.get}`);
  if (!sheet.other || !/8 decimal places/.test(sheet.other)) throw new Error('the sheet does not show what other wallets read');
  const getUnits = units(sheet.get, 3);
  await page.click(tid('consent-approve'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'txStatus', 120000);
  const swap = await waitTx(page, (t) => !txs0.has(t.txId), 'swap', 25 * 60000);
  log('swap completed:', JSON.stringify(swap));
  await page.waitForFunction(([id, before]) => BigInt((window.__campfire.totals()[id] || { available: '0' }).available) > BigInt(before), [CROWN, crown0.available], { timeout: 300000, polling: 3000 });
  await sleep(5000);
  const crown1 = await total(page, CROWN);
  const crownIn = BigInt(crown1.available) - BigInt(crown0.available);
  log(`CROWN in ${crownIn} units (sheet: ${getUnits}, at 3 decimals)`);
  if (crownIn < (getUnits * 99n) / 100n || crownIn > getUnits) throw new Error('CROWN received does not match the sheet read at 3 decimals');
  if (crownIn < ONE_CROWN) throw new Error('less than 1 CROWN arrived: nothing to send');

  // ---- 2. "1" CROWN to B, through Send and Review
  log('B: a new throwaway wallet');
  await B.page.goto(srv.url);
  const { words: wordsB } = await createWallet(B.page, { password: passwordB, passkey: false });
  keepThrowaway('DECB', wordsB);
  await waitHome(B.page, { timeout: 20 * 60000 });
  await waitSynced(B.page, 15 * 60000);
  await B.page.click(tid('receive'));
  await waitScreen(B.page, 'receive');
  await B.page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
  const addrB = (await B.page.textContent(tid('receive-address'))).trim();
  await B.page.evaluate(() => window.__campfire.go('home'));
  const txs1 = new Set((await page.evaluate(() => window.__campfire.txs())).map((t) => t.txId));
  await page.evaluate(() => window.__campfire.go('send'));
  await waitScreen(page, 'send');
  await page.fill(tid('send-address'), addrB);
  await page.waitForFunction(() => /Regular address/.test(document.querySelector('[data-testid="address-hint"]').textContent), null, { timeout: 30000 });
  await page.selectOption(tid('send-asset'), String(CROWN));
  await page.fill(tid('send-amount'), '1');
  await page.waitForFunction(() => !document.querySelector('[data-testid="review"]').disabled, null, { timeout: 60000 });
  const sendOther = await page.textContent(tid('send-other-wallets'));
  log('send:', sendOther);
  if (!/0\.00001 CROWN/.test(sendOther)) throw new Error(`Send does not say 0.00001 CROWN for other wallets: ${sendOther}`);
  await shot(page, 'live-decimals-03-send');
  await page.click(tid('review'));
  await waitScreen(page, 'review');
  const review = { amount: await page.textContent(tid('review-amount')), other: await page.textContent(tid('review-other-wallets')), fee: await page.textContent(tid('review-fee')) };
  log('review:', JSON.stringify(review));
  await shot(page, 'live-decimals-04-review');
  if (!/^1 CROWN$/.test(review.amount.trim())) throw new Error(`refusing: Review says ${review.amount}`);
  if (units(review.fee, 8) !== 100000n) throw new Error(`refusing: the fee is ${review.fee}`);
  await page.click(tid('confirm-send'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 20000 });
  await page.fill(tid('auth-pw'), password);
  await page.click(tid('auth-submit'));
  await waitScreen(page, 'txStatus', 60000);
  const pay = await waitTx(page, (t) => !txs1.has(t.txId) && !t.income, 'payment', 25 * 60000);
  log('payment completed:', JSON.stringify(pay));
  if (BigInt(pay.value) !== ONE_CROWN) throw new Error(`the payment carried ${pay.value} units, not ${ONE_CROWN}`);
  await shot(page, 'live-decimals-05-done');
  const got = await waitTx(B.page, (t) => t.income, 'B receives', 25 * 60000);
  if (BigInt(got.value) !== ONE_CROWN) throw new Error(`B received ${got.value} units, not ${ONE_CROWN}`);
  await B.page.waitForFunction((id) => (window.__campfire.totals()[id] || { available: '0' }).available === '1000', CROWN, { timeout: 300000, polling: 3000 });
  await B.page.evaluate((id) => window.__campfire.go('token', { assetId: id }), CROWN);
  await sleep(2000);
  const shownB = await B.page.textContent(tid('token-available'));
  log('B shows:', shownB);
  if (!/^1\s*CROWN$/.test(shownB.trim())) throw new Error(`B shows ${shownB}`);
  await shot(B.page, 'live-decimals-06-B-crown');
  log('PASS: "1 CROWN" was sent as exactly 1,000 units and B shows 1 CROWN; foreign hosts', JSON.stringify(foreignHosts(rec, srv.url)));
} catch (e) {
  exit = 1;
  log('LIVE DECIMALS FAILED:', e.message);
  await shot(page, 'live-decimals-failure').catch(() => {});
} finally {
  awake = false;
  await browser.close();
  srv.stop();
}
process.exit(exit);
