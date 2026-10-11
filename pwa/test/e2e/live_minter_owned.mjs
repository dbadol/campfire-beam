// LIVE, read-only: which tokens a funded test wallet created with BEAM's Minter (view_owned),
// read through the web wallet's own Minter code on mainnet. Nothing is sent or signed.
//
//   node test/e2e/live_minter_owned.mjs [LWTEST|FUNDER|FUNDER2]   (default LWTEST)
//
// The wallet is a COPY of that wallet's wallet.db (path and password read from
// ~/.config/campfire-beam/test_wallets.env at run time, never printed), imported into a fresh
// browser profile. Prints the asset ids, minted and limits it owns, and opens My tokens.
import { copyFileSync, chmodSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { startServer, launch, recordedPage, waitScreen, shot, PWA } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const WHO = (process.argv[2] || 'LWTEST').toUpperCase();
const PORT = 8932;
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
const dbPath = env[`${WHO}_WALLET_DB`];
const pass = env[`${WHO}_WALLET_PASS`];
if (!dbPath || !pass) throw new Error(`${WHO}_WALLET_DB / ${WHO}_WALLET_PASS missing (not printed)`);
const tmp = mkdtempSync(join(tmpdir(), 'campfire-minter-owned-'));
const db = join(tmp, 'wallet.db');
copyFileSync(dbPath, db);
chmodSync(db, 0o600);
execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });

const srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'owned' });
let exit = 0;
try {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  await page.click(tid('import'));
  await waitScreen(page, 'importWallet');
  await page.setInputFiles(tid('import-file'), db);
  await page.fill(tid('import-pw'), pass);
  await page.click(tid('import-submit'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart', 'home'].includes(window.__campfire.screen()), null, { timeout: 180000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.click(tid('passkey-skip'));
  await page.waitForFunction(() => window.__campfire.screen() === 'home' && window.__campfire.sync().state === 'synced', null, { timeout: 240000 });
  const owned = await page.evaluate(async () => {
    const { minter } = await import('./screens/minter.js');
    const list = await minter().owned();
    return list.map((t) => ({ aid: t.assetId, minted: String(t.minted), limit: String(t.limit), mintable: String(t.mintable), name: (t.metadata || '').match(/;N=([^;]*)/)?.[1] || null }));
  });
  log(`${WHO} owns ${owned.length} Minter token(s): ${JSON.stringify(owned)}`);
  const held = await page.evaluate(() => Object.keys(window.__campfire.totals()).filter((k) => k !== '0'));
  log(`${WHO} holds assets: ${JSON.stringify(held)}`);
  await page.evaluate(() => window.__campfire.go('minterTokens'));
  await waitScreen(page, 'minterTokens');
  await page.waitForFunction(() => !document.querySelector('[data-testid="tokens-loading"]'), null, { timeout: 120000 });
  await shot(page, `minter-live-${WHO.toLowerCase()}-tokens`);
  if (rec.errors.length) throw new Error(`page error: ${rec.errors[0].slice(0, 200)}`);
  log('PASS');
} catch (e) {
  exit = 1;
  log('LIVE OWNED FAILED:', e.message);
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);
