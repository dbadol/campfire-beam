// Issue #17 (and #75): a voucher code works like cash, and a claim shows it to the network before it
// is confirmed. The app says so since 1.2.0 (AirdropBearerText); the web wallet says the same words,
// where codes are made and where they are claimed. Nothing beyond what the app already says.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { BEARER_TEXT } from '../../src/screens/airdrop.js';

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

test('said where codes are made (before the button) and with a code that was found', () => {
  const create = src('screens/airdrop_create.js');
  assert.match(create, /notice\('warn', h\('strong', \{ text: `\$\{BEARER_TEXT\.createTitle\}\. ` \}\), BEARER_TEXT\.createMessage\)/);
  assert.match(create, /bearer\.dataset\.testid = 'drop-bearer';/);
  assert.doesNotMatch(create, /Anyone with a code can claim it\./, 'not said twice');
  assert.match(src('screens/airdrop.js'), /'data-testid': 'airdrop-bearer', text: BEARER_TEXT\.claimMessage/);
});

test('the app\'s code comments no longer say a code is safe until the claim is mined (#75)', () => {
  const service = repo('lib/wallets/beam/contracts/airdrop/beam_airdrop_service.dart');
  const args = repo('lib/wallets/beam/contracts/airdrop/airdrop_args.dart');
  assert.doesNotMatch(service, /once the claim is mined, not before/);
  assert.match(service, /the network sees it before the claim is\n\/\/\/ mined, so someone watching could claim the voucher first/);
  assert.match(args, /It does not protect\n {2}\/\/\/ the claim itself: the code travels in the claim transaction, which the\n {2}\/\/\/ network sees before it is mined/);
});
