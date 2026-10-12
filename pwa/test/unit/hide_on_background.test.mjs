// Secrets leave the screen when the app does (audit A-2). The system keeps a picture of the last
// screen for the app switcher when the app goes to the background (iOS, Android, a desktop's window
// switcher), and the auto-lock never came while it was out of sight: revealed recovery words, the
// owner key, the Ethereum words, the name key and airdrop codes stayed in that picture. Only the
// Ethereum private key (eth_settings.js) hid itself. lib/ui.js onHidden (visibilitychange to
// hidden, and pagehide) is now the one way every such screen hides what it shows.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { onHidden, onShown } from '../../src/lib/ui.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const read = (f) => readFileSync(join(src, f), 'utf8');

function fakePage() {
  const listeners = new Map();
  const target = () => ({
    addEventListener: (t, f) => listeners.set(t, [...(listeners.get(t) || []), f]),
    removeEventListener: (t, f) => listeners.set(t, (listeners.get(t) || []).filter((x) => x !== f)),
  });
  const doc = { visibilityState: 'visible', ...target() };
  const win = target();
  return {
    doc,
    win,
    fire: (t) => (listeners.get(t) || []).forEach((f) => f()),
    count: () => [...listeners.values()].reduce((n, l) => n + l.length, 0),
  };
}

test('onHidden: runs when the page goes out of sight or is left, not when it comes back; unsubscribes fully', () => {
  const p = fakePage();
  let hid = 0;
  let shown = 0;
  const off = onHidden(() => hid++, p.doc, p.win);
  const offShown = onShown(() => shown++, p.doc);
  p.doc.visibilityState = 'hidden';
  p.fire('visibilitychange');
  assert.equal(hid, 1, 'app switcher / another app / screen off');
  assert.equal(shown, 0);
  p.fire('pagehide');
  assert.equal(hid, 2, 'the page left (bfcache, closed)');
  p.doc.visibilityState = 'visible';
  p.fire('visibilitychange');
  assert.equal(hid, 2);
  assert.equal(shown, 1, 'back in sight');
  off();
  offShown();
  assert.equal(p.count(), 0, 'every listener removed');
});

test('every screen that shows a secret hides it when the app goes out of sight', () => {
  // The words grid (create, and the Ethereum words through it): blurred again behind its cover.
  const backup = read('screens/backup.js');
  assert.match(backup, /const off = onHidden\(\(\) => \(el\.isConnected \? hide\(\) : off\(\)\)\);/);
  assert.match(backup, /grid\.classList\.add\('hidden-words'\)/);
  assert.match(backup, /return \{ el, destroy: reveal\.destroy \};/, 'the create screen stops watching when left');
  assert.match(read('screens/eth_words.js'), /return \{ el, destroy: reveal\.destroy \};/);
  // The owner key: forgotten, and the screen asks for the password again.
  const okey = read('screens/owner_key.js');
  assert.match(okey, /const offHidden = onHidden\(/);
  assert.match(okey, /key = null;\s*keyText\.textContent = '';\s*put\(content, \.\.\.askBody\(\)\);/);
  assert.match(okey, /document\.visibilityState === 'hidden'/, 'a key that arrives while out of sight is not shown');
  assert.match(okey, /offHidden\(\);/);
  // The name key and the airdrop codes: off the page while away, back by themselves on return.
  const nkey = read('screens/name_key.js');
  assert.match(nkey, /onHidden\(\(\) => key && put\(box\)\)/);
  assert.match(nkey, /onShown\(\(\) => app\.dbPass && showKey\(\)\)/);
  const codes = read('screens/airdrop_codes.js');
  assert.match(codes, /const offHidden = onHidden\(\(\) => \{\s*away = true;\s*render\(\);/);
  assert.match(codes, /if \(away\) \{\s*put\(body, h\('div', \{ class: 'card empty', 'data-testid': 'codes-away' \}/);
  assert.match(codes, /if \(!away \|\| !app\.dbPass\) return;/, 'never shown again behind a lock');
  // The Ethereum private key: the same helper (pagehide too).
  assert.match(read('screens/eth_settings.js'), /const offHidden = onHidden\(\(\) => reveal && reveal\.hide\(\)\);/);
});
