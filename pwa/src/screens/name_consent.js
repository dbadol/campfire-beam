// What the approve sheet says for BEAM names' own requests (screens/consent.js asks):
// transfer, sell, stop selling, buy and claim. Register, renew and pay stay in
// consent.js. Only the wallet's own app may carry an intent (lib/contracts.js),
// and every name in one is a canonical name read from the chain (a-z 0-9 - _ ~).
// The amounts always come from the engine's report (req), never from the intent.
import { h } from '../lib/dom.js';
import { notice } from '../lib/ui.js';
import { formatAmount } from '../lib/amount.js';

const NAME_ACTIONS = new Set(['nameTransfer', 'nameSell', 'nameUnlist', 'nameBuy', 'nameClaim']);

export const isNameIntent = (intent) => Boolean(intent && NAME_ACTIONS.has(intent.action));

/** The sheet's title. */
export function nameTitle(intent) {
  switch (intent && intent.action) {
    case 'nameTransfer':
      return 'Confirm the transfer';
    case 'nameSell':
      return 'Confirm the listing';
    case 'nameUnlist':
      return 'Stop selling';
    case 'nameBuy':
      return 'Confirm your purchase';
    case 'nameClaim':
      return typeof intent.headline === 'string' && intent.headline ? intent.headline : 'Confirm your claim';
    default:
      return null;
  }
}

/** The approve button: the outcome. pay/get are "500 BEAM" strings from the engine's report. */
export function nameLabel(intent, pay, get) {
  const one = (l) => (l.length === 1 ? l[0] : null);
  switch (intent && intent.action) {
    case 'nameTransfer':
      return !pay.length && !get.length ? `Transfer ${intent.name}` : null;
    case 'nameSell':
      return !pay.length && !get.length ? `List ${intent.name} for sale` : null;
    case 'nameUnlist':
      return !pay.length && !get.length ? `Stop selling ${intent.name}` : null;
    case 'nameBuy':
      return one(pay) && !get.length ? `Pay ${pay[0]} and buy ${intent.name}` : null;
    case 'nameClaim':
      if (pay.length || !get.length) return null;
      return one(get) ? `Claim ${get[0]}` : 'Claim all';
    default:
      return null;
  }
}

const kv = (k, v, testid, cls = '') => h('div', { class: `kv ${cls}`.trim() }, h('span', { class: 'k', text: k }), h('span', { class: 'v', 'data-testid': testid, text: v }));

/** Rows inside the sheet's card, after what moves. unit(assetId) names an asset. */
export function nameRows(req, unit) {
  const i = req.intent;
  if (!isNameIntent(i)) return [];
  const name = typeof i.name === 'string' ? `${i.name}.beam` : null;
  switch (i.action) {
    case 'nameTransfer':
      return [kv('Name', name, 'consent-name'), h('div', { class: 'kv kv-stack' }, h('span', { class: 'k', text: 'New owner' }), h('span', { class: 'v mono check-code', 'data-testid': 'consent-new-owner', text: String(i.checkCode || '') }))];
    case 'nameSell':
      return [kv('Name', name, 'consent-name'), kv('Price', `${formatAmount(BigInt(i.amount))} ${unit(Number(i.assetId))}`, 'consent-price')];
    case 'nameUnlist':
      return [kv('Name', name, 'consent-name'), kv('Price', 'Not for sale', 'consent-price')];
    case 'nameBuy':
      return [kv('Name', name, 'consent-name'), i.untilText ? kv('Yours until', String(i.untilText), 'consent-until') : null];
    case 'nameClaim': {
      // What the balance gains once confirmed: what arrives, the fee taken from BEAM.
      const beamIn = req.receives.filter((a) => a.assetId === 0).reduce((s, a) => s + a.amount, 0n);
      const net = beamIn - req.fee;
      const parts = [];
      if (net > 0n) parts.push(`+${formatAmount(net)} BEAM`);
      for (const a of req.receives) if (a.assetId !== 0) parts.push(`+${formatAmount(a.amount)} ${unit(a.assetId)}`);
      if (net < 0n) parts.push(`−${formatAmount(-net)} BEAM`);
      return [typeof i.from === 'string' && i.from ? kv('Sent to', i.from, 'consent-from') : null, kv('Your balance changes by', parts.join(', ') || '0 BEAM', 'consent-change')];
    }
    default:
      return [];
  }
}

/** Notes under the card: what this does that the numbers do not say. */
export function nameNotes(req) {
  const i = req.intent;
  if (!isNameIntent(i)) return [];
  const p = (text, testid) => h('p', { class: 'small', 'data-testid': testid, text });
  switch (i.action) {
    case 'nameTransfer':
      return [
        p(`Read these 16 characters to the receiving wallet's owner: their Receive a name screen shows the same ones. If even one differs, cancel.`, 'consent-check-hint'),
        h('div', { 'data-testid': 'consent-final' }, notice('warn', h('strong', { text: "This can't be undone. " }), `Only the new owner can give ${i.name} back. Its time left goes with it.`)),
      ];
    case 'nameSell':
      return [p(`Anyone can buy ${i.name} at this price at any moment, without asking you. The payment waits for you under BEAM names, where you claim it.`, 'consent-sell-note')];
    case 'nameUnlist':
      return [p(`Nobody can buy ${i.name} after this.`, 'consent-unlist-note')];
    case 'nameBuy':
      return [p('Buying does not renew the name: you get the time left on it. Renew it under BEAM names to keep it longer.', 'consent-buy-note')];
    case 'nameClaim':
      return (Array.isArray(i.notes) ? i.notes : []).filter((t) => typeof t === 'string' && t).map((t, n) => p(t, `consent-claim-note-${n}`));
    default:
      return [];
  }
}
