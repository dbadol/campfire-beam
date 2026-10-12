// What the loader (sw.js) and the page (lib/loader.js) send when they fetch release files and the
// loader script: never cookies, not even to the app's own address. A cookie set for the parent
// domain (any script on a sibling *.buybeam.my site can set one) rides along on every same-origin
// request that carries credentials; a large one makes the CDN refuse the request outright, which
// would take updates and loader checks down with it (audit E-9b). The app sets no cookies, so
// nothing is lost.
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { loadLoader } from './helpers/sw_sandbox.mjs';

async function testPub() {
  const k = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const j = await webcrypto.subtle.exportKey('jwk', k.publicKey);
  return { kty: j.kty, crv: j.crv, x: j.x, y: j.y };
}

test('the loader fetches release files without cookies, from its own address and from copies', async () => {
  const seen = [];
  const sw = await loadLoader({
    pub: await testPub(),
    fetch: async (url, init) => {
      seen.push({ url, init });
      return new Response('nope', { status: 404 });
    },
  });
  for (const base of ['https://wallet.example/', 'https://copy.example.net/campfire/']) {
    await assert.rejects(sw.fetchBytes(new URL(base), 'release.json'), (e) => e.code === 'unreachable');
  }
  assert.deepEqual(seen.map((s) => s.url), ['https://wallet.example/release.json', 'https://copy.example.net/campfire/release.json']);
  for (const { url, init } of seen) {
    assert.equal(init.credentials, 'omit', `${url}: no cookies`);
    assert.equal(init.cache, 'no-store', `${url}: past any HTTP cache`);
    assert.equal(init.referrerPolicy, 'no-referrer', `${url}: no referrer`);
  }
});

test("the page checks the loader's bytes without cookies", async () => {
  const seen = [];
  const prev = { fetch: globalThis.fetch, document: globalThis.document };
  globalThis.document = { baseURI: 'https://wallet.example/' };
  globalThis.fetch = async (url, init) => {
    seen.push({ url, init });
    return new Response('self.x = 1;', { status: 200, headers: { 'Content-Type': 'text/javascript' } });
  };
  try {
    const { loaderServed } = await import('../../src/lib/loader.js');
    assert.equal(await loaderServed('sw-0123456789abcdef.js'), false, 'other bytes than the name says');
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, 'https://wallet.example/sw-0123456789abcdef.js');
    assert.equal(seen[0].init.credentials, 'omit');
    assert.equal(seen[0].init.cache, 'no-store');
    assert.equal(seen[0].init.referrerPolicy, 'no-referrer');
  } finally {
    globalThis.fetch = prev.fetch;
    globalThis.document = prev.document;
  }
});
