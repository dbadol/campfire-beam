// A notice when a payment arrives (lib/payment_notice.js): which payments are news (BEAM
// Campfire's BeamWallet._announceIncoming), what the notice says (beam_payment_notice_test.dart),
// and the browser's notification states.
import test from 'node:test';
import assert from 'node:assert/strict';
import { isNews, incomingWatcher, catchUp, settled, CATCH_UP_GRACE_MS, noticeTitle, noticeBody, severalTitle, notificationPermission, isIos, isStandalone, rowSubtitle, NOTICE_TEXT } from '../../src/lib/payment_notice.js';

const tx = (txId, extra = {}) => ({ txId, tx_type: 0, income: true, status: 3, value: 50000000, asset_id: 0, sender: 'a', receiver: 'b', ...extra });

test('news: a completed incoming payment; never a send, change, a split or a contract call', () => {
  assert.equal(isNews(tx('1')), true);
  assert.equal(isNews(tx('2', { tx_type: 7, address_type: 'max_privacy' })), true, 'offline / max privacy');
  assert.equal(isNews(tx('3', { income: false })), false, 'a send');
  assert.equal(isNews(tx('4', { income: false, sender: '', receiver: '' })), false, 'a split');
  assert.equal(isNews(tx('5', { tx_type: 12 })), false, 'a contract call');
  assert.equal(isNews(tx('6', { status: 1 })), false, 'not finished');
  assert.equal(isNews(tx('7', { status: 4 })), false, 'failed');
  assert.equal(isNews(tx('8', { value: 0 })), false);
  assert.equal(isNews(null), false);
});

test('the first read is history; each later payment once; nothing before the list is read', () => {
  const w = incomingWatcher();
  assert.deepEqual(w.update([tx('old')], false), [], 'not read yet');
  assert.equal(w.started, false);
  assert.deepEqual(w.update([tx('old'), tx('waiting', { status: 1 })]), []);
  assert.equal(w.started, true);
  const fresh = w.update([tx('new'), tx('waiting'), tx('old'), tx('mine', { income: false })]);
  assert.deepEqual(fresh.map((t) => t.txId), ['new', 'waiting']);
  assert.deepEqual(w.update([tx('new'), tx('waiting'), tx('old')]), [], 'once');
  w.reset();
  assert.deepEqual(w.update([tx('new'), tx('another')]), [], 'after a stop the first read is history again');
  // Found while catching up (a restore reading the blocks after the snapshot): history, then never news.
  const caught = incomingWatcher();
  assert.deepEqual(caught.update([]), []);
  assert.deepEqual(caught.update([tx('found')], true, false), []);
  assert.deepEqual(caught.update([tx('found')], true, true), [], 'not news once synced either');
  assert.deepEqual(caught.update([tx('found'), tx('live')], true, true).map((t) => t.txId), ['live']);
  // A new wallet with nothing yet: its first payment is news.
  const empty = incomingWatcher();
  assert.deepEqual(empty.update([]), []);
  assert.deepEqual(empty.update([tx('first')]).map((t) => t.txId), ['first']);
});

test('news starts once the run has caught up (Synced, no block requests left) for 20 s, then stays on', () => {
  const synced = { running: true, importing: false, sync: { state: 'synced' }, progress: { done: 40, total: 40 } };
  assert.equal(settled(synced), true);
  assert.equal(settled({ ...synced, progress: { done: 12, total: 40 } }), false, 'block bodies still being read');
  assert.equal(settled({ ...synced, progress: null }), true);
  assert.equal(settled({ ...synced, sync: { state: 'syncing' } }), false);
  assert.equal(settled({ ...synced, importing: true }), false);
  assert.equal(CATCH_UP_GRACE_MS, 20000);
  const run = catchUp();
  assert.equal(run.live({ ...synced, progress: { done: 1, total: 9 } }, 0), false);
  assert.equal(run.live(synced, 1000), false, 'just caught up');
  assert.equal(run.live(synced, 20999), false);
  assert.equal(run.live(synced, 21000), true);
  assert.equal(run.live({ ...synced, progress: { done: 3, total: 4 } }, 22000), true, "a new block's requests do not turn it off");
  run.reset();
  assert.equal(run.live(synced, 30000), false, 'a new run catches up again');
});

test('the words: BEAM and verified assets by ticker, anything else by number', () => {
  assert.equal(noticeTitle(tx('1'), null), 'Received 0.5 BEAM');
  assert.equal(noticeTitle(tx('1', { value: 1200000000 }), null), 'Received 12 BEAM');
  assert.equal(noticeTitle(tx('1', { asset_id: 174, value: 56812970000 }), { verified: true, symbol: 'FOMO' }), 'Received 568.1297 FOMO');
  assert.equal(noticeTitle(tx('1', { asset_id: 779, value: 300000000 }), { verified: false, symbol: 'BEAM' }), 'Received 3 of token #779');
  assert.equal(severalTitle(3), 'Received 3 payments');
  assert.match(noticeBody(tx('1', { tx_type: 7, address_type: 'max_privacy' })), /privately.*72 hours/);
  assert.equal(noticeBody(tx('1')), 'Tap to see it in Activity.');
  assert.equal(noticeBody(tx('1'), { walletName: 'Savings' }), 'Tap to see it in Activity. In Savings.');
});

test("the browser's notifications: unsupported, asked, allowed, blocked", () => {
  const N = (permission) => Object.assign(function Notification() {}, { permission, requestPermission: () => Promise.resolve(permission) });
  assert.equal(notificationPermission({}), 'unsupported');
  assert.equal(notificationPermission({ Notification: N('default') }), 'default');
  assert.equal(notificationPermission({ Notification: N('granted') }), 'granted');
  assert.equal(notificationPermission({ Notification: N('denied') }), 'denied');
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }), true);
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 5 }), true, 'iPadOS');
  assert.equal(isIos({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', maxTouchPoints: 0 }), false);
  assert.equal(isStandalone({ navigator: { standalone: true } }), true);
  assert.equal(isStandalone({ navigator: {}, matchMedia: () => ({ matches: false }) }), false);
});

test('the switch says plainly what it does and when it cannot', () => {
  assert.match(rowSubtitle({ on: false, permission: 'unsupported', ios: true, standalone: false }), /Home Screen/);
  assert.match(rowSubtitle({ on: false, permission: 'unsupported' }), /can't/);
  assert.match(rowSubtitle({ on: false, permission: 'denied' }), /Blocked/);
  assert.equal(rowSubtitle({ on: true, permission: 'granted' }), 'On, while BEAM Campfire is open');
  assert.equal(rowSubtitle({ on: true, permission: 'granted', ios: true }), 'On, while BEAM Campfire is on screen');
  assert.match(rowSubtitle({ on: false, permission: 'granted' }), /^Off/);
  assert.match(NOTICE_TEXT.onlyWhileOpen, /only while BEAM Campfire is open/);
  assert.match(NOTICE_TEXT.onlyWhileOpen, /iPhone/);
});
