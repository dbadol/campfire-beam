// A transaction of this Ethereum wallet whose fate is in doubt, and the rule that follows from it
// (release audit BM-1): while one is, nothing new is signed from this account.
//
// "In doubt" is an open outbox entry (signed or pending) that lib/eth/send.js marked:
//   unsureSince  its server says its nonce is used up but cannot show by what ("Not sure yet");
//   refusedAt    its server refused its bytes, which it may have passed on first ("Not sent yet").
// Either may still be mined. A new transaction takes its nonce from the server's 'pending' count,
// one past the doubtful one when the server counts it: both could then be mined, and the person
// pays twice. So every way out of this account (a payment, a Uniswap swap or permission, a move to
// BEAM over the bridge) asks here first, before the key is opened, and is refused while one is in
// doubt. The ways out are said with it: wait until it is settled (the screens keep following it),
// or pick another Ethereum server in Settings, which then follows it there.

import { isOpen, loadOutbox } from './outbox.js';
import { formatUnits } from './units.js';
import { ETH, tokenBySymbol, tokenByAddress } from './tokens.js';

/** 'unsure' | 'refused' for an open entry in doubt, else null. */
export function doubtOf(entry) {
  if (!entry || !isOpen(entry)) return null;
  if (entry.unsureSince) return 'unsure';
  if (entry.refusedAt) return 'refused';
  return null;
}

/** The newest entry of `outbox` (newest first, as stored) whose fate is in doubt, or null. */
export function entryInDoubt(outbox) {
  return (Array.isArray(outbox) ? outbox : []).find((e) => doubtOf(e) !== null) || null;
}

/** What the status screens and the activity list call it. */
export const DOUBT_TITLE = Object.freeze({ unsure: 'Not sure yet', refused: 'Not sent yet' });

/** The way out, said wherever something is refused because of it. */
export const DOUBT_WAY_OUT = 'Wait until BEAM Campfire knows what happened to it, or choose another Ethereum server in Settings: it is checked there.';

const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function assetOf(entry) {
  if (!entry.token) return ETH;
  return tokenBySymbol(entry.asset) || tokenByAddress(String(entry.token).toLowerCase()) || { symbol: entry.asset, decimals: 18 };
}

/** 'payment' | 'swap' | 'permission'. */
export function doubtNoun(entry) {
  if (entry.kind === 'swap') return 'swap';
  if (entry.kind === 'approve' || entry.kind === 'approveReset') return 'permission';
  return 'payment';
}

/**
 * Its name in pieces, so a screen can set the address apart: {lead, address} with lead "your
 * payment of 0.01 ETH to" and address "0x7099…79C8"; "your swap of 0.01 ETH" and "your WBEAM
 * permission for Uniswap" have no address (null).
 */
export function doubtNameParts(entry) {
  const a = assetOf(entry);
  const amount = `${formatUnits(BigInt(entry.amount), a.decimals)} ${a.symbol}`;
  const noun = doubtNoun(entry);
  if (noun === 'swap') return { lead: `your swap of ${amount}`, address: null };
  if (noun === 'permission') return { lead: `your ${a.symbol} permission for Uniswap`, address: null };
  return { lead: `your payment of ${amount} to`, address: shortAddr(entry.to) };
}

/** "your payment of 0.01 ETH to 0x7099…79C8", "your swap of 0.01 ETH", "your WBEAM permission for Uniswap". */
export function doubtName(entry) {
  const { lead, address } = doubtNameParts(entry);
  return address ? `${lead} ${address}` : lead;
}

/** Why nothing new goes while it is in doubt, after its name. */
export const DOUBT_WHY = 'It may still go through, so nothing new is sent from this Ethereum wallet until it is settled, or both could go through.';

/** The whole refusal in words: what is in doubt, why nothing new goes, and the way out. */
export function doubtMessage(entry) {
  const name = doubtName(entry);
  return `${name.charAt(0).toUpperCase()}${name.slice(1)} is "${DOUBT_TITLE[doubtOf(entry)]}". ${DOUBT_WHY} ${DOUBT_WAY_OUT}`;
}

/** Thrown instead of signing while a transaction is in doubt; .entry is that transaction. */
export class EthInDoubtError extends Error {
  constructor(entry) {
    super(doubtMessage(entry));
    this.code = 'in_doubt';
    this.entry = entry;
  }
}

/**
 * Refuses (EthInDoubtError) while a transaction of this Ethereum wallet is in doubt, reading the
 * outbox as stored (not a screen's copy of it). Called before any key is opened.
 */
export async function assertNothingInDoubt(app, { ethId, kv } = {}) {
  const e = entryInDoubt(await loadOutbox(app, { ethId, kv }));
  if (e) throw new EthInDoubtError(e);
}
