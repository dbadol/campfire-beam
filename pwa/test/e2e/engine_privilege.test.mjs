// The engine itself refuses invoke data that raises its app's privilege (issue #73, wasm patch
// 0112), with the page's own check out of the way. The installed Google Chrome (headless), its own
// build and port, BEAM mainnet, a throwaway wallet that holds nothing.
//
//   npm run e2e:engine-privilege   (port 8851, CAMPFIRE_PRIVILEGE_PORT)
//
// Two app APIs are opened directly on the engine (WasmWalletClient.createAppAPI): one at privilege
// 0, as every dApp's, and one at 1, as BEAM names' app. The test answers the engine's consent
// handler itself and approves every request, so lib/contracts.js and lib/dapps/policy.js
// (checkContractData, which refuses such data before anyone is asked) are not in the path:
// whatever is refused here, the engine refused on its own.
//
// The invoke data is built here: one call (method 2) to a contract that does not exist, no
// signature, nothing spent, and - for most - an app body stored to re-run (SaveAppInvoke) at a
// chosen privilege, never with a dependent call, so nothing is ever re-run. What the engine
// accepts becomes a contract transaction that fails at once (no coins for its fee, no such
// contract): nothing can reach the chain, nothing is spent.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer, launch, recordedPage, sleep, PWA } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const PORT = Number(process.env.CAMPFIRE_PRIVILEGE_PORT || 8851);
const PASSWORD = `priv-${Math.random().toString(36).slice(2, 10)}`;
const REFUSAL = 'invoke data requests a shader privilege that was not granted';
const NO_SUCH_CONTRACT = `${'00'.repeat(30)}c073`;

let tmp, srv, browser, ctx, page, rec;

/** In the page: an invoke data builder, both app APIs opened on the engine, and a consent handler that approves. */
async function install() {
  await page.evaluate(async (cid) => {
    const { wallet } = await import('./lib/wallet.js');
    const { decodeInvokeData } = await import('./lib/dapps/invoke_data.js');
    const session = wallet.session;
    const client = session.client;

    // yas, as the core writes it (lib/dapps/invoke_data.js reads it back below).
    const u = (v) => {
      v = BigInt(v);
      if (v < 128n) return [0x80 | Number(v)];
      const b = [];
      for (let x = v; x > 0n; x >>= 8n) b.push(Number(x & 0xffn));
      return [b.length, ...b];
    };
    const buf = (b) => [...u(b.length), ...b];
    const hex = (s) => s.match(/../g).map((x) => parseInt(x, 16));
    const enc = (s) => [...new TextEncoder().encode(s)];
    const SAVE_APP_INVOKE = 0x20;
    // privilege null: no stored app body; otherwise one stored at that privilege.
    const build = ({ privilege = null, body = Array(64).fill(0x42) } = {}) => {
      const stored = privilege !== null;
      const entry = [
        ...(stored ? [...u(0x80000000 + SAVE_APP_INVOKE), ...u(2)] : u(2)),
        ...buf([1, 2, 3, 4]), // the method's arguments
        ...u(0), // no signatures
        ...u(50000), // charge
        ...buf(enc('campfire engine privilege test')),
        ...u(0), // spends nothing
        ...hex(cid),
      ];
      const out = [...u(1), ...entry];
      if (stored) out.push(...buf(body), ...buf([]), ...u(0), ...u(privilege)); // app, contract, args, privilege
      const read = decodeInvokeData(Uint8Array.from(out));
      if (read.entries.length !== 1 || read.appPrivilege !== privilege) throw new Error(`built ${JSON.stringify(read)}`);
      return out;
    };

    const t = { seen: [], apis: {} };
    window.__p73 = t;
    t.build = build;
    t.policy = async (bytes) => {
      const { checkContractData, PolicyRefusal } = await import('./lib/dapps/policy.js');
      try {
        checkContractData(Uint8Array.from(bytes));
        return null;
      } catch (e) {
        return e instanceof PolicyRefusal ? e.reason : `threw ${e && e.message}`;
      }
    };

    // The test's own consent: every request it sent is approved, anything else refused.
    client.setApproveContractInfoHandler((request, info, amounts, cb) => {
      let id = null;
      try {
        id = JSON.parse(request).id;
      } catch {
        /* not ours */
      }
      const ours = typeof id === 'string' && id.startsWith('p73-');
      t.seen.push({ id, approved: ours, info: JSON.parse(info) });
      try {
        if (ours) cb.contractInfoApproved(request);
        else cb.contractInfoRejected(request);
      } finally {
        cb.delete();
      }
    });

    const open = (name, privilege) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`createAppAPI ${name}: no answer`)), 20000);
        const appId = session.M.WasmWalletClient.GenerateAppID(name, `campfire:test-73-${privilege}`);
        client.createAppAPI('current', 'current', appId, name, (err, api) => {
          clearTimeout(timer);
          if (err || !api) return reject(new Error(`createAppAPI ${name}: ${err}`));
          const waiting = new Map();
          api.setHandler((s) => {
            const m = JSON.parse(s);
            const w = waiting.get(m.id);
            if (w) {
              waiting.delete(m.id);
              w(m);
            }
          });
          let n = 0;
          resolve({
            api,
            call: (method, params) =>
              new Promise((res, rej) => {
                const id = `p73-${privilege}-${++n}`;
                const tm = setTimeout(() => rej(new Error(`${method} ${id}: no answer`)), 60000);
                waiting.set(id, (m) => {
                  clearTimeout(tm);
                  res({ id, result: m.result ?? null, error: m.error ?? null });
                });
                api.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
              }),
          });
        }, privilege);
      });
    // One at a time: two createAppAPI calls in flight stop the page (PWA.md §8).
    t.apis[0] = await open('Privilege test 0', 0);
    t.apis[1] = await open('Privilege test 1', 1);
  }, NO_SUCH_CONTRACT);
}

/** process_invoke_data with the data built for `spec`, through the app API at `privilege`. */
function send(privilege, spec) {
  return page.evaluate(async ([privilege, spec]) => {
    const t = window.__p73;
    const data = t.build(spec);
    const policy = await t.policy(data);
    const r = await t.apis[privilege].call('process_invoke_data', { data });
    return { ...r, policy, approved: t.seen.some((s) => s.id === r.id && s.approved) };
  }, [privilege, spec]);
}

const contractTxs = () =>
  page.evaluate(async () => {
    const { wallet } = await import('./lib/wallet.js');
    const txs = (await wallet.session.call('tx_list', { count: 100, skip: 0 })) || [];
    return txs.filter((x) => x.tx_type === 12).map((x) => x.txId);
  });

const refused = (r, why) => {
  assert.equal(r.approved, true, `${r.id} was approved by the test, so a refusal is the engine's own`);
  assert.equal(r.result, null, `${r.id}: the engine made a transaction: ${JSON.stringify(r.result)}`);
  assert.ok(r.error, `${r.id}: no error`);
  assert.equal(r.error.code, -32019);
  assert.equal(r.error.data, `${REFUSAL} (${why})`);
};

const accepted = (r) => {
  assert.equal(r.approved, true);
  assert.equal(r.error, null, `${r.id}: ${JSON.stringify(r.error)}`);
  assert.match(String(r.result && r.result.txid), /^[0-9a-f]{32}$/);
  return r.result.txid;
};

test.before(async () => {
  tmp = mkdtempSync(join(tmpdir(), 'campfire-engine-privilege-'));
  execFileSync(process.execPath, [join(PWA, 'tools', 'build.mjs'), '--out', join(tmp, 'dist'), '--quiet'], { cwd: PWA });
  srv = await startServer({ root: join(tmp, 'dist'), port: PORT });
  browser = await launch();
  ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  ({ page, rec } = await recordedPage(ctx, { label: 'privilege' }));
});

test.after(async () => {
  if (page) {
    await page
      .evaluate(async () => {
        for (const a of Object.values((window.__p73 && window.__p73.apis) || {})) a.api.delete();
        const { wallet } = await import('./lib/wallet.js');
        const c = await import('./lib/contracts.js');
        c.unbindSession();
        c.bindSession(wallet.session);
      })
      .catch(() => {});
  }
  if (browser) await browser.close();
  if (srv) srv.stop();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
});

test('a new wallet that holds nothing; two app APIs opened on the engine, at privilege 0 and 1', { timeout: 15 * 60000 }, async () => {
  await page.goto(srv.url);
  await createWallet(page, { password: PASSWORD });
  await waitHome(page);
  await waitSynced(page);
  await sleep(3000);
  const totals = await page.evaluate(() => window.__campfire.totals());
  assert.ok(Object.values(totals).every((v) => v.available === '0' && v.receiving === '0'), `a new wallet holds nothing: ${JSON.stringify(totals)}`);
  assert.deepEqual(await contractTxs(), []);
  await install();
});

test('privilege 0 (every dApp): invoke data asking to re-run app code at privilege 1 is refused by the engine; none is made', { timeout: 5 * 60000 }, async () => {
  const r = await send(0, { privilege: 1 });
  console.log(`# privilege 0, data at 1: ${JSON.stringify({ policy: r.policy, error: r.error })}`);
  assert.equal(r.policy, 'privileged', 'the page check (policy.js) refuses the same bytes first; it was not asked here');
  refused(r, 'it asks for privilege 1, this app runs at 0');
  const r2 = await send(0, { privilege: 7 });
  refused(r2, 'it asks for privilege 7, this app runs at 0');
  assert.deepEqual(await contractTxs(), [], 'no transaction was made');
});

test('privilege 0: invoke data with its app stored at privilege 0 still works (a transaction id)', { timeout: 5 * 60000 }, async () => {
  const r = await send(0, { privilege: 0 });
  console.log(`# privilege 0, data at 0: ${JSON.stringify({ policy: r.policy, result: r.result })}`);
  assert.equal(r.policy, null, 'the page check lets it on');
  const txid = accepted(r);
  assert.ok((await contractTxs()).includes(txid));
});

test("privilege 1 (BEAM names' app): above 1, or app code it did not compile, is refused; data with no stored app works", { timeout: 5 * 60000 }, async () => {
  const before = await contractTxs();
  refused(await send(1, { privilege: 2 }), 'it asks for privilege 2, this app runs at 1');
  refused(await send(1, { privilege: 1 }), 'privilege 1 for app code this app did not compile');
  assert.deepEqual(await contractTxs(), before, 'no transaction was made');
  const r = await send(1, {});
  assert.equal(r.policy, null);
  const txid = accepted(r);
  const after = await contractTxs();
  assert.ok(after.includes(txid));
  assert.equal(after.length, before.length + 1);
});

test('every request reached the engine through its consent handler, and the page saw no error', async () => {
  const seen = await page.evaluate(() => window.__p73.seen.map((s) => ({ id: s.id, approved: s.approved })));
  assert.equal(seen.length, 6, JSON.stringify(seen));
  assert.ok(seen.every((s) => s.approved));
  assert.deepEqual(rec.errors, []);
});
