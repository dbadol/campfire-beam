// Airdrop v3 end-to-end: the installed Google Chrome (headless), the dev server, BEAM mainnet.
// Spends nothing: a throwaway wallet that holds nothing, and no approve button is ever pressed.
//
//   npm run e2e:airdrop-v3   (stages the engine, builds dist/, runs this file)
//
// Real, on mainnet, through the pinned v3 app shader in the wallet engine: the seeds and voucher
// keys it derives (equal to the wallet's own), check_voucher and view_my_batches on the deployed
// contract, and a create_batch of 2 bETH codes with their claim fees paid, built by the shader and
// checked by the library up to the approve sheet (the engine's own figures, "Not enough"), then
// cancelled. The codes stay saved, with their keys and the creator key.
//
// A claim, a batch on chain and its check need codes and batches this wallet cannot have. Those
// tests answer the read-only lookups in the page (check_voucher, view_my_batches, view_batch, the
// transaction's status), and for the sheets the bytes the shader would build. Everything after -
// the library's byte checks, the engine's process_invoke_data and consent - is real. A claim whose
// code pays its own fee reaches a sheet with an approve button on an empty wallet; it is cancelled.
//
// Screenshots of every screen go to CAMPFIRE_SHOTS (390x844 and 1280x800, light and dark).
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, launch, recordedPage, shot, waitScreen, foreignHosts, sleep, SHOTS } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.E2E_PORT || 8840);
const PASSWORD = `drop3-${Math.random().toString(36).slice(2, 10)}`;
const tid = (id) => `[data-testid="${id}"]`;
const V3_CID = 'ac85d74b88aca36a8033f19b00b89df55e9c75a45c8a567c0ee158e9c11aeffe';
const CREATOR = '7c'.repeat(32) + '01';

let srv, browser, ctx, page, rec;

async function shots(name) {
  for (const [w, hgt, tag] of [
    [390, 844, 'phone'],
    [1280, 800, 'desktop'],
  ]) {
    for (const scheme of ['light', 'dark']) {
      await page.setViewportSize({ width: w, height: hgt });
      await page.emulateMedia({ colorScheme: scheme });
      await sleep(250);
      await shot(page, `${name}-${tag}-${scheme}`);
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'light' });
}

/** The screens see these balances (groth); the engine still holds nothing. */
async function pretendBalance(beam, tokens = {}) {
  await page.evaluate(
    async ([g, t]) => {
      const { wallet } = await import('./lib/wallet.js');
      if (!wallet.__realRefresh) wallet.__realRefresh = wallet.refreshStatus.bind(wallet);
      wallet.refreshStatus = async function () {
        await this.__realRefresh();
        this.state.totals.set(0, { available: BigInt(g), receiving: 0n, sending: 0n, maturing: 0n });
        for (const [id, v] of Object.entries(t)) this.state.totals.set(Number(id), { available: BigInt(v), receiving: 0n, sending: 0n, maturing: 0n });
        this.emit();
      };
      await wallet.refreshStatus();
    },
    [String(beam), Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, String(v)]))],
  );
}

async function realBalance() {
  await page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const id of [...wallet.state.totals.keys()]) if (id !== 0) wallet.state.totals.delete(id);
    await wallet.refreshStatus();
  });
}

/** Taps a button the pretended balance enabled, then shows the page the engine's truth again before the sheet opens. */
async function tapWithRealBalance(testid) {
  await page.evaluate(async (id) => {
    const { wallet } = await import('./lib/wallet.js');
    document.querySelector(`[data-testid="${id}"]`).click();
    if (wallet.__realRefresh) {
      wallet.refreshStatus = wallet.__realRefresh;
      wallet.__realRefresh = null;
    }
    for (const k of [...wallet.state.totals.keys()]) wallet.state.totals.delete(k);
    wallet.emit();
    wallet.refreshStatus();
  }, testid);
}

async function passKeptHere() {
  const go = await page.waitForSelector('[data-testid="kept-here-go"]', { timeout: 5000 }).catch(() => null);
  if (go) await go.click();
}

async function engineTruth() {
  return page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = await wallet.session.call('tx_list', { count: 100, skip: 0 });
    const st = await wallet.session.call('wallet_status', { nz_totals: true });
    return { allTxs: txs.length, available: String(st.available) };
  });
}

const lastConsent = async () => (await page.evaluate(() => window.__campfire.consents())).at(-1);

async function readSheet() {
  await page.waitForSelector(tid('consent'), { timeout: 120000 });
  const text = async (id) => ((await page.$(tid(id))) ? (await page.textContent(tid(id))).trim() : null);
  return {
    title: (await page.textContent('.consent h2')).trim(),
    pay0: await text('consent-pay-0'),
    pay1: await text('consent-pay-1'),
    get0: await text('consent-get-0'),
    get1: await text('consent-get-1'),
    fee: await text('consent-fee'),
    note: await text('consent-note-0'),
    short: await text('consent-not-enough'),
    approve: await text('consent-approve'),
  };
}

/**
 * In the page: window.__v3 = helpers to stub the read-only v3 lookups and the bytes the v3 shader
 * builds, and to save a v3 batch record as the service would. Nothing here reaches signing.
 */
async function installStubs() {
  await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const { nativeApp } = await import('./lib/contracts.js');
    const { wallet } = await import('./lib/wallet.js');
    const m = await import('./lib/airdrop_v3.js');
    const a = await import('./lib/airdrop.js');
    const { walletStore } = await import('./lib/wallet_scope.js');
    const svc = airdrop(app);
    const native = await nativeApp();
    const u = (v) => {
      v = BigInt(v);
      if (v < 128n) return [0x80 | Number(v)];
      const b = [];
      for (let x = v; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
      return [b.length, ...b];
    };
    const sgn = (v) => {
      v = BigInt(v);
      const abs = v < 0n ? -v : v;
      const sign = v < 0n ? 0x80 : 0;
      if (abs < 64n) return [sign | 0x40 | Number(abs)];
      const b = [];
      for (let x = abs; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
      return [sign | b.length, ...b];
    };
    const hex = (s) => s.match(/../g).map((x) => parseInt(x, 16));
    const le = (v, n) => Array.from({ length: n }, (_, i) => Number((BigInt(v) >> BigInt(8 * i)) & 0xffn));
    const buf = (b) => [...u(b.length), ...b];
    const enc = (s) => [...new TextEncoder().encode(s)];
    /** One contract call to v3, serialized the way the core does. funds: [[aid, signed amount]] ascending. */
    const raw = ({ method, args, funds, charge, comment }) => [...u(1), ...u(method), ...buf(args), ...u(1), ...Array(32).fill(0x11), ...u(charge), ...buf(enc(comment)), ...u(funds.length), ...funds.flatMap(([k, v]) => [...u(k), ...sgn(v)]), ...hex(m.V3_CID)];
    const real = { checkVoucher: svc.v3.checkVoucher, myBatches: svc.v3.myBatches, viewBatch: svc.v3.viewBatch, oldBatches: svc.old.myBatches, redeem: svc.redeem, txStatus: wallet.txStatus, call: native.call };
    const builds = [];
    window.__v3 = {
      m,
      builds,
      chain: null, // code -> v3 voucher info or null
      batches: { batches: [], truncated: false },
      batch: null, // id -> view_batch answer
      delay: 0,
      tx: null, // the answer to every tx_status
      build: null, // args -> raw_data for redeem / cancel_batch
      on() {
        svc.v3.checkVoucher = async (code) => {
          if (window.__v3.delay) await new Promise((r) => setTimeout(r, window.__v3.delay));
          const f = window.__v3.chain;
          return f ? f(m.normaliseV3(code)) : null;
        };
        svc.v3.myBatches = async () => window.__v3.batches;
        svc.v3.viewBatch = async (id) => window.__v3.batch(id);
        svc.old.myBatches = async () => [];
        wallet.txStatus = async (txId) => (window.__v3.tx ? window.__v3.tx(txId) : real.txStatus.call(wallet, txId));
        native.call = (method, params, opts) => {
          if (method === 'invoke_contract' && window.__v3.build && params.args.includes(`cid=${m.V3_CID}`) && /action=(redeem|cancel_batch)(,|$)/.test(params.args)) {
            builds.push(params.args);
            return Promise.resolve(window.__v3.build(params.args));
          }
          return real.call.call(native, method, params, opts);
        };
      },
      off() {
        Object.assign(svc.v3, { checkVoucher: real.checkVoucher, myBatches: real.myBatches, viewBatch: real.viewBatch });
        svc.old.myBatches = real.oldBatches;
        svc.redeem = real.redeem;
        wallet.txStatus = real.txStatus;
        native.call = real.call;
        window.__v3.build = null;
      },
      raw,
      le,
      hex,
      /** A redeem as the shader builds it: voucher key, a receiving key, no pool gas, a signature. */
      redeemRaw(info) {
        const args = [...hex(info.key), ...hex('3d'.repeat(32) + '00'), ...le(0, 8), ...Array(65).fill(0x42)];
        const funds = [...(info.gas ? [[0, -info.gas]] : []), [info.assetId, -info.value]].sort((x, y) => x[0] - y[0]);
        return { output: JSON.stringify({ asset_id: info.assetId, value: Number(info.value), gas: Number(info.gas), gas_source: info.gas ? 'voucher' : 'none' }), raw_data: raw({ method: 3, args, funds, charge: 200000, comment: 'Redeem airdrop voucher' }) };
      },
      /** A take-back of `keys` of batch `id` as the shader builds it. */
      cancelRaw({ id, creator, keys, assetId, value, gas }) {
        const args = [...hex(creator), ...le(id, 8), ...le(keys.length, 4), ...keys.flatMap(hex)];
        const funds = [...(gas ? [[0, -gas]] : []), [assetId, -value]].sort((x, y) => x[0] - y[0]);
        return { output: JSON.stringify({ cancelled: keys.length, value: Number(value), gas: Number(gas) }), raw_data: raw({ method: 4, args, funds, charge: m.cancelCharge(keys.length), comment: 'Cancel airdrop batch' }) };
      },
      /** A v3 batch record of `n` fresh codes, saved as the service saves one after sending. */
      async save({ n = 10, value = 50000000n, assetId = 36, gas = m.GAS_PER_VOUCHER, creator = '7c'.repeat(32) + '01', txId = 'cd'.repeat(16) } = {}) {
        const vault = a.codeVault({ kv: walletStore(app.record), walletId: app.record.id, secret: app.dbPass, imported: Boolean(app.record.imported) });
        const codes = [];
        while (codes.length < n) {
          const code = a.generateCode();
          codes.push({ code, hash: await a.codeHash(code), key: m.voucherKeyOf(code), value: String(value), status: 'unknown' });
        }
        const localId = `batch_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;
        await vault.put({ localId, contractId: m.V3_CID, assetId, createdAt: new Date().toISOString(), txId, txStatus: 'broadcast', gasPerVoucher: String(gas), creatorKey: creator, batchId: null, check: null, codes });
        return { localId, codes: codes.map((c) => ({ code: c.code, key: c.key })) };
      },
      async saved(localId) {
        const list = await svc.savedBatches();
        const b = list.find((x) => x.localId === localId);
        return b ? JSON.parse(JSON.stringify(b)) : null;
      },
    };
  });
}

/** The chain as it answers for a saved batch: every code under batch `id` of this wallet (or `mutate`d). */
async function chainOf(saved, { id = 12, value = '50000000', gas = '2200000', assetId = 36, mutate = null } = {}) {
  await page.evaluate(
    ([s, id, value, gas, assetId, mutate]) => {
      const byCode = new Map(s.codes.map((c) => [c.code.replace(/-/g, ''), c]));
      const f = mutate ? new Function('info', 'i', mutate) : null;
      window.__v3.chain = (n) => {
        const c = byCode.get(n);
        if (!c) return null;
        const info = { contract: 'v3', key: c.key, batchId: BigInt(id), assetId, value: BigInt(value), gas: BigInt(gas), redeemed: false, redeemedAtHeight: null };
        return f ? f(info, [...byCode.keys()].indexOf(n)) : info;
      };
      window.__v3.batches = { batches: [{ id: BigInt(id), assetId, created: s.codes.length, unclaimed: 6, redeemed: 3, cancelled: 1, valueUnclaimed: BigInt(value) * 6n, gasPerVoucher: BigInt(gas), createdAtHeight: 4080000n }], truncated: false };
    },
    [saved, id, value, gas, assetId, mutate],
  );
}

before(async () => {
  srv = await startServer({ root: 'dist', port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, locale: 'en-GB' });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: srv.url });
  ({ page, rec } = await recordedPage(ctx, { label: 'airdrop-v3' }));
  console.log(`# screenshots: ${SHOTS}`);
});

after(async () => {
  if (browser) await browser.close();
  if (srv) srv.stop();
});

const typedCodes = [];

test('a new wallet, synced', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
});

test('the pinned v3 shader derives the same seeds and keys as the wallet; the deployed contract answers', { timeout: 10 * 60000 }, async () => {
  const r = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const m = await import('./lib/airdrop_v3.js');
    const { generateCode } = await import('./lib/airdrop.js');
    const svc = airdrop(app);
    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    const codes = ['ABCD-EFGH-JKLM-NPQR', 'abcd efgh jklm npqr', '7', 'BBBB-BBBB-BBBB-BBBB', 'DDDD-DDDD-DDDD-DDDD', ...Array.from({ length: 12 }, () => generateCode())];
    const out = [];
    for (const code of codes) {
      const s = await svc.v3.voucherKey(code);
      out.push({ code, same: s.seed === hex(m.seedOf(code)) && s.key === m.voucherKeyOf(code), parity: s.key.slice(-2), seed: s.seed, key: s.key });
    }
    const fresh = generateCode();
    const unknownV3 = await svc.v3.checkVoucher(fresh);
    const unknownBoth = await svc.checkVoucher(fresh);
    const mine = await svc.v3.myBatches();
    return { out, unknownV3, unknownBoth, mine: { n: mine.batches.length, truncated: mine.truncated } };
  });
  for (const x of r.out) console.log(`# ${x.code.padEnd(20)} seed ${x.seed.slice(0, 12)}… key ${x.key.slice(0, 12)}…${x.parity} same=${x.same}`);
  assert.ok(r.out.every((x) => x.same), 'every seed and key the shader derives is the wallet\'s');
  assert.equal(r.out[0].seed, '722f480abe6a26a479b9bdd177c979d320254787b2f24c11b618689c613ff8f3', 'the README test vector');
  assert.deepEqual(new Set(r.out.map((x) => x.parity)), new Set(['00', '01']), 'both Y parities covered');
  assert.equal(r.unknownV3, null, 'check_voucher on the deployed v3 contract: not found');
  assert.equal(r.unknownBoth, null, 'then the old contract: not found');
  assert.deepEqual(r.mine, { n: 0, truncated: false }, 'view_my_batches answers for a new wallet');
});

test('create 2 bETH codes with their claim fees paid: the real v3 build up to the sheet, the option, Cancel; codes kept with their keys', { timeout: 10 * 60000 }, async () => {
  await pretendBalance(100000000n, { 36: 1000000000n });
  await page.evaluate(() => window.__campfire.go('airdropCreate'));
  await waitScreen(page, 'airdropCreate');
  await page.selectOption(tid('drop-asset'), '36');
  await page.fill(tid('drop-amount'), '0.5');
  await page.fill(tid('drop-count'), '2');
  const summary = async () => ({
    locked: await page.textContent(tid('drop-locked')),
    fee: await page.textContent(tid('drop-fee')),
    gas: (await page.$(tid('drop-gas-total'))) ? await page.textContent(tid('drop-gas-total')) : null,
    network: await page.textContent(tid('drop-network-fee')),
    total: await page.textContent(tid('drop-total')),
  });
  assert.equal(await page.isChecked(tid('drop-gas')), true, 'on by default');
  assert.equal((await page.textContent(tid('drop-gas-row'))).trim(), 'Pay the claim fee for each code (0.022 BEAM per code), so people with an empty wallet can claim');
  const on = await summary();
  console.log(`# with claim fees: ${JSON.stringify(on)}`);
  assert.deepEqual(on, { locked: '1 bETH', fee: '0.01 bETH', gas: '0.044 BEAM', network: '0.0185 BEAM', total: '1.01 bETH + 0.0625 BEAM' });
  assert.equal(await page.textContent(tid('drop-cta')), 'Create 2 codes');
  assert.equal(await page.isDisabled(tid('drop-cta')), false);
  assert.match(await page.textContent(tid('drop-check-note')), /checks every code/);
  const cta = await page.locator(tid('drop-cta')).boundingBox();
  assert.ok(cta && cta.y + cta.height <= 844, 'the button in sight on a phone');
  await shots('v3-create-01-fees-paid');
  await page.click(tid('drop-gas'));
  const off = await summary();
  assert.deepEqual(off, { locked: '1 bETH', fee: '0.01 bETH', gas: null, network: '0.0185 BEAM', total: '1.01 bETH + 0.0185 BEAM' });
  await shots('v3-create-02-fees-not-paid');
  await page.click(tid('drop-gas'));
  await page.fill(tid('drop-count'), '100');
  assert.equal(await page.textContent(tid('drop-network-fee')), '0.3125 BEAM');
  await page.fill(tid('drop-count'), '2');

  await tapWithRealBalance('drop-cta');
  await passKeptHere();
  const sheet = await readSheet();
  console.log(`# create sheet: ${JSON.stringify(sheet)}`);
  await shots('v3-create-03-sheet');
  assert.equal(sheet.title, 'Confirm your codes');
  assert.deepEqual([sheet.pay0, sheet.pay1].sort(), ['0.044 BEAM', '1.01 bETH'].sort());
  assert.equal(sheet.fee, '0.0185 BEAM');
  assert.match(sheet.note, /^0\.044 BEAM of this pays the claim fee of each code, so people with an empty wallet can claim\./);
  assert.ok(sheet.short, 'not enough on an empty wallet');
  assert.equal(sheet.approve, null);
  await page.click(tid('consent-cancel'));
  await page.waitForSelector(`${tid('drop-result')}[data-code="rejected"]`, { timeout: 30000 });
  const last = await lastConsent();
  assert.equal(last.decision, 'rejected');
  assert.equal(last.fee, '0.0185');
  const saved = await page.evaluate(async () => {
    const { app } = await import('./app.js');
    const { airdrop } = await import('./screens/airdrop.js');
    const { store } = await import('./lib/store.js');
    const m = await import('./lib/airdrop_v3.js');
    const list = await airdrop(app).savedBatches();
    const b = list[0];
    const raw = JSON.stringify(await store.get('airdropCodes')) + JSON.stringify(await store.get(`w:${app.record.id}:airdropCodes`));
    const hex = (x) => Array.from(x, (y) => y.toString(16).padStart(2, '0')).join('');
    return {
      v3: b.contractId === m.V3_CID,
      status: b.txStatus,
      gas: b.gasPerVoucher,
      creator: /^[0-9a-f]{64}0[01]$/.test(b.creatorKey || ''),
      keys: b.codes.every((c) => c.key === m.voucherKeyOf(c.code)),
      n: b.codes.length,
      clear: b.codes.some((c) => raw.includes(c.code) || raw.includes(c.code.replace(/-/g, '')) || raw.includes(hex(m.seedOf(c.code)))),
      codes: b.codes.map((c) => c.code),
    };
  });
  console.log(`# saved after Cancel: ${JSON.stringify({ ...saved, codes: saved.codes.length })}`);
  typedCodes.push(...saved.codes);
  assert.deepEqual({ v3: saved.v3, status: saved.status, gas: saved.gas, creator: saved.creator, keys: saved.keys, n: saved.n, clear: saved.clear }, { v3: true, status: 'failed', gas: '2200000', creator: true, keys: true, n: 2, clear: false });
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });
  const state = await page.evaluate(() => window.__campfire.contracts());
  assert.equal(state.consents, 0);
  assert.equal(state.inflight, 0);
  await realBalance();
});

test('the check before sharing: waiting, checking each code, ready; a squatted batch fails; turned down; a lookup error', { timeout: 10 * 60000 }, async () => {
  await installStubs();
  await page.evaluate(() => window.__v3.on());
  try {
    // 1. Waiting for confirmations, then every code checked, then ready.
    const good = await page.evaluate(() => window.__v3.save({ n: 10 }));
    typedCodes.push(...good.codes.map((c) => c.code));
    await chainOf(good);
    await page.evaluate(() => (window.__v3.tx = async () => ({ status: 3, confirmations: 1 })));
    await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id, justCreated: true }), good.localId);
    await page.waitForSelector(`${tid('codes-steps')}[data-state="waiting"]`, { timeout: 30000 });
    assert.equal((await page.textContent(tid('codes-step-1'))).trim(), 'Confirmed by the network1 of 3');
    assert.equal(await page.$(tid('code')), null, 'no code before the check');
    assert.equal(await page.$(tid('codes-copy-all')), null, 'nothing to copy before the check');
    await shots('v3-codes-01-waiting');
    await page.evaluate(() => {
      window.__v3.tx = async () => ({ status: 3, confirmations: 4 });
      window.__v3.delay = 900;
    });
    await page.waitForSelector(`${tid('codes-steps')}[data-state="checking"]`, { timeout: 30000 });
    await page.waitForFunction(() => /[2-9] of 10/.test(document.querySelector('[data-testid="codes-step-2"]')?.textContent || ''), null, { timeout: 30000 });
    await shots('v3-codes-02-checking');
    await page.evaluate(() => (window.__v3.delay = 0));
    await page.waitForSelector(tid('codes-ready'), { timeout: 60000 });
    assert.equal(await page.$$eval(tid('code'), (els) => els.length), 10);
    assert.ok(await page.isVisible(tid('codes-copy-all')), 'Copy all, once ready');
    assert.equal(await page.textContent(tid('codes-copy-all')), 'Copy all 10 codes');
    const ok = await page.evaluate((id) => window.__v3.saved(id), good.localId);
    assert.deepEqual({ check: ok.check.state, batchId: ok.batchId, status: ok.txStatus }, { check: 'ok', batchId: '12', status: 'confirmed' });
    await shots('v3-codes-03-ready');

    // 2. Squatted: the codes point at a copy holding 1 groth each.
    const squat = await page.evaluate(() => window.__v3.save({ n: 3 }));
    typedCodes.push(...squat.codes.map((c) => c.code));
    await chainOf(squat, { id: 13, mutate: 'return { ...info, batchId: 99n, value: 1n, gas: 0n };' });
    await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id }), squat.localId);
    await page.waitForSelector(tid('codes-check-failed'), { timeout: 60000 });
    const failed = await page.textContent(tid('codes-check-failed'));
    console.log(`# check failed: ${failed}`);
    assert.match(failed, /^Do not share these codes\. A code holds a different amount than this batch locked\./);
    assert.match(failed, /Your funds are safe: take this batch back in My batches/);
    assert.equal(await page.$(tid('code')), null);
    assert.equal(await page.textContent(tid('codes-make-new')), 'Make new codes');
    assert.equal(await page.textContent(tid('codes-take-back')), 'Take the batch back');
    await shots('v3-codes-04-check-failed');
    await page.click(tid('codes-make-new'));
    await waitScreen(page, 'airdropCreate');
    assert.deepEqual(
      { amount: await page.inputValue(tid('drop-amount')), count: await page.inputValue(tid('drop-count')), asset: await page.inputValue(tid('drop-asset')), gas: await page.isChecked(tid('drop-gas')) },
      { amount: '0.5', count: '3', asset: '36', gas: true },
      'new codes for the same airdrop',
    );
    await page.evaluate(async () => {
      const { app } = await import('./app.js');
      app.dropCreateDraft = null;
    });

    // 3. The network turned the create down.
    const down = await page.evaluate(() => window.__v3.save({ n: 2 }));
    typedCodes.push(...down.codes.map((c) => c.code));
    await page.evaluate(() => (window.__v3.tx = async () => ({ status: 4 })));
    await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id }), down.localId);
    await page.waitForSelector(tid('codes-not-sent'), { timeout: 30000 });
    assert.match(await page.textContent(tid('codes-not-sent')), /The network turned it down, so nothing was locked and these codes hold nothing\. Do not use them: make new codes\./);
    await shots('v3-codes-05-turned-down');

    // 4. A lookup that fails: said, and tried again on a tap.
    const flaky = await page.evaluate(() => window.__v3.save({ n: 2 }));
    typedCodes.push(...flaky.codes.map((c) => c.code));
    await chainOf(flaky, { id: 14 });
    await page.evaluate(() => {
      window.__v3.tx = async () => ({ status: 3, confirmations: 9 });
      window.__v3.realChain = window.__v3.chain;
      window.__v3.chain = () => {
        throw Object.assign(new Error('The wallet did not answer in time.'), { code: 'timeout' });
      };
    });
    await page.evaluate((id) => window.__campfire.go('airdropCodes', { localId: id }), flaky.localId);
    await page.waitForSelector(tid('codes-check-error'), { timeout: 30000 });
    assert.deepEqual(await page.$$eval('[data-testid^="codes-step-"]', (els) => els.map((e) => e.dataset.mark)), ['done', 'done', 'failed'], 'the error at the step it happened in');
    assert.match(await page.textContent(tid('codes-check-error')), /^The codes could not be checked: The wallet did not answer in time\. They are saved on this device\. Check again$/);
    await shots('v3-codes-06-check-error');
    await page.evaluate(() => (window.__v3.chain = window.__v3.realChain));
    await page.click(tid('codes-check-again'));
    await page.waitForSelector(tid('codes-ready'), { timeout: 60000 });
  } finally {
    await page.evaluate(() => window.__v3.off());
  }
});

test('claim: a code whose fee was paid needs no BEAM and reaches an approve button on an empty wallet; another says what it needs', { timeout: 10 * 60000 }, async () => {
  await installStubs();
  await page.evaluate(() => window.__v3.on());
  try {
    await realBalance();
    const code = 'WXYZ-2345-6789-ABCD';
    typedCodes.push(code);
    await page.evaluate((c) => {
      const m = window.__v3.m;
      window.__v3.info = { contract: 'v3', key: m.voucherKeyOf(c), batchId: 5n, assetId: 36, value: 500000000n, gas: 2200000n, redeemed: false, redeemedAtHeight: null };
      window.__v3.chain = (n) => (n === m.normaliseV3(c) ? window.__v3.info : null);
      window.__v3.build = () => window.__v3.redeemRaw(window.__v3.info);
    }, code);
    await page.evaluate(() => window.__campfire.go('airdrop'));
    await waitScreen(page, 'airdrop');
    await page.fill(tid('airdrop-code'), code.toLowerCase());
    await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
    assert.equal(await page.getAttribute(tid('airdrop-result'), 'data-contract'), 'v3');
    assert.match(await page.textContent(tid('airdrop-gasless')), /^No BEAM needed\. Whoever made this code paid its network fee, so you can claim it even with an empty wallet\./);
    assert.equal(await page.textContent(tid('airdrop-gets')), '5 bETH');
    assert.equal(await page.textContent(tid('airdrop-fee')), '0.021 BEAM');
    assert.deepEqual(await page.$$eval(`${tid('airdrop-net')} > div`, (els) => els.map((e) => e.textContent)), ['+5 bETH', '+0.001 BEAM']);
    assert.equal(await page.textContent(tid('airdrop-bearer')), 'The network never sees this code, so nobody watching can take your claim. Until the claim is confirmed, anyone else who has the code could still claim it first, and whoever made it could still take it back.');
    await page.waitForFunction(() => !document.querySelector('[data-testid="airdrop-cta"]').disabled, null, { timeout: 30000 });
    assert.equal(await page.textContent(tid('airdrop-cta')), 'Claim 5 bETH', 'enabled with 0 BEAM');
    await shots('v3-claim-01-fee-paid');
    await page.click(tid('airdrop-cta'));
    const sheet = await readSheet();
    console.log(`# gasless claim sheet: ${JSON.stringify(sheet)}`);
    await shots('v3-claim-02-sheet-fee-paid');
    assert.equal(sheet.title, 'Confirm your claim');
    assert.deepEqual([sheet.get0, sheet.get1].sort(), ['0.022 BEAM', '5 bETH'].sort());
    assert.equal(sheet.fee, '0.021 BEAM');
    assert.equal(sheet.short, null, 'not "not enough": the claim pays its own fee');
    assert.equal(sheet.approve, 'Claim 5 bETH', 'an empty wallet can approve it (never pressed here)');
    assert.equal(sheet.note, 'This code brings 0.022 BEAM that pays the network fee, so no BEAM leaves your wallet.');
    const built = await page.evaluate(() => window.__v3.builds.at(-1));
    assert.match(built, /,code=WXYZ23456789ABCD,use_gas_pool=0$/);
    assert.doesNotMatch(built, /fee/, 'no fee passed');
    await page.click(tid('consent-cancel'));
    await page.waitForSelector(`${tid('airdrop-notice')}[data-code="rejected"]`, { timeout: 30000 });
    const last = await lastConsent();
    assert.equal(last.decision, 'rejected');
    assert.equal(last.fee, '0.021');
    assert.deepEqual(last.spends, []);

    // The same code without its fee paid: 0.021 BEAM needed, said with the way to get it.
    await page.evaluate(() => (window.__v3.info = { ...window.__v3.info, gas: 0n }));
    await page.fill(tid('airdrop-code'), '');
    await page.fill(tid('airdrop-code'), code);
    await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
    assert.equal(await page.$(tid('airdrop-gasless')), null);
    assert.deepEqual(await page.$$eval(`${tid('airdrop-net')} > div`, (els) => els.map((e) => e.textContent)), ['+5 bETH', '−0.021 BEAM']);
    assert.equal(await page.isDisabled(tid('airdrop-cta')), true);
    assert.match(await page.textContent(tid('airdrop-reason')), /^Claiming needs 0\.021 BEAM for the network fee and this wallet has 0 BEAM\. Add BEAM, then claim\. Receive BEAM$/);
    await shots('v3-claim-03-needs-beam');

    // Sent, then received only once mined; or not through, with nothing lost.
    await page.evaluate(() => {
      window.__v3.info = { ...window.__v3.info, gas: 2200000n };
      window.__v3.status = 1;
      window.__v3.tx = async () => ({ status: window.__v3.status });
    });
    await page.evaluate(async () => {
      const { app } = await import('./app.js');
      const { airdrop } = await import('./screens/airdrop.js');
      airdrop(app).redeem = async () => ({ txId: 'ef'.repeat(16), info: window.__v3.info });
    });
    await page.fill(tid('airdrop-code'), '');
    await page.fill(tid('airdrop-code'), code);
    await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
    await page.click(tid('airdrop-cta'));
    await page.waitForSelector(`${tid('airdrop-done')}[data-status="sent"]`);
    assert.equal(await page.textContent(tid('airdrop-done')), 'Claim sent');
    await shots('v3-claim-04-sent');
    await page.evaluate(() => (window.__v3.status = 3));
    await page.waitForSelector(`${tid('airdrop-done')}[data-status="received"]`, { timeout: 20000 });
    assert.equal(await page.textContent(tid('airdrop-done')), '5 bETH received');
    await shots('v3-claim-05-received');
    await page.evaluate(() => {
      window.__v3.status = 1;
      window.__campfire.go('airdrop');
    });
    await waitScreen(page, 'airdrop');
    await page.fill(tid('airdrop-code'), code);
    await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
    await page.click(tid('airdrop-cta'));
    await page.waitForSelector(`${tid('airdrop-done')}[data-status="sent"]`);
    await page.evaluate(() => (window.__v3.status = 4));
    await page.waitForSelector(`${tid('airdrop-done')}[data-status="failed"]`, { timeout: 20000 });
    assert.equal(await page.textContent(tid('airdrop-done')), 'The claim did not go through');
    await shots('v3-claim-06-not-through');
    await page.click(tid('airdrop-done-again'));
    await page.waitForSelector(`${tid('airdrop-result')}[data-state="found"]`, { timeout: 60000 });
    assert.equal(await page.inputValue(tid('airdrop-code')), code, 'the code is back to check');
  } finally {
    await page.evaluate(() => window.__v3.off());
  }
});

test('my batches: a v3 batch with its fees paid, an older one, the take-back sheet and a claim landing while it is prepared', { timeout: 10 * 60000 }, async () => {
  await installStubs();
  await page.evaluate(() => window.__v3.on());
  try {
    await realBalance();
    // The ready batch from the check above is batch 12 of this wallet.
    const ready = await page.evaluate(async () => {
      const { app } = await import('./app.js');
      const { airdrop } = await import('./screens/airdrop.js');
      const b = (await airdrop(app).savedBatches()).find((x) => x.batchId === '12');
      return { localId: b.localId, creator: b.creatorKey, keys: b.codes.map((c) => c.key) };
    });
    await page.evaluate((r) => {
      window.__v3.batches = { batches: [{ id: 12n, assetId: 36, created: 10, unclaimed: 6, redeemed: 3, cancelled: 1, valueUnclaimed: 300000000n, gasPerVoucher: 2200000n, createdAtHeight: 4080000n }], truncated: false };
      window.__v3.listed = 6;
      window.__v3.build = () => window.__v3.cancelRaw({ id: 12, creator: r.creator, keys: r.keys.slice(0, window.__v3.listed), assetId: 36, value: 50000000n * BigInt(window.__v3.listed), gas: 2200000n * BigInt(window.__v3.listed) });
    }, ready);
    await page.evaluate(async () => {
      const { app } = await import('./app.js');
      const { airdrop } = await import('./screens/airdrop.js');
      const svc = airdrop(app);
      svc.old.myBatches = async () => [{ id: 7n, assetId: 0, valuePerVoucher: 100000n, totalCount: 2, redeemedCount: 1, unclaimedCount: 1, createdAtHeight: 4073000n }];
      svc.old.batchVouchers = async () => [{ hash: 'ab'.repeat(32), value: 100000n, redeemed: false }, { hash: 'cd'.repeat(32), value: 100000n, redeemed: true }];
    });
    await page.evaluate(() => window.__campfire.go('airdropBatches'));
    await page.waitForSelector('[data-batch-id="12"]', { timeout: 60000 });
    const v3 = '[data-batch-id="12"][data-contract="v3"]';
    assert.equal(await page.textContent(`${v3} ${tid('batch-counts')}`), '3 claimed · 6 not claimed · 1 taken back');
    assert.equal(await page.textContent(`${v3} ${tid('batch-cancel')}`), 'Take back 3 bETH + 0.132 BEAM');
    assert.equal(await page.textContent(`${v3} ${tid('batch-fee')}`), 'Network fee 0.0213 BEAM');
    assert.equal(await page.isDisabled(`${v3} ${tid('batch-cancel')}`), false, 'the BEAM coming back pays the fee: no BEAM needed');
    assert.ok(await page.isVisible(`${v3} ${tid('batch-show')}`));
    // The older batch: its take-back costs 0.181 BEAM and brings back 0.001, on a wallet holding none.
    assert.match(await page.textContent(`[data-batch-id="7"][data-contract="v2"] ${tid('batch-fee-short')}`), /^Taking back needs 0\.18 BEAM for the network fee; this wallet has 0 BEAM\. Receive BEAM$/);
    assert.equal(await page.isDisabled(`[data-batch-id="7"][data-contract="v2"] ${tid('batch-cancel')}`), true);
    await shots('v3-batches-01');
    await page.click(`${v3} ${tid('batch-cancel')}`);
    const sheet = await readSheet();
    console.log(`# take-back sheet: ${JSON.stringify(sheet)}`);
    await shots('v3-batches-02-take-back-sheet');
    assert.equal(sheet.title, 'Take back unclaimed codes');
    assert.deepEqual([sheet.get0, sheet.get1].sort(), ['0.132 BEAM', '3 bETH'].sort());
    assert.equal(sheet.fee, '0.0213 BEAM');
    assert.equal(sheet.short, null);
    assert.equal(sheet.approve, 'Take back 3 bETH + 0.132 BEAM', 'the same words as the batch\'s button');
    await page.click(tid('consent-cancel'));
    await page.waitForSelector(`${tid('batches-result')}[data-code="rejected"]`, { timeout: 30000 });
    // A code is claimed while the take-back is prepared: the shader lists 5, the screen read 6.
    await page.evaluate(() => (window.__v3.listed = 5));
    await page.click(`${v3} ${tid('batch-cancel')}`);
    await page.waitForSelector(`${tid('batches-result')}[data-code="changed"]`, { timeout: 30000 });
    assert.equal(await page.textContent(tid('batches-result')), 'Some codes were claimed while this was being prepared. Nothing was sent. Look at the batch again, then take back what is left.');
    await shots('v3-batches-03-claimed-meanwhile');
    assert.equal((await page.evaluate(() => window.__campfire.contracts())).consents, 0, 'never shown');
  } finally {
    await page.evaluate(() => window.__v3.off());
  }
  assert.deepEqual(await engineTruth(), { allTxs: 0, available: '0' });
});

test('IP privacy, and no code or seed in the console', async () => {
  assert.deepEqual(foreignHosts(rec, srv.url), []);
  assert.deepEqual(rec.csp, []);
  assert.deepEqual(rec.errors, []);
  const text = rec.console.map((c) => c.text).join('\n');
  assert.ok(typedCodes.length > 10);
  for (const c of typedCodes) {
    assert.ok(!text.includes(c) && !text.includes(c.replace(/-/g, '')), `code ${c.slice(0, 4)}… in the console`);
  }
});
