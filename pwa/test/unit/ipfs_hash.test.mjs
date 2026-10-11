// The IPFS hash of a file worked out on the device (lib/dapps/ipfs_hash.js), against kubo 0.39's
// `ipfs add --only-hash --cid-version=0` and a real DApp Store package.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ipfsHashV0, matchesCid } from '../../src/lib/dapps/ipfs_hash.js';

// Deterministic bytes, exactly as the kubo vectors were made (plain JavaScript numbers, which round
// past 2^53: the same in every engine).
function gen(n, seed) {
  const b = new Uint8Array(n);
  let x = seed;
  for (let i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) >>> 0;
    b[i] = x >>> 24;
  }
  return b;
}

test("the same hash as kubo: empty, a few bytes, one chunk, three chunks, and a tree two levels deep", async () => {
  assert.equal(await ipfsHashV0(new Uint8Array(0)), 'QmbFMke1KXqnYyBBWxB74N4c5SBnJMVAiMNRcGu6x1AwQH');
  assert.equal(await ipfsHashV0(new TextEncoder().encode('BEAM Campfire')), 'QmV1qWoKV6NCQQPpXBJp4a1ePs6iGa2EfsWa6etN1zfof3');
  assert.equal(await ipfsHashV0(gen(262144, 1)), 'QmSCcKpgYJWa8Fge68NxZcHRsJYpCXokbAET597DKP94ps');
  assert.equal(await ipfsHashV0(gen(700000, 2)), 'QmRmpLHeSoh9ei6NtuLcJ9iFpYengxaqsEkFsDm5sd2wAP');
  assert.equal(await ipfsHashV0(gen(262144 * 176 + 5, 3)), 'QmSii5o6pv8tfSFBiTqy6QDqD3nDFM5ZhCZuXT1nkwiNL4', '177 chunks: more than one node can link');
});

test('a real store package matches its on-chain hash; one changed byte does not', async () => {
  const bytes = new Uint8Array(readFileSync(new URL('../fixtures/store-test-n1.dapp', import.meta.url)));
  const cid = 'QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z'; // "Test N1" by ABRAKADABRA, on mainnet
  assert.equal(await matchesCid(bytes, cid), true);
  const changed = bytes.slice();
  changed[100] ^= 1;
  assert.equal(await matchesCid(changed, cid), false);
  assert.equal(await matchesCid(bytes, 'not a cid'), false);
  assert.equal(await matchesCid(bytes, 'bafybeifx7yeb55armcsxwwitkymga5xf53dxiarykms3ygqic223w5sk3m'), false, 'CIDv1: the store holds only v0');
});
