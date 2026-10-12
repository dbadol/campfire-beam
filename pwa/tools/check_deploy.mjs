// Checks a deployment from the outside, the way a phone sees it. Read-only: GET requests, plus a
// HEAD and a CORS preflight (OPTIONS) on the recovery relay, whose 330 MB file is never downloaded.
//
//   node tools/check_deploy.mjs <https://address/of/the/app/> [--copy] [--public <jwk>] [--concurrency 6]
//
// Run it after every deploy: the build cannot see what the host or its CDN does to the files.
//   - release.json, release.sig and manifest.json verify the way the loader verifies them
//     (lib/update_sources.js readRelease: the signature under keys/release_public.jwk, the
//     manifest hash, the app id);
//   - every file of the manifest is served with its signed size and SHA-256 and its Content-Type
//     (tools/headers.mjs MIME), the loader under its content-addressed name (sw-<first 16 hex of
//     its SHA-256>.js), named by both release.json and lib/version.js;
//   - every response carries exactly the headers tools/headers.mjs headersFor() gives its path:
//     the loader its own policy (with the page policy it can never update from a copy), HSTS,
//     CORS on the app's files, and Cache-Control: no-cache unchanged (a CDN that rewrites it to
//     max-age makes first visits mix an old and a new release);
//   - the recovery relay answers any origin (copies without a relay restore through it) and its
//     preflight; the explorer proxy answers this origin only;
//   - a path that is not in the release gets a 404 with the security headers, and http://
//     redirects to https://.
// --copy checks a public copy (GitHub Pages, jsDelivr, raw.githubusercontent.com): the release,
// every file, and CORS on each (installs elsewhere read it cross-origin); no headers, no proxies.
// Exits 1 on any problem, listing each; prints nothing secret (there is nothing secret here).
import { readFile } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { headersFor, cacheControlFor, mimeFor, RECOVERY_RELAY, EXPLORER_PROXY } from './headers.mjs';
import { readRelease } from '../src/lib/update_sources.js';
import { verifyFile } from '../src/lib/release.js';

const here = dirname(fileURLToPath(import.meta.url));
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const TIMEOUT_MS = 60000;
const RELAY = RECOVERY_RELAY.slice(1);
const EXPLORER = EXPLORER_PROXY.slice(1);

/** The headers a response must carry for `rel` (a path under the app's folder). */
export function expectedHeaders(rel) {
  const cc = cacheControlFor(rel);
  return { ...headersFor(rel), ...(cc ? { 'Cache-Control': cc } : {}) };
}

/** Differences between what a response carried and what it must carry: ["Name: got X (want Y)"]. */
export function headerProblems(rel, headers) {
  const want = expectedHeaders(rel);
  const out = [];
  for (const [k, v] of Object.entries(want)) {
    const got = headers.get(k);
    if (got === null) out.push(`${k}: missing (want ${v})`);
    else if (got !== v) out.push(`${k}: ${got} (want ${v})`);
  }
  // A path that must not be readable by other origins (the explorer proxy) must not say it is.
  if (!('Access-Control-Allow-Origin' in want) && headers.get('Access-Control-Allow-Origin') !== null) out.push(`Access-Control-Allow-Origin: ${headers.get('Access-Control-Allow-Origin')} (want none: this origin's own)`);
  return out;
}

const normType = (t) => String(t || '').toLowerCase().replace(/\s+/g, '');

/**
 * base: the app's folder (https://…/ with the trailing slash). publicJwk: the release key.
 * fetchImpl(url, init): one request. copy: a public copy (see above).
 * Returns { ok, problems: [string], release, files }.
 */
export async function checkDeploy({ base, publicJwk, fetchImpl = fetch, concurrency = 6, copy = false, onProgress = null }) {
  const root = new URL(base);
  if (!root.pathname.endsWith('/')) root.pathname += '/';
  const problems = [];
  const ask = async (url, { method = 'GET', headers = {} } = {}) => {
    const r = await fetchImpl(url, { method, cache: 'no-store', redirect: 'manual', credentials: 'omit', signal: AbortSignal.timeout(TIMEOUT_MS), headers: { 'User-Agent': 'beam-campfire-check-deploy/1', ...headers } });
    const bytes = method === 'GET' ? new Uint8Array(await r.arrayBuffer()) : new Uint8Array(0);
    if (method !== 'GET' && r.body) await r.body.cancel().catch(() => {});
    return { status: r.status, headers: r.headers, bytes };
  };
  const get = (rel, opts) => ask(new URL(rel, root).href, opts);
  const look = (rel, res) => {
    if (copy) {
      if (res.headers.get('Access-Control-Allow-Origin') !== '*') problems.push(`${rel}: Access-Control-Allow-Origin: ${res.headers.get('Access-Control-Allow-Origin') || 'missing'} (want *)`);
      return;
    }
    for (const p of headerProblems(rel, res.headers)) problems.push(`${rel}: ${p}`);
  };

  // The three release files, verified like the loader does.
  const meta = {};
  let rel = null;
  try {
    rel = await readRelease(async (p) => {
      const res = await get(p);
      meta[p] = res;
      if (res.status !== 200) throw Object.assign(new Error(`${p}: HTTP ${res.status}`), { code: 'unreachable' });
      return res.bytes;
    }, publicJwk);
  } catch (e) {
    problems.push(`release: ${e.message}`);
    for (const [p, res] of Object.entries(meta)) look(p, res);
    return { ok: false, problems, release: null, files: 0 };
  }
  for (const [p, res] of Object.entries(meta)) look(p, res);
  const { release, manifest } = rel;

  // Every file, with its signed size and SHA-256 and the right headers.
  let next = 0;
  let done = 0;
  const byPath = new Map();
  const worker = async () => {
    while (next < manifest.files.length) {
      const f = manifest.files[next++];
      let res;
      try {
        res = await get(f.path);
      } catch (e) {
        problems.push(`${f.path}: ${e.message}`);
        continue;
      }
      if (res.status !== 200) problems.push(`${f.path}: HTTP ${res.status}`);
      else {
        try {
          await verifyFile(f, res.bytes);
          byPath.set(f.path, res.bytes);
        } catch {
          problems.push(`${f.path}: not the signed file (${res.bytes.length} bytes, SHA-256 ${sha256(res.bytes).slice(0, 16)}…; signed ${f.size} bytes, ${f.sha256.slice(0, 16)}…)`);
        }
        // A copy's types do not matter: the loader stores every file with its own (tools/headers.mjs MIME).
        if (!copy && normType(res.headers.get('content-type')) !== normType(mimeFor(f.path))) problems.push(`${f.path}: Content-Type ${res.headers.get('content-type')} (want ${mimeFor(f.path)})`);
      }
      look(f.path, res);
      done++;
      if (onProgress) onProgress(done, manifest.files.length);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(concurrency, manifest.files.length)) }, worker));

  // The loader: named in release.json and lib/version.js, in the manifest, named after its bytes.
  const loader = release.loader;
  if (typeof loader !== 'string' || !/^sw-[0-9a-f]{16}\.js$/.test(loader)) problems.push(`release.json: loader ${loader} is not a loader name`);
  else {
    if (!manifest.files.some((f) => f.path === loader)) problems.push(`manifest.json: the loader ${loader} is not in it`);
    const bytes = byPath.get(loader);
    if (bytes && !sha256(bytes).startsWith(loader.slice(3, 19))) problems.push(`${loader}: its bytes do not hash to its name`);
    const versionJs = byPath.get('lib/version.js');
    const named = versionJs ? (new TextDecoder().decode(versionJs).match(/LOADER = "(sw-[0-9a-f]+\.js)"/) || [])[1] : null;
    if (versionJs && named !== loader) problems.push(`lib/version.js names loader ${named}, release.json ${loader}`);
  }
  if (copy) return { ok: problems.length === 0, problems, release, files: manifest.files.length };

  // The recovery relay: read cross-origin by copies without one (lib/recovery.js), resumed with
  // Range/If-Range after a preflight. HEAD only: the file is ~330 MB.
  const origin = { Origin: 'https://copy.example' };
  try {
    const res = await get(RELAY, { method: 'HEAD', headers: origin });
    if (res.status === 404) problems.push(`${RELAY}: HTTP 404 (no snapshot relay here)`);
    else if (res.status !== 200) problems.push(`${RELAY}: HTTP ${res.status}`);
    else {
      look(RELAY, res);
      if (!(Number(res.headers.get('content-length')) > 1e6)) problems.push(`${RELAY}: Content-Length ${res.headers.get('content-length')} (want the snapshot's size)`);
      const pre = await get(RELAY, { method: 'OPTIONS', headers: { ...origin, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'range,if-range' } });
      if (pre.status !== 204 && pre.status !== 200) problems.push(`${RELAY} (preflight): HTTP ${pre.status} (want 204 or 200)`);
      else for (const k of ['Access-Control-Allow-Origin', 'Access-Control-Allow-Methods', 'Access-Control-Allow-Headers']) if (pre.headers.get(k) !== headersFor(RELAY)[k]) problems.push(`${RELAY} (preflight): ${k}: ${pre.headers.get(k) || 'missing'} (want ${headersFor(RELAY)[k]})`);
    }
  } catch (e) {
    problems.push(`${RELAY}: ${e.message}`);
  }

  // The explorer proxy, when there is one: this origin's own.
  try {
    const res = await get(EXPLORER, { headers: origin });
    if (res.status === 200) look(EXPLORER, res);
  } catch (e) {
    problems.push(`${EXPLORER}: ${e.message}`);
  }

  // A path outside the release: 404, with the security headers too.
  const missing = `__campfire_check_deploy_${Date.now().toString(36)}.txt`;
  try {
    const res = await get(missing);
    if (res.status !== 404) problems.push(`${missing}: HTTP ${res.status} (want 404 for a path that is not in the release)`);
    // The security headers matter on an error page too; caching and CORS do not.
    for (const p of headerProblems(missing, res.headers)) if (!/^(Cache-Control|Access-Control-Allow-Origin):/.test(p)) problems.push(`a 404: ${p}`);
  } catch (e) {
    problems.push(`a 404: ${e.message}`);
  }

  // http:// must send the browser to https:// (HSTS takes over from the first https answer on).
  if (root.protocol === 'https:') {
    const plain = new URL(root.href);
    plain.protocol = 'http:';
    try {
      const res = await ask(plain.href);
      const to = res.headers.get('location') || '';
      if (![301, 302, 307, 308].includes(res.status) || !to.startsWith('https://')) problems.push(`${plain.href}: HTTP ${res.status}${to ? ` to ${to}` : ''} (want a redirect to https://)`);
    } catch (e) {
      problems.push(`${plain.href}: ${e.message}`);
    }
  }
  return { ok: problems.length === 0, problems, release, files: manifest.files.length };
}

async function main() {
  const args = process.argv.slice(2);
  const opt = (name, def) => {
    const i = args.indexOf(`--${name}`);
    return i < 0 ? def : args[i + 1];
  };
  const base = args.find((a, i) => !a.startsWith('--') && !(i > 0 && ['--public', '--concurrency'].includes(args[i - 1])));
  if (!base || !/^https?:\/\//.test(base)) {
    console.error('usage: node tools/check_deploy.mjs <https://address/of/the/app/> [--copy] [--public <jwk>] [--concurrency 6]');
    process.exit(2);
  }
  const pubPath = resolve(process.cwd(), opt('public', join(here, '..', 'keys', 'release_public.jwk')));
  const publicJwk = JSON.parse(await readFile(pubPath, 'utf8'));
  const copy = args.includes('--copy');
  const r = await checkDeploy({ base, publicJwk, copy, concurrency: Number(opt('concurrency', 6)), onProgress: (d, n) => d % 50 === 0 && console.log(`check-deploy: ${d} of ${n} files`) });
  if (r.release) console.log(`check-deploy: ${base} serves ${r.release.app} ${r.release.version} (${r.files} files, loader ${r.release.loader}, created ${r.release.created})${copy ? ' [public copy]' : ''}`);
  for (const p of r.problems) console.log(`PROBLEM ${p}`);
  console.log(r.ok ? 'check-deploy: OK' : `check-deploy: ${r.problems.length} problem(s)`);
  process.exit(r.ok ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
