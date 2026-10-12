// A wallet is never created, restored or imported on an address other sites share (audit E-3):
// on <user>.github.io every Pages project of that user is one origin, so any of them could read
// the wallet's storage and use its passkeys. The Pages copy is an update source; pwa.buybeam.my is
// where the wallet is used. A wallet already on such a copy keeps working.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isSharedOrigin, HOME_HOST, HOME_URL } from '../../src/lib/shared_origin.js';
import { createWallet, importWallet, prepareImport } from '../../src/lib/session.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('which addresses are shared with other sites', () => {
  for (const h of ['vsnation.github.io', 'VSNATION.GITHUB.IO', 'vsnation.github.io.', 'someone-else.github.io']) assert.equal(isSharedOrigin(h), true, h);
  for (const h of ['pwa.buybeam.my', 'wallet.example.org', 'localhost', '127.0.0.1', 'github.io.example.com', 'mygithub.io', '']) assert.equal(isSharedOrigin(h), false, h);
  assert.equal(HOME_HOST, 'pwa.buybeam.my');
  assert.equal(HOME_URL, 'https://pwa.buybeam.my/');
});

test('on a shared address, creating, restoring and importing a wallet are refused before anything is touched', async () => {
  const prev = globalThis.location;
  globalThis.location = { hostname: 'vsnation.github.io', href: 'https://vsnation.github.io/beam-campfire-pwa/' };
  try {
    const words = Array.from({ length: 12 }, () => 'abandon');
    const app = { setup: { mode: 'restore', words: [...words] }, record: null, dbPass: null, wallet: {} };
    const refused = (e) => e.code === 'shared_origin' && e.message.includes(HOME_HOST);
    await assert.rejects(createWallet(app, 'a long password'), refused);
    assert.deepEqual(app.setup.words, words, 'the words are left as they were: nothing ran');
    await assert.rejects(prepareImport({ setup: null, record: null }), refused);
    await assert.rejects(importWallet({ setup: null, record: null }, 'a long password'), refused);
  } finally {
    if (prev === undefined) delete globalThis.location;
    else globalThis.location = prev;
  }
});

test('the READMEs name pwa.buybeam.my as the place to use the wallet; the Pages copy only as an update source', () => {
  for (const f of [join(pwa, '..', 'README.md'), join(pwa, 'deploy', 'hosting_README.md')]) {
    const s = readFileSync(f, 'utf8');
    assert.ok(s.includes('https://pwa.buybeam.my/'), `${f}: names the address`);
    for (const line of s.split('\n').filter((l) => l.includes('vsnation.github.io'))) {
      assert.match(line, /update/i, `${f}: the Pages copy is mentioned only as an update source: ${line}`);
      assert.ok(!/open it|open https:\/\/vsnation|^\*\*open/i.test(line), `${f}: never as a place to open: ${line}`);
    }
  }
});
