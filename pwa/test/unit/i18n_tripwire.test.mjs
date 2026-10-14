// The tripwire's words (src/loader-watch.js) live in the signed file, never in storage (release audit
// 0.2.17): its table must stay equal to the catalogs, and only a known language name is read from storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { LANGUAGES } from '../../src/lib/i18n.js';

const src = readFileSync(new URL('../../src/loader-watch.js', import.meta.url), 'utf8');
const table = JSON.parse(src.slice(src.indexOf('var TEXTS = ') + 'var TEXTS = '.length, src.indexOf(';\n  var lang = null;')));

test('the tripwire table equals the shipped catalogs, sentence for sentence, every sentence and every language', () => {
  const WARNING = /var WARNING = "([^"]+)"/.exec(src)[1];
  const sentences = [...src.matchAll(/tr\((?:'((?:[^'\\]|\\.)*)'|(WARNING))\)/g)].map((m) => (m[2] ? WARNING : m[1].replace(/\\'/g, "'")));
  assert.ok(sentences.includes(WARNING) && sentences.length >= 5, 'the warning is among the sentences read');
  const shipped = LANGUAGES.filter((l) => l !== 'en');
  assert.deepEqual(Object.keys(table).sort(), [...shipped].sort(), 'one table per shipped language');
  for (const l of shipped) {
    const cat = JSON.parse(readFileSync(new URL(`../../src/i18n/${l}.json`, import.meta.url), 'utf8'));
    assert.deepEqual(Object.keys(table[l]).sort(), [...new Set(sentences)].sort(), `${l}: exactly the sentences the screen shows`);
    for (const k of Object.keys(table[l])) assert.equal(table[l][k], cat[k], `${l}: ${k.slice(0, 40)}`);
  }
});

// The stop screen itself (a takeover, in the kept language, never words from storage) is driven in
// test/unit/i18n.test.mjs; this checks the watcher still starts with hostile storage and reads no sentence.
test('storage gives only a language name: the watcher starts with hostile storage, and reads no sentence from it', () => {
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
  assert.doesNotMatch(src, /early\.s\b|kept\.s\b/, 'no sentence is ever read from storage');
});
