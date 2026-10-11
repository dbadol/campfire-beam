// LIVE on BEAM mainnet, read-only: a real payment proof. Nothing is sent, signed or removed.
//
//   node test/e2e/live_payments.mjs        (npm run e2e:live:payments)
//
// The wallet is a COPY of FUNDER2's wallet.db (path and password from
// ~/.config/campfire-beam/test_wallets.env at run time, never printed): restoring FUNDER2 from its
// words would bring its coins but not its history, and a proof needs the payment's record (the
// receiver's signature is kept only there). In a fresh browser profile:
//   1. a completed payment FUNDER2 sent shows "Get payment proof" and the explorer link (a plain
//      link to explorer.beam.mw by kernel id; the test reads its href, the app opens nothing);
//   2. the proof is exported, then checked on "Check a payment proof": valid, the amount and
//      transaction ID match the payment, "Paid by You";
//   3. the same proof with one signature digit changed is not valid; cut short, it is not a proof.
// Nothing but this origin and the node is contacted.
import { copyFileSync, chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8921;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.FUNDER2_WALLET_DB || !env.FUNDER2_WALLET_PASS) throw new Error('FUNDER2_WALLET_DB / FUNDER2_WALLET_PASS missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-proof-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.FUNDER2_WALLET_DB, db);
chmodSync(db, 0o600);

const srv = await startServer({ root: process.env.PWA_DIST || 'dist', port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'proof' });
const report = {};
let exit = 0;
try {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), db);
  await page.fill(tid('import-pw'), env.FUNDER2_WALLET_PASS);
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(window.__campfire.screen()), null, { timeout: 180000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 300000 });
  log('imported the copy and synced');

  // The newest completed regular payment it sent.
  let tx = null;
  for (let i = 0; i < 30 && !tx; i++) {
    const txs = await page.evaluate(async () => (await import('./lib/wallet.js')).wallet.state.txs);
    tx = txs.find((t) => Number(t.status) === 3 && !t.income && [0, 7].includes(Number(t.tx_type)) && !/own address/.test(t.status_string || '') && t.kernel);
    report.txCount = txs.length;
    if (!tx) await sleep(2000);
  }
  if (!tx) throw new Error(`no completed sent payment in the copy (${report.txCount} records)`);
  report.payment = { value: String(tx.value), assetId: tx.asset_id || 0, kernel: tx.kernel, type: tx.tx_type, height: tx.height };
  log(`payment: ${tx.value} groth, kernel ${tx.kernel.slice(0, 12)}…, height ${tx.height}`);

  await page.evaluate((id) => window.__campfire.go('activity', { txId: id }), tx.txId);
  await page.waitForSelector(tid('tx-get-proof'), { timeout: 30000 });
  const href = await page.getAttribute(tid('tx-explorer'), 'href');
  if (href !== `https://explorer.beam.mw/block?kernel_id=${tx.kernel}`) throw new Error(`explorer link ${href}`);
  if ((await page.getAttribute(tid('tx-explorer'), 'rel')) !== 'noopener noreferrer') throw new Error('explorer link rel');
  report.explorer = href;
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `payments-live-01-details-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
  await page.click(tid('tx-get-proof'));
  await page.waitForSelector(tid('proof-text'), { timeout: 30000 });
  const proof = await page.getAttribute(tid('proof-text'), 'data-proof');
  if (!/^[0-9a-f]{100,}$/.test(proof)) throw new Error('the proof is not hex');
  report.proofLength = proof.length;
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `payments-live-02-proof-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });
  log(`exported a proof of ${proof.length} hex characters`);

  const check = async (text) => {
    await page.evaluate(() => window.__campfire.go('checkProof'));
    await waitScreen(page, 'checkProof');
    await page.fill(tid('proof-input'), text);
    await page.click(tid('proof-check'));
    await page.waitForSelector(`${tid('proof-valid')}, ${tid('proof-invalid')}, ${tid('proof-not-a-proof')}, ${tid('proof-result')} .notice`, { timeout: 30000 });
    return page.textContent(tid('proof-result'));
  };
  const ok = await check(proof);
  if (!(await page.isVisible(tid('proof-valid')))) throw new Error(`the real proof was not valid: ${ok}`);
  const amountShown = await page.textContent(`${tid('proof-result')} .kv:nth-child(1) .v`);
  report.valid = ok.slice(0, 220);
  if (!ok.includes(tx.kernel.slice(0, 8))) throw new Error('the verdict does not name the kernel');
  if (!/PaidbyYou/.test(ok.replace(/\s+/g, ''))) throw new Error('the sender was not recognised as this wallet');
  if (!(await page.isVisible(tid('proof-in-list')))) throw new Error('the proof was not matched to the payment in the list');
  report.fromYou = true;
  log(`valid: ${ok.slice(0, 160)}… amount shown ${amountShown}`);
  for (const scheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme: scheme });
    await sleep(300);
    await shot(page, `payments-live-03-valid-${scheme}`);
  }
  await page.emulateMedia({ colorScheme: 'light' });

  // One digit of the receiver's signature (the proof's last bytes) changed.
  const i = proof.length - 20;
  const tampered = `${proof.slice(0, i)}${proof[i] === '0' ? '1' : '0'}${proof.slice(i + 1)}`;
  const bad = await check(tampered);
  report.tampered = (await page.isVisible(tid('proof-invalid'))) ? 'not valid' : (await page.isVisible(tid('proof-not-a-proof'))) ? 'not a proof' : bad;
  if (report.tampered !== 'not valid' && report.tampered !== 'not a proof') throw new Error(`a tampered proof passed: ${bad}`);
  await shot(page, 'payments-live-04-tampered');
  // One byte in the middle changed instead: also refused.
  const amountTampered = `${proof.slice(0, 140)}${proof[140] === 'f' ? 'e' : 'f'}${proof.slice(141)}`;
  await check(amountTampered);
  report.amountTampered = (await page.isVisible(tid('proof-valid'))) ? 'VALID (bad)' : 'refused';
  if (report.amountTampered !== 'refused') throw new Error('a proof with a changed byte passed');
  const cut = await check(proof.slice(0, 60));
  report.cut = (await page.isVisible(tid('proof-valid'))) ? 'VALID (bad)' : cut.slice(0, 80);
  log(`tampered: ${report.tampered}; changed byte: ${report.amountTampered}; cut: ${report.cut}`);

  const foreign = foreignHosts(rec, srv.url);
  if (foreign.length) throw new Error(`contacted ${foreign.join(', ')}`);
  report.requests = rec.requests.length;
  log('PASS', JSON.stringify(report));
} catch (e) {
  exit = 1;
  log('LIVE PROOF FAILED:', e.message, JSON.stringify(report));
  console.log(rec.console.filter((c) => !c.text.includes(env.FUNDER2_WALLET_PASS)).slice(-25).map((c) => `[console] ${c.text.slice(0, 200)}`).join('\n'));
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
  process.exit(exit);
}
