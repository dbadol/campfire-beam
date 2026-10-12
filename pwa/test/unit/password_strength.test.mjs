// The wallet password: long enough, and not one of the first guesses (audit A-3). Whoever copies
// this browser's data can try passwords offline for as long as they like (PBKDF2-SHA256, 600,000
// rounds: about 15,000 guesses a second on one gaming graphics card), and the password envelope is
// in that copy whether or not Face ID is on. "8 characters" was the only rule, so "Password2024!",
// "qwertyuiop" and "1234567890" passed and showed "Good.". Decided on the device, no list
// downloaded (ported from the Firo wallet); a long passphrase of ordinary words always passes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { passwordWeakness, MIN_PASSWORD, PASSPHRASE_LENGTH } from '../../src/lib/password_strength.js';
import { passwordProblem, MIN_PASSWORD as SESSION_MIN } from '../../src/lib/session.js';
import { CLOUD_MIN_PASSWORD } from '../../src/lib/export.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const code = (pw, opts) => (passwordWeakness(pw, opts) || {}).code || null;

test('the old rule let first guesses through (what the audit found)', () => {
  for (const pw of ['Password2024!', 'qwertyuiop', '1234567890', 'aaaaaaaaaa', 'beamwallet1']) assert.notEqual(passwordProblem(pw, pw), null, pw);
});

test('at least 10 characters (counted as characters, not UTF-16 units)', () => {
  assert.ok(MIN_PASSWORD >= 10);
  assert.equal(SESSION_MIN, MIN_PASSWORD, 'one rule for the whole app');
  assert.equal(code('k7#vQ2!x'), 'short', 'the old 8-character minimum is not enough');
  assert.equal(code('k7#vQ2!xm'), 'short');
  assert.equal(code('k7#vQ2!xmW'), null);
  assert.equal(code('🔥🔥🌲🌲🏕️'), 'short');
  assert.match(passwordWeakness('abc').text, /at least 10 characters/);
});

test('the most common passwords, with numbers or symbols around them or look-alike digits inside', () => {
  for (const pw of ['Password2024!', 'password1234', 'P@ssw0rd123!', 'Passw0rd2024', '!!Qwerty!!12', 'Iloveyou2024', 'ILoveYou!!!', 'iloveyou12345', 'Bitcoin2024!', 'Campfire123', 'Beam2024!!!', 'BeamWallet1', 'Monkey12345', 'Superman2024', 'Summer2024!', 'letmein12345', 'Welcome2024!', 'Michael1985!', 'Dragon!!1234', 'admin1234567', 'Mimblewimble1'])
    assert.equal(code(pw), 'common', pw);
  assert.match(passwordWeakness('Password2024!').text, /one of the most common passwords/);
});

test('runs anyone tries first: abcd, 1234, keyboard rows and columns, either direction', () => {
  for (const pw of ['1234567890', '0987654321', 'abcdefghijk', 'qwertyuiop', 'Qwerty123!', 'poiuytrewq', '1q2w3e4r5t', '1qaz2wsx3edc', 'zaq12wsxcde', 'asdfghjkl;', 'qwertyuiop1', 'azertyuiop', 'zyxwvutsrqp'])
    assert.equal(code(pw), 'run', pw);
  assert.match(passwordWeakness('qwertyuiop').text, /abcd, 1234 or qwerty/);
});

test('the same few characters, or one part repeated', () => {
  for (const pw of ['aaaaaaaaaaaa', 'ababababababab', '1122112211', 'abc123abc123', 'xk9xk9xk9xk9', 'q7!q7!q7!q7!q7!']) assert.equal(code(pw), 'repeat', pw);
  assert.equal(code('passwordpassword'), 'repeat');
});

test('numbers alone (dates, phone numbers) unless very long', () => {
  for (const pw of ['1990051712', '0612 345 678', '17-05-1990-12', '31415926535']) assert.equal(code(pw), 'digits', pw);
  assert.equal(code('3141592653589793'), null, '16 digits or more is a lot to search');
  assert.match(passwordWeakness('1990051712').text, /Numbers alone/);
});

test('ordinary strong passwords and long passphrases pass', () => {
  for (const pw of ['correct horse battery staple', 'Tr0mbone-Lantern-77', 'mydogrex2019!', 'k7#vQ2!xmW', 'blue kettle on fire', 'Correct-Horse-7', 'violin-sunrise-otter', 'I love my old red bike', 'password is not my password at all', 'my beam wallet on the phone'])
    assert.equal(passwordWeakness(pw), null, pw);
  assert.ok(PASSPHRASE_LENGTH >= 16);
});

test("the e2e suites' throwaway passwords pass (a prefix and random letters or digits)", () => {
  const r36 = () => Math.random().toString(36).slice(2, 10).padEnd(8, '7');
  const hex6 = () => [...crypto.getRandomValues(new Uint8Array(6))].map((b) => b.toString(16).padStart(2, '0')).join('');
  for (let i = 0; i < 200; i++) {
    for (const pw of [`e2e-${r36()}`, `in-${r36()}`, `eth-${r36()}`, `ni-${r36()}`, `df-${r36()}`, `back-${hex6()}`, `fo-${hex6()}`, `mw-a-${hex6()}`, `okey-${r36()}${r36()}`, `notify-${r36()}`]) assert.equal(passwordWeakness(pw), null, pw);
  }
});

test('a copy kept in the cloud asks for more, by the same rules', () => {
  assert.equal(code('Tr0mb0ne-x', { min: CLOUD_MIN_PASSWORD }), 'short');
  assert.equal(code('Tr0mbone-x7!', { min: CLOUD_MIN_PASSWORD }), null);
  assert.equal(code('Password2024!', { min: CLOUD_MIN_PASSWORD }), 'common');
  const backup = readFileSync(join(src, 'screens', 'backup.js'), 'utf8');
  assert.match(backup, /if \(!passwordWeakness\(pw\.value, \{ min: CLOUD_MIN_PASSWORD \}\)\) \{/, 'the app password is reused for the copy only when it passes');
  assert.match(backup, /const weak = passwordWeakness\(pw1\.value, \{ min: CLOUD_MIN_PASSWORD \}\);/);
});

test('passwordProblem: the weakness first, then whether both fields match; Set and Change password use it', () => {
  assert.match(passwordProblem('short'), /at least 10/);
  assert.match(passwordProblem('Password2024!', 'Password2024!'), /most common/);
  assert.equal(passwordProblem('correct horse battery', 'correct horse battery'), null);
  assert.match(passwordProblem('correct horse battery', 'correct horse'), /don't match/);
  const set = readFileSync(join(src, 'screens', 'set_password.js'), 'utf8');
  assert.match(set, /passwordWeakness\(pw\.value\)/, 'named as it is typed');
  assert.match(set, /Face ID only saves typing: this password guards the wallet if someone copies this device's data\./);
  assert.match(readFileSync(join(src, 'screens', 'change_password.js'), 'utf8'), /passwordProblem\(n1\.value, n2\.value\)/);
});
