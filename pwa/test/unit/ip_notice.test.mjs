// Settings -> IP privacy and PWA.md say who sees the device's IP address. Audit UPD-4: since
// "the newest signed release wins", a tapped Check for updates asks every update source at once
// (lib/update_sources.js findUpdate: Promise.all), the own address and the public copies on GitHub
// and jsDelivr alike, so each of them sees the IP. The screen said the app "talks only to two
// places ... no other servers", and PWA.md that the copies are asked only when the own address
// fails ("the copies receive zero requests").
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { IP_APP_TEXT } from '../../src/screens/ip_notice.js';
import { BUILTIN_SOURCES } from '../../src/lib/update_sources.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const owners = { 'raw.githubusercontent.com': 'GitHub', 'vsnation.github.io': 'GitHub', 'cdn.jsdelivr.net': 'jsDelivr' };

test('the IP privacy screen says a tapped update check asks every update source, and that they see the IP', () => {
  assert.match(IP_APP_TEXT, /Check for updates/);
  assert.match(IP_APP_TEXT, /every update source/);
  assert.match(IP_APP_TEXT, /IP address/);
  for (const src of BUILTIN_SOURCES) {
    const host = new URL(src).hostname;
    assert.ok(owners[host], `a new built-in update source must be named on the IP privacy screen: ${host}`);
    assert.ok(IP_APP_TEXT.includes(owners[host]), `names ${owners[host]} (${host})`);
  }
  assert.ok(!/no other servers|only to two places/i.test(IP_APP_TEXT), 'no claim that only two places are contacted');
});

test('PWA.md §3b and §4 say the same: every source is asked on a tapped check, and sees the IP', () => {
  const doc = readFileSync(join(pwa, '..', 'docs', 'beam', 'PWA.md'), 'utf8');
  const section = (start, end) => doc.slice(doc.indexOf(start), doc.indexOf(end));
  const s3b = section('## 3b. Without the domain', '## 3c.');
  const s4 = section('## 4. IP privacy', '## 4a.');
  for (const [name, s] of [['§3b', s3b], ['§4', s4]]) {
    assert.ok(s.length > 100, name);
    assert.ok(!/receive zero requests|no later source is contacted|only when this app's\s+address gave no usable answer/.test(s), `${name}: no claim that the copies are skipped while the address answers`);
    assert.match(s, /every (update )?source/, `${name}: every source is asked`);
  }
  assert.match(s4, /GitHub[\s\S]{0,200}jsDelivr[\s\S]{0,300}IP address/, '§4: GitHub and jsDelivr see the IP address');
});
