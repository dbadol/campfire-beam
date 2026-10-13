// Languages, end to end (lib/i18n.js, lang-boot.js, Settings -> Appearance -> Language). The installed
// Google Chrome (headless), its own builds and port, a throwaway mainnet wallet that holds nothing.
//
// 1. Chrome set to Russian, the release as it ships (no catalog translated yet): never asked, <html
//    lang="ru"> from the first paint, English words, only ru.json read, Settings shows "Like this
//    device (Русский)" chosen; another language at once on the same screen; kept after a reload; like
//    this device again.
// 2. The same app built with a pseudo-Russian catalog (every text "⟦English⟧"): screen after screen,
//    every word on show must come from the catalog. What does not is listed (an English text that does
//    not go through lib/i18n.js), with a screenshot of each screen.
//
//   npm run e2e:i18n   (own build folders and port 8836; CAMPFIRE_IGNORE_NODE_CERTS=1 when BEAM's
//                       node certificates have lapsed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, waitScreen, shot, foreignHosts, PWA, SHOTS } from './harness.mjs';
import { createWallet, waitHome, unlockWithPassword } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_I18N_PORT || 8836);
const tid = (id) => `[data-testid="${id}"]`;
const PASSWORD = `i18n-${Math.random().toString(36).slice(2, 10)}`;

let tmp, srv, browser;

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-i18n-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  browser = await launch();
  console.log(`# screenshots: ${SHOTS}`);
});

test.after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

const htmlLang = (page) => page.evaluate(() => document.documentElement.lang);

test('Chrome in Russian, nothing translated yet: never asked, lang="ru", English words; Settings switches at once', { timeout: 20 * 60000 }, async () => {
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'ru-RU', colorScheme: 'light' });
  const { page, rec } = await recordedPage(ctx, { label: 'i18n-ru' });
  const catalogs = [];
  ctx.on('request', (r) => {
    const m = /\/i18n\/([A-Za-z-]+)\.json$/.exec(r.url());
    if (m) catalogs.push(m[1]);
  });
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  assert.deepEqual(await page.evaluate(() => navigator.languages), ['ru-RU'], 'the browser speaks Russian');
  assert.equal(await htmlLang(page), 'ru');
  assert.equal(await page.textContent(tid('create')), 'Create a new wallet', 'catalogs empty: English');
  assert.equal(await page.textContent(tid('restore')), 'Restore with 12 words');
  assert.ok(!(await page.evaluate(() => document.body.innerText)).match(/[А-я]/), 'not a word of Russian anywhere yet');
  // Before any module runs: lang-boot.js already set it.
  await page.addInitScript(() => {
    document.addEventListener('readystatechange', () => {
      if (document.readyState === 'interactive' && !window.__langAtInteractive) window.__langAtInteractive = document.documentElement.lang;
    });
  });
  await page.reload();
  await waitScreen(page, 'welcome', 120000);
  assert.equal(await page.evaluate(() => window.__langAtInteractive), 'ru', 'from the first paint');
  await shot(page, 'i18n-01-welcome-ru-device');

  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  assert.equal(await htmlLang(page), 'ru');
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.locator(tid('lang-row')).scrollIntoViewIfNeeded();
  const card = await page.evaluate(() => {
    const row = document.querySelector('[data-testid="lang-row"]');
    return { title: row.parentElement.previousElementSibling.textContent, rowTitle: row.querySelector('.t').textContent, sameCard: row.parentElement === document.querySelector('[data-testid="theme-row"]').parentElement };
  });
  assert.deepEqual(card, { title: 'Appearance', rowTitle: 'Language', sameCard: true });
  assert.equal(await page.inputValue(tid('lang-select')), 'system', 'like this device: nothing was asked or saved');
  assert.deepEqual(await page.$$eval(`${tid('lang-select')} option`, (o) => o.map((x) => x.textContent)), ['Like this device (Русский)', 'English', 'Русский', '简体中文', '日本語']);
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), null);
  await shot(page, 'i18n-02-settings-language-ru-device');
  await page.emulateMedia({ colorScheme: 'dark' });
  await shot(page, 'i18n-03-settings-language-ru-device-dark');
  await page.emulateMedia({ colorScheme: 'light' });

  // Japanese: at once, the same screen drawn again where it was, the choice kept.
  const before = await page.evaluate(() => {
    document.querySelector('[data-testid="lang-row"]').dataset.old = '1';
    return window.scrollY;
  });
  await page.selectOption(tid('lang-select'), 'ja');
  await page.waitForFunction(() => document.documentElement.lang === 'ja');
  await page.waitForFunction(() => !document.querySelector('[data-testid="lang-row"]').dataset.old);
  assert.equal(await page.evaluate(() => window.__campfire.screen()), 'settings');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), 'ja');
  assert.equal(await page.inputValue(tid('lang-select')), 'ja');
  assert.ok(Math.abs((await page.evaluate(() => window.scrollY)) - before) < 4, 'where it was');
  assert.equal(await page.textContent(`${tid('lang-row')} .t`), 'Language', 'nothing translated yet: English');
  assert.ok(catalogs.includes('ja'), 'the Japanese catalog was read once chosen');
  await shot(page, 'i18n-04-settings-japanese-chosen');

  await page.selectOption(tid('lang-select'), 'en');
  await page.waitForFunction(() => document.documentElement.lang === 'en');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), 'en');

  // Kept: after a reload (the wallet locks) English, even on a Russian device.
  await page.reload();
  await waitScreen(page, 'unlock', 120000);
  assert.equal(await page.evaluate(() => window.__langAtInteractive), 'en');
  await unlockWithPassword(page, PASSWORD);
  await waitHome(page);
  await page.evaluate(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  await page.selectOption(tid('lang-select'), 'system');
  await page.waitForFunction(() => document.documentElement.lang === 'ru');
  assert.equal(await page.evaluate(() => localStorage.getItem('campfire-lang')), null, 'like this device: forgotten');
  assert.ok(!catalogs.includes('zh-Hans'), 'a catalog is read only when its language is in use');
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  assert.deepEqual(rec.errors, []);
  await ctx.close();
  srv.stop();
  srv = null;
});

// ---------------------------------------------------------------- 2. every word from the catalog

// Words that are not the app's to translate: names, tickers, units, the language names, values.
const KEEP = /\b(BEAM|Beam|Campfire|bETH|bUSDT|bWBTC|bDAI|WBEAM|ETH|FOMO|BeamX|Ethereum|Uniswap|NEAR|Intents|CoinGecko|Face|Touch|ID|English|wallet\.db|wss|https?|QR|IPv[46]|HF6|groth)\b/g;

function pseudoCatalog(keys) {
  const out = {};
  for (const [k, info] of Object.entries(keys)) {
    if (info.count) out[k] = { one: `⟦${k}⟧`, few: `⟦${k}⟧`, many: `⟦${k}⟧`, other: `⟦${k}⟧` };
    else out[k] = `⟦${k}⟧`;
  }
  return out;
}

async function wordsOnScreen(page) {
  return page.evaluate(() => {
    const out = [];
    const shown = (el) => {
      for (let e = el; e && e !== document.body; e = e.parentElement) {
        const cs = getComputedStyle(e);
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
      }
      return true;
    };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const el = n.parentElement;
      if (!el || !n.nodeValue.trim() || el.closest('script,style,noscript,[data-i18n-value]')) continue;
      if (shown(el)) out.push(n.nodeValue);
    }
    for (const el of document.querySelectorAll('[aria-label],[placeholder],[title],[alt]')) {
      if (!shown(el)) continue;
      for (const a of ['aria-label', 'placeholder', 'title', 'alt']) {
        const v = el.getAttribute(a);
        if (v && v.trim()) out.push(v);
      }
    }
    for (const o of document.querySelectorAll('option')) if (shown(o.parentElement)) out.push(o.textContent);
    return out;
  });
}

/** What is left of a text once the catalog's words and the values are taken out: English words, if any. */
export function leftover(text) {
  return text.replace(/⟦[^⟧]*⟧/g, ' ').replace(/[0-9a-f]{12,}/gi, ' ').replace(KEEP, ' ').match(/[A-Za-z]{2,}/g);
}

const AUDIT = [
  ['home', {}], ['receive', {}], ['send', {}], ['activity', {}], ['settings', {}], ['nodeSettings', {}], ['ownNode', {}], ['ipNotice', {}], ['about', {}],
  ['changePassword', {}], ['deleteWallet', {}], ['wallets', {}], ['addWallet', {}], ['contacts', {}], ['addresses', {}], ['checkProof', {}], ['notifications', {}],
  ['coins', {}], ['hiddenTokens', {}], ['swap', {}], ['pools', {}], ['dapps', {}], ['names', {}], ['ownerKey', { from: 'settings' }], ['ethStart', { from: 'settings' }],
];

test('pseudo-Russian: every word on these screens comes from the catalog', { timeout: 25 * 60000 }, async () => {
  const keys = JSON.parse(readFileSync(join(PWA, 'src', 'i18n', 'keys.json'), 'utf8'));
  const catDir = join(tmp, 'catalogs');
  mkdirSync(catDir);
  writeFileSync(join(catDir, 'ru.json'), JSON.stringify(pseudoCatalog(keys)));
  for (const l of ['zh-Hans', 'ja']) writeFileSync(join(catDir, `${l}.json`), '{}');
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'pseudo'), '--catalogs', catDir, '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'pseudo'), port: PORT });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, locale: 'ru-RU' });
  const { page, rec } = await recordedPage(ctx, { label: 'i18n-pseudo' });
  const found = [];
  const audit = async (name) => {
    for (const text of await wordsOnScreen(page)) {
      const left = leftover(text);
      if (left) found.push(`${name}: ${JSON.stringify(text.trim()).slice(0, 140)}`);
    }
    await shot(page, `i18n-pseudo-${name}`);
  };
  await page.goto(srv.url);
  await waitScreen(page, 'welcome', 120000);
  await audit('welcome');
  // The setup screens, as a person goes through them.
  await page.click(tid('create'));
  await waitScreen(page, 'backup');
  await audit('backup');
  await page.click(tid('reveal'));
  const words = await page.$$eval('[data-testid="words"] .word span:last-child', (els) => els.map((e) => e.textContent));
  await page.click(tid('wrote-down'));
  await waitScreen(page, 'confirmWords');
  await audit('confirmWords');
  for (const pos of await page.$$eval('[data-position]', (els) => els.map((e) => Number(e.dataset.position)))) await page.click(`[data-position="${pos}"] [data-word="${words[pos - 1]}"]`);
  await page.click(tid('confirm-words'));
  await waitScreen(page, 'setPassword');
  await audit('setPassword');
  await page.fill(tid('pw1'), PASSWORD);
  await page.fill(tid('pw2'), PASSWORD);
  await page.click(tid('save-password'));
  await page.waitForFunction(() => ['passkeySetup', 'home', 'fastStart'].includes(document.getElementById('app').dataset.screen), null, { timeout: 60000 });
  if ((await page.evaluate(() => window.__campfire.screen())) === 'passkeySetup') {
    await audit('passkeySetup');
    await page.click(tid('passkey-skip'));
  }
  await waitHome(page);
  await page.waitForFunction(() => window.__campfire.sync() && window.__campfire.sync().state === 'synced', null, { timeout: 180000 }).catch(() => {});
  for (const [name, params] of AUDIT) {
    await page.evaluate(([n, p]) => window.__campfire.go(n, p), [name, params]);
    await page.waitForTimeout(1500);
    await audit(name);
    await page.keyboard.press('Escape').catch(() => {});
  }
  await page.evaluate(() => window.__campfire.go('settings'));
  await page.evaluate(() => document.querySelector('[data-testid="lock-now"]').click());
  await waitScreen(page, 'unlock');
  await audit('unlock');
  console.log(`# pseudo-Russian: ${found.length} texts not from the catalog`);
  for (const f of found) console.log(`#   ${f}`);
  assert.deepEqual(rec.errors, [], 'no screen breaks in another language');
  assert.deepEqual(found, [], 'English left on screen: route it through lib/i18n.js');
  await ctx.close();
});
