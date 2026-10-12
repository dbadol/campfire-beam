// The wallet password is never offered to the browser's password manager (audit A-3; the Firo
// wallet's A-4). A password saved there sits in the same browser profile as the wallet it opens:
// whoever copies the profile (an infostealer, a backup) reads both, and for an imported wallet it is
// also the key of wallet.db itself. autocomplete="current-password" / "new-password" are the
// invitation to save it; every password field says "off" instead. Unlock, Set and Change password
// say why to refuse when a browser offers anyway.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CHANGE_TEXT } from '../../src/screens/change_password.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');

function sources() {
  const files = [];
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) {
        if (e.name !== 'vendor') walk(join(d, e.name));
      } else if (e.name.endsWith('.js')) files.push(join(d, e.name));
    }
  };
  walk(src);
  return files;
}

test('no field asks the browser to save or fill a password (current-password / new-password)', () => {
  const bad = [];
  for (const f of sources()) {
    readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      if (/['"](current|new)-password['"]/.test(line)) bad.push(`${f.slice(src.length + 1)}:${i + 1}`);
    });
  }
  assert.deepEqual(bad, []);
});

test('every password field says autocomplete off', () => {
  const bad = [];
  for (const f of sources()) {
    const lines = readFileSync(f, 'utf8').split('\n');
    lines.forEach((line, i) => {
      // backup.js builds its sheet fields with one helper that sets it for all of them.
      if (/type:\s*'password'/.test(line) && !/autocomplete:\s*'off'/.test(line)) bad.push(`${f.slice(src.length + 1)}:${i + 1}`);
    });
  }
  assert.deepEqual(bad, []);
});

test('Unlock, Set and Change password say why the browser should not keep it', () => {
  for (const f of ['screens/unlock.js', 'screens/set_password.js', 'screens/change_password.js']) assert.match(readFileSync(join(src, f), 'utf8'), /notSavedNote\(app/, f);
  assert.match(readFileSync(join(src, 'lib', 'auth_ui.js'), 'utf8'), /If the browser offers to save this password, choose Never: there it would sit next to the wallet it opens\./);
});

test('Change password tells an imported wallet that its wallet.db still opens with the file password', () => {
  assert.match(CHANGE_TEXT.leadImported, /the copy inside this browser, still open with the password the file had/);
  assert.match(CHANGE_TEXT.newLabel, /10\+ characters, not a common one/);
});
