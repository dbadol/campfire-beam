// Amounts. The engine speaks smallest units (groth: 1 BEAM = 100,000,000 groth).
// BEAM has 8 decimals; a Confidential Asset has the ones its metadata's NTH_RATIO
// gives (lib/meta.js decimalsFromMetadata), 8 when it sets none. Everything here is
// BigInt, so there are no float errors anywhere between what the user types and
// what tx_send receives.
import { t, tn } from './i18n.js';

/** BEAM's decimals, and every token's that sets none of its own. */
export const DECIMALS = 8;
export const GROTH_PER_COIN = 100000000n;
export const REGULAR_FEE = 100000n; // 0.001 BEAM
export const OFFLINE_FEE = 1100000n; // 0.011 BEAM (offline, max-privacy, public-offline)
// tx_send takes a JSON number, so an amount must stay exactly representable.
export const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);

export class AmountError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * A typed number with "," or "." as its decimal mark: "0,5" is 0.5, as people write it in much of
 * the world (user feedback, 2026-10-27). Returns {text} with a dot, or {error} in plain words: two
 * marks, or "1,000", which is a thousand in some places and one in others, so it is never guessed
 * (Firo PWA public audit, PN: a thousand read as one).
 */
export function oneDecimalMark(s) {
  if ((s.match(/[.,]/g) || []).length > 1) return { text: null, error: t('Use one decimal mark, like 1.25') };
  if (/^[1-9]\d*,\d{3}$/.test(s)) return { text: null, error: t('Is that {a} or {b}? Write it without the comma, or with a dot for decimals.', { a: s.replace(',', ''), b: s.replace(',', '.') }) };
  return { text: s.replace(',', '.'), error: null };
}

/** "CANDY #31 has 1 decimal place at most." for a token with `decimals` places, called `unit`. */
export function precisionError(decimals, unit) {
  if (unit === 'BEAM' && decimals === DECIMALS) return t('BEAM has 8 decimal places at most.');
  if (decimals === 0) return t('{symbol} has no decimal places.', { symbol: unit });
  return tn({ one: '{symbol} has {n} decimal place at most.', other: '{symbol} has {n} decimal places at most.' }, decimals, { symbol: unit });
}

/** For a token whose metadata (and so its decimals) has not arrived yet. */
export const unknownDecimals = (unit) => t('The wallet is still reading {symbol} from the network. Try again in a moment.', { symbol: unit });

/**
 * Parses what a person typed into smallest units of a token with `decimals`
 * places (BEAM's 8 by default), called `unit` in the messages.
 * Accepts "1", "1.5", "1,5" (comma as the decimal mark), ".5", spaces
 * (including thin and no-break spaces) as group separators.
 * Rejects: empty, negative, letters, two decimal marks, more decimals than the
 * token has, and any amount while its decimals are not known yet (null): read
 * as 8, "1" of a whole-number token would be 100,000,000 of it.
 */
export function parseAmount(input, { decimals = DECIMALS, unit = 'BEAM' } = {}) {
  if (decimals == null) throw new AmountError('unknown', unknownDecimals(unit));
  if (typeof input !== 'string') throw new AmountError('empty', t('Enter an amount.'));
  let s = input.replace(/[\s   ]/g, '');
  if (s === '') throw new AmountError('empty', t('Enter an amount.'));
  if (s.startsWith('-')) throw new AmountError('negative', t('The amount must be more than zero.'));
  const mark = oneDecimalMark(s);
  if (mark.error) throw new AmountError(/,\d{3}$/.test(s) && !s.includes('.') ? 'ambiguous' : 'format', mark.error);
  s = mark.text;
  if (!/^\d*\.?\d*$/.test(s) || !/\d/.test(s)) throw new AmountError('format', t('Only digits and one decimal mark, like 1.25'));
  const [whole, frac = ''] = s.split('.');
  if (frac.length > decimals) throw new AmountError('precision', precisionError(decimals, unit));
  const groth = BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
  if (groth > MAX_SAFE) throw new AmountError('too_large', t('That amount is too large.'));
  return groth;
}

/**
 * Smallest units of a token with `decimals` places (BEAM's 8 by default; null, not
 * known yet, shows as 8) → "1,234.5" (trailing zeros dropped, grouped thousands).
 */
export function formatAmount(groth, { group = true, minDecimals = 0, maxDecimals = null, decimals = DECIMALS } = {}) {
  const places = decimals == null ? DECIMALS : decimals;
  const most = maxDecimals == null ? places : Math.min(maxDecimals, places);
  let g = BigInt(groth);
  const neg = g < 0n;
  if (neg) g = -g;
  const perCoin = 10n ** BigInt(places);
  let whole = (g / perCoin).toString();
  let frac = places ? (g % perCoin).toString().padStart(places, '0') : '';
  if (most < places) {
    // round half up to `most` places
    const unit = 10n ** BigInt(places - most);
    let rounded = (g + unit / 2n) / unit; // in units of 10^-most
    const base = 10n ** BigInt(most);
    whole = (rounded / base).toString();
    frac = most ? (rounded % base).toString().padStart(most, '0') : '';
  }
  frac = frac.replace(/0+$/, '');
  while (frac.length < Math.min(minDecimals, places)) frac += '0';
  if (group) whole = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return (neg ? '-' : '') + whole + (frac ? '.' + frac : '');
}

/**
 * Smallest units → the plain decimal string an input field can hold ("1234.5"). Nothing ("") while the
 * token's decimals are not known (null): written as 8, it would be read again with the real ones.
 */
export function toInputString(groth, decimals = DECIMALS) {
  if (decimals === null) return '';
  return formatAmount(groth, { group: false, decimals });
}

/** Parses an engine number or *_str field into BigInt groth. */
export function toGroth(v) {
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v) || v < 0) throw new AmountError('format', 'bad amount from wallet'); // i18n-ignore: an invariant on the engine's numbers, never expected
    return BigInt(v);
  }
  if (typeof v === 'string' && /^\d+$/.test(v)) return BigInt(v);
  throw new AmountError('format', 'bad amount from wallet'); // i18n-ignore: an invariant on the engine's numbers, never expected
}

/** The JSON number tx_send wants. */
export function toJsonNumber(groth) {
  if (groth < 0n || groth > MAX_SAFE) throw new AmountError('too_large', t('That amount is too large.'));
  return Number(groth);
}
