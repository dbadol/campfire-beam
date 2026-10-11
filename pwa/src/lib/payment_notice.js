// A notice when a payment arrives. A port of BEAM Campfire's
// lib/wallets/beam/wallet/beam_payment_notice.dart and BeamWallet._announceIncoming for the
// web wallet. Pure: which payments are news, and what the notice says. The banner and the
// system notification are screens/payment_notices.js.
//
// Rules (the app's):
//   - only a payment that came IN and completed while this wallet was open: income, status 3,
//     a value above 0, a plain payment (tx_type 0) or an offline / max-privacy one (7). Never
//     the wallet's own sends, its change, a split, or a contract call;
//   - the first read of the payment list in a session is history, not news: it is recorded and
//     nothing is announced;
//   - what turns up before the wallet has caught up once in this run is history too: a restore or
//     a Rescan finds past payments as it reads the blocks after BEAM's snapshot (measured: the
//     restored max-privacy throwaway "received" its 0.01 BEAM a second after the restore, while
//     the wallet already said Synced: is_in_sync follows the block headers, the coins come from the
//     block bodies read after them), and a payment made while the app was closed is found the same
//     way after an unlock. So news starts once the wallet is Synced with no block requests left,
//     and 20 s after that (catchUp below); from then on it stays on for the run. The app
//     announces from its first read on; the web wallet does not, so a restore says nothing;
//   - each payment once.
//
// There is no server: nothing watches the wallet while BEAM Campfire is closed, so notices come
// only while it is open. On iPhone a web app runs only while it is on screen.

import { formatAmount } from './amount.js';
import { PRIVATE_LIMIT_HOURS } from './coins.js';

/** A completed incoming payment worth announcing. */
export function isNews(tx) {
  if (!tx || tx.income !== true || Number(tx.status) !== 3) return false;
  const type = Number(tx.tx_type);
  if (type !== 0 && type !== 7) return false;
  try {
    return BigInt(tx.value || 0) > 0n;
  } catch {
    return false;
  }
}

/**
 * Remembers which completed incoming payments were already seen. update(txs, loaded, live) returns
 * the ones that are news; while loaded is false (the list has not been read yet) it returns
 * nothing and records nothing; the first read after that only records, and so does any read
 * while live is false (the wallet is catching up). reset() starts over (a wallet locked,
 * switched or restarted).
 */
export function incomingWatcher() {
  let seen = null;
  return {
    reset() {
      seen = null;
    },
    get started() {
      return seen !== null;
    },
    update(txs, loaded = true, live = true) {
      if (!loaded) return [];
      const done = (txs || []).filter(isNews);
      if (seen === null || !live) {
        if (seen === null) seen = new Set();
        for (const t of done) seen.add(t.txId);
        return [];
      }
      const fresh = [];
      for (const t of done) {
        if (seen.has(t.txId)) continue;
        seen.add(t.txId);
        fresh.push(t);
      }
      return fresh;
    },
  };
}

export const CATCH_UP_GRACE_MS = 20000;

/** The wallet is up to date and has no sync requests (block bodies included) outstanding. */
export function settled(s) {
  if (!s || !s.running || s.importing || !s.sync || s.sync.state !== 'synced') return false;
  const p = s.progress;
  return !p || !(Number(p.total) > 0) || Number(p.done) >= Number(p.total);
}

/**
 * When a run has caught up: live(s, now) is false until the wallet has first been settled for
 * CATCH_UP_GRACE_MS, then true for the rest of the run (a new block's requests or a node hop do
 * not turn it off again, so a payment completing then is still news). reset() for a new run.
 */
export function catchUp(graceMs = CATCH_UP_GRACE_MS) {
  let since = null;
  return {
    reset() {
      since = null;
    },
    live(s, now = Date.now()) {
      if (since === null && settled(s)) since = now;
      return since !== null && now - since >= graceMs;
    },
  };
}

/**
 * "Received 0.5 BEAM", "Received 12 FOMO", "Received 3 of token #779". Only a verified asset is
 * named by its ticker: anyone can mint a token called "BEAM". label: wallet.label(assetId).
 */
export function noticeTitle(tx, label) {
  const amount = formatAmount(BigInt(tx.value || 0));
  const id = Number(tx.asset_id) || 0;
  if (id === 0) return `Received ${amount} BEAM`;
  return label && label.verified && !label.pool ? `Received ${amount} ${label.symbol}` : `Received ${amount} of token #${id}`;
}

/** The line under it: how a private payment becomes spendable, or where to see it. */
export function noticeBody(tx, { walletName = null } = {}) {
  const where = walletName ? ` In ${walletName}.` : '';
  if (Number(tx.tx_type) === 7 && tx.address_type === 'max_privacy') return `It arrived privately: you can spend it within ${PRIVATE_LIMIT_HOURS} hours.${where}`;
  return `Tap to see it in Activity.${where}`;
}

/** Several at once: one notice. */
export const severalTitle = (n) => `Received ${n} payments`;

// ---------------------------------------------------------------- the browser's notifications

/** 'granted' | 'denied' | 'default' | 'unsupported' (no Notification API here: an iPhone's Safari tab, an old browser). */
export function notificationPermission(win = globalThis) {
  const N = win && win.Notification;
  if (typeof N !== 'function' || typeof N.requestPermission !== 'function') return 'unsupported';
  return ['granted', 'denied', 'default'].includes(N.permission) ? N.permission : 'default';
}

export function isIos(nav = globalThis.navigator) {
  if (!nav) return false;
  const ua = String(nav.userAgent || '');
  // iPadOS reports a Mac; it has touch.
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && Number(nav.maxTouchPoints) > 1);
}

export function isStandalone(win = globalThis) {
  try {
    return Boolean((win.navigator && win.navigator.standalone) || (win.matchMedia && win.matchMedia('(display-mode: standalone)').matches));
  } catch {
    return false;
  }
}

export const NOTICE_TEXT = Object.freeze({
  rowTitle: 'Payment notifications',
  /** Said plainly, wherever the switch is. */
  onlyWhileOpen: 'No server watches your wallet for you, so a notification comes only while BEAM Campfire is open. On iPhone that means while it is on screen.',
  denied: "Notifications are blocked for BEAM Campfire in this browser's settings. Allow them there, then turn this on again. The banner inside the app shows each payment either way.",
  iosHomeScreen: 'On iPhone, notifications work only in the app added to your Home Screen (Share → Add to Home Screen), and only while it is open.',
  unsupported: "This browser can't show notifications. The banner inside the app shows each payment either way.",
  turnedOn: 'Payment notifications are on while BEAM Campfire is open',
  turnedOff: 'Payment notifications are off. The banner inside the app stays.',
  bannerOnly: 'The banner inside the app shows each payment either way',
  notAsked: "Not turned on: the browser's question was closed. Tap the switch to be asked again.",
});

/** The switch's line under its title. */
export function rowSubtitle({ on, permission, ios = false, standalone = false }) {
  if (permission === 'unsupported') return ios && !standalone ? 'On iPhone: add BEAM Campfire to your Home Screen first' : "This browser can't show them";
  if (permission === 'denied') return 'Blocked in this browser’s settings';
  if (on && permission === 'granted') return ios ? 'On, while BEAM Campfire is on screen' : 'On, while BEAM Campfire is open';
  return 'Off. A banner in the app shows each payment';
}
