// The Minter and BlackHole app shaders the web wallet runs: pinned here by SHA-256 and size,
// byte for byte the desktop app's own files (assets/beam/shaders/, which the build copies), the
// same pins as its Dart constants and lib/shaders.js, and, from a real build, the same bytes in
// the release. A substituted shader could make the engine build something other than what the
// screen shows, so a change here must be deliberate.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SHADERS, SHADER_DIR } from '../../src/lib/shaders.js';

const PWA = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const REPO = join(PWA, '..');
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

const PINS = {
  minter: { file: 'minter_app.wasm', sha256: '95b37fc5708fbad7b323d52ef32e02c40d572433251d8ab6d1e88c80ba4b0fe1', size: 7430, dart: 'lib/wallets/beam/contracts/minter/minter_constants.dart' },
  blackhole: { file: 'blackhole_app.wasm', sha256: '98ee89c899026b1481be4202da1a26636925ffdcef8068ce18ba58eedc927e31', size: 3271, dart: 'lib/wallets/beam/contracts/burn/blackhole_constants.dart' },
};

test('the desktop app\'s shader files are exactly the pinned bytes', () => {
  for (const [key, pin] of Object.entries(PINS)) {
    const bytes = readFileSync(join(REPO, 'assets', 'beam', 'shaders', pin.file));
    assert.equal(bytes.length, pin.size, key);
    assert.equal(sha256(bytes), pin.sha256, key);
    // A WebAssembly module, version 1.
    assert.deepEqual([...bytes.subarray(0, 8)], [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0], key);
  }
});

test('lib/shaders.js and the desktop\'s Dart constants pin the same', () => {
  for (const [key, pin] of Object.entries(PINS)) {
    assert.deepEqual({ ...SHADERS[key] }, pin, key);
    const dart = readFileSync(join(REPO, pin.dart), 'utf8');
    assert.ok(dart.includes(`'${pin.sha256}'`), `${pin.dart} pins ${pin.sha256}`);
    assert.match(dart, new RegExp(`=\\s*${pin.size}\\s*;`));
  }
});

test('a build ships them byte for byte, and lists them in the signed manifest', { timeout: 120000 }, () => {
  const out = mkdtempSync(join(tmpdir(), 'campfire-minter-shaders-'));
  try {
    execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(out, 'dist'), '--quiet'], { cwd: PWA });
    const manifest = JSON.parse(readFileSync(join(out, 'dist', 'manifest.json'), 'utf8'));
    const files = new Map((manifest.files || manifest).map((f) => [f.path, f]));
    for (const pin of Object.values(PINS)) {
      const path = `${SHADER_DIR}/${pin.file}`;
      const bytes = readFileSync(join(out, 'dist', path));
      assert.equal(sha256(bytes), pin.sha256, path);
      assert.ok(files.has(path), `${path} in manifest.json`);
      assert.equal(files.get(path).sha256, pin.sha256);
      assert.equal(files.get(path).size, pin.size);
    }
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
