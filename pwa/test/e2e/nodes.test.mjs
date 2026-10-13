// BEAM node screen: every public node with its newest block, "Use this one", and the signal bars on
// Home. End to end on BEAM mainnet (the installed Google Chrome, headless). Spends nothing (a
// throwaway wallet). Nothing in the app is changed for the test.
//
//   CAMPFIRE_IGNORE_NODE_CERTS=1 npm run e2e:nodes
//
// As the failover suite: Chrome maps every pool host name to 127.0.0.1 (--host-resolver-rules), where
// one TLS relay (node_relay.mjs, self-signed, so Chrome runs with --ignore-certificate-errors) relays
// to the real BEAM node the app asked for (TLS SNI), or refuses, or goes silent, per name.
//
// 1. The signal bars on Home open the node screen in one tap. It checks every public node from the
//    browser as it opens: each answering row shows a block within 3 of the wallet's own (BEAM's real
//    protocol through the relay), a silent node shows "Checking…" and then "Not answering".
// 2. "Use this one" on another node: the wallet reaches Synced on exactly that node, without a reload
//    or an unlock; Settings names it; after lock and unlock the wallet starts on it.
// 3. That node goes away: the wallet still moves on by itself (as Firo's web wallet does), Home offers
//    "Choose another BEAM node", and the node screen shows it "Not answering".
// 4. "Start on any node": the pick is forgotten; lock and unlock start on a random node and fail over
//    past the dead one as before.
// 5. Every pool node refusing: every row says "Not answering" (no endless spinner).
// 6. Without the relay and without --ignore-certificate-errors (BEAM's real nodes, 2026-10-13: their
//    certificates lapsed): the rows say "Not answering", as a person's browser sees them.
// Screenshots of every state at 390x844 and 1280x900, light and dark: CAMPFIRE_NODE_SHOTS.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { CHROME, NODE_HOSTS, startServer, recordedPage, waitScreen, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword, lock } from './flows.mjs';
import { selfSignedCert, upstreamCa, startRelay } from './node_relay.mjs';

const PORT = Number(process.env.CAMPFIRE_NODES_PORT || 8816);
const RELAY_PORT = 8200; // the pool's port: the mapped names land here
const PASSWORD = `nodes-${randomBytes(6).toString('hex')}`;
const OUT = process.env.CAMPFIRE_NODE_SHOTS || join(SHOTS, 'nodes');
const MAP = NODE_HOSTS.map((n) => `MAP ${n.split(':')[0]} 127.0.0.1`).join(', ');
const FULL = ['eu-node02.mainnet.beam.mw:8200', 'eu-node03.mainnet.beam.mw:8200', 'eu-node04.mainnet.beam.mw:8200'];
const tid = (id) => `[data-testid="${id}"]`;
const host = (a) => a.split(':')[0];
const name = (a) => a.split('.')[0];

let tmp, srv, relay;
const modes = new Map(); // host -> 'forward' | 'refuse' | 'silent'
let ctx = null;
let page = null;
let rec = null;

/** The current screen at phone and desktop size, light and dark. */
async function shots(label, { full = true } = {}) {
  mkdirSync(OUT, { recursive: true });
  for (const [size, vp] of [['390', { width: 390, height: 844 }], ['1280', { width: 1280, height: 900 }]]) {
    await page.setViewportSize(vp);
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(150);
      await page.screenshot({ path: join(OUT, `${label}-${size}-${scheme}.png`), fullPage: full });
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

const app = (fn, arg) => page.evaluate(fn, arg);
const rowState = (a) => page.evaluate((n) => {
  const r = document.querySelector(`[data-testid="node-${n}"]`);
  return r ? { state: r.dataset.state, inUse: r.dataset.inUse === 'true', text: r.querySelector(`[data-testid="node-${n}-state"]`).textContent, use: Boolean(r.querySelector(`[data-testid="node-${n}-use"]`)) } : null;
}, name(a));
const allRows = () => Promise.all(NODE_HOSTS.map(async (a) => [name(a), await rowState(a)]));

async function goHome() {
  await app(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
}

async function openNodeScreenFromHome() {
  await app(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('sync-bars'));
  await waitScreen(page, 'nodeSettings');
}

/** Every row that is not the node in use has finished its check. */
async function waitChecked(timeout = 30000) {
  await page.waitForFunction(() => [...document.querySelectorAll('.node-row')].every((r) => r.dataset.inUse === 'true' || !/Checking…|Not checked/.test(r.textContent)), null, { timeout, polling: 200 });
}

before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-nodes-'));
  const tlsCert = selfSignedCert(join(tmp, 'cert'));
  const ca = await upstreamCa();
  relay = await startRelay({ port: RELAY_PORT, tlsCert, ca, behaviour: (n) => modes.get(n) || 'forward', upstream: (n) => ({ host: n, port: 8200 }) });
  srv = await startServer({ root: 'dist', port: PORT });
  ctx = await chromium.launchPersistentContext(join(tmp, 'profile'), {
    executablePath: CHROME,
    headless: !process.env.HEADED,
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
    ignoreHTTPSErrors: true,
    args: [`--host-resolver-rules=${MAP}`, '--ignore-certificate-errors', '--disable-features=AutofillServerCommunication'],
  });
  for (const p of ctx.pages()) await p.close().catch(() => {});
  ({ page, rec } = await recordedPage(ctx, { label: 'nodes' }));
  await page.goto(srv.url);
  console.log(`# pool mapped to the relay on 127.0.0.1:${RELAY_PORT}; screenshots: ${OUT}`);
});

after(async () => {
  if (ctx) await ctx.close().catch(() => {});
  if (relay) await relay.stop().catch(() => {});
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('nodes: signal bars -> node screen; every public node checked from the browser; a silent one is "Not answering"', { timeout: 15 * 60000 }, async () => {
  await waitScreen(page, 'welcome', 180000);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  const s0 = await waitSynced(page, 5 * 60000);
  const inUse = await app(() => window.__campfire.node());
  assert.ok(FULL.includes(inUse), `starts on a full-chain node: ${inUse}`);
  await page.waitForFunction(() => document.querySelector('[data-testid="sync-bars"]')?.dataset.state === 'synced');
  assert.equal(await page.locator(`${tid('sync-bars')} .bar.lit`).count(), 4, 'four bars lit when synced');
  await shots('nodes-01-home-bars-synced', { full: false });

  // One node goes silent before the screen opens: its check waits, then gives up.
  const silent = FULL.find((a) => a !== inUse);
  modes.set(host(silent), 'silent');
  relay.counts.clear();
  const tOpen = Date.now();
  await openNodeScreenFromHome(); // one tap from Home
  assert.equal(await page.textContent(tid('node-connection')), 'Connected to');
  assert.equal(await page.textContent(tid('node-address')), inUse);
  assert.match(await page.textContent(tid('node-check-line')), /Checking connects to each node from this device, so they see your IP address\./);
  await page.waitForFunction((n) => /Checking…/.test(document.querySelector(`[data-testid="node-${n}-state"]`)?.textContent || ''), name(silent), { timeout: 5000 });
  // The others answer while the silent one is still being checked.
  await page.waitForFunction((n) => [...document.querySelectorAll('.node-row')].filter((r) => r.dataset.inUse !== 'true' && r.dataset.testid !== `node-${n}`).every((r) => r.dataset.state === 'ok'), name(silent), { timeout: 20000, polling: 100 });
  await shots('nodes-02-list-checking');
  await waitChecked(20000);
  console.log(`# checks done ${Date.now() - tOpen} ms after the tap; relay connections by name: ${JSON.stringify(Object.fromEntries(relay.counts))}`);
  const height = await app(() => window.__campfire.height());
  for (const [n, r] of await allRows()) {
    if (`${n}.mainnet.beam.mw:8200` === inUse) {
      assert.equal(r.inUse, true);
      assert.match(r.text, /^Block\s[\d,]+$/);
      assert.equal(r.use, false, 'no "Use this one" on the node in use');
      continue;
    }
    if (`${n}.mainnet.beam.mw:8200` === silent) {
      assert.deepEqual([r.state, r.text, r.use], ['bad', 'Not answering', false]);
      continue;
    }
    const m = r.text.match(/^Block\s([\d,]+) · (\d+(?:\.\d)?)\s(ms|s)$/);
    assert.ok(m, `${n}: ${r.text}`);
    const h = Number(m[1].replace(/,/g, ''));
    assert.ok(Math.abs(h - height) <= 3, `${n}: block ${h} vs the wallet's ${height}`);
    assert.equal(r.state, 'ok');
    assert.equal(r.use, true, `${n}: "Use this one"`);
  }
  for (const a of NODE_HOSTS) if (a !== inUse) assert.ok(relay.counts.get(host(a)) >= 1, `${name(a)} was checked`);
  assert.equal(relay.counts.get(host(inUse)) || 0, 0, 'the node in use is not checked again');
  console.log(`# rows: ${JSON.stringify(Object.fromEntries((await allRows()).map(([n, r]) => [n, r.text])))}; wallet ${s0.height} -> ${height}`);
  modes.delete(host(silent));
  await page.click(tid('node-check'));
  await waitChecked(20000);
  assert.equal((await rowState(silent)).state, 'ok', '"Check again" sees it answer now');
  await shots('nodes-03-list-automatic');
  assert.deepEqual(await app(() => window.__campfire.guard().blocked), {}, 'the checks went past the node guard, never through it');
});

test('nodes: "Use this one" moves the wallet to that node now, without a reload or an unlock; it is remembered', { timeout: 15 * 60000 }, async () => {
  const from = await app(() => window.__campfire.node());
  const pick = 'eu-node01.mainnet.beam.mw:8200'; // last in the automatic order: never where a wallet starts by itself
  await app(() => (window.__sameDocument = true));
  const t0 = Date.now();
  await page.click(tid(`node-${name(pick)}-use`));
  await page.waitForFunction((p) => window.__campfire.node() === p, pick, { timeout: 30000 });
  await waitScreen(page, 'nodeSettings');
  const synced = await waitSynced(page, 3 * 60000);
  const tSynced = Date.now();
  assert.equal(await app(() => window.__sameDocument), true, 'no reload');
  assert.equal(await app(() => window.__campfire.screen()), 'nodeSettings', 'still unlocked, still on the screen');
  assert.equal(await app(() => window.__campfire.node()), pick, 'Synced on exactly the picked node');
  const log = await app(() => window.__campfire.nodeSwitches());
  assert.deepEqual({ from: log.at(-1).from, to: log.at(-1).to, reason: log.at(-1).reason }, { from, to: pick, reason: 'chosen' });
  console.log(`# picked ${name(pick)}: Synced on it ${((tSynced - t0) / 1000).toFixed(1)} s after the tap, height ${synced.height}`);
  await page.waitForFunction((n) => document.querySelector(`[data-testid="node-${n}"]`)?.dataset.inUse === 'true', name(pick));
  assert.match(await page.textContent(tid('node-first')), /It starts on eu-node01 each time it opens\./);
  await waitChecked(20000);
  await shots('nodes-04-list-picked');
  // Settings names it.
  await app(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.match(await page.textContent(tid('node-row')), /BEAM's public nodes, eu-node01 first/);
  // Remembered: the next unlock starts on it, not on a random node.
  await goHome();
  await lock(page);
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  assert.equal(await app(() => window.__campfire.node()), pick, 'the next start begins on the picked node');
  await waitSynced(page, 3 * 60000);
  assert.equal(await app(() => window.__campfire.node()), pick);
  assert.deepEqual(await app(() => window.__campfire.nodeSwitches()), [], 'no hop was needed');
});

test('nodes: the picked node goes away: the wallet moves on by itself, Home offers another node, the row says "Not answering"', { timeout: 15 * 60000 }, async () => {
  const pick = await app(() => window.__campfire.node());
  modes.set(host(pick), 'refuse');
  const t0 = Date.now();
  const killed = relay.kill(host(pick));
  assert.ok(killed >= 1, 'the wallet had a connection to it');
  await page.waitForFunction(() => window.__campfire.sync().reconnecting === true || window.__campfire.sync().state === 'offline', null, { timeout: 90000, polling: 250 });
  await page.waitForSelector(tid('sync-choose-node'), { timeout: 30000 });
  await shots('nodes-05-home-picked-down', { full: false });
  await waitSynced(page, 5 * 60000);
  const now = await app(() => window.__campfire.node());
  const log = await app(() => window.__campfire.nodeSwitches());
  console.log(`# ${name(pick)} went away: moved to ${name(now)} by itself after ${((Date.now() - t0) / 1000).toFixed(1)} s (${log.map((e) => `${name(e.from)} ${e.reason} -> ${name(e.to)}`).join(', ')})`);
  assert.notEqual(now, pick);
  assert.equal(log[0].from, pick);
  assert.ok(['dropped', 'unreachable'].includes(log[0].reason), log[0].reason);
  // The way there from Home, and what it shows.
  await app(() => window.__campfire.go('home'));
  await waitScreen(page, 'home');
  await page.click(tid('sync-bars'));
  await waitScreen(page, 'nodeSettings');
  await waitChecked(20000);
  assert.deepEqual(await rowState(pick), { state: 'bad', inUse: false, text: 'Not answering', use: false });
  assert.equal((await rowState(now)).inUse, true);
  assert.match(await page.textContent(tid('node-first')), /It starts on eu-node01/);
  await shots('nodes-06-list-picked-down');
});

test('nodes: "Start on any node" forgets the pick; the next start is random and fails over as before', { timeout: 15 * 60000 }, async () => {
  const dead = 'eu-node01.mainnet.beam.mw:8200';
  await page.click(tid('node-forget-first'));
  await page.waitForSelector(tid('node-first'), { state: 'detached' });
  await app(() => window.__campfire.go('settings'));
  await waitScreen(page, 'settings');
  assert.equal((await page.textContent(tid('node-row'))).includes("BEAM's public nodes") && !(await page.textContent(tid('node-row'))).includes('first'), true);
  // The three full-chain nodes refuse, as in the failover suite: whichever the random start is, it moves past them.
  for (const a of FULL) modes.set(host(a), 'refuse');
  await goHome();
  await lock(page);
  relay.counts.clear();
  await unlockWithPassword(page, PASSWORD);
  await waitScreen(page, 'home', 60000);
  const first = await app(() => window.__campfire.nodeSwitches().length ? window.__campfire.nodeSwitches()[0].from : window.__campfire.node());
  assert.ok(FULL.includes(first), `a random full-chain start again, not the forgotten pick: ${first}`);
  await waitSynced(page, 5 * 60000);
  const list = await app(() => window.__campfire.nodeSwitches());
  console.log(`# after "Start on any node": ${list.map((e) => `${name(e.from)} ${e.reason} -> ${name(e.to)}`).join(', ')}`);
  assert.equal(await app(() => window.__campfire.node()), 'eu-nodes.mainnet.beam.mw:8200', 'past the three refusing nodes, on eu-nodes, as before');
  assert.deepEqual(list.map((e) => e.reason), ['unreachable', 'unreachable', 'unreachable']);
  assert.equal(relay.counts.get(host(dead)) || 0, 0, 'eu-node01 (last) never needed');
});

test('nodes: every pool node refusing: each row says "Not answering", none spins', { timeout: 10 * 60000 }, async () => {
  for (const a of NODE_HOSTS) modes.set(host(a), 'refuse');
  for (const a of NODE_HOSTS) relay.kill(host(a));
  await openNodeScreenFromHome();
  await page.click(tid('node-check'));
  await page.waitForFunction(() => [...document.querySelectorAll('.node-row')].every((r) => r.dataset.inUse === 'true' || /Not answering/.test(r.textContent)), null, { timeout: 20000 });
  for (const [n, r] of await allRows()) if (!r.inUse) assert.equal(r.text, 'Not answering', n);
  await page.waitForFunction(() => /None of BEAM's public nodes is answering this browser right now\./.test(document.querySelector('[data-testid="nodes-all-down"]')?.textContent || ''), null, { timeout: 30000 });
  await shots('nodes-07-list-all-down');
  // Not a dead end: the one thing that still works then is a node of your own.
  await page.click(tid('nodes-all-down-own'));
  await waitScreen(page, 'ownNode');
  const hosts = [...new Set(rec.websockets.map((u) => new URL(u).host))];
  assert.ok(hosts.every((h) => NODE_HOSTS.includes(h)), `only pool nodes, ever: ${hosts}`);
  assert.deepEqual(rec.errors, [], 'no page errors');
  const violations = await app(() => window.__cspViolations.slice());
  assert.deepEqual(violations, [], 'no CSP violations: every check stayed inside connect-src');
});

test("nodes: BEAM's real nodes as a browser sees them on 2026-10-13 (certificates lapsed): \"Not answering\", no spinner", { timeout: 10 * 60000 }, async () => {
  // CAMPFIRE_IGNORE_NODE_CERTS is for the relay's upstream: this browser verifies certificates as a person's does.
  const real = await chromium.launchPersistentContext(join(tmp, 'profile-real'), {
    executablePath: CHROME,
    headless: !process.env.HEADED,
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
    args: ['--disable-features=AutofillServerCommunication'],
  });
  try {
    for (const p of real.pages()) await p.close().catch(() => {});
    const r = await recordedPage(real, { label: 'real' });
    const keep = page;
    page = r.page;
    try {
      await page.goto(srv.url);
      await waitScreen(page, 'welcome', 180000);
      await createWallet(page, { password: PASSWORD });
      await waitHome(page);
      await openNodeScreenFromHome();
      await page.waitForFunction(() => [...document.querySelectorAll('.node-row')].every((x) => /Not answering|Block|Connecting…/.test(x.textContent) && !/Checking…/.test(x.textContent)), null, { timeout: 30000 });
      const rows = await allRows();
      console.log(`# BEAM's real nodes from this browser: ${JSON.stringify(Object.fromEntries(rows.map(([n, x]) => [n, x.text])))}`);
      await page.waitForSelector(tid('nodes-all-down'), { timeout: 30000 });
      await shots('nodes-08-real-nodes-today');
      assert.ok(rows.every(([, x]) => !/Checking…/.test(x.text)), 'nothing left spinning');
    } finally {
      page = keep;
    }
  } finally {
    await real.close().catch(() => {});
  }
});
