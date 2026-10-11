// Every text field takes typing on a phone. The owner, on an iPhone: "I can't type there, only
// Paste" (Backup's password), then "some yes and some no". Fields that the app focused by itself
// after opening got no keyboard on iOS, and a tap on such a focused field offered only Paste.
// So, on an emulated iPhone (touch, coarse pointer), on every screen and sheet with a text field:
//   1. nothing focuses a text field by itself when it opens;
//   2. each visible field, tapped, takes typed text.
// A throwaway mainnet wallet, no money. Own build and port, so it runs beside the other suites.
//   npm run e2e:inputs
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, sleep, PWA } from './harness.mjs';
import { waitHome } from './flows.mjs';

const PORT = 8824;
const tid = (id) => `[data-testid="${id}"]`;
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const PASSWORD = `in-${Math.random().toString(36).slice(2, 8)}`; // 9 characters: short for the iCloud copy, so its second step shows

let tmp, srv, browser, page;
const checked = [];

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-inputs-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, userAgent: IPHONE, hasTouch: true, isMobile: true });
  ({ page } = await recordedPage(ctx, { label: 'inputs' }));
});
test.after(async () => {
  console.log(`# fields typed into: ${checked.length}\n# ${checked.join(', ')}`);
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

/** No text field focused by itself; then tap every visible text field and type into it. */
async function fieldsTakeTyping(where) {
  await sleep(400);
  const self = await page.evaluate(() => {
    const a = document.activeElement;
    return a && (a.tagName === 'TEXTAREA' || (a.tagName === 'INPUT' && !['checkbox', 'radio', 'file', 'range', 'button', 'submit'].includes(a.type))) ? a.dataset.testid || a.getAttribute('aria-label') || a.tagName : null;
  });
  assert.equal(self, null, `${where}: a field focused itself (${self}); on an iPhone it would get no keyboard`);
  const n = await page.evaluate(() => {
    let i = 0;
    for (const e of document.querySelectorAll('input, textarea')) {
      e.removeAttribute('data-typecheck');
      const t = (e.type || '').toLowerCase();
      if (['checkbox', 'radio', 'file', 'range', 'button', 'submit', 'hidden'].includes(t) || e.disabled || e.readOnly) continue;
      if (typeof e.checkVisibility === 'function' ? !e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : !e.getClientRects().length) continue;
      e.setAttribute('data-typecheck', String(i++));
    }
    return i;
  });
  assert.ok(n > 0, `${where}: no text field found`);
  for (let i = 0; i < n; i++) {
    const sel = `[data-typecheck="${i}"]`;
    const name = await page.$eval(sel, (e) => e.dataset.testid || e.getAttribute('aria-label') || e.placeholder || e.tagName);
    await page.locator(sel).scrollIntoViewIfNeeded();
    const before = await page.inputValue(sel);
    await page.tap(sel);
    assert.equal(await page.evaluate((s) => document.activeElement === document.querySelector(s), sel), true, `${where} ${name}: a tap does not focus it`);
    await page.keyboard.type('12');
    const after = await page.inputValue(sel);
    assert.notEqual(after, before, `${where} ${name}: typing did not reach it`);
    await page.fill(sel, before);
    checked.push(`${where}:${name}`);
  }
  await page.evaluate(() => document.activeElement && document.activeElement.blur && document.activeElement.blur());
}

const go = async (name, params) => {
  await page.evaluate(([n, p]) => window.__campfire.go(n, p || {}), [name, params]);
  await waitScreen(page, name, 30000);
};

test('setup: restore and password fields take typing; nothing focuses itself', { timeout: 10 * 60000 }, async () => {
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 60000);
  // Throwaway words from the create screen (no picture of them), then back to restore them.
  await page.tap(tid('create'));
  await waitScreen(page, 'backup');
  await page.waitForSelector('[data-testid="words"] .word');
  await page.tap(tid('reveal'));
  const words = await page.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  await go('welcome');
  await page.tap(tid('restore'));
  await waitScreen(page, 'restore');
  await fieldsTakeTyping('restore');
  await page.fill(tid('word-1'), words.join(' '));
  await page.waitForFunction(() => !document.querySelector('[data-testid="restore-submit"]').disabled, null, { timeout: 30000 });
  await page.tap(tid('restore-submit'));
  await waitScreen(page, 'setPassword');
  await fieldsTakeTyping('setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.tap(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'fastStart'].includes(window.__campfire.screen()), null, { timeout: 30000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') await page.tap(tid('passkey-skip'));
  await waitScreen(page, 'fastStart');
  await page.waitForSelector(tid('fast-skip'));
  await page.tap(tid('fast-skip'));
  // Scanning from genesis (skipped snapshot): Home, not "synced", is enough for the fields.
  await waitHome(page, { timeout: 5 * 60000 });
});

test('screens: Send, names, airdrop codes, Swap, Buy, change password, delete, own node, owner key', { timeout: 10 * 60000 }, async () => {
  for (const name of ['send', 'names', 'airdrop', 'airdropCreate', 'swap', 'buyBeam', 'changePassword', 'deleteWallet', 'ownNode', 'ownerKey']) {
    await go(name);
    await sleep(name === 'swap' || name === 'buyBeam' ? 2500 : 600);
    await fieldsTakeTyping(name);
  }
});

test('sheets: Backup export, the iCloud copy (both steps), update from another address, confirm it is you', { timeout: 10 * 60000 }, async () => {
  await go('backup');
  await page.tap(tid('export-start'));
  await page.waitForSelector(tid('export-pw'));
  await fieldsTakeTyping('backup-export-sheet');
  await page.tap('.sheet .btn-text');
  await page.waitForSelector('.sheet', { state: 'detached' });
  await page.locator(tid('cloud-start')).scrollIntoViewIfNeeded();
  await page.tap(tid('cloud-start'));
  await page.waitForSelector(tid('cloud-pw'));
  await fieldsTakeTyping('cloud-sheet');
  await page.fill(tid('cloud-pw'), PASSWORD);
  await page.tap(tid('cloud-continue'));
  await page.waitForSelector(tid('cloud-pw1'));
  await fieldsTakeTyping('cloud-sheet-choose');
  await page.tap(tid('cloud-cancel'));
  await page.waitForSelector('.sheet', { state: 'detached' });
  await go('settings');
  await page.tap(tid('update-other-row'));
  await page.waitForSelector('.sheet input');
  await fieldsTakeTyping('update-other-sheet');
  await page.tap('.sheet .btn-text');
  await page.waitForSelector('.sheet', { state: 'detached' });
  // "Confirm it is you" (the password sheet before a payment, a node change, a key): through Use this node.
  await go('ownNode');
  await page.fill(tid('own-node-address'), 'eu-node02.mainnet.beam.mw:8200');
  const use = page.locator('button', { hasText: 'Use this node' });
  await use.tap();
  const sheet = await page.waitForSelector(tid('auth-pw'), { timeout: 60000 }).catch(() => null);
  if (sheet) {
    await fieldsTakeTyping('confirm-identity-sheet');
    await page.tap('.sheet .btn-text');
  } else console.log('# confirm-it-is-you sheet not reached from Use this node (the node check said no); covered by the payment e2e');
});

test('unlock after Lock: the password field takes typing and does not focus itself', { timeout: 5 * 60000 }, async () => {
  await go('home');
  await page.tap(tid('lock'));
  await waitScreen(page, 'unlock');
  await fieldsTakeTyping('unlock');
  await page.fill(tid('unlock-pw'), PASSWORD);
  await page.tap(tid('unlock-submit')).catch(() => page.keyboard.press('Enter'));
  await waitHome(page, { timeout: 3 * 60000 });
});

test('Ethereum: import recovery words or a private key', { timeout: 5 * 60000 }, async () => {
  await go('ethImport');
  await sleep(1500);
  await fieldsTakeTyping('ethImport');
});
