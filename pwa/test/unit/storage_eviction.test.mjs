// The browser may delete the only copy of what this app keeps (audit A-7): in a Safari tab, a
// site's data goes after 7 days without a visit; elsewhere, a site whose storage is not kept is
// cleared when space runs low. An imported wallet (no 12 words), airdrop codes (the only key to
// locked coins) and bridge records (the only handle to coins in flight) would be gone for good, and
// nothing said so outside Settings -> About. Now: evictionRisk() says which applies; Home says it in
// a Safari tab; an airdrop batch and a bridge move say it before they are made.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evictionRisk, isSafariTab } from '../../src/lib/storage.js';
import { STORAGE_TEXT } from '../../src/screens/storage_warning.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const read = (f) => readFileSync(join(src, f), 'utf8');
const UA = {
  iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  ipadAsMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
  macSafari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
  macChrome: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
  android: 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
};
const env = (ua, { touch = 0, standalone = false } = {}) => ({ navigator: { userAgent: ua, maxTouchPoints: touch, standalone }, matchMedia: () => ({ matches: standalone }) });

test('Safari in a tab: iPhone, iPad, Safari on a Mac; not a Home Screen app, not Chrome', () => {
  assert.equal(isSafariTab(env(UA.iphone)), true);
  assert.equal(isSafariTab(env(UA.ipadAsMac, { touch: 5 })), true);
  assert.equal(isSafariTab(env(UA.macSafari)), true);
  assert.equal(isSafariTab(env(UA.iphone, { standalone: true })), false, 'the Home Screen app keeps its own data');
  assert.equal(isSafariTab(env(UA.macChrome)), false);
  assert.equal(isSafariTab(env(UA.android)), false);
});

test('the risk: none while the browser keeps the storage or cannot say; which kind otherwise', () => {
  assert.equal(evictionRisk({ persisted: true }, env(UA.iphone)), null);
  assert.equal(evictionRisk({ persisted: null }, env(UA.iphone)), null);
  assert.equal(evictionRisk({ persisted: false }, env(UA.iphone)), 'safariTab');
  assert.equal(evictionRisk({ persisted: false }, env(UA.iphone, { standalone: true })), 'mayClear');
  assert.equal(evictionRisk({ persisted: false }, env(UA.android)), 'mayClear');
});

test('the words say what could happen and what keeps it', () => {
  assert.match(STORAGE_TEXT.homeTitle, /Safari can delete this wallet after 7 days without a visit/);
  assert.match(STORAGE_TEXT.homeBody(false), /Home Screen.*with your 12 words/);
  assert.match(STORAGE_TEXT.homeBody(true), /from your wallet\.db file/);
  assert.match(STORAGE_TEXT.codesBody(STORAGE_TEXT.why.safariTab), /7 days.*only key to the coins you lock.*Save as CSV file/);
  assert.match(STORAGE_TEXT.bridgeBody(STORAGE_TEXT.why.mayClear), /runs low on space.*record is kept only here/);
});

test('wired: Home shows it, an airdrop batch and a bridge move ask first, the codes say it, persistence asked again on install', () => {
  assert.match(read('screens/home.js'), /evictionNotice\(app, renderEvict\)/);
  const create = read('screens/airdrop_create.js');
  assert.ok(create.indexOf("await confirmKeptHere(app, 'codes')") > -1 && create.indexOf("await confirmKeptHere(app, 'codes')") < create.indexOf('createBatch('), 'asked before the batch is made');
  const move = read('screens/bridge_move.js');
  assert.ok(move.indexOf("await confirmKeptHere(app, 'bridge')") > -1 && move.indexOf("await confirmKeptHere(app, 'bridge')") < move.indexOf('s.ctl.prepare(q)'), 'asked before the move is prepared');
  assert.match(read('screens/airdrop_codes.js'), /STORAGE_TEXT\.codesNote\[evictionRisk\(app\)\]/);
  assert.match(read('lib/storage.js'), /addEventListener\('appinstalled'/);
});

test('backup reminder (Firo 5cded2676): an imported wallet already gets one until exported; it adds the storage risk; persistence asked again when notifications are allowed', () => {
  const home = read('screens/home.js');
  assert.match(home, /if \(needsBackupPrompt\(app\)\)/);
  assert.match(home, /evictionRisk\(app\) === 'mayClear' \? ` \$\{t\('This browser may also clear its storage\.'\)\}` : null/);
  assert.match(read('screens/notifications.js'), /if \(result === 'granted'\) refreshPersistence\(app, \{ request: true \}\)/);
});
