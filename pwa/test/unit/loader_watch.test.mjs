// The tripwire's first watch (src/loader-watch.js) runs before every module of the app, and
// lib/loader.js watchLoader() replays what it saw. Without it, a loader swapped at its own URL that
// takes over a page while it is still loading its modules serves every module not loaded yet, and
// the app's own watch, which starts after its last module, never runs (ported from the Firo
// wallet, a15b0b6ba).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const OLD = 'https://wallet.example/sw-0000000000000000.js';

/** A page's navigator.serviceWorker as the watch sees it: a controller, listeners, a registration. */
function fakeServiceWorker(controllerUrl) {
  const listeners = {};
  const regListeners = {};
  const reg = { installing: null, waiting: null, addEventListener: (t, f) => ((regListeners[t] ||= []).push(f)) };
  const sw = {
    controller: controllerUrl ? { scriptURL: controllerUrl } : null,
    addEventListener: (t, f) => ((listeners[t] ||= []).push(f)),
    getRegistration: async () => reg,
    fire: (t) => (listeners[t] || []).forEach((f) => f()),
    install: (url) => {
      reg.installing = { scriptURL: url };
      (regListeners.updatefound || []).forEach((f) => f());
    },
    reg,
  };
  return sw;
}

/** A DOM just big enough for the early warning: elements with children, text and attributes. */
function fakeDocument() {
  const el = (tag) => ({ tag, children: [], attrs: {}, className: '', textContent: '', appendChild(c) { this.children.push(c); return c; }, removeChild(c) { this.children.splice(this.children.indexOf(c), 1); }, get firstChild() { return this.children[0] || null; }, setAttribute(k, v) { this.attrs[k] = v; } });
  const body = el('body');
  body.appendChild(el('div'));
  return { body, documentElement: el('html'), createElement: el, createTextNode: (t) => ({ tag: '#text', textContent: t }) };
}

function runEarlyWatch(sw) {
  const window = { stopped: 0, stop() { this.stopped++; } };
  const document = fakeDocument();
  vm.runInNewContext(readFileSync(join(src, 'loader-watch.js'), 'utf8'), { window, document, navigator: { serviceWorker: sw }, Object, Date });
  return { window, document, watch: window.__campfireLoaderWatch };
}

const texts = (n) => [n.textContent, ...(n.children || []).flatMap(texts)].join(' ');

test('index.html loads the watch as a classic script before anything else of the page', () => {
  const html = readFileSync(join(src, 'index.html'), 'utf8');
  const scripts = [...html.matchAll(/<script[^>]*>/g)].map((m) => m[0]);
  assert.equal(scripts[0], '<script src="loader-watch.js">', 'first, and not a module (modules are deferred)');
  assert.ok(html.indexOf('loader-watch.js') < html.indexOf('<link rel="stylesheet"'));
});

test('the loader that served the page taking over again stops the page at once, before the app watches', async () => {
  const sw = fakeServiceWorker(OLD);
  const { window, document, watch } = runEarlyWatch(sw);
  assert.equal(watch.initial, OLD);
  assert.equal(watch.stopped(), false);
  sw.fire('controllerchange'); // same URL, new bytes: what a takeover looks like
  assert.equal(watch.stopped(), true);
  assert.equal(window.stopped, 1, 'nothing else of the page loads');
  assert.equal(document.body.children[0].attrs['data-testid'], 'tripwire-early');
  assert.match(texts(document.body), /This app's web address is serving code BEAM Campfire did not sign\. Don't enter your password here\./);
  assert.throws(() => (window.__campfireLoaderWatch = null), 'the record cannot be replaced');
});

test('anything else is recorded for the app, which decides; once it watches, the early watch only reports', async () => {
  const sw = fakeServiceWorker(OLD);
  const { watch, window } = runEarlyWatch(sw);
  await new Promise((r) => setImmediate(r));
  sw.install('https://wallet.example/sw-1111111111111111.js');
  assert.equal(watch.stopped(), false, 'another name: the app decides (a move it expects, or a takeover)');
  const seen = [];
  watch.subscribe((ev) => seen.push([ev.type, ev.url]));
  assert.deepEqual(seen, [['updatefound', 'https://wallet.example/sw-1111111111111111.js']], 'replayed');
  sw.fire('controllerchange');
  assert.deepEqual(seen.at(-1), ['controllerchange', OLD], 'then followed');
  assert.equal(window.stopped, 0, 'the app watches now: it shows its own screen');
});

test('watchLoader replays the early record: a takeover before the app started is not missed', async () => {
  const prev = { window: globalThis.window, navigator: Object.getOwnPropertyDescriptor(globalThis, 'navigator') };
  try {
    const sw = fakeServiceWorker(OLD);
    Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: sw }, configurable: true, writable: true });
    const early = runEarlyWatch(sw).watch;
    globalThis.window = { __campfireLoaderWatch: early };
    // No registration for the app's own look: what it decides comes from the record alone (and no
    // take-over retries keep the test running).
    sw.getRegistration = async () => null;
    // A first page: no early stop (pretend the app was already watching when it came)...
    early.subscribe(() => {});
    sw.fire('controllerchange'); // ...the takeover happened while the modules loaded
    const { watchLoader } = await import(`../../src/lib/loader.js?early=${Date.now()}`);
    let why = null;
    await watchLoader({ onIntrusion: (w) => (why = w), onMoved: () => (why = 'moved') });
    assert.match(String(why), /changed|replaced/, 'the record says the controller changed: the tripwire fires');
  } finally {
    globalThis.window = prev.window;
    if (prev.navigator) Object.defineProperty(globalThis, 'navigator', prev.navigator);
    else delete globalThis.navigator;
  }
});
