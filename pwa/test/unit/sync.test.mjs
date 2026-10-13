import test from 'node:test';
import assert from 'node:assert/strict';
import { ageText, assessSync, HF6_HEIGHT } from '../../src/lib/sync.js';

const now = 1_800_000_000;
const st = (h, age, inSync = true) => ({ current_height: h, current_state_timestamp: now - age, is_in_sync: inSync });
const ex = (h, age = 30) => ({ height: h, timestamp: now - age, fetchedAt: now - 5 });
const base = { nodeConnected: true, everConnected: true, now };

test('synced and verified: in sync, fresh tip, explorer agrees within 5 blocks', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: ex(4_000_003) });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, true);
  assert.equal(r.canSend, true);
});

test('no explorer (the installed app asks its web address for nothing): synced from the node\'s own fresh tip, saying so', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: null });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
  assert.equal(r.canSend, true);
  assert.equal(r.detail, 'Block 4,000,000, made 40 s ago (from the BEAM node).');
});

test('no explorer and a stale node tip: not synced, says how far behind by the clock', () => {
  const r = assessSync({ ...base, status: { ...st(4_000_000, 40), current_state_timestamp: base.now - 3600, is_in_sync: false }, explorer: null });
  assert.equal(r.state, 'syncing');
  assert.equal(r.canSend, false);
  assert.equal(r.behindBlocks, 60);
});

test('tip age wording', () => {
  assert.equal(ageText(5), 'just now');
  assert.equal(ageText(40), '40 s ago');
  assert.equal(ageText(300), '5 min ago');
});

test('explorer 6+ blocks ahead: behind, sending refused, says how far', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 40), explorer: ex(4_000_006) });
  assert.equal(r.state, 'behind');
  assert.equal(r.canSend, false);
  assert.equal(r.behindBlocks, 6);
  assert.match(r.title, /6 blocks behind/);
});

test('is_in_sync false: catching up, sending refused, blocks behind named', () => {
  const r = assessSync({ ...base, status: st(3_999_880, 7200, false), explorer: ex(4_000_000) });
  assert.equal(r.state, 'syncing');
  assert.equal(r.canSend, false);
  assert.equal(r.behindBlocks, 120);
  assert.match(r.title, /120 blocks behind/);
});

test('is_in_sync true but the tip is 11 minutes old: not synced', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 660, true), explorer: null });
  assert.equal(r.state, 'syncing');
  assert.equal(r.canSend, false);
});

test('a tip from the future (clock skew > 2 min) is not trusted', () => {
  const r = assessSync({ ...base, status: st(4_000_000, -600, true), explorer: null });
  assert.equal(r.canSend, false);
});

test('not connected to a node this session: never synced, whatever the stored tip says', () => {
  const r = assessSync({ ...base, everConnected: false, nodeConnected: false, status: st(4_000_000, 30), explorer: ex(4_000_000) });
  assert.equal(r.state, 'connecting');
  assert.equal(r.canSend, false);
  const r2 = assessSync({ ...base, nodeConnected: false, status: st(4_000_000, 30), explorer: ex(4_000_000) });
  assert.equal(r2.state, 'offline');
  assert.equal(r2.canSend, false);
});

test('connection failed: an honest offline state', () => {
  const r = assessSync({ ...base, everConnected: false, nodeConnected: false, connectFailed: true, status: null, explorer: null });
  assert.equal(r.state, 'offline');
  // No explorer in the installed app and the device says it is online: BEAM's nodes, never "check your internet".
  assert.equal(r.nodesDown, true);
  assert.match(r.title, /BEAM's nodes aren't answering/);
  assert.match(r.detail, /If other websites open, the problem is on BEAM's side/);
  assert.doesNotMatch(r.detail, /Check your internet/);
  const off = assessSync({ ...base, everConnected: false, nodeConnected: false, connectFailed: true, status: null, explorer: null, online: false });
  assert.equal(off.title, "You're offline");
  assert.match(off.detail, /no internet connection/);
  assert.notEqual(off.nodesDown, true);
});

test('no node answers but the explorer does: the nodes are down, not the person\'s internet', () => {
  const r = assessSync({ ...base, everConnected: false, nodeConnected: false, connectFailed: true, status: null, explorer: ex(4_000_000) });
  assert.equal(r.state, 'offline');
  assert.equal(r.nodesDown, true);
  assert.match(r.title, /BEAM's nodes aren't answering/);
  assert.match(r.detail, /Your internet works/);
  assert.match(r.detail, /coins are safe/);
  assert.equal(r.canSend, false);
  // Own node: still about that node.
  const own = assessSync({ ...base, everConnected: false, nodeConnected: false, connectFailed: true, status: null, explorer: ex(4_000_000), ownNode: 'node.example:8200' });
  assert.match(own.title, /Can't reach your node/);
});

test('below the HF6 fork while the network is past it: stalled on an old chain', () => {
  const r = assessSync({ ...base, status: st(HF6_HEIGHT - 1, 30), explorer: ex(HF6_HEIGHT + 100000) });
  assert.equal(r.state, 'stalled');
  assert.equal(r.canSend, false);
});

test('a stale explorer (old tip or old fetch) is not used as a check', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 30), explorer: { height: 4_000_100, timestamp: now - 3600, fetchedAt: now } });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
  const r2 = assessSync({ ...base, status: st(4_000_000, 30), explorer: { height: 4_000_100, timestamp: now - 10, fetchedAt: now - 3600 } });
  assert.equal(r2.verified, false);
});

test('an explorer far behind the wallet cannot vouch for it', () => {
  const r = assessSync({ ...base, status: st(4_000_000, 30), explorer: ex(3_999_000) });
  assert.equal(r.state, 'synced');
  assert.equal(r.verified, false);
});

test('no height constant grants synced: a high height with is_in_sync false stays unsynced', () => {
  const r = assessSync({ ...base, status: st(9_999_999, 30, false), explorer: null });
  assert.equal(r.canSend, false);
});

test('importing the snapshot is its own state', () => {
  const r = assessSync({ ...base, importing: true, status: null, explorer: null });
  assert.equal(r.state, 'importing');
  assert.equal(r.canSend, false);
});

test('reconnecting stands only while the first nodes are tried; then the real state (13 Oct 2026 outage)', async () => {
  const { reconnectView, RECONNECT_EMPTY_HOPS, assessSync } = await import('../../src/lib/sync.js');
  const sw = { from: 'a', to: 'b' };
  assert.deepEqual(reconnectView({ switching: sw, emptyHops: 0 }), { reconnecting: true, connectFailed: false });
  assert.deepEqual(reconnectView({ switching: sw, emptyHops: RECONNECT_EMPTY_HOPS - 1 }), { reconnecting: true, connectFailed: false });
  assert.deepEqual(reconnectView({ switching: sw, emptyHops: RECONNECT_EMPTY_HOPS }), { reconnecting: false, connectFailed: true });
  assert.deepEqual(reconnectView({ switching: null, emptyHops: 9 }), { reconnecting: false, connectFailed: false }, 'not moving: nothing to say here');
  assert.deepEqual(reconnectView({ switching: null, connectFailed: true }), { reconnecting: false, connectFailed: true });
  // Every node refusing while the explorer answers: "BEAM's nodes aren't answering", not a spinner.
  const now = 2_000_000_000;
  const v = reconnectView({ switching: sw, emptyHops: 5 });
  const s = assessSync({ status: { current_height: 100, current_state_timestamp: now - 600 }, nodeConnected: false, everConnected: false, connectFailed: v.connectFailed, explorer: { height: 4078400, at: now }, now, reconnecting: v.reconnecting });
  assert.equal(s.nodesDown, true);
  assert.equal(s.title, "BEAM's nodes aren't answering");
});
