// More ways to receive (lib/receive_types.js): when the web wallet may offer offline, max-privacy
// and public addresses (measured on mainnet: only with block scanning on or on an own node with the
// owner key), what each says, and how they are made.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PRIVATE_TYPES, typeTitle, typeExplainer, privateReceiveGate, blockedReason, receiveErrorText, makePrivateAddress } from '../../src/lib/receive_types.js';

const base = { running: true, importing: false, scanning: false, nodeMode: 'random', nodeConnected: true, connEvent: { node_connected: true, own_node: false } };

test('the gate: scanning on, or an own node holding the owner key; otherwise it says why', () => {
  assert.deepEqual(privateReceiveGate({ ...base, scanning: true }), { available: true, block: null });
  assert.deepEqual(privateReceiveGate({ ...base, nodeMode: 'own', connEvent: { node_connected: true, own_node: true } }), { available: true, block: null });
  assert.equal(privateReceiveGate(base).block, 'noScan', 'a new wallet on a random node');
  assert.equal(privateReceiveGate({ ...base, nodeMode: 'own' }).block, 'ownNodeNoKey');
  assert.equal(privateReceiveGate({ ...base, nodeMode: 'own', nodeConnected: false, connEvent: null }).block, 'ownNodeConnecting');
  assert.equal(privateReceiveGate({ ...base, scanning: true, importing: true }).block, 'importing', 'still reading the snapshot');
  assert.equal(privateReceiveGate({ ...base, running: false, scanning: true }).block, 'connecting');
  assert.equal(privateReceiveGate(null).block, 'connecting');
});

test('every block says what turns them on, with the screens that help', () => {
  assert.deepEqual(blockedReason({ available: true, block: null }), { reason: '', actions: [] });
  const noScan = blockedReason({ block: 'noScan' });
  assert.deepEqual(noScan.actions, ['rescan', 'ownNode']);
  assert.match(noScan.reason, /Rescan/);
  assert.match(noScan.reason, /330 MB/);
  assert.match(noScan.reason, /owner key/);
  assert.deepEqual(blockedReason({ block: 'ownNodeNoKey' }).actions, ['ownerKey', 'rescan']);
  for (const b of ['connecting', 'importing', 'ownNodeConnecting']) assert.ok(blockedReason({ block: b }).reason.length > 20);
});

test('each type says what it does for the person paid: offline, when it can be spent, the fee', () => {
  assert.deepEqual([...PRIVATE_TYPES], ['offline', 'max_privacy', 'public_offline']);
  assert.equal(typeTitle('offline'), 'Offline address');
  assert.equal(typeTitle('max_privacy'), 'Max privacy address');
  assert.equal(typeTitle('public_offline'), 'Public address');
  for (const t of PRIVATE_TYPES) {
    assert.match(typeExplainer(t), /closed/, `${t}: works while the wallet is closed`);
    assert.match(typeExplainer(t), /0\.011 BEAM/, `${t}: the sender's fee`);
    assert.doesNotMatch(typeExplainer(t), /SBBS|voucher|Lelantus|shielded|token/i);
  }
  assert.match(typeExplainer('max_privacy'), /72 hours/);
});

test('errors never blame the person; -32005 says what turns it on', () => {
  const e = Object.assign(new Error('x'), { code: 'rpc', rpc: { code: -32005, message: 'Wallet must be connected to own node or mobile node protocol should be turned on' } });
  assert.match(receiveErrorText(e), /Rescan/);
  assert.match(receiveErrorText({ code: 'timeout' }), /Try again/);
  assert.match(receiveErrorText(new Error('boom')), /Try again/);
});

function fakeSession(list = []) {
  const calls = [];
  return {
    calls,
    async call(method, params) {
      calls.push({ method, params });
      if (method === 'addr_list') return list;
      if (method === 'create_address') return `${params.type}-address`;
      throw new Error(method);
    },
  };
}

test('making them: offline for one payment, max privacy fresh each time, a public address reused', async () => {
  const s = fakeSession();
  assert.deepEqual(await makePrivateAddress(s, 'offline'), { address: 'offline-address', reused: false });
  assert.deepEqual(s.calls[0].params, { type: 'offline', expiration: 'auto', offline_payments: 1 });
  await makePrivateAddress(s, 'max_privacy');
  assert.deepEqual(s.calls[1].params, { type: 'max_privacy', expiration: 'auto' });
  await makePrivateAddress(s, 'public_offline');
  assert.deepEqual(s.calls.slice(2).map((c) => c.method), ['addr_list', 'create_address']);
  assert.deepEqual(s.calls[3].params, { type: 'public_offline', expiration: 'never' });
  const have = fakeSession([{ address: 'old-public', type: 'public_offline', own: true, expired: false }]);
  assert.deepEqual(await makePrivateAddress(have, 'public_offline'), { address: 'old-public', reused: true });
  assert.equal(have.calls.length, 1);
  await assert.rejects(makePrivateAddress(s, 'regular'));
});
