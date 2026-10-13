// A BEAM node's newest block over its own protocol (lib/node_tip.js): the node screen's check.
// The known answer is a real exchange with a mainnet node (test/unit/fixtures/node_tip_mainnet.json,
// recorded with the check key fixed): the keys, the cipher, the tags and the header parse all have
// to match BEAM's C++ for it to come out as the explorer's height.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TipReader, checkTip, frame, nonceKey, channelKeys, keystream, tagOf, readCompact, parseTip, MSG, MAX_ENCRYPTED } from '../../src/lib/node_tip.js';

const fx = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'node_tip_mainnet.json'), 'utf8'));
const hex = (s) => Uint8Array.from(s.match(/../g), (b) => parseInt(b, 16));
const secret = hex(fx.secret);
const transcript = hex(fx.transcript);

test('known answer: a real mainnet node, decrypted with the recorded key, gives the explorer height', async () => {
  const r = new TipReader({ secret });
  const ours = r.start();
  assert.deepEqual([...ours.slice(0, 8)], [0x42, 0x6d, 10, MSG.SChannelInitiate, 32, 0, 0, 0], "our SChannelInitiate: 'B' 'm' 10, type 4, 32 bytes");
  assert.deepEqual(ours.slice(8), nonceKey(secret).pub);
  assert.deepEqual(await r.push(transcript), { height: fx.height, timestamp: fx.timestamp });
  assert.equal(fx.height, 4078390);
});

test('the same bytes in pieces of any size, down to one at a time', async () => {
  for (const size of [1, 7, 8, 9, 40, 48, 133]) {
    const r = new TipReader({ secret });
    let tip = null;
    for (let i = 0; i < transcript.length && !tip; i += size) tip = await r.push(transcript.slice(i, i + size));
    assert.deepEqual(tip, { height: fx.height, timestamp: fx.timestamp }, `pieces of ${size}`);
  }
});

test('one changed bit anywhere after the handshake fails the tag: nothing is believed', async () => {
  // 48 plaintext bytes (SChannelInitiate 40 + SChannelReady 8), then the encrypted messages.
  for (const at of [48 + 3, 48 + 20, 48 + 100, transcript.length - 30, transcript.length - 1]) {
    const bad = transcript.slice();
    bad[at] ^= 0x01;
    await assert.rejects(new TipReader({ secret }).push(bad), /bad tag|not a BEAM node|no tip|bad integer|short/, `bit at ${at}`);
  }
  // With another key the stream is noise.
  const other = new Uint8Array(32);
  other[31] = 8;
  await assert.rejects(new TipReader({ secret: other }).push(transcript));
});

test('something that is not a BEAM node is refused at once', async () => {
  await assert.rejects(new TipReader().push(new TextEncoder().encode('HTTP/1.1 400 Bad Request\r\n\r\n')), /not a BEAM node/);
  await assert.rejects(new TipReader().push(frame(MSG.Bye, Uint8Array.of(3))), /goodbye/);
  await assert.rejects(new TipReader().push(frame(0x10, new Uint8Array(200))), /unexpected/);
});

/** A node of our own: the other side of the same handshake, encrypting what we choose. */
async function fakeNode(ourInitiate, messages) {
  const ourPub = ourInitiate.slice(8);
  const node = nonceKey();
  const keys = channelKeys(node.sk, ourPub, ourPub); // the node's outgoing counter uses OUR PeerID
  let body = new Uint8Array(0);
  for (const [type, payload] of messages) {
    const m = frame(type, new Uint8Array(payload.length + 8));
    m.set(payload, 8);
    new DataView(m.buffer).setUint32(4, payload.length + 8, true);
    m.set(tagOf(keys.secret, m.slice(0, m.length - 8)), m.length - 8);
    body = Uint8Array.from([...body, ...m]);
  }
  const ks = await keystream(keys, body.length);
  return Uint8Array.from([...frame(MSG.SChannelInitiate, node.pub), ...frame(MSG.SChannelReady), ...body.map((b, i) => b ^ ks[i])]);
}

const tipBody = (heightBytes, tsBytes) => Uint8Array.from([...heightBytes, ...new Uint8Array(128), ...tsBytes, ...new Uint8Array(120)]);

test('both directions agree: a node built from the same rules is read, small and large numbers alike', async () => {
  const r = new TipReader();
  const bytes = await fakeNode(r.start(), [
    [0x0b, []], // GetTime
    [0x0f, [0x80, 0x81]], // a Login
    [MSG.NewTip, tipBody([0x03, 0x36, 0x3b, 0x3e], [0x04, 0x7e, 0xf0, 0xcd, 0x6a])],
  ]);
  assert.deepEqual(await r.push(bytes), { height: 0x3e3b36, timestamp: 0x6acdf07e });
  const r2 = new TipReader();
  assert.deepEqual(await r2.push(await fakeNode(r2.start(), [[MSG.NewTip, tipBody([0x80 | 5], [0x80 | 9])]])), { height: 5, timestamp: 9 });
});

test('a node that never gets to NewTip within the limit is not answering', async () => {
  const r = new TipReader();
  const filler = Array.from({ length: 5 }, () => [0x08, new Uint8Array(4000)]);
  await assert.rejects(r.push(await fakeNode(r.start(), filler)), /no tip/);
  assert.ok(MAX_ENCRYPTED >= 4096 && MAX_ENCRYPTED <= 65536);
});

test('compacted integers and the tip header', () => {
  assert.deepEqual(readCompact(Uint8Array.of(0x85), 0), { value: 5, next: 1 });
  assert.deepEqual(readCompact(Uint8Array.of(0x02, 0x34, 0x12), 0), { value: 0x1234, next: 3 });
  assert.throws(() => readCompact(Uint8Array.of(0x09, 1, 2, 3, 4, 5, 6, 7, 8, 9), 0), /bad integer/);
  assert.throws(() => readCompact(Uint8Array.of(0x03, 1), 0), /bad integer/);
  assert.ok(Number.isNaN(readCompact(Uint8Array.of(0x08, 255, 255, 255, 255, 255, 255, 255, 255), 0).value));
  assert.throws(() => parseTip(tipBody([0x80], [0x81])), /bad tip/, 'height 0 is not a tip');
  assert.throws(() => parseTip(new Uint8Array(10)), /bad integer|short/);
});

test('the key: x only, the secret negated when Y is odd (PeerID::FromSk), so the point has an even Y', async () => {
  const { secp256k1 } = await import('../../src/vendor/noble/noble-curves/secp256k1.js');
  for (let i = 1; i <= 12; i++) {
    const s = new Uint8Array(32);
    s[31] = i;
    const k = nonceKey(s);
    const full = secp256k1.getPublicKey(k.sk, true);
    assert.equal(full[0], 0x02, `secret ${i}: even Y after normalising`);
    assert.deepEqual(full.slice(1), k.pub);
  }
});

/** A WebSocket-shaped stand-in. */
function fakeSocket(script) {
  const ws = { sent: [], closed: 0, send: (b) => ws.sent.push(b), close: () => ws.closed++ };
  queueMicrotask(() => script(ws));
  return ws;
}

test('checkTip: answers, refusals, silence and garbage each end with the socket closed and a plain result', async () => {
  // Answers: the recorded node, with the recorded key.
  let sock;
  const ok = await checkTip(() => (sock = fakeSocket((ws) => { ws.onopen(); ws.onmessage({ data: transcript.slice().buffer }); })), { secret, timeoutMs: 5000 });
  assert.equal(ok.ok, true);
  assert.equal(ok.height, fx.height);
  assert.ok(ok.ms >= 1);
  assert.equal(sock.sent.length, 1, 'one message sent: our SChannelInitiate, nothing of the wallet');
  assert.equal(sock.sent[0].length, 40);
  assert.equal(sock.closed, 1);
  // Refused (an expired certificate looks like this to a page: an error, then a close).
  const refused = await checkTip(() => (sock = fakeSocket((ws) => { ws.onerror(); ws.onclose(); })));
  assert.deepEqual(refused, { ok: false, code: 'unreachable' });
  assert.equal(sock.closed, 1);
  // Opens, then says nothing.
  const t0 = Date.now();
  const silent = await checkTip(() => (sock = fakeSocket((ws) => ws.onopen())), { timeoutMs: 200 });
  assert.deepEqual(silent, { ok: false, code: 'timeout' });
  assert.ok(Date.now() - t0 < 2000);
  assert.equal(sock.closed, 1);
  // Text, or bytes that are not BEAM.
  assert.equal((await checkTip(() => fakeSocket((ws) => { ws.onopen(); ws.onmessage({ data: 'hello' }); }))).code, 'protocol');
  assert.equal((await checkTip(() => fakeSocket((ws) => { ws.onopen(); ws.onmessage({ data: new Uint8Array(16).buffer }); }))).code, 'protocol');
  // The socket cannot even be made (the guard refuses a host that is not one of BEAM's).
  assert.equal((await checkTip(() => { throw new DOMException('no', 'SecurityError'); })).code, 'refused');
});
