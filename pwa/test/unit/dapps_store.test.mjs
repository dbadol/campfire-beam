// BEAM's DApp Store read from the chain (lib/dapps/store.js), on the store's real answer
// (test/fixtures/dapps_store_views.json: view_publishers and view_dapps on mainnet, 2026-10-11).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as S from '../../src/lib/dapps/store.js';

const fx = JSON.parse(readFileSync(new URL('../fixtures/dapps_store_views.json', import.meta.url), 'utf8'));
const store = S.buildStore(fx.view_publishers, fx.view_dapps, { now: 1 });

test('the real store: every publisher and dApp read, ids, keys and IPFS hashes well formed', () => {
  assert.equal(store.publishers.size, 33);
  assert.equal(store.dapps.length, 21);
  for (const d of store.dapps) {
    assert.match(d.id, /^[0-9a-f]{32}$/);
    assert.match(d.publisher, /^[0-9a-f]{66}$/);
    assert.match(d.cid, /^Qm[1-9A-HJ-NP-Za-km-z]{44}$/);
    assert.ok(store.publishers.get(d.publisher).dapps.includes(d));
  }
  assert.equal(S.listedPublishers(store).length, 12, 'the Desktop Wallet lists publishers with dApps');
  const community = [...store.publishers.values()].find((p) => p.name === 'Beam Community');
  assert.deepEqual(community.dapps.map((d) => d.name).sort(), ['BEAM All-in-One', 'BEAM Explorer', 'BeamScreener']);
  assert.ok(store.dapps.every((d, i, a) => i === 0 || a[i - 1].timestamp >= d.timestamp), 'newest first');
});

test('every text is one clean line: no line breaks, direction marks or invisible characters', () => {
  const all = [...store.publishers.values()].flatMap((p) => [p.name, p.title]).concat(store.dapps.map((d) => d.name));
  for (const t of all) assert.doesNotMatch(t, /[\u0000-\u001f​-‏‪-‮⁦-⁩﻿]/, JSON.stringify(t));
  assert.equal(S.cleanText('Beam\nDev‮ lol​'), 'Beam Dev lol');
  assert.equal(S.cleanText('a'.repeat(40), 30), `${'a'.repeat(29)}…`);
  assert.equal(S.cleanText('one\r\ntwo\n\n\n\nthree', 100, { paragraphs: true }), 'one\ntwo\n\nthree');
  assert.equal(S.fromHex(S.toHex('Beam ✓ ü')), 'Beam ✓ ü');
  assert.equal(S.fromHex('zz'), '');
});

test('icons: an SVG or base64 image is kept; anything else (a PNG pasted as SVG text) is not', () => {
  const kept = store.dapps.filter((d) => d.icon).length;
  assert.ok(kept >= 1 && kept < 21, `${kept} of 21 have a usable icon`);
  assert.equal(store.dapps.find((d) => d.name === 'Test N1').icon, null, 'PNG bytes behind an SVG label');
  assert.match(S.iconUrl('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>'), /^data:image\/svg\+xml;charset=utf-8,%3Csvg/);
  assert.equal(S.iconUrl('data:image/svg+xml;utf8,<html><script>x</script></html>'), null);
  assert.equal(S.iconUrl('javascript:alert(1)'), null);
  assert.equal(S.iconUrl('https://tracker.example/pixel.png'), null, 'never a remote image: it would see the IP address');
  assert.match(S.iconUrl('data:image/png;base64,iVBORw0KGgo='), /^data:image\/png;base64,/);
});

test('links: https websites only; social names as profile links where the network has one', () => {
  assert.equal(S.websiteUrl('beam.mw'), 'https://beam.mw/');
  assert.equal(S.websiteUrl('http://beam.mw'), null);
  assert.equal(S.websiteUrl('javascript:alert(1)'), null);
  assert.equal(S.websiteUrl('https://user:pw@beam.mw'), null);
  const s = S.socialLinks({ twitter: '@vsnation_', telegram: 'beamprivacy', discord: 'beam#1234', linkedin: 'not a handle!' });
  assert.deepEqual(s.map((x) => [x.kind, x.url]), [['twitter', 'https://x.com/vsnation_'], ['telegram', 'https://t.me/beamprivacy'], ['linkedin', null], ['discord', null]]);
});

test('versions and API: shown as people read them, compared as numbers, served or not', () => {
  assert.equal(S.versionText({ major: 1, minor: 4, release: 2, build: 0 }), '1.4.2');
  assert.equal(S.versionText({ major: 3, minor: 3, release: 12, build: 7 }), '3.3.12.7');
  assert.equal(S.compareVersions([1, 3, 1, 0], [1, 3, 0, 9]), 1);
  assert.deepEqual(S.parseVersionText('1.4.2'), [1, 4, 2, 0]);
  assert.equal(S.parseVersionText('1.x'), null);
  const t = store.dapps.find((d) => d.name === 'Test N1' && d.apiVersion === '6.3');
  assert.ok(t);
  assert.equal(t.servedApi, '6.0', 'it asks for 6.3, which this wallet does not serve, and accepts 6.0, which it does');
});

test('look-alikes: a bundled dApp\'s name or id, and names two publishers share', () => {
  // The real store: "Test N1" is listed by two publishers.
  const shared = store.dapps.filter((d) => (store.flags.dapp.get(d.id) || []).some((f) => f.code === 'sharedName'));
  assert.ok(shared.some((d) => d.name === 'Test N1'));
  // Crafted entries.
  const pk = (c) => c.repeat(66).slice(0, 66);
  const row = (id, name, publisher) => ({ id, name: S.toHex(name), publisher, ipfs_id: 'QmY2xgq85jf6AywaKXTxowiH5GJbN3bHgoGuUtmcEKoC2z', version: { major: 1, minor: 0, release: 0, build: 0 }, category: 2, timestamp: 1, description: '', api_version: S.toHex('7.0'), min_api_version: S.toHex('7.0'), icon: '' });
  const fake = S.buildStore(
    { publishers: [{ pubkey: pk('a'), name: S.toHex('Beam') }, { pubkey: pk('b'), name: S.toHex('8eam') }] },
    { dapps: [row('11'.repeat(16), '8eam DEX', pk('a')), row('db851322f6674a6da3e84e9953db2ffd', 'Something', pk('b'))] },
  );
  const f1 = fake.flags.dapp.get('11'.repeat(16)).map((f) => f.code);
  assert.deepEqual(f1, ['bundledName']);
  assert.match(S.flagText(fake.flags.dapp.get('11'.repeat(16))[0]), /reads like Beam DEX/);
  assert.deepEqual(fake.flags.dapp.get('db851322f6674a6da3e84e9953db2ffd').map((f) => f.code), ['bundledId']);
  assert.deepEqual(fake.flags.publisher.get(pk('a')).map((f) => f.code), ['publisherName'], 'Beam and 8eam read the same');
});

test('what is shown: hidden publishers out, a category, a search over names, descriptions and publishers', () => {
  const community = [...store.publishers.values()].find((p) => p.name === 'Beam Community');
  assert.equal(S.visibleDapps(store).length, 21);
  assert.equal(S.visibleDapps(store, { hidden: new Set([community.key]) }).length, 18);
  assert.ok(S.visibleDapps(store, { category: 2 }).every((d) => d.category === 2));
  assert.deepEqual(S.visibleDapps(store, { query: 'beam community' }).map((d) => d.publisher), [community.key, community.key, community.key]);
  assert.ok(S.visibleDapps(store, { query: 'NEPHRITE' }).length >= 2);
  assert.equal(S.categoryName(0), 'Other');
  assert.equal(S.categoryName(3), 'Games');
});

test('read through two view calls with the store id', async () => {
  const calls = [];
  const s = await S.readStore(async (args) => (calls.push(args), args.includes('view_publishers') ? fx.view_publishers : fx.view_dapps));
  assert.deepEqual(calls, [`action=view_publishers,cid=${S.STORE_CID}`, `action=view_dapps,cid=${S.STORE_CID}`]);
  assert.equal(s.dapps.length, 21);
});
