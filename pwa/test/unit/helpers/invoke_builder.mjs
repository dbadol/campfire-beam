// Hand-built raw_data for tests: what a malicious dApp can send to
// process_invoke_data without running any shader (as the desktop's
// dapp_invoke_builder.dart). yas, little-endian, compacted integers.
export const FLAG_DEPENDENT = 0x02;
export const FLAG_SAVE_APP_INVOKE = 0x20;
export const FLAG_SAVE_SPEND_MAX = 0x40;

export function yu(v) {
  v = BigInt(v);
  if (v < 128n) return [0x80 | Number(v)];
  const b = [];
  for (let x = v; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
  return [b.length, ...b];
}
export function ys(v) {
  v = BigInt(v);
  const a = v < 0n ? -v : v;
  const sign = v < 0n ? 0x80 : 0;
  if (a < 64n) return [sign | 0x40 | Number(a)];
  const b = [];
  for (let x = a; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
  return [sign | b.length, ...b];
}
const yBuf = (bytes) => [...yu(bytes.length), ...bytes];
const yStr = (s) => yBuf([...new TextEncoder().encode(s)]);
export const hexBytes = (hex) => hex.match(/../g).map((x) => parseInt(x, 16));
export const cid = (fill) => fill.toString(16).padStart(2, '0').repeat(32);

export const FLAG_ADVANCED = 0x01;
export const FLAG_HAS_COMMITMENT = 0x10;

/** adv: an advanced entry's own part (flags must carry FLAG_ADVANCED): { minHeight, dh, fee }. */
export function invokeEntry({ contractId, method = 2, flags = 0, spend = {}, sigs = [], comment = '', charge = 0, args = [1, 2, 3, 4], parentHeight = 4068100, adv = { minHeight: 4075100, dh: 15, fee: 1100000 } }) {
  return [
    ...(flags ? [...yu(0x80000000 + flags), ...yu(method)] : yu(method)),
    ...yBuf(args),
    ...yu(sigs.length),
    ...sigs.flatMap(hexBytes),
    ...yu(charge),
    ...yStr(comment),
    ...yu(Object.keys(spend).length),
    ...Object.entries(spend).flatMap(([k, v]) => [...yu(k), ...ys(v)]),
    ...(contractId == null ? yBuf([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]) : hexBytes(contractId)),
    // Advanced: HeightRange (min, max - min), fee, signature (33 + 32), key preimage hash (32).
    ...(flags & FLAG_ADVANCED ? [...yu(adv.minHeight), ...yu(adv.dh), ...yu(adv.fee), ...new Array(65).fill(1), ...new Array(32).fill(2)] : []),
    ...(flags & FLAG_DEPENDENT ? [...yu(parentHeight), ...new Array(32).fill(0x5c)] : []),
    ...(flags & FLAG_HAS_COMMITMENT ? new Array(33).fill(3) : []),
  ];
}

// appArgs: an object, or an array of [key, value] pairs (a dApp can repeat a key; an object cannot).
export function invokeData(entries, { firstFlags = 0, appShader = [0, 0x61, 0x73, 0x6d], appArgs = { action: 'steal' }, privilege = 0, spendMax = { 0: 100000000000 } } = {}) {
  const pairs = Array.isArray(appArgs) ? appArgs : Object.entries(appArgs);
  return [
    ...yu(entries.length),
    ...entries.flat(),
    ...(firstFlags & FLAG_SAVE_APP_INVOKE ? [...yBuf(appShader), ...yBuf([]), ...yu(pairs.length), ...pairs.flatMap(([k, v]) => [...yStr(k), ...yStr(v)]), ...yu(privilege)] : []),
    ...(firstFlags & FLAG_SAVE_SPEND_MAX ? [...yu(Object.keys(spendMax).length), ...Object.entries(spendMax).flatMap(([k, v]) => [...yu(k), ...ys(v)])] : []),
  ];
}
