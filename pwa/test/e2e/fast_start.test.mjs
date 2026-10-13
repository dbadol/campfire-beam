// Issue #79, end to end: on Restore and Rescan, "Use a recovery file I downloaded" is always there
// as the second button, under one line on where the snapshot comes from (BEAM's address as a link).
// The installed Google Chrome (headless), its own build and port; the dev server serves a small junk
// file as the snapshot (nothing is downloaded from BEAM, nothing is imported); throwaway mainnet
// wallets that hold nothing.
//
//   npm run e2e:fast-start   (port CAMPFIRE_FAST_START_PORT, default 8837)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, sleep, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_FAST_START_PORT || 8837);
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `fs-${randomBytes(6).toString('hex')}`;
const OFFICIAL = 'mobile-restore.beam.mw/mainnet/mainnet_recovery.bin';
const LINE =
  "BEAM publishes this snapshot daily at mobile-restore.beam.mw/mainnet/mainnet_recovery.bin, for its own wallets too. This site only passes it on, and the wallet engine checks any copy against the blockchain's proof of work.";
const SCAN = ' Without it, the wallet can scan the chain instead (1–4 hours).';

let tmp, srv, browser, junk, words;
const pages = [];

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-faststart-'));
  junk = join(tmp, 'junk_recovery.bin');
  writeFileSync(junk, randomBytes(2 * 1024 * 1024)); // "2 MB": a snapshot the engine refuses
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT, extra: ['--recovery-file', junk] });
  browser = await launch();
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

async function fresh(label) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: 'light' });
  const r = await recordedPage(ctx, { label });
  pages.push(r);
  return r.page;
}

async function shots(page, name) {
  const size = page.viewportSize();
  for (const [w, h] of [[390, 844], [1280, 800]]) {
    await page.setViewportSize({ width: w, height: h });
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(200);
      await shot(page, `${name}-${w}-${scheme}`);
    }
  }
  await page.setViewportSize(size);
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The primary and the file button are both in sight on a 375 x 667 phone. */
async function bothFit(page) {
  const size = page.viewportSize();
  await page.setViewportSize({ width: 375, height: 667 });
  await sleep(250);
  const boxes = await Promise.all(['.actions .btn-primary', tid('recovery-file-choose')].map((s) => page.locator(s).first().boundingBox()));
  await page.setViewportSize(size);
  return boxes.every((b) => b && b.y >= 0 && b.y + b.height <= 667);
}

async function choiceScreen(page) {
  await page.waitForFunction(() => /^Download 2 MB and (start|rescan)$/.test(document.querySelector('[data-testid="fast-download"]')?.textContent || ''), null, { timeout: 60000 });
  return page.evaluate(() => {
    const t = (id) => document.querySelector(`[data-testid="${id}"]`);
    const file = t('recovery-file-choose');
    const link = t('recovery-file-link');
    return {
      download: t('fast-download').className,
      file: file && file.checkVisibility() ? file.className : null,
      fileText: file && file.textContent,
      source: t('recovery-source') && t('recovery-source').textContent,
      link: link && { href: link.getAttribute('href'), text: link.textContent, target: link.target, rel: link.rel },
      skip: t('fast-skip') && t('fast-skip').textContent,
      help: Boolean(t('recovery-file-help')),
      notNow: Boolean(t('fast-cancel')),
    };
  });
}

test('Rescan (any wallet): the file is the second button, the line says where it comes from, no scanning instead', { timeout: 10 * 60000 }, async () => {
  const page = await fresh('rescan');
  await page.goto(srv.url);
  ({ words } = await createWallet(page, { password: PASSWORD }));
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.click(tid('rescan-row'));
  await waitScreen(page, 'fastStart');
  const c = await choiceScreen(page);
  assert.deepEqual(c, {
    download: 'btn btn-primary',
    file: 'btn btn-secondary',
    fileText: 'Use a recovery file I downloaded',
    source: LINE,
    link: { href: `https://${OFFICIAL}`, text: OFFICIAL, target: '_blank', rel: 'noopener noreferrer' },
    skip: null,
    help: false,
    notNow: true,
  });
  await shots(page, 'faststart-01-rescan');
  assert.ok(await bothFit(page), 'Download and the file button in sight at 375 x 667');
  await page.click(tid('fast-cancel'));
  await waitScreen(page, 'settings', 60000);
});

test('Restore: the same, with scanning instead (1–4 hours); a file the engine refuses says so and keeps every way on', { timeout: 10 * 60000 }, async () => {
  assert.ok(words, 'needs the words of the wallet made above');
  const page = await fresh('restore');
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  await page.click(tid('restore'));
  await waitScreen(page, 'restore');
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.click(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.click(tid('save-password'));
  for (let i = 0; i < 60; i++) {
    const s = await page.evaluate(() => document.getElementById('app').dataset.screen);
    if (s === 'fastStart') break;
    if (s === 'passkeySetup') await page.click(tid('passkey-skip')).catch(() => {});
    if (s === 'ipNotice') await page.click(tid('ip-connect')).catch(() => {});
    await sleep(500);
  }
  await waitScreen(page, 'fastStart');
  const c = await choiceScreen(page);
  assert.deepEqual(c, {
    download: 'btn btn-primary',
    file: 'btn btn-secondary',
    fileText: 'Use a recovery file I downloaded',
    source: LINE + SCAN,
    link: { href: `https://${OFFICIAL}`, text: OFFICIAL, target: '_blank', rel: 'noopener noreferrer' },
    skip: 'Skip and scan instead (1–4 hours)',
    help: false,
    notNow: false,
  });
  await shots(page, 'faststart-02-restore');
  assert.ok(await bothFit(page), 'Download and the file button in sight at 375 x 667');

  // A file that is not BEAM's snapshot: refused in words, nothing changed, every way on still there.
  await page.setInputFiles(tid('recovery-file'), junk);
  await page.waitForSelector('main .notice.error', { timeout: 5 * 60000 });
  const after = await choiceScreen(page);
  assert.equal(after.file, 'btn btn-secondary', 'the file button stays');
  assert.equal(after.help, true, 'and now says how to get the file');
  assert.equal(
    await page.textContent(tid('recovery-file-help')),
    'To use the file: tap the address above (about 330 MB; on iPhone, Safari saves it to Files → Downloads), then come back and choose it with "Use a recovery file I downloaded". It is read on this device only.',
  );
  assert.equal(after.skip, 'Skip and scan instead (1–4 hours)');
  console.log(`# refused: ${(await page.textContent('main .notice.error')).slice(0, 160)}`);
  await shots(page, 'faststart-03-restore-file-refused');
});

test('privacy: no host but this one and BEAM nodes; no CSP violation; no page error', async () => {
  await sleep(200);
  for (const { page, rec } of pages) {
    assert.deepEqual(foreignHosts(rec, srv.url), [], rec.label);
    assert.deepEqual(await page.evaluate(() => window.__cspViolations), [], rec.label);
    assert.deepEqual(rec.errors, [], rec.label);
  }
});
