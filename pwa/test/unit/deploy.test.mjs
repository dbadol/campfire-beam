// The deployment configs (deploy/nginx.conf, deploy/Caddyfile, deploy/_headers) say exactly what
// tools/headers.mjs headersFor() says, path by path. The build refuses to run when they drift;
// these tests say why each rule is there.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CSP, LOADER_CSP, SECURITY_HEADERS, MIME, caddyHeaderLines, headersFor } from '../../tools/headers.mjs';
import { RECOVERY_FALLBACK } from '../../src/lib/recovery.js';

const deploy = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'deploy');
const read = (name) => readFileSync(join(deploy, name), 'utf8');

/** The Caddyfile's header block without a matcher (it applies to every response). */
function caddyAllBlock(caddy) {
  const m = caddy.match(/\n\theader \{\n([\s\S]*?)\n\t\}\n/);
  assert.ok(m, 'deploy/Caddyfile has a header block for every response');
  return m[1];
}

test('Caddyfile: the loader gets its own policy, pages the page policy, never both (audit C1/E-1)', () => {
  const caddy = read('Caddyfile');
  for (const line of caddyHeaderLines()) assert.ok(caddy.includes(line), `Caddyfile: ${line.slice(0, 70)}`);
  // A Content-Security-Policy in the block for every response reaches the loader too: the loader
  // then cannot fetch an update from any other copy (what the published Caddyfile did).
  assert.ok(!/Content-Security-Policy/.test(caddyAllBlock(caddy)), 'no policy in the block every response gets');
  assert.ok(caddy.includes(`header @loader Content-Security-Policy "${LOADER_CSP}"`));
  assert.ok(caddy.includes(`header @page Content-Security-Policy "${CSP}"`));
  // Every other security header is the same on every path, but CORP: the recovery relay's is cross-origin.
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (!['Content-Security-Policy', 'Cross-Origin-Resource-Policy'].includes(k)) assert.ok(caddyAllBlock(caddy).includes(`\t\t${k} "${v}"`), k);
  assert.ok(!/Cross-Origin-Resource-Policy|Access-Control-|Cache-Control/.test(caddyAllBlock(caddy)), 'path-dependent headers are set by matchers only');
});

test('nginx: the loader rule matches the loader at the root only, as headersFor() does', () => {
  const nginx = read('nginx.conf');
  assert.ok(nginx.includes(`"~^/sw(-[0-9a-f]+)?\\.js$" "${LOADER_CSP}";`), 'anchored: /lib/sw-….js is a page file, not the loader');
});

test('HSTS on every response, in every deploy config (audit C3/E-2)', () => {
  // One year, this host only. includeSubDomains/preload would bind every *.buybeam.my site: the owner's call.
  const HSTS = 'max-age=31536000';
  assert.equal(SECURITY_HEADERS['Strict-Transport-Security'], HSTS);
  for (const p of ['index.html', 'sw-0123456789abcdef.js', 'release.json', 'recovery/mainnet_recovery.bin', 'explorer/status']) assert.equal(headersFor(p)['Strict-Transport-Security'], HSTS, p);
  assert.ok(read('nginx.conf').includes(`add_header Strict-Transport-Security "${HSTS}" always;`), 'nginx');
  assert.ok(caddyAllBlock(read('Caddyfile')).includes(`\t\tStrict-Transport-Security "${HSTS}"`), 'Caddy');
  assert.match(read('_headers'), new RegExp(`\\n/\\*\\n(?:  [^\\n]+\\n)*  Strict-Transport-Security: ${HSTS}\\n`), '_headers');
});

test('the recovery relay is open to every copy, read-only; the explorer proxy is not (audit E-5)', () => {
  // lib/recovery.js: a copy with no relay of its own (GitHub Pages, jsDelivr) restores through this
  // one, cross-origin, with Range/If-Range to resume, reading ETag and Content-Range.
  assert.equal(new URL(RECOVERY_FALLBACK).pathname, '/recovery/mainnet_recovery.bin');
  const r = headersFor('recovery/mainnet_recovery.bin');
  assert.equal(r['Access-Control-Allow-Origin'], '*');
  assert.equal(r['Cross-Origin-Resource-Policy'], 'cross-origin');
  assert.equal(r['Access-Control-Allow-Methods'], 'GET, HEAD');
  assert.equal(r['Access-Control-Allow-Headers'], 'Range, If-Range');
  for (const h of ['Content-Range', 'ETag', 'Last-Modified', 'Content-Length']) assert.ok(r['Access-Control-Expose-Headers'].split(', ').includes(h), h);
  const e = headersFor('explorer/status');
  assert.equal(e['Access-Control-Allow-Origin'], undefined, 'the explorer proxy is for this origin only');
  assert.equal(e['Cross-Origin-Resource-Policy'], 'same-origin');
  for (const k of Object.keys(e)) assert.ok(!/^Access-Control-/.test(k), k);
  // nginx: a preflight (If-Range is not a simple header) is answered before the GET/HEAD-only rule.
  const nginx = read('nginx.conf');
  const relay = nginx.slice(nginx.indexOf('location = /recovery/mainnet_recovery.bin {'));
  const relayBlock = relay.slice(0, relay.indexOf('\n    }\n')).replace(/^\s*#.*\n/gm, '');
  // Not limit_except: nginx applies it before any "if" runs, and the preflight got 403 (measured on nginx 1.31).
  assert.match(relayBlock, /if \(\$request_method = OPTIONS\) \{ return 204; \}\n\s+if \(\$request_method !~ \^\(GET\|HEAD\)\$\) \{ return 405; \}/);
  assert.ok(!relayBlock.includes('limit_except'));
  // Caddy: the same.
  const caddy = read('Caddyfile');
  const ch = caddy.slice(caddy.indexOf('handle /recovery/mainnet_recovery.bin {'));
  assert.match(ch.slice(0, ch.indexOf('\n\t}\n')), /@preflight method OPTIONS\n\t\trespond @preflight 204\n\t\t@write not method GET HEAD\n\t\trespond @write 405/);
});

test('nginx.conf loads on nginx 1.24, the version pwa.buybeam.my runs', () => {
  const nginx = read('nginx.conf');
  assert.ok(!/^\s*http2 on;/m.test(nginx), '"http2 on;" exists from nginx 1.25.1 only');
  assert.match(nginx, /^\s*listen 443 ssl http2;$/m);
  assert.match(nginx, /^\s*listen \[::\]:443 ssl http2;$/m);
  // http:// answers with a redirect to this host only, never to whatever Host the request named.
  assert.match(nginx, /listen 80;[\s\S]*return 301 https:\/\/\$server_name\$request_uri;/);
});

test('nginx serves the Content-Type the loader serves (tools/headers.mjs MIME), UTF-8 for text', () => {
  const nginx = read('nginx.conf');
  const types = nginx.slice(nginx.indexOf('types {'), nginx.indexOf('}', nginx.indexOf('types {')));
  // nginx always counts text/html among charset_types (naming it again is a warning).
  const charsetTypes = ['text/html', ...(nginx.match(/charset_types ([^;]+);/) || [, ''])[1].split(/\s+/)];
  assert.match(nginx, /^\s*charset utf-8;$/m);
  for (const [ext, mime] of Object.entries(MIME)) {
    const [type, param] = mime.split('; ');
    assert.match(types, new RegExp(`${type.replace(/[+/.]/g, '\\$&')}[^;]*\\b${ext.slice(1)}\\b`), `nginx types: ${ext}`);
    assert.equal(charsetTypes.includes(type), param === 'charset=utf-8', `nginx charset for ${ext}`);
  }
});

test("the hosting repository's own files are never served (its root is a git checkout)", () => {
  const nginx = read('nginx.conf');
  for (const rule of ['location = /_headers { return 404; }', 'location = /README.md { return 404; }', 'location ^~ /deploy/ { return 404; }', 'location ~ "^/\\.(?!well-known/)" { return 404; }']) assert.ok(nginx.includes(rule), rule);
  const caddy = read('Caddyfile');
  assert.ok(caddy.includes('@private path /.git /.git/* /.github/* /.nojekyll /deploy/* /README.md /_headers'));
});
