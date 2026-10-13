// Issue #17 (and #75): a voucher code works like cash, and on the old contract a claim shows it to the
// network before it is confirmed. The app says so since 1.2.0 (AirdropBearerText); the web wallet says
// the same words where an old contract's code is claimed. New codes are made on Airdrop v3, where a
// claim never carries the code: its own words say what changed and what did not (a code is still a
// bearer secret, and its maker can take it back until the claim is confirmed).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { BEARER_TEXT, BEARER_TEXT_V3 } from '../../src/screens/airdrop.js';

const repo = (p) => readFileSync(new URL(`../../../${p}`, import.meta.url), 'utf8');
const src = (p) => readFileSync(new URL(`../../src/${p}`, import.meta.url), 'utf8');

/** A Dart `static const name = '...' '...';` with its adjacent literals joined. */
function dartConst(dart, name) {
  const m = new RegExp(`static const ${name} =((?:\\s*'(?:[^'\\\\]|\\\\.)*')+)\\s*;`).exec(dart);
  assert.ok(m, name);
  return [...m[1].matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((x) => x[1].replace(/\\'/g, "'")).join('');
}

test("the web wallet's words are the app's, word for word", () => {
  const dart = repo('lib/widgets/beam/airdrop/airdrop_text.dart');
  for (const k of ['createTitle', 'createMessage', 'claimMessage']) assert.equal(BEARER_TEXT[k], dartConst(dart, k), k);
  assert.match(BEARER_TEXT.claimMessage, /^Claiming shows this code to the network before it is confirmed, so someone watching could claim it first\./);
});

test('v3: a claim never shows the code, but a code still works like cash and can be taken back until claimed', () => {
  assert.equal(BEARER_TEXT_V3.createTitle, 'Codes work like cash');
  assert.match(BEARER_TEXT_V3.createMessage, /^Anyone who has a code can claim it, so give each code only to its person\./);
  assert.match(BEARER_TEXT_V3.createMessage, /Claiming never shows the code to the network, so nobody watching can take it\./);
  assert.match(BEARER_TEXT_V3.claimMessage, /^The network never sees this code, so nobody watching can take your claim\./);
  assert.match(BEARER_TEXT_V3.claimMessage, /anyone else who has the code could still claim it first, and whoever made it could still take it back\.$/);
  // Never the old warning for a v3 code, and never "safe" without its limits.
  for (const t of Object.values(BEARER_TEXT_V3)) {
    assert.doesNotMatch(t, /shows (this|the) code to the network before/);
    assert.doesNotMatch(t, /\bsafe\b/);
  }
});

test('said where codes are made (before the button) and with a code that was found, in the words of its contract', () => {
  const create = src('screens/airdrop_create.js');
  // New codes are made on v3 only, so the create screen says v3's words.
  assert.match(create, /notice\('warn', h\('strong', \{ text: `\$\{BEARER_TEXT_V3\.createTitle\}\. ` \}\), BEARER_TEXT_V3\.createMessage\)/);
  assert.doesNotMatch(create, /BEARER_TEXT\./, 'not the old contract\'s words');
  assert.match(create, /bearer\.dataset\.testid = 'drop-bearer';/);
  assert.doesNotMatch(create, /Anyone with a code can claim it\./, 'not said twice');
  assert.match(src('screens/airdrop.js'), /'data-testid': 'airdrop-bearer', text: info\.contract === 'v3' \? BEARER_TEXT_V3\.claimMessage : BEARER_TEXT\.claimMessage/);
});

test('the app\'s code comments no longer say a code is safe until the claim is mined (#75)', () => {
  const service = repo('lib/wallets/beam/contracts/airdrop/beam_airdrop_service.dart');
  const args = repo('lib/wallets/beam/contracts/airdrop/airdrop_args.dart');
  assert.doesNotMatch(service, /once the claim is mined, not before/);
  assert.match(service, /the network sees it before the claim is\n\/\/\/ mined, so someone watching could claim the voucher first/);
  assert.match(args, /It does not protect\n {2}\/\/\/ the claim itself: the code travels in the claim transaction, which the\n {2}\/\/\/ network sees before it is mined/);
});
