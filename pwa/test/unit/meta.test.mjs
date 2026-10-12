// Asset names, tickers and icons (lib/meta.js). The desktop app is the spec:
// asset_parity.test.mjs compares every mainnet asset with its own code's output;
// these are the rules spelt out one by one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMetadata, assetLabel, badgeText, display, cleanText, genericIcon, unverifiedIcon, frameInset, MISSING_ICON, VERIFIED, metadataOf, tokenSubtitle, copyWarning } from '../../src/lib/meta.js';
import { learnPool, lpPoolOf, resetLpTokens, SNAPSHOT, lpMetadata, contractAssetOwner, confirmLpToken, confirmLearnt, unconfirmedLpTokens, lpTrusted } from '../../src/lib/lp_tokens.js';
import { DEX_CID } from '../../src/lib/dex.js';

const meta = (fields) => `STD:SCH_VER=1;${fields}`;

test('metadata: the STD fields as the desktop reads them; a repeated key keeps its last value', () => {
  const m = parseMetadata('STD:SCH_VER=1;N=Fomo Token;SN=FOMO;UN=FOMO;NTHUN=GROTH;NTH_RATIO=100000000;OPT_COLOR=#FF00AA');
  assert.equal(m.get('N'), 'Fomo Token');
  assert.equal(m.get('UN'), 'FOMO');
  assert.equal(parseMetadata('STD:N=a=b;N=other;UN=X').get('N'), 'other');
  assert.equal(parseMetadata('STD:N=a=b;UN=X').get('N'), 'a=b', 'values may contain "="');
  assert.equal(parseMetadata('N=No prefix;UN=X').size, 0, 'no STD: prefix, no fields');
  assert.equal(parseMetadata(null).size, 0);
});

test('verified ids keep their checked names, colour and icon whatever their metadata says', () => {
  const l = assetLabel(174, meta('N=Something else;UN=SCAM'));
  assert.equal(l.name, 'FOMO');
  assert.equal(l.unit, 'FOMO');
  assert.equal(l.verified, true);
  assert.equal(l.icon, 'img/assets/174.png');
  assert.equal(assetLabel(0).icon, 'img/beam.svg');
  assert.deepEqual([190, 191].map((id) => [assetLabel(id).symbol, assetLabel(id).icon]), [['CHAD', 'img/assets/187.png'], ['GIGA', 'img/assets/186.png']]);
  // Verified without an icon of their own: the generic icon for the id.
  assert.equal(assetLabel(36).icon, 'img/assets/generic/asset-16.svg');
  assert.equal(assetLabel(6).icon, 'img/assets/generic/asset-6.svg');
});

test('an unverified asset: its cleaned on-chain name, its ticker with its number, a generic icon', () => {
  const l = display(773, meta('N=Moon Rocket;SN=MOON;UN=MOON;NTHUN=m'));
  assert.equal(l.verified, false);
  assert.equal(l.name, 'Moon Rocket');
  assert.equal(l.symbol, 'MOON');
  assert.equal(l.label, 'MOON #773');
  assert.equal(l.unit, 'MOON #773', 'money screens write the number too');
  assert.equal(l.icon, `img/assets/generic/asset-${773 % 20}.svg`);
  assert.equal(l.impersonates, null);
  // UN wins over SN, even when empty; SN when UN is absent; the number when neither gives text.
  assert.equal(display(5, meta('SN=Shorty')).symbol, 'Shorty');
  assert.equal(display(5, meta('UN=;SN=Shorty')).symbol, '#5');
  const none = display(557, null);
  assert.deepEqual([none.name, none.symbol, none.label], ['Asset #557', '#557', '#557']);
  assert.equal(display(13, 'garbage').name, 'Asset #13');
});

test('an unverified asset never wears its own colour, nor a verified asset\'s icon', () => {
  const l = display(250, meta('N=Fake;UN=FOMO;OPT_COLOR=#60a5fa'));
  assert.notEqual(l.color, '#60a5fa');
  assert.match(l.color, /^#[0-9a-f]{6}$/);
  // asset-6 is RFC's (#6), asset-16..19 the bridge assets' (#36..#39): never an unverified one's.
  const worn = new Set(['img/assets/generic/asset-6.svg', 'img/assets/generic/asset-16.svg', 'img/assets/generic/asset-17.svg', 'img/assets/generic/asset-18.svg', 'img/assets/generic/asset-19.svg']);
  for (let id = 1; id < 1000; id++) if (!VERIFIED[id]) assert.ok(!worn.has(unverifiedIcon(id)), `#${id}`);
  assert.equal(unverifiedIcon(26), 'img/assets/generic/asset-7.svg');
  assert.equal(unverifiedIcon(16), 'img/assets/generic/asset-0.svg');
  assert.equal(genericIcon(46), 'img/assets/generic/asset-6.svg');
  assert.equal(MISSING_ICON, 'img/assets/generic/asset-err.svg');
});

test('icons that are not a filled circle sit inset on a disc', () => {
  assert.equal(frameInset('img/assets/47.svg'), 0.17);
  assert.equal(frameInset('img/assets/186.png'), 0);
  assert.equal(frameInset('img/assets/174.png'), null);
});

test('names are text: invisible, direction and layout characters dropped, length capped, no borrowed #id', () => {
  assert.equal(display(555, meta('N=‮OMOF​;UN=‮OMOF')).name, 'OMOF');
  assert.equal(display(555, meta('N=A؜B C⁠D­E͏FㅤG\u{E0041}H⠀I️J;UN=X')).name, 'ABCDEFGHIJ');
  const long = display(556, meta(`N=${'A'.repeat(80)};UN=LONGTICKER1`));
  assert.equal(long.name.length, 32);
  assert.ok(long.name.endsWith('…'));
  assert.equal(long.symbol, 'LONGTIC…');
  assert.equal(cleanText('Z' + '́'.repeat(30) + 'a', 32), 'Ź́a', 'combining marks capped');
  assert.equal(cleanText('🚀'.repeat(40), 32), `${'🚀'.repeat(31)}…`, 'a cut never splits a character');
  assert.equal(cleanText('Moon    Rocket', 32), 'Moon Rocket');
  assert.equal(display(999, meta('N=Pepe #174;UN=PEPE')).name, 'Pepe');
  assert.equal(cleanText('   ', 32), null);
});

test('a copy of a verified asset is flagged, however it is spelt', () => {
  const copies = (fields) => display(999, meta(fields)).impersonates;
  assert.equal(copies('N=Fomo Token;UN=FOMO'), 174);
  assert.equal(copies('N=FОМО;UN=FОМО'), 174, 'Cyrillic');
  assert.equal(copies('N=ΒΕΑΜ;UN=X'), 0, 'Greek');
  assert.equal(copies('N=Pepe;UN=ＦＯＭＯ'), 174, 'fullwidth');
  assert.equal(copies('N=Pepe;UN=F0M0'), 174);
  assert.equal(copies('N=Pepe;UN=wFOMO'), 174);
  assert.equal(copies('N=Gothic Crwn;UN=X'), 4);
  assert.equal(copies('N=Pepe;UN=BEAMX2'), 7, 'the longest match wins');
  assert.equal(copies('N=Pepe #174;UN=PEPE'), 174, 'a borrowed number');
  assert.equal(copies('N=bUSDT;UN=bUSDT'), 37);
  for (const f of ['N=Beatcoin;UN=Beat', 'N=Bean;UN=BEAN', 'N=Amm Liquidity Token 0-174-2;UN=AMML', 'N=Tether;UN=USD Tether', 'N=Moon #12345;UN=MOON']) assert.equal(copies(f), null, f);
  const fake = display(173, meta('N=FOMO;UN=FOMO;SN=FOMO'));
  assert.equal(copyWarning(fake), 'Not the verified FOMO (#174). Anyone can create an asset with any name.');
  assert.equal(copyWarning(display(174, null)), null);
});

test('LP tokens: named after their pool from the DEX\'s list, never from their own metadata', () => {
  resetLpTokens();
  const lp = display(175, meta('N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;NTHUN=GROTH'));
  assert.deepEqual([lp.name, lp.symbol, lp.label, lp.verified], ['BEAM/FOMO LP', 'BEAM/FOMO LP', 'BEAM/FOMO LP', true]);
  assert.deepEqual({ ...lp.pool }, { lpToken: 175, aid1: 0, aid2: 174, kind: 2, confirmed: true });
  assert.equal(display(192, null).name, 'BEAM/CHAD LP');
  assert.equal(display(193, null).name, 'BEAM/GIGA LP');
  assert.equal(display(110, null).name, 'bETH/bWBTC LP');
  // An unverified side keeps its number; an LP side is bracketed.
  const rays = (id) => (id === 2 ? meta('N=RAYS;SN=RAYS;UN=RAYS') : null);
  const l55 = display(55, null, rays);
  assert.deepEqual([l55.name, l55.label, l55.verified], ['BEAM/RAYS #2 LP', 'BEAM/RAYS #2 LP #55', false]);
  assert.equal(display(55, null).name, 'BEAM/#2 LP', 'before the side\'s metadata arrives');
  assert.equal(display(67, null).name, 'BEAM/(BEAM/NPH LP) LP');
  // The same text from anyone else's key is just an unverified asset.
  const copy = display(5000, meta('N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;NTHUN=GROTH'));
  assert.deepEqual([copy.name, copy.label, copy.pool], ['Amm Liquidity Token 0-174-2', 'AMML #5000', null]);
  assert.equal(tokenSubtitle(lp), 'Pool share · 1% fee');
  assert.equal(tokenSubtitle(display(89, null)), 'Pool share · 0.3% fee');
});

test('LP tokens: pools newer than the bundled list are learnt from the DEX; malformed rows are ignored', () => {
  resetLpTokens();
  assert.equal(lpPoolOf(9001), null);
  learnPool({ lpToken: 9001, aid1: 0, aid2: 174, kind: 1 });
  assert.equal(display(9001, null).name, 'BEAM/FOMO LP');
  for (const bad of [{ lpToken: 9002, aid1: 174, aid2: 0, kind: 2 }, { lpToken: 0, aid1: 0, aid2: 7, kind: 2 }, { lpToken: 7, aid1: 0, aid2: 7, kind: 2 }, { lpToken: 9003, aid1: -1, aid2: 7, kind: 2 }]) {
    learnPool(bad);
    assert.equal(lpPoolOf(bad.lpToken), null, JSON.stringify(bad));
  }
  resetLpTokens();
  assert.equal(lpPoolOf(9001), null);
  assert.equal(Object.keys(SNAPSHOT).length, 98);
});

// What get_asset_info answered for four DEX liquidity tokens (wallet-api 7.5.14493, assets_list
// refresh, mainnet height 4,077,026, 2026-10-12): 50 and 175 are in the snapshot, 205 and 209 are
// pools created after it. Public chain data: a contract's asset owner is derived from its id.
const LIVE_LP = {
  50: { asset_id: 50, ownerId: '54d1ec805f0e656cd017e89151304fa1cc7e6b6e2606d7da4995ddf6c202d04b', metadata: 'STD:SCH_VER=1;N=Amm Liquidity Token 0-7-2;SN=AmmL;UN=AMML;NTHUN=GROTH' },
  175: { asset_id: 175, ownerId: '60ed0e518ddb1c9f685c6df1d7b19d899d7e764e2c2d23baa26faa39dad65b0f', metadata: 'STD:SCH_VER=1;N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;NTHUN=GROTH' },
  205: { asset_id: 205, ownerId: '74a8c779628e608c5bc37e24fd8a2fd83f809d6277e8e390a2aa5def0c933feb', metadata: 'STD:SCH_VER=1;N=Amm Liquidity Token 0-204-2;SN=AmmL;UN=AMML;NTHUN=GROTH' },
  209: { asset_id: 209, ownerId: '51522e230c832991ae5769b8b79aa6f2c4d3c58b96853714cf0949cb22e3f2a1', metadata: 'STD:SCH_VER=1;N=Amm Liquidity Token 0-208-2;SN=AmmL;UN=AMML;NTHUN=GROTH' },
};

test('LP tokens: the owner the wallet reports for a DEX liquidity token is derived from the DEX id and its metadata', async () => {
  for (const [id, info] of Object.entries(LIVE_LP)) {
    const [aid1, aid2, kind] = /Token (\d+)-(\d+)-(\d+);/.exec(info.metadata).slice(1).map(Number);
    assert.equal(lpMetadata(aid1, aid2, kind), info.metadata, `metadata of ${id}`);
    assert.equal(await contractAssetOwner(DEX_CID, info.metadata), info.ownerId, `owner of ${id}`);
  }
  assert.notEqual(await contractAssetOwner('11'.repeat(32), LIVE_LP[175].metadata), LIVE_LP[175].ownerId, 'another contract owns other assets');
});

test('LP tokens: a pool list from the node never renames a snapshot token, and a learnt one is unconfirmed until its asset record agrees (audit D-5)', async () => {
  resetLpTokens();
  // A node that says 175 (BEAM/FOMO LP) is the LP token of BEAM/BEAMX: ignored.
  learnPool({ lpToken: 175, aid1: 0, aid2: 7, kind: 2 });
  assert.deepEqual({ ...lpPoolOf(175) }, { lpToken: 175, aid1: 0, aid2: 174, kind: 2, confirmed: true });
  assert.equal(display(175, null).name, 'BEAM/FOMO LP');

  // A node that says an airdropped asset is BEAM/FOMO's LP token: shown with its number, never verified.
  learnPool({ lpToken: 9100, aid1: 0, aid2: 174, kind: 2 });
  const fake = display(9100, meta('N=Bonus;UN=BONUS'));
  assert.deepEqual([fake.name, fake.label, fake.verified, fake.pool], ['BEAM/FOMO LP', 'LP #9100', false, null]);
  assert.deepEqual({ ...fake.unconfirmedPool }, { lpToken: 9100, aid1: 0, aid2: 174, kind: 2, confirmed: false });
  assert.equal(tokenSubtitle(fake), 'Pool share · unconfirmed #9100');
  assert.equal(fake.icon, unverifiedIcon(9100), 'drawn as an unverified asset, not as the pair');
  // Its own asset record says something else (another owner, or another pool's text): stays unconfirmed.
  assert.equal(await confirmLpToken(9100, { asset_id: 9100, metadata: 'STD:SCH_VER=1;N=Bonus;UN=BONUS', ownerId: 'ab'.repeat(32) }), false);
  // The owner id binds the DEX and the text, not the number: 175's own record copied onto 9100 matches it,
  // but BEAM/FOMO already has its LP token (175), and a pool has one while it lives.
  assert.equal(await confirmLpToken(9100, { ...LIVE_LP[175], asset_id: 9100 }), false, "the pool's real record copied onto another number");
  assert.equal(await confirmLpToken(9100, { asset_id: 9100, metadata: LIVE_LP[205].metadata, ownerId: LIVE_LP[205].ownerId }), false, "another pool's record");
  assert.equal(display(9100, null).verified, false);
  assert.deepEqual(unconfirmedLpTokens(), [9100]);

  // A real pool newer than the snapshot: confirmed by its record, then named and drawn as a pool.
  learnPool({ lpToken: 205, aid1: 0, aid2: 204, kind: 2 });
  assert.equal(display(205, null).pool, null);
  assert.equal(await confirmLpToken(205, LIVE_LP[205]), true);
  assert.deepEqual({ ...display(205, null).pool }, { lpToken: 205, aid1: 0, aid2: 204, kind: 2, confirmed: true });
  assert.equal(tokenSubtitle(display(205, null)), 'Pool share · 1% fee');
  // A confirmed token is not renamed by a later row either.
  learnPool({ lpToken: 205, aid1: 0, aid2: 174, kind: 2 });
  assert.equal(lpPoolOf(205).aid2, 204);
  assert.equal(lpTrusted({ lpToken: 205, aid1: 0, aid2: 204, kind: 2 }), true);
  assert.equal(lpTrusted({ lpToken: 205, aid1: 0, aid2: 174, kind: 2 }), false);
  assert.equal(lpTrusted({ lpToken: 9100, aid1: 0, aid2: 174, kind: 2 }), false);

  // confirmLearnt asks for each unconfirmed token's record once and confirms what agrees.
  learnPool({ lpToken: 209, aid1: 0, aid2: 208, kind: 2 });
  const asked = [];
  const changed = await confirmLearnt(async (id) => {
    asked.push(id);
    if (id === 209) return LIVE_LP[209];
    throw new Error('Asset not found in a local database');
  });
  assert.equal(changed, true);
  assert.deepEqual(asked.sort((a, b) => a - b), [209, 9100]);
  assert.equal(lpPoolOf(209).confirmed, true);
  assert.equal(lpPoolOf(9100).confirmed, false);
  resetLpTokens();
});

test('a label stays current: metadata or a pool learnt later renames it everywhere it is shown', () => {
  resetLpTokens();
  const held = assetLabel(9100);
  assert.equal(held.name, 'Asset #9100');
  assetLabel(9100, meta('N=Later Name;UN=LATE'));
  assert.deepEqual([held.name, held.unit], ['Later Name', 'LATE #9100']);
  assert.equal(metadataOf(9100), meta('N=Later Name;UN=LATE'));
  learnPool({ lpToken: 9100, aid1: 0, aid2: 7, kind: 2 });
  assert.equal(held.name, 'BEAM/BEAMX LP');
  assert.equal({ ...held }.name, 'BEAM/BEAMX LP', 'a copy carries the current values');
  resetLpTokens();
});

test('badge letters (for a label without an icon): first two letters of the ticker, a number for unnamed assets', () => {
  assert.equal(badgeText({ id: -1, unit: 'USDC' }), 'US');
  assert.equal(badgeText(assetLabel(36)), 'bE');
  assert.equal(badgeText(display(12, '')), '#12');
  assert.equal(badgeText(display(7777, '')), 'CA', 'never a cut-off number');
  assert.equal(badgeText(display(250, 'STD:UN=$—X')), 'X');
});
