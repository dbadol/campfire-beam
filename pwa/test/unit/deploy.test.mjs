// The deployment configs (deploy/nginx.conf, deploy/Caddyfile, deploy/_headers) say exactly what
// tools/headers.mjs headersFor() says, path by path. The build refuses to run when they drift;
// these tests say why each rule is there.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CSP, LOADER_CSP, SECURITY_HEADERS, caddyHeaderLines, headersFor } from '../../tools/headers.mjs';

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
  // Every other security header is the same on every path.
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (k !== 'Content-Security-Policy') assert.ok(caddyAllBlock(caddy).includes(`\t\t${k} "${v}"`), k);
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
