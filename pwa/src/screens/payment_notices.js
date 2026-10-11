/* Payment arrived (a banner over any screen) and Settings -> Payment notifications
 * Spec: ONE job: tell me when money arrives while BEAM Campfire is open.
 *       Primary CTA: none on the banner (a tap on it opens the payment in Activity); in Settings, one
 *       switch for the system notification, which asks the browser's permission on that tap.
 *       Taps from app open: 0 (the banner appears by itself); 2 to the switch (Settings -> Payment notifications).
 * Exit-intent reasons and answers:
 *   - "Did my money arrive?" -> the banner says "Received 0.5 BEAM" the moment the payment completes,
 *     and a tap shows it; a private payment also says when it can be spent.
 *   - "Will it ping me when the app is closed?" -> no, and the switch says so before it is turned on:
 *     no server watches the wallet; on iPhone it works only while the app is on screen.
 *   - "Why did it ask for permission?" -> it asks only when the switch is tapped, once; never by itself.
 *   - "Notifications for my own payments?" -> never: not for sends, change, splits or contract calls.
 */
import { h, put } from '../lib/dom.js';
import { icon } from '../lib/icons.js';
import { notice, openSheet, toast } from '../lib/ui.js';
import { wallet } from '../lib/wallet.js';
import { listWallets, nameOf } from '../lib/wallets.js';
import { incomingWatcher, catchUp, noticeTitle, noticeBody, severalTitle, notificationPermission, isIos, isStandalone, rowSubtitle, NOTICE_TEXT as T } from '../lib/payment_notice.js';

const BANNER_MS = 8000;
// What was announced this page's life (counts only, for the e2e harness and the self-test): nothing a payment said.
const stats = { banners: 0, system: 0, failed: 0 };
export const noticeStats = () => ({ ...stats });

export function installPaymentNotices(app) {
  const watch = incomingWatcher();
  const run = catchUp();
  wallet.onChange((s) => {
    // Stopped (locked, another wallet, a restart): the next run's first read is history. A move to
    // another node keeps the run, and the list, so nothing is missed or announced twice.
    if (!s.running) {
      watch.reset();
      run.reset();
      return;
    }
    // Locked (a payment keeps the engine running): nothing on screen; announced once unlocked.
    if (!app.dbPass || wallet.lockedRun) return;
    // Only once the run has caught up: what a catching-up wallet finds is history (lib/payment_notice.js).
    const fresh = watch.update(s.txs, s.txsLoaded === true, run.live(s));
    if (fresh.length) announce(app, fresh);
  });
}

async function announce(app, txs) {
  const one = txs.length === 1 ? txs[0] : null;
  const title = one ? noticeTitle(one, wallet.label(one.asset_id || 0)) : severalTitle(txs.length);
  showBanner(app, title, one ? noticeBody(one) : 'Tap to see them in Activity.', one ? one.txId : null);
  if (!(app.prefs && app.prefs.paymentNotifications === true) || notificationPermission() !== 'granted') return;
  let walletName = null;
  try {
    if ((await listWallets()).length > 1) walletName = nameOf(app.record);
  } catch {
    /* one wallet as far as we know */
  }
  const ok = await systemNotify(app, title, one ? noticeBody(one, { walletName }) : `Tap to see them in Activity.${walletName ? ` In ${walletName}.` : ''}`, one ? one.txId : 'several');
  stats[ok ? 'system' : 'failed']++;
}

/** The banner over whatever is on screen; a tap opens the payment. One at a time: a newer one replaces it. */
function showBanner(app, title, body, txId) {
  document.querySelectorAll('.pay-banner').forEach((b) => b.remove());
  const close = () => banner.remove();
  const open = () => {
    close();
    if (app.dbPass) app.go('activity', txId ? { txId } : {});
  };
  const banner = h(
    'div',
    { class: 'pay-banner', role: 'status', 'aria-live': 'polite', 'data-testid': 'pay-banner' },
    h(
      'button',
      { class: 'pay-banner-main', type: 'button', onclick: open, 'data-testid': 'pay-banner-open' },
      h('span', { class: 'ico' }, icon('receive')),
      h('span', { class: 'main' }, h('span', { class: 't', 'data-testid': 'pay-banner-title', text: title }), h('span', { class: 's', text: body })),
    ),
    h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Close', onclick: close, 'data-testid': 'pay-banner-close' }, icon('close')),
  );
  document.body.appendChild(banner);
  stats.banners++;
  setTimeout(close, BANNER_MS);
}

/**
 * The system notification. A page's own Notification where the browser has one (computers); else the
 * service worker's showNotification (Android, iPhone's Home Screen app), which needs no handler in it.
 */
async function systemNotify(app, title, body, tag) {
  const opts = { body, tag: `campfire-pay-${tag}`, icon: 'icons/icon-192.png', lang: 'en' };
  try {
    const n = new Notification(title, opts);
    n.addEventListener('click', () => {
      try {
        window.focus();
      } catch {
        /* nothing to focus */
      }
      if (app.dbPass) app.go('activity', tag !== 'several' ? { txId: tag } : {});
      n.close();
    });
    return true;
  } catch {
    try {
      const reg = navigator.serviceWorker ? await navigator.serviceWorker.getRegistration() : null;
      if (reg && typeof reg.showNotification === 'function') {
        await reg.showNotification(title, opts);
        return true;
      }
    } catch {
      /* not shown */
    }
  }
  return false;
}

/** Asks the browser, from the person's tap (it must be the first thing that tap does). Old Safari answers through a callback. */
function askPermission() {
  return new Promise((resolve) => {
    try {
      const r = Notification.requestPermission((v) => resolve(v));
      if (r && typeof r.then === 'function') r.then(resolve, () => resolve('denied'));
    } catch {
      resolve('denied');
    }
  });
}

function explain(text, testid) {
  openSheet((close) => [h('h2', { text: T.rowTitle }), h('div', { 'data-testid': testid }, notice('info', text)), h('p', { class: 'small', text: T.onlyWhileOpen }), h('button', { class: 'btn btn-primary', onclick: () => close() }, 'OK')], { label: T.rowTitle });
}

/** Settings' row: the switch, what it does now, and that notices come only while the app is open. */
export function notificationsRow(app) {
  const box = h('div');
  const ios = isIos();
  function render() {
    const permission = notificationPermission();
    const on = Boolean(app.prefs && app.prefs.paymentNotifications === true) && permission === 'granted';
    const sw = h('input', { type: 'checkbox', class: 'switch', role: 'switch', 'aria-label': T.rowTitle, 'data-testid': 'notify-switch', checked: on });
    sw.addEventListener('change', () => {
      if (!sw.checked) {
        app.setPrefs({ paymentNotifications: false }).then(() => {
          toast(T.turnedOff);
          render();
        });
        return;
      }
      if (permission === 'unsupported') {
        sw.checked = false;
        explain(ios && !isStandalone() ? T.iosHomeScreen : T.unsupported, 'notify-unsupported');
        return;
      }
      if (permission === 'denied') {
        sw.checked = false;
        explain(T.denied, 'notify-denied');
        return;
      }
      // The browser's question comes from this tap, before anything else is awaited.
      const asked = permission === 'granted' ? Promise.resolve('granted') : askPermission();
      asked.then(async (result) => {
        await app.setPrefs({ paymentNotifications: result === 'granted' });
        if (result === 'granted') toast(T.turnedOn, 3500);
        else if (result === 'denied') explain(T.denied, 'notify-denied');
        else toast(T.notAsked, 4000);
        render();
      });
    });
    put(
      box,
      h(
        'label',
        { class: 'row', 'data-testid': 'notify-row' },
        h('span', { class: 'ico' }, icon('receive')),
        h('span', { class: 'main' }, h('div', { class: 't', text: T.rowTitle }), h('div', { class: 's wrap', 'data-testid': 'notify-sub', text: rowSubtitle({ on, permission, ios, standalone: isStandalone() }) })),
        sw,
      ),
    );
  }
  render();
  return box;
}

/** The line under Settings' Payments group: said plainly before anyone turns it on. */
export const notificationsNote = () => h('p', { class: 'small settings-note', 'data-testid': 'notify-note', text: T.onlyWhileOpen });
