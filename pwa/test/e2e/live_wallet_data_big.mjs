// LIVE, read-only: a wallet with a long history saves its names, notes and history (issue #55) in
// pages (engine patch 0111), where one-piece export ran out of the engine's 100 MB memory.
// A COPY of LWTEST's wallet.db (920 payments) is imported, its data saved through Settings → Backup
// → "Save wallet data", and BEAM's own CLI imports the file into another COPY of the same wallet.db.
// Nothing is sent or signed; the original wallet.db is never opened for writing.
//   node test/e2e/live_wallet_data_big.mjs
import { copyFileSync, chmodSync, mkdtempSync, rmSync, statSync, writeFileSync, readFileSync, readdirSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { startServer, launch, recordedPage, waitScreen, sleep } from './harness.mjs';
import { readEnv, tid, log } from './live_common.mjs';

const PORT = 8805;
const CLI = process.env.BEAM_WALLET_CLI || join(homedir(), 'Desktop', 'Beam', 'beam-core-build', 'out', 'macos-arm64', 'beam-wallet');
const env = readEnv(join(homedir(), '.config', 'campfire-beam', 'test_wallets.env'));
if (!env.LWTEST_WALLET_DB || !env.LWTEST_WALLET_PASS) throw new Error('LWTEST entries missing (not printed)');
const tmp = mkdtempSync(join(tmpdir(), 'campfire-bigdata-'));
const db = join(tmp, 'wallet.db');
copyFileSync(env.LWTEST_WALLET_DB, db);
chmodSync(db, 0o600);

/** The native CLI, the password in a 0600 config file (never on argv), output never printed. */
function cli(dir, args) {
  const cfg = join(dir, 'beam-wallet.cfg');
  writeFileSync(cfg, `pass=${env.LWTEST_WALLET_PASS}\n`, { mode: 0o600 });
  const r = spawnSync(CLI, [...args, `--config_file=${cfg}`], { cwd: dir, encoding: 'utf8', timeout: 300000 });
  rmSync(cfg, { force: true });
  return r.status;
}

const srv = await startServer({ port: PORT });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true });
const { page, rec } = await recordedPage(ctx, { label: 'bigdata' });
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
  await page.evaluate(() => window.__campfire.go('backup'));
  await waitScreen(page, 'backup');
  await page.locator(tid('data-save')).scrollIntoViewIfNeeded();
  const t0 = Date.now();
  await page.click(tid('data-save'));
  await page.waitForSelector(tid('auth-pw'), { timeout: 30000 });
  await page.fill(tid('auth-pw'), env.LWTEST_WALLET_PASS);
  await page.click(tid('auth-submit'));
  await page.waitForSelector(`${tid('data-save-file')}, ${tid('data-export-problem')}`, { timeout: 600000 });
  if (await page.isVisible(tid('data-export-problem'))) throw new Error(`refused: ${(await page.textContent(tid('data-export-problem'))).trim().slice(0, 200)}`);
  log(`file prepared in ${Math.round((Date.now() - t0) / 1000)} s`);
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 60000 }), page.click(tid('data-save-file'))]);
  const file = join(tmp, dl.suggestedFilename());
  await dl.saveAs(file);
  const size = statSync(file).size;
  const j = JSON.parse(readFileSync(file, 'utf8'));
  const txs = new Set((j.TransactionParameters || []).map((p) => p.TransactionId)).size;
  log(`saved ${dl.suggestedFilename()}: ${(size / 1e6).toFixed(1)} MB, ${(j.OwnAddresses || []).length} own addresses, ${(j.Contacts || []).length} contacts, ${txs} transactions`);
  if (txs < 500) throw new Error(`only ${txs} transactions in the file`);
  if (rec.console.some((c) => /Cannot enlarge memory|OOM|Aborted\(/.test(c.text))) throw new Error('the engine ran out of memory');
  // BEAM's own CLI reads it, into another copy of the same wallet.db.
  const dir2 = mkdtempSync(join(tmpdir(), 'campfire-bigdata-cli-'));
  copyFileSync(env.LWTEST_WALLET_DB, join(dir2, 'wallet.db'));
  chmodSync(join(dir2, 'wallet.db'), 0o600);
  const st = cli(dir2, ['import_data', `--wallet_path=${join(dir2, 'wallet.db')}`, `--file_location=${file}`]);
  rmSync(dir2, { recursive: true, force: true });
  log(`BEAM's CLI import_data exit ${st}`);
  if (st !== 0) throw new Error(`CLI import_data exit ${st}`);
  log('PASS');
} catch (e) {
  exit = 1;
  log('LIVE BIG EXPORT FAILED:', e.message);
} finally {
  await browser.close();
  srv.stop();
  rmSync(tmp, { recursive: true, force: true });
}
process.exit(exit);
