// Settings -> Theme (lib/theme.js, theme-boot.js, css/app.css): like this device, light or dark.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { THEMES, THEME_WORDS, SKINS, SKIN_WORDS, BARS, readTheme, readSkin, applyTheme, applyLook, setTheme, setSkin } from '../../src/lib/theme.js';

const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');

function memoryStorage(init = {}) {
  const m = new Map(Object.entries(init));
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m };
}
const blocked = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); }, removeItem: () => { throw new Error('blocked'); } };

function fakeDoc() {
  const meta = (attrs) => ({ attrs: { ...attrs }, getAttribute(k) { return this.attrs[k] ?? null; }, setAttribute(k, v) { this.attrs[k] = v; } });
  const light = meta({ name: 'theme-color', content: '#fff1f1', media: '(prefers-color-scheme: light)' });
  const dark = meta({ name: 'theme-color', content: '#1c1d22', media: '(prefers-color-scheme: dark)' });
  const scheme = meta({ name: 'color-scheme', content: 'light dark' });
  return {
    documentElement: { dataset: {} },
    querySelectorAll: (sel) => (sel === 'meta[name="theme-color"]' ? [light, dark] : []),
    querySelector: (sel) => (sel === 'meta[name="color-scheme"]' ? scheme : null),
    light,
    dark,
    scheme,
  };
}

test('the choice: like this device unless one is saved; anything unknown or unreadable is like this device', () => {
  assert.deepEqual(THEMES, ['system', 'light', 'dark']);
  assert.equal(THEME_WORDS.system, 'Like this device');
  assert.equal(readTheme(memoryStorage()), 'system');
  assert.equal(readTheme(memoryStorage({ 'campfire-theme': 'dark' })), 'dark');
  assert.equal(readTheme(memoryStorage({ 'campfire-theme': 'purple' })), 'system');
  assert.equal(readTheme(blocked), 'system');
});

test('applied: the palette attribute, the native controls and the browser bar', () => {
  const d = fakeDoc();
  applyTheme('dark', d);
  assert.equal(d.documentElement.dataset.theme, 'dark');
  assert.equal(d.light.attrs.content, '#1c1d22', 'the bar is dark whatever the device says');
  assert.equal(d.dark.attrs.content, '#1c1d22');
  assert.equal(d.scheme.attrs.content, 'dark');
  applyTheme('light', d);
  assert.equal(d.documentElement.dataset.theme, 'light');
  assert.equal(d.dark.attrs.content, '#fff1f1');
  assert.equal(d.scheme.attrs.content, 'light');
  applyTheme('system', d);
  assert.equal('theme' in d.documentElement.dataset, false);
  assert.equal(d.light.attrs.content, '#fff1f1');
  assert.equal(d.dark.attrs.content, '#1c1d22', 'each tag its own colour again');
  assert.equal(d.scheme.attrs.content, 'light dark');
});

test('saved and applied at once; like this device leaves nothing saved; blocked storage still applies', () => {
  const st = memoryStorage();
  const d = fakeDoc();
  assert.equal(setTheme('dark', { storage: st, doc: d }), 'dark');
  assert.equal(st.m.get('campfire-theme'), 'dark');
  assert.equal(d.documentElement.dataset.theme, 'dark');
  setTheme('system', { storage: st, doc: d });
  assert.equal(st.m.has('campfire-theme'), false);
  const d2 = fakeDoc();
  assert.equal(setTheme('light', { storage: blocked, doc: d2 }), 'light');
  assert.equal(d2.documentElement.dataset.theme, 'light');
});

test('before the first paint: theme-boot.js reads the same key, and index.html loads it before the stylesheets', () => {
  const boot = src('theme-boot.js');
  assert.match(src('lib/theme.js'), /const KEY = 'campfire-theme';/);
  assert.match(boot, /localStorage\.getItem\('campfire-theme'\)/);
  const html = src('index.html');
  assert.ok(html.indexOf('<script src="theme-boot.js"></script>') > 0);
  assert.ok(html.indexOf('theme-boot.js') < html.indexOf('css/app.css'), 'before the colours are read');
  assert.doesNotMatch(boot, /\bimport\b|\bexport\b/, 'a classic script: it runs before the page is drawn');
});

test("css: the dark palette under the device's dark mode and under Dark is one palette", () => {
  const css = src('css/app.css');
  const decls = (body) => body.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('--')).join('\n');
  const sys = /@media \(prefers-color-scheme: dark\) \{\n {2}:root:not\(\[data-theme="light"\]\) \{\n([\s\S]*?)\n {2}\}\n\}/.exec(css);
  const forced = /\n:root\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/.exec(css);
  assert.ok(sys && forced, 'both blocks found');
  assert.ok(decls(sys[1]).split('\n').length >= 20);
  assert.equal(decls(forced[1]), decls(sys[1]));
  // Every dark rule in the file follows the choice: none under the media query alone.
  for (const m of css.matchAll(/@media \(prefers-color-scheme: dark\) \{([\s\S]*?)\n\}/g)) {
    for (const line of m[1].split('\n').filter((l) => /\{/.test(l))) assert.match(line, /:root(\[data-skin="beam"\])?:not\(\[data-theme="light"\]\)/, line.trim());
  }
});

// ---------------------------------------------------------------- colours: Campfire red or BEAM blue (#80)

const css = src('css/app.css');
const tokens = (body) => Object.fromEntries([...body.matchAll(/--([a-z0-9-]+):\s*([^;]+);/g)].map((x) => [x[1], x[2].trim()]));
const blockOf = (re) => {
  const m = re.exec(css);
  assert.ok(m, `block ${re}`);
  return tokens(m[1]);
};
const PALETTES = {
  'campfire light': blockOf(/\n:root \{\n([\s\S]*?)\n\}/),
  'campfire dark': blockOf(/\n:root\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/),
  'beam light': blockOf(/\n:root\[data-skin="beam"\] \{\n([\s\S]*?)\n\}/),
  'beam dark': blockOf(/\n:root\[data-skin="beam"\]\[data-theme="dark"\] \{\n([\s\S]*?)\n\}/),
};
const COLOUR_KEYS = Object.keys(PALETTES['campfire dark']);

test('colours: Campfire red unless BEAM blue is saved; anything unknown or unreadable is Campfire red', () => {
  assert.deepEqual(SKINS, ['campfire', 'beam']);
  assert.deepEqual(SKIN_WORDS, { campfire: 'Campfire red', beam: 'BEAM blue' });
  assert.equal(readSkin(memoryStorage()), 'campfire');
  assert.equal(readSkin(memoryStorage({ 'campfire-skin': 'beam' })), 'beam');
  assert.equal(readSkin(memoryStorage({ 'campfire-skin': 'purple' })), 'campfire');
  assert.equal(readSkin(blocked), 'campfire');
});

test('colours applied with the theme: the attribute, and the browser bar in that palette', () => {
  const d = fakeDoc();
  applyLook({ theme: 'system', skin: 'beam' }, d);
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.light.attrs.content, '#eef5fa');
  assert.equal(d.dark.attrs.content, '#042548');
  applyTheme('dark', d); // the theme changes, the colours stay
  assert.equal(d.documentElement.dataset.skin, 'beam');
  assert.equal(d.light.attrs.content, '#042548');
  const st = memoryStorage();
  assert.equal(setSkin('campfire', { storage: st, doc: d }), 'campfire');
  assert.equal('skin' in d.documentElement.dataset, false, 'Campfire red: no attribute');
  assert.equal(d.documentElement.dataset.theme, 'dark', 'the theme stays');
  assert.equal(d.light.attrs.content, '#1c1d22');
  assert.equal(st.m.has('campfire-skin'), false, 'the default leaves nothing saved');
  setSkin('beam', { storage: st, doc: d });
  assert.equal(st.m.get('campfire-skin'), 'beam');
  const d2 = fakeDoc();
  assert.equal(setSkin('beam', { storage: blocked, doc: d2 }), 'beam', 'storage blocked: this page only');
  assert.equal(d2.documentElement.dataset.skin, 'beam');
  // Each bar colour is its palette's background.
  for (const k of SKINS) for (const m of ['light', 'dark']) assert.equal(BARS[k][m], PALETTES[`${k} ${m}`].bg, `${k} ${m}`);
});

test('before the first paint: theme-boot.js sets the colours and the bar from the same key, the same values', () => {
  const boot = src('theme-boot.js');
  assert.match(src('lib/theme.js'), /const SKIN_KEY = 'campfire-skin';/);
  assert.match(boot, /localStorage\.getItem\('campfire-skin'\) === 'beam'/);
  assert.match(boot, /setAttribute\('data-skin', 'beam'\)/);
  assert.match(boot, new RegExp(`var bars = \\{ light: '${BARS.beam.light}', dark: '${BARS.beam.dark}' \\};`));
  const html = src('index.html');
  assert.ok(html.indexOf('theme-boot.js') > html.lastIndexOf('name="theme-color"'), 'the bar tags are read before it runs');
});

test('css: BEAM blue gives every colour Campfire has, light and dark, and its two dark blocks are one palette', () => {
  for (const name of ['beam light', 'beam dark']) assert.deepEqual(Object.keys(PALETTES[name]), COLOUR_KEYS, name);
  for (const k of COLOUR_KEYS) assert.ok(k in PALETTES['campfire light'], `campfire light has --${k}`);
  const sys = /@media \(prefers-color-scheme: dark\) \{\n {2}:root\[data-skin="beam"\]:not\(\[data-theme="light"\]\) \{\n([\s\S]*?)\n {2}\}\n\}/.exec(css);
  assert.ok(sys, 'the dark block under the device\'s dark mode');
  assert.deepEqual(tokens(sys[1]), PALETTES['beam dark']);
  // The palette is BEAM's own: navy, its blue and turquoise.
  assert.equal(PALETTES['beam dark'].bg, '#042548');
  assert.equal(PALETTES['beam light'].primary, '#035b8f');
  assert.equal(PALETTES['beam dark'].primary, '#00f6d2');
});

// WCAG 2 contrast of two opaque colours.
const lin = (c) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const lum = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
};
const ratio = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
// Every text colour, on every background the stylesheet puts it on.
const TEXT_PAIRS = [
  ...['text', 'text-2', 'muted', 'primary-text', 'on-secondary', 'error', 'success'].flatMap((f) => ['bg', 'surface', 'surface-2'].map((b) => [f, b])),
  ['on-primary', 'primary'], ['on-secondary', 'secondary'], ['bg', 'text'],
  ['success', 'success-bg'], ['error', 'error-bg'], ['info', 'info-bg'], ['warn', 'warn-bg'], ['text', 'secondary'],
];

test('every text colour reads at 4.5:1 or more on what it sits on, in both skins, light and dark', () => {
  const low = [];
  for (const [name, p] of Object.entries(PALETTES)) {
    for (const [f, b] of TEXT_PAIRS) {
      const r = ratio(p[f], p[b]);
      if (r < 4.5) low.push(`${name}: --${f} on --${b} ${r.toFixed(2)}`);
    }
  }
  assert.deepEqual(low, []);
});

test('css: text never takes the icon grey (--subtle) or the button colour (--primary) as its colour', () => {
  for (const m of css.matchAll(/([^{}\n]+)\{([^}]*)\}/g)) {
    const [sel, body] = [m[1].trim(), m[2]];
    if (/(^|[;\s])color: var\(--subtle\)/.test(body)) assert.match(sel, /svg|\.chev|\.off\b/, `${sel} draws text in --subtle`);
    if (/(^|[;\s])color: var\(--primary\)/.test(body)) assert.fail(`${sel} draws text in --primary (use --primary-text)`);
  }
});
