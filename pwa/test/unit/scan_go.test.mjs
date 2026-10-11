// Home's Scan: where each kind of code goes (screens/scan_go.js destination), never a payment by itself.
import test from 'node:test';
import assert from 'node:assert/strict';
import { destination } from '../../src/screens/scan_go.js';
import { recognize } from '../../src/lib/scan_recognize.js';
import { TOKENS } from '../../src/lib/eth/tokens.js';

const yes = async () => true;
const no = async () => false;

test('BEAM address, link with amount, and a name: Send, filled', async () => {
  assert.deepEqual(await destination(recognize('beam:3f25d94eac4a95f4ff2b764f844aa588254982c6bcc83e02f157218d698c9df9477?amount=2')), { to: 'send', draft: { address: '3f25d94eac4a95f4ff2b764f844aa588254982c6bcc83e02f157218d698c9df9477', amount: '2' } });
  assert.deepEqual(await destination(recognize('Alice.beam')), { to: 'send', draft: { address: 'alice.beam', amount: '' } });
});

test('Ethereum: its Send with the recipient (and value), a known token, or a way to add the wallet', async () => {
  const to = '0x52908400098527886E0F7030069857D2E4169EE7';
  assert.deepEqual(await destination(recognize(`ethereum:${to}?value=1e18`), { hasEth: yes, tokens: TOKENS }), { to: 'ethSend', draft: { to, amountWei: '1000000000000000000', symbol: 'ETH' } });
  assert.deepEqual(await destination(recognize(to), { hasEth: no }), { sheet: 'noEth' });
  assert.deepEqual(await destination(recognize(`ethereum:0xe5acbb03d73267c03349c76ead672ee4d941f499/transfer?address=${to}&uint256=100`), { hasEth: yes, tokens: TOKENS }), { to: 'ethSend', draft: { to, amount: '', symbol: 'WBEAM' } });
  assert.deepEqual(await destination(recognize(`ethereum:0x1111111111111111111111111111111111111111/transfer?address=${to}`), { hasEth: yes, tokens: TOKENS }), { sheet: 'token' });
});

test('an airdrop code: Airdrop codes, filled; everything else: shown, never opened', async () => {
  assert.deepEqual(await destination(recognize('abcd-efgh-jklm-npqr')), { to: 'airdrop', draft: { code: 'ABCDEFGHJKLMNPQR' } });
  assert.deepEqual(await destination(recognize('https://example.com')), { sheet: 'link' });
  assert.deepEqual(await destination(recognize('bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq')), { sheet: 'coin' });
  assert.deepEqual(await destination(recognize('hello world')), { sheet: 'unknown' });
});
