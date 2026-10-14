#!/usr/bin/env node
// Writes test/beam/buy/deposit_address_vectors.json: what the web wallet's
// audited check (pwa/src/lib/buy/deposit_address.js, audit D-10) answers for
// a few thousand candidate deposit addresses on every chain it knows, so the
// app's Dart port (lib/wallets/beam/buy/buybeam_deposit_address.dart) is held
// to exactly the same answers.
//
//   node scripts/beam/buy/deposit_address_vectors.mjs
//
// Candidates: real, well-known addresses; addresses built here with each
// chain's version bytes and checksum (as the web's own test builds them);
// each of those with one character changed, one dropped, one added, its case
// flipped, wrapped in a payment link; and the made-up wrong answers the web's
// client test refuses. Deterministic (a seeded generator), so a re-run
// changes the file only when the web's check changes.

import { writeFileSync } from 'node:fs';
import { bech32, bech32m, base58, base58xrp, createBase58check } from '../../../pwa/src/vendor/noble/scure-base/index.js';
import { sha256 } from '../../../pwa/src/vendor/noble/noble-hashes/sha2.js';
import { isDepositAddressOf, EVM_CHAINS } from '../../../pwa/src/lib/buy/deposit_address.js';

const CHAINS = [
  'btc', 'bitcoin', 'ltc', 'doge', 'dash', 'bch', 'zec', 'tron', 'sol', 'fogo', 'xrp', 'ton', 'stellar',
  'cardano', 'sui', 'aptos', 'movement', 'starknet', 'near', 'aleo', 'hypercore', ...EVM_CHAINS, 'kaia',
];

// A small seeded generator (mulberry32): the same file on every run.
let seed = 0x5eed1234;
const rand = () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (s) => s[Math.floor(rand() * s.length)];
const bytes = (n, from = 0x31) => Uint8Array.from({ length: n }, (_, i) => (from + i * 7) & 0xff);
const randomBytes = (n) => Uint8Array.from({ length: n }, () => Math.floor(rand() * 256));

const b58c = createBase58check(sha256);
const b58 = (prefix, n = 20, body = bytes(n)) => b58c.encode(Uint8Array.from([...prefix, ...body]));
const segwit = (hrp, v, n, body = bytes(n)) => {
  const coder = v === 0 ? bech32 : bech32m;
  return coder.encode(hrp, [v, ...coder.toWords(body)], 200);
};
const xrpOf = (body = bytes(20)) => {
  const payload = Uint8Array.from([0, ...body]);
  return base58xrp.encode(Uint8Array.from([...payload, ...sha256(sha256(payload)).subarray(0, 4)]));
};

const base = new Set([
  // Real, well-known addresses.
  '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
  '3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy',
  'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
  'BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4',
  'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0',
  'bc1q6rga95756htd0kxemtdaehw7mlswrchr6zzx2s',
  'ltc1q6rga95756htd0kxemtdaehw7mlswrchry7jd4h',
  'tb1q6rga95756htd0kxemtdaehw7mlswrchrv3jq65',
  'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a',
  'qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a',
  'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
  'So11111111111111111111111111111111111111112',
  'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh',
  '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
  '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
  '0x52908400098527886E0F7030069857D2E4169EE7',
  '0xdac17f958d2ee523a2206206994597c13d831ec7',
  '0xDAC17F958D2EE523A2206206994597C13D831EC7',
  '0x1111111111111111111111111111111111111111',
  'EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N',
  `0:${'ab'.repeat(32)}`,
  `-1:${'cd'.repeat(32)}`,
  `G${'A'.repeat(55)}`,
  `0x${'5f'.repeat(32)}`,
  '0x1',
  `${'a1'.repeat(32)}`,
  'campfire.near',
  'sub.campfire-beam.near',
  'a',
  `Ae2${'1'.repeat(50)}`,
  `DdzFF${'z'.repeat(60)}`,
  // Built with each chain's version bytes and checksum.
  b58([0x00]), b58([0x05]), b58([0x30]), b58([0x32]), b58([0x1e]), b58([0x16]), b58([0x4c]), b58([0x10]),
  b58([0x41]), b58([0x1c, 0xb8]), b58([0x1c, 0xbd]), b58([0x1c, 0xb8], 19), b58([0x00], 21), b58([0x00], 19),
  segwit('bc', 0, 20), segwit('bc', 0, 32), segwit('bc', 0, 25), segwit('bc', 1, 32), segwit('bc', 16, 2),
  segwit('bc', 16, 40), segwit('bc', 2, 41), segwit('bc', 1, 1), segwit('ltc', 0, 20), segwit('ltc', 1, 32),
  segwit('tb', 0, 20), segwit('bcrt', 0, 20),
  // Version 0 in bech32m, version 1 in bech32: both wrong.
  bech32m.encode('bc', [0, ...bech32m.toWords(bytes(20))]),
  bech32.encode('bc', [1, ...bech32.toWords(bytes(32))]),
  bech32m.encode('tex', bech32m.toWords(bytes(20))),
  bech32.encode('tex', bech32.toWords(bytes(20))),
  bech32.encode('zs', bech32.toWords(bytes(43)), 200),
  bech32m.encode('u', bech32m.toWords(bytes(60)), 200),
  bech32.encode('addr', bech32.toWords(bytes(57)), 200),
  bech32m.encode('aleo', bech32m.toWords(bytes(32)), 200),
  base58.encode(bytes(32)), base58.encode(bytes(31)), base58.encode(bytes(33)),
  xrpOf(), base58xrp.encode(Uint8Array.from([0, ...bytes(24)])),
  // Made-up wrong answers.
  'bc1qfake0deposit0address0000000000000000000',
  'pay to this address',
  ' bc1q6rga95756htd0kxemtdaehw7mlswrchr6zzx2s ',
  `bc1q${'q'.repeat(200)}`,
  `0x${'1'.repeat(200)}`,
  'short',
  '',
  'an address with spaces in it',
  `abc‮def${'1'.repeat(20)}`,
  'sbx_1_fake',
]);
// Random ones of each kind, with random bodies.
for (let i = 0; i < 12; i++) {
  base.add(b58([pick([0x00, 0x05, 0x30, 0x32, 0x1e, 0x16, 0x4c, 0x10, 0x41])], 20, randomBytes(20)));
  base.add(b58([0x1c, pick([0xb8, 0xbd])], 20, randomBytes(20)));
  base.add(segwit(pick(['bc', 'ltc', 'tb']), pick([0, 0, 1, 2, 16]), pick([20, 32, 2, 40]), undefined));
  base.add(segwit(pick(['bc', 'ltc']), 0, pick([20, 32]), randomBytes(32).subarray(0, pick([20, 32]))));
  base.add(base58.encode(randomBytes(32)));
  base.add(xrpOf(randomBytes(20)));
  base.add(`0x${Array.from(randomBytes(20), (x) => x.toString(16).padStart(2, '0')).join('')}`);
}

/** One character of [a] changed to another of its kind (digit, letter, the same case). */
function substitute(a) {
  const i = Math.floor(rand() * a.length);
  const c = a[i];
  const pool = /[0-9]/.test(c) ? '0123456789' : /[a-z]/.test(c) ? 'abcdefghijklmnopqrstuvwxyz' : /[A-Z]/.test(c) ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' : '-_:.';
  let r = c;
  while (r === c) r = pick(pool);
  return a.slice(0, i) + r + a.slice(i + 1);
}

const candidates = new Set(base);
for (const a of base) {
  if (a.length < 2) continue;
  for (let k = 0; k < 6; k++) candidates.add(substitute(a));
  const i = Math.floor(rand() * a.length);
  candidates.add(a.slice(0, i) + a.slice(i + 1));
  candidates.add(a.slice(0, i) + pick('qpzry9x8gf2tvdw0') + a.slice(i));
  candidates.add(a.toUpperCase());
  candidates.add(a.toLowerCase());
  // One letter's case flipped.
  const letters = [...a].map((c, j) => (/[a-zA-Z]/.test(c) ? j : -1)).filter((j) => j >= 0);
  if (letters.length) {
    const j = pick(letters);
    const c = a[j];
    candidates.add(a.slice(0, j) + (c === c.toLowerCase() ? c.toUpperCase() : c.toLowerCase()) + a.slice(j + 1));
  }
  candidates.add(`bitcoin:${a}`);
  candidates.add(`${a}?amount=1`);
  candidates.add(`BITCOINCASH:${a}`);
}

const cases = [...candidates].sort().map((a) => ({ a, ok: CHAINS.filter((c) => isDepositAddressOf(a, c)) }));
const out = new URL('../../../test/beam/buy/deposit_address_vectors.json', import.meta.url);
writeFileSync(
  out,
  `${JSON.stringify(
    {
      about: 'What pwa/src/lib/buy/deposit_address.js answers (audit D-10). Generated by scripts/beam/buy/deposit_address_vectors.mjs; do not edit.',
      chains: CHAINS,
      cases,
    },
    null,
    0,
  )
    .replace(/\{"a":/g, '\n{"a":')
    // Every character outside ASCII as \uXXXX: a direction mark in a candidate stays visible.
    .replace(/[^\x20-\x7e\n]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`)}\n`,
);
console.log(`${cases.length} cases, ${cases.filter((c) => c.ok.length).length} valid somewhere`);
