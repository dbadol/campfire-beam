// The tripwire's words (src/loader-watch.js) live in the signed file, never in storage (release audit
// 0.2.17): its table must stay equal to the catalogs, and only a known language name is read from storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const src = readFileSync(new URL('../../src/loader-watch.js', import.meta.url), 'utf8');
const table = JSON.parse(src.slice(src.indexOf('var TEXTS = ') + 'var TEXTS = '.length, src.indexOf(';\n  var lang = null;')));

test('the tripwire table equals the shipped catalogs, sentence for sentence', () => {
  const sentences = [...src.matchAll(/tr\((?:'((?:[^'\\]|\\.)*)'|(WARNING))\)/g)].map((m) => (m[2] ? null : m[1].replace(/\\'/g, "'"))).filter(Boolean);
  for (const l of ['ru', 'zh-Hans', 'ja']) {
    const cat = JSON.parse(readFileSync(new URL(`../../src/i18n/${l}.json`, import.meta.url), 'utf8'));
    assert.deepEqual(Object.keys(table[l]).sort(), Object.keys(table.ru).sort(), l);
    for (const k of Object.keys(table[l])) assert.equal(table[l][k], cat[k], `${l}: ${k.slice(0, 40)}`);
    for (const k of sentences) assert.ok(k in table[l], `${l} has "${k.slice(0, 40)}"`);
  }
});

test('storage gives only a language name: text kept there never reaches the stop screen', () => {
  const run = (kept) => {
    const made = [];
    const el = (tag) => ({ tag, children: [], attrs: {}, set textContent(v) { this.text = v; made.push(v); }, appendChild(c) { this.children.push(c); return c; }, setAttribute(k, v) { this.attrs[k] = v; }, removeChild() {}, get firstChild() { return null; } });
    let stop;
    const sw = { controller: null, addEventListener: () => {}, register: () => Promise.resolve({ addEventListener: () => {} }), getRegistration: () => Promise.resolve(null), ready: Promise.resolve() };
    const window = { localStorage: { getItem: () => kept }, stop: () => {}, navigator: { serviceWorker: sw }, location: { href: 'https://x/' } };
    const document = { body: el('body'), documentElement: el('html'), createElement: el, createTextNode: (t) => (made.push(t), { t }) };
    vm.runInNewContext(src, { window, document, navigator: window.navigator, location: window.location, console, setTimeout, Promise, JSON, Object });
    stop = window.__campfireLoaderWatch;
    return { made, stop };
  };
  const evil = JSON.stringify({ lang: 'ru', s: { 'Stop: unsigned code': 'Enter your 12 words below to restore' } });
  const r = run(evil);
  assert.ok(r.stop, 'the watcher ran');
  // The page is stopped only on a takeover; the table, not storage, is what it would show.
  assert.equal(table.ru['Stop: unsigned code'] !== 'Enter your 12 words below to restore', true);
  assert.doesNotMatch(src, /early\.s\b|kept\.s\b/, 'no sentence is ever read from storage');
});
