// BEAM names: the shader's name rules, argument builders, answer parsing and
// the checks on every built transaction, over recorded mainnet answers
// (test/beam/contracts/bans/fixtures, recorded with create_tx:false, nothing sent).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BANS_CID, args, nameProblem, normaliseName, parseName, tryName, describeNameProblem, usdPerPeriod, isKey, requireKey, fingerprint, checkCode, ZERO_KEY,
  parseMyKey, parseViewName, parseViewDomain, parseViewParams, refusal, mapError, isPrivilegeFailure, statusOf, STATUS, canRegister, canReceivePayments,
  holdEndHeight, expiryAfterRegister, expiryAfterExtend, maxExtendPeriods, priceEstimate, classifyRecipient, createBans, consentExpectation, BansError,
  HOLD_BLOCKS, BLOCKS_PER_PERIOD, dateOf, pinVerdict, nameMessage,
} from '../../src/lib/bans.js';
import { parseShaderJson, bindSession, unbindSession, nativeApp, setConsentPresenter } from '../../src/lib/contracts.js';
import { fakeEngine } from './helpers/fake_engine.mjs';
import { readContractTx, le, fromHex } from '../../src/lib/contract_tx.js';
import { VAULT_ANON_CID } from '../../src/lib/dapps/policy.js';
import { invokeEntry, invokeData, cid, FLAG_SAVE_APP_INVOKE } from './helpers/invoke_builder.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const envelope = (name) => JSON.parse(readFileSync(join(REPO, 'test', 'beam', 'contracts', 'bans', 'fixtures', `${name}.json`), 'utf8'));
const out = (name) => parseShaderJson(envelope(name).result.output);
const FAKE_KEY = '5a'.repeat(32) + '00';
const BEAM_OWNER = '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';
const VAULT = 'a3385e50cf33afc9f769ee1d82d56b73046d680d343977f36d9a303d7bcdc4da';
const TIP = 4068103;
const TXID = 'ee'.repeat(16);

test('names: the shader charset and lengths, the lenient door for typed text', () => {
  for (const n of ['beam', 'abc', 'a-b_c~1', '0xredbeard', 'a'.repeat(64)]) assert.equal(nameProblem(n), null, n);
  const cases = { '': 'empty', ab: 'tooShort', ['a'.repeat(65)]: 'tooLong', Beam: 'invalidCharacter', 'alice.beam': 'invalidCharacter', 'al ice': 'invalidCharacter', 'a,b=c': 'invalidCharacter', 'аlice': 'invalidCharacter', 'café': 'invalidCharacter' };
  for (const [input, problem] of Object.entries(cases)) {
    assert.equal(nameProblem(input), problem, input);
  }
  assert.equal(tryName('Beam'), 'beam', 'typed text is lower-cased first');
  assert.equal(tryName('alice.beam'), 'alice');
  assert.equal(tryName('café'), null);
  for (let c = 0; c < 256; c++) {
    const want = c === 0x5f || c === 0x2d || c === 0x7e || (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
    assert.equal(nameProblem(`aa${String.fromCharCode(c)}`) === null, want, `code unit ${c}`);
  }
  assert.equal(normaliseName('  Alice.BEAM '), 'alice');
  assert.equal(normaliseName('a.beam.beam'), 'a.beam');
  assert.equal(parseName('ALICE'), 'alice');
  assert.throws(() => parseName('Ålice'), (e) => e instanceof BansError && e.code === 'invalidName');
  assert.throws(() => parseName('ab.beam'), (e) => e.problem === 'tooShort' && e.message === 'Names need at least 3 characters.');
  assert.equal(describeNameProblem('invalidCharacter'), 'Use only lowercase letters, numbers, - _ and ~.');
  assert.deepEqual([3, 4, 5, 64].map(usdPerPeriod), [320, 120, 10, 10]);
});

test('keys: 33 bytes with a 00/01 parity byte, never the zero key; short forms', () => {
  assert.ok(isKey(BEAM_OWNER));
  assert.equal(requireKey(` ${BEAM_OWNER.toUpperCase()} `), BEAM_OWNER);
  for (const k of ['', BEAM_OWNER.slice(2), `${BEAM_OWNER}00`, `${BEAM_OWNER.slice(0, 64)}02`, `${'g'.repeat(64)}00`, ZERO_KEY]) assert.throws(() => requireKey(k), (e) => e.code === 'invalidKey', k);
  assert.equal(fingerprint(BEAM_OWNER), '72e3…51ef');
  assert.equal(checkCode(BEAM_OWNER), '72e3 68c0 … 570d 51ef');
});

test('argument builders: every argument the shader reads, nothing a name could smuggle in', () => {
  const cid = BANS_CID;
  assert.equal(args.myKey(), `role=user,action=my_key,cid=${cid}`);
  assert.equal(args.viewParams(), `role=manager,action=view_params,cid=${cid}`);
  assert.equal(args.viewName('alice'), `role=manager,action=view_name,cid=${cid},name=alice`);
  assert.equal(args.viewDomain(), `role=manager,action=view_domain,cid=${cid},pk=${ZERO_KEY}`);
  assert.equal(args.viewDomain(BEAM_OWNER), `role=manager,action=view_domain,cid=${cid},pk=${BEAM_OWNER}`);
  assert.equal(args.register('alice', 2), `role=user,action=domain_register,cid=${cid},name=alice,nPeriods=2`);
  assert.equal(args.extend('alice', 1), `role=user,action=domain_extend,cid=${cid},name=alice,nPeriods=1`);
  assert.equal(args.sendAnon(BEAM_OWNER, 'alice', 0, 12345n), `role=user,action=send_anon,cid=${VAULT_ANON_CID},pkOwner=${BEAM_OWNER},aid=0,amount=12345,msg=616c696365${'00'.repeat(59)}`);
  assert.equal(nameMessage('a'.repeat(64)), '61'.repeat(64));
  assert.throws(() => args.register('alice', 0), RangeError);
  assert.throws(() => args.register('alice', 51), RangeError);
  assert.throws(() => args.extend('alice', -1), RangeError);
  assert.throws(() => args.sendAnon(BEAM_OWNER, 'alice', 0, 0n), RangeError);
  assert.throws(() => args.sendAnon(BEAM_OWNER, 'alice', -1, 1n), RangeError);
  assert.throws(() => args.sendAnon(BEAM_OWNER, 'alice', 0x100000000, 1n), RangeError);
  assert.throws(() => args.sendAnon(BEAM_OWNER, 'alice', 0, 1n << 64n), RangeError);
  assert.throws(() => args.sendAnon(ZERO_KEY, 'alice', 0, 1n), (e) => e.code === 'invalidKey');
  assert.throws(() => args.sendAnon(`${BEAM_OWNER},cid=${'00'.repeat(32)}`, 'alice', 0, 1n), (e) => e.code === 'invalidKey');
  assert.throws(() => args.sendAnon(BEAM_OWNER, 'a,b=c', 0, 1n), (e) => e.code === 'invalidName');
  assert.throws(() => args.viewName('a,b=c'), (e) => e.code === 'invalidName');
  assert.throws(() => args.register('alice,nPeriods=50', 1), (e) => e.code === 'invalidName');
});

test('answers: my key, a name, a list of names, the price feed (recorded)', () => {
  assert.equal(parseMyKey(out('my_key')), FAKE_KEY);
  const beam = parseViewName(out('view_name_beam'), 'beam');
  assert.deepEqual(beam, { name: 'beam', ownerKey: BEAM_OWNER, expireHeight: 4918184, salePrice: null });
  assert.equal(parseViewName(out('view_name_free'), 'zzzzz'), null);
  const listed = parseViewName(out('view_name_listed'), 'nephrite');
  assert.deepEqual(listed.salePrice, { assetId: 0, amount: 10000000000000n });
  assert.deepEqual(parseViewDomain(out('view_domain_pk')).map((d) => d.name), ['amir', 'beam', 'foundation']);
  const p = parseViewParams(out('view_params'));
  assert.equal(p.vaultCid, VAULT);
  assert.equal(p.daoVaultCid, '0066b12078623df132b691001b25d7eb94b207b42c018020c9e58152e21ecd25');
  assert.equal(p.usdPerBeamText, '0.00860');
  assert.equal(p.activationHeight, 1896111);
  // Malformed answers are refused, never guessed at.
  assert.throws(() => parseViewName({ res: { key: 'nope', hExpire: 1 } }, 'x'), (e) => e.code === 'unexpected');
  assert.throws(() => parseViewName({ res: { key: BEAM_OWNER, hExpire: -1 } }, 'x'), (e) => e.code === 'unexpected');
  assert.throws(() => parseViewDomain({ domains: [{ key: BEAM_OWNER, hExpire: 1 }] }), (e) => e.code === 'unexpected');
  assert.throws(() => parseViewParams({ res: { vault: 'x' } }), (e) => e.code === 'unexpected');
  assert.throws(() => parseViewParams({ res: { ...out('view_params').res, price: 0.0086 } }), (e) => e.code === 'unexpected');
});

test('shader refusals and the privilege failure become plain words', () => {
  const taken = mapError(Object.assign(new Error(parseShaderJson(envelope('register_taken').result.output).error), { code: 'shader' }));
  assert.equal(taken.refusal, 'ownedByOther');
  assert.equal(refusal('validity period too long').message, 'A name can be paid for at most 50 years ahead. Choose fewer years.');
  assert.equal(refusal('price feed unavailable').refusal, 'priceFeedUnavailable');
  assert.match(refusal('state not found').message, /could not do that \(state not found\)/);
  assert.ok(isPrivilegeFailure(envelope('receive_all').error));
  assert.equal(isPrivilegeFailure({ code: -32019, message: 'Contract call failed', data: 'Error: x' }), false);
  assert.equal(mapError(Object.assign(new Error('x'), { code: 'rpc', rpc: envelope('user_view').error })).code, 'claimUnsupported');
});

test('time: status at the next block, the 90-day hold, renewal limits', () => {
  assert.equal(statusOf({ expireHeight: 4918184, tipHeight: TIP }), STATUS.active);
  assert.equal(statusOf({ expireHeight: 4524205, tipHeight: TIP, listed: true }), STATUS.forSale);
  assert.equal(statusOf({ expireHeight: 3998572, tipHeight: TIP }), STATUS.onHold);
  assert.equal(statusOf({ expireHeight: TIP + 1, tipHeight: TIP }), STATUS.onHold, 'expiring at the next block');
  assert.equal(statusOf({ expireHeight: TIP + 1 - HOLD_BLOCKS, tipHeight: TIP }), STATUS.availableAgain);
  assert.ok(canRegister(STATUS.available) && canRegister(STATUS.availableAgain) && !canRegister(STATUS.onHold));
  assert.ok(canReceivePayments(STATUS.onHold) && !canReceivePayments(STATUS.availableAgain));
  assert.equal(holdEndHeight(100), 100 + HOLD_BLOCKS);
  assert.equal(expiryAfterRegister({ tipHeight: TIP, periods: 1 }), TIP + 1 + BLOCKS_PER_PERIOD);
  assert.equal(expiryAfterExtend({ expireHeight: TIP + 10, tipHeight: TIP, periods: 2 }), TIP + 10 + 2 * BLOCKS_PER_PERIOD);
  assert.equal(expiryAfterExtend({ expireHeight: 5, tipHeight: TIP, periods: 1 }), TIP + 1 + BLOCKS_PER_PERIOD);
  assert.equal(maxExtendPeriods({ expireHeight: TIP + 1, tipHeight: TIP }), 50);
  assert.equal(maxExtendPeriods({ expireHeight: TIP + 1 + 49 * BLOCKS_PER_PERIOD, tipHeight: TIP }), 1);
  assert.equal(maxExtendPeriods({ expireHeight: TIP + 1 + 50 * BLOCKS_PER_PERIOD, tipHeight: TIP }), 0);
  assert.equal(dateOf(TIP + 60, { tipHeight: TIP, tipTime: 1000 }), (1000 + 3600) * 1000);
});

test('price: a range from the truncated median that contains what the kernel charged', () => {
  const e = priceEstimate({ usdPerPeriod: 10, periods: 1, medianText: '0.00860' });
  assert.equal(e.maxGroth, 116279069767n);
  assert.equal(e.minGroth, 116144018583n);
  const charged = readContractTx(envelope('register5').result.raw_data).spend.get(0);
  assert.ok(charged >= e.minGroth && charged <= e.maxGroth, `${charged} within the estimate`);
  assert.equal(priceEstimate({ usdPerPeriod: 120, periods: 2, medianText: '0.00860' }).usdTotal, 240);
  for (const bad of [null, '', '0', '0.00000', '-1', 'abc']) assert.throws(() => priceEstimate({ usdPerPeriod: 10, periods: 1, medianText: bad }), (x) => x.refusal === 'priceFeedUnavailable');
});

test('the Send field: an address always wins, a name otherwise, and why not', () => {
  const hexAddr = '3f25d94eac4a95f4ff2b764f844aa588254982c6bcc83e02f157218d698c9df9477';
  assert.deepEqual(classifyRecipient(hexAddr), { kind: 'address' });
  assert.deepEqual(classifyRecipient('a'.repeat(64)), { kind: 'address' }, 'a 64-hex string is an address, not a name');
  assert.deepEqual(classifyRecipient('x'.repeat(200)), { kind: 'address' });
  assert.deepEqual(classifyRecipient(' Alice.beam '), { kind: 'name', name: 'alice' });
  assert.deepEqual(classifyRecipient('@bob'), { kind: 'name', name: 'bob' });
  assert.deepEqual(classifyRecipient(''), { kind: 'empty' });
  assert.deepEqual(classifyRecipient('ab'), { kind: 'invalid', problem: 'tooShort' });
  assert.deepEqual(classifyRecipient('hi there'), { kind: 'invalid', problem: 'invalidCharacter' });
});

// ---------------------------------------------------------------- the service over a fake engine

/**
 * A stand-in for App.view / App.transact: answers by action (and name) from the
 * recordings, runs inspect on the built bytes as lib/contracts.js does (a copy
 * as a Uint8Array and the parsed output; a truthy answer or a throw refuses,
 * reported as 'unexpected'), then shows expect the consent request the engine
 * would report (or the one `consent` makes up).
 */
function fakeDeps(answers, { consent = null, status = { current_height: TIP, current_state_timestamp: 1791276300, is_in_sync: true } } = {}) {
  const calls = [];
  const pick = (a) => {
    const action = /action=([a-z_]+)/.exec(a)[1];
    const name = /name=([^,]*)/.exec(a)?.[1];
    calls.push(action);
    const reply = answers[`${action}:${name}`] ?? answers[action];
    if (reply == null) throw new Error(`no fixture for ${a}`);
    return typeof reply === 'string' ? envelope(reply).result : reply;
  };
  const shaderErr = (o) => {
    if (o && typeof o === 'object' && 'error' in o) throw Object.assign(new Error(String(o.error)), { code: 'shader' });
    return o;
  };
  const deps = {
    calls,
    view: async (a) => shaderErr(parseShaderJson(pick(a).output || '{}')),
    transact: async (a, { inspect, expect }) => {
      const r = pick(a);
      const output = shaderErr(parseShaderJson(r.output || '{}'));
      let problem = null;
      try {
        problem = await inspect(Uint8Array.from(r.raw_data), output);
      } catch (e) {
        throw Object.assign(new Error(e.message), { code: 'unexpected' });
      }
      if (problem) throw Object.assign(new Error(problem.message || String(problem)), { code: problem.code || 'refused' });
      const d = readContractTx(r.raw_data);
      const req = consent
        ? consent(d)
        : { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
      const refusal = expect(req);
      if (refusal) throw Object.assign(new Error(refusal.message), { code: refusal.code });
      calls.push('signed');
      return TXID;
    },
    status: async () => status,
  };
  // Payments to a name: the Anon-Vault app shader in the app, the same recorded answers here.
  deps.transactVault = (a, o) => deps.transact(a, o);
  return deps;
}

const params = out('view_params');
const estimate5 = priceEstimate({ usdPerPeriod: 10, periods: 1, medianText: params.res.price });

test('resolve and my names read the wallet\'s own node', async () => {
  const deps = fakeDeps({ 'view_name:beam': 'view_name_beam', 'view_name:beamer': 'view_name_hold', view_name: 'view_name_free', my_key: 'my_key', view_domain: 'view_domain_pk' });
  const bans = createBans(deps);
  const r = await bans.resolve('beam');
  assert.equal(r.ownerKey, BEAM_OWNER);
  assert.equal(r.status, STATUS.active);
  assert.equal(r.tipHeight, TIP);
  assert.equal(r.inSync, true);
  assert.equal((await bans.resolve('zzzzz')).status, STATUS.available);
  assert.equal((await bans.resolve('beamer')).status, STATUS.onHold);
  const mine = await bans.myNames();
  assert.equal(mine.key, FAKE_KEY);
  assert.deepEqual(mine.names.map((d) => d.name), ['amir', 'beam', 'foundation']);
  await bans.myNames();
  assert.deepEqual(deps.calls.filter((c) => c === 'my_key' || c === 'view_domain'), ['my_key', 'view_domain', 'view_domain'], 'the key is read once');
});

test('register: the kernel must register this name, these years, to this wallet, for about the price shown', async () => {
  const name = 'cfbac2de77099';
  let deps = fakeDeps({ my_key: 'my_key', domain_register: 'register5' });
  const r = await createBans(deps).register(name, 1, { estimate: estimate5 });
  assert.equal(r.txId, TXID);
  assert.equal(r.pay, 116213166091n);
  assert.equal(r.fee, 1100000n);

  // The core answers a register with a payment kernel.
  deps = fakeDeps({ my_key: 'my_key', domain_register: 'pay_beam' });
  await assert.rejects(createBans(deps).register(name, 1, { estimate: estimate5 }), (e) => e.code === 'unexpected');
  assert.ok(!deps.calls.includes('signed'));
  // The right kernel for another name, or other years.
  deps = fakeDeps({ my_key: 'my_key', domain_register: 'register5' });
  await assert.rejects(createBans(deps).register('someoneelse', 1, { estimate: estimate5 }), (e) => e.code === 'unexpected');
  await assert.rejects(createBans(deps).register(name, 2, { estimate: estimate5 }), (e) => e.code === 'unexpected');
  // Registered to another key.
  deps = fakeDeps({ my_key: { output: `{"res": {"key": "${BEAM_OWNER}"}}` }, domain_register: 'register5' });
  await assert.rejects(createBans(deps).register(name, 1, { estimate: estimate5 }), (e) => e.code === 'unexpected');
  // A price far above the estimate shown is refused before signing.
  const cheap = priceEstimate({ usdPerPeriod: 10, periods: 1, medianText: '0.0100' });
  deps = fakeDeps({ my_key: 'my_key', domain_register: 'register5' });
  await assert.rejects(createBans(deps).register(name, 1, { estimate: cheap }), (e) => e.code === 'priceMoved');
  assert.ok(!deps.calls.includes('signed'));
  // A taken name: the shader's refusal, in words.
  deps = fakeDeps({ my_key: 'my_key', domain_register: 'register_taken' });
  await assert.rejects(createBans(deps).register('beam', 1, { estimate: estimate5 }), (e) => e.refusal === 'ownedByOther');
});

test('register: an approve sheet that differs from the built kernel is refused unseen', async () => {
  const name = 'cfbac2de77099';
  const variants = {
    'more BEAM': (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) + 1n }], receives: [], fee: d.fee }),
    'another fee': (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) }], receives: [], fee: d.fee + 1n }),
    'an extra asset': (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) }, { assetId: 7, amount: 1n }], receives: [], fee: d.fee }),
    'something received': (d) => ({ kind: 'contract', spends: [{ assetId: 0, amount: d.pays.get(0) }], receives: [{ assetId: 174, amount: 1n }], fee: d.fee }),
    'a plain payment': (d) => ({ kind: 'send', spends: [{ assetId: 0, amount: d.pays.get(0) }], receives: [], fee: d.fee }),
  };
  for (const [what, consent] of Object.entries(variants)) {
    const deps = fakeDeps({ my_key: 'my_key', domain_register: 'register5' }, { consent });
    await assert.rejects(createBans(deps).register(name, 1, { estimate: estimate5 }), (e) => e.code === 'unexpected', what);
    assert.ok(!deps.calls.includes('signed'), what);
  }
  assert.equal(consentExpectation(() => null)({ kind: 'contract', spends: [], receives: [], fee: 0n }).code, 'unexpected', 'nothing built, nothing approved');
});

// pay_beam is what BANS's pay built for 12345 groth to beam.beam (create_tx:false, nothing sent). The vault
// app's send_anon builds the same deposit (both call vault_anon/app_impl.h OnUser_send_anon with the name
// zero-padded to 64 bytes); only the random sender key differs.
test('pay a name: resolved before and after the build, the kernel pays exactly the amount into the vault', async () => {
  const answers = { view_name: 'view_name_beam', send_anon: 'pay_beam' };
  let deps = fakeDeps(answers);
  const r = await createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: BEAM_OWNER });
  assert.equal(r.ownerKey, BEAM_OWNER);
  assert.equal(r.fee, 1100000n);
  assert.deepEqual(deps.calls, ['view_name', 'send_anon', 'view_name', 'signed']);
  // Another amount than the request.
  deps = fakeDeps(answers);
  await assert.rejects(createBans(deps).pay('beam', 0, 99999n), (e) => e.code === 'unexpected');
  // A key the person was not shown: stops before anything is built.
  deps = fakeDeps(answers);
  await assert.rejects(createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: FAKE_KEY }), (e) => e.code === 'ownerChanged');
  assert.ok(!deps.calls.includes('send_anon'));
  // The owner changes between the build and the check after it.
  let n = 0;
  deps = fakeDeps({ ...answers, view_name: null });
  deps.view = async (a) => {
    if (/view_params/.test(a)) return out('view_params');
    n++;
    return n === 1 ? out('view_name_beam') : { res: { key: FAKE_KEY, hExpire: 4918184 } };
  };
  await assert.rejects(createBans(deps).pay('beam', 0, 12345n), (e) => e.code === 'ownerChanged');
  assert.ok(!deps.calls.includes('signed'));
  // Unregistered and long-expired names are not paid.
  deps = fakeDeps({ view_name: 'view_name_free' });
  await assert.rejects(createBans(deps).pay('zzzzz', 0, 1n), (e) => e.refusal === 'notRegistered');
  deps = fakeDeps({ view_name: { output: `{"res": {"key": "${BEAM_OWNER}","hExpire": 100}}` } });
  await assert.rejects(createBans(deps).pay('old', 0, 1n), (e) => e.refusal === 'domainExpired');
});

// ------------------------------------------------------------ a node that lies about a name (audit D-1)

const ATTACKER_CID = cid(0xa7);
const ATTACKER_KEY = '9c'.repeat(32) + '01';
const SENDER_AND_NAME = new Array(97).fill(5);
/** What the BANS shader builds for a payment, aimed at `contractId` (vault_anon Method::Deposit). */
const depositTo = (contractId, amount, aid = 0) =>
  invokeData([invokeEntry({ contractId, method: 2, args: [...le(amount, 8), ...le(97, 4), ...fromHex('4f'.repeat(32) + '00'), ...le(aid, 4), ...SENDER_AND_NAME], comment: 'vault_anon send anon', spend: { [aid]: amount } })]);
const forgedParams = { output: JSON.stringify({ res: { ...params.res, vault: ATTACKER_CID } }) };

test('pay a name: into BEAM\'s own vault whatever the node says the vault is; a build into any other contract is refused (audit D-1)', async () => {
  assert.equal(VAULT, VAULT_ANON_CID, 'the vault the dApp policy pins is the one view_params answers on mainnet');
  // A node whose view_params names the attacker's contract: the payment never asks it; it goes to the pinned vault.
  let deps = fakeDeps({ view_params: forgedParams, view_name: 'view_name_beam', send_anon: 'pay_beam' });
  assert.equal((await createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: BEAM_OWNER })).txId, TXID);
  assert.ok(!deps.calls.includes('view_params'));
  assert.throws(() => parseViewParams(JSON.parse(forgedParams.output)), (e) => e.code === 'wrongVault' && /not BEAM's own/.test(e.message));
  // Whatever comes back must be one plain deposit into the vault: another contract, a second call, a
  // signature asked of this wallet, stored app code, other funds or another message size are refused unsigned.
  const vaultEntry = (o = {}) => invokeEntry({ contractId: VAULT, method: 2, args: [...le(12345, 8), ...le(97, 4), ...fromHex('4f'.repeat(32) + '00'), ...le(0, 4), ...fromHex('8b'.repeat(32) + '00'), ...new Array(64).fill(5)], comment: 'vault_anon send anon', spend: { 0: 12345 }, ...o });
  const bad = {
    'another contract': depositTo(ATTACKER_CID, 12345),
    'two calls': invokeData([vaultEntry(), vaultEntry()]),
    'a withdrawal': invokeData([vaultEntry({ method: 3, spend: { 0: -12345 } })]),
    'a signature': invokeData([vaultEntry({ sigs: ['11'.repeat(32)] })]),
    'stored app code': invokeData([vaultEntry({ flags: FLAG_SAVE_APP_INVOKE })], { firstFlags: FLAG_SAVE_APP_INVOKE }),
    'more BEAM than the amount': invokeData([vaultEntry({ spend: { 0: 12346 } })]),
    'another asset': invokeData([vaultEntry({ spend: { 0: 12345, 174: 1 } })]),
    'another comment': invokeData([vaultEntry({ comment: 'vault_anon send to code' })]),
    'no message': invokeData([invokeEntry({ contractId: VAULT, method: 2, args: [...le(12345, 8), ...le(0, 4), ...fromHex('4f'.repeat(32) + '00'), ...le(0, 4)], comment: 'vault_anon send anon', spend: { 0: 12345 } })]),
  };
  for (const [what, raw] of Object.entries(bad)) {
    deps = fakeDeps({ view_name: 'view_name_beam', send_anon: { output: '{}', raw_data: raw } });
    await assert.rejects(createBans(deps).pay('beam', 0, 12345n), (e) => e.code === 'unexpected', what);
    assert.ok(!deps.calls.includes('signed'), what);
  }
  // The same plain deposit goes through.
  deps = fakeDeps({ view_name: 'view_name_beam', send_anon: { output: '{}', raw_data: invokeData([vaultEntry()]) } });
  assert.equal((await createBans(deps).pay('beam', 0, 12345n)).txId, TXID);
  // Claims are built by the BANS shader from the node's settings: from the real vault only.
  deps = fakeDeps({ view_params: forgedParams, my_key: 'my_key' });
  deps.transactPrivileged = deps.transact;
  await assert.rejects(createBans(deps).claimAll(), (e) => e.code === 'wrongVault');
  assert.ok(!deps.calls.includes('signed'));
});

test('pay a name: an owner key different from the one this wallet paid before stops, until the person picks the new one', async () => {
  const lying = { view_name: { output: `{"res": {"key": "${ATTACKER_KEY}","hExpire": 4918184}}` }, send_anon: 'pay_beam' };
  // Paid before to BEAM_OWNER; the node now says the attacker owns beam: nothing is built.
  let deps = fakeDeps(lying);
  await assert.rejects(createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: ATTACKER_KEY, pinnedKey: BEAM_OWNER }), (e) => e.code === 'nameChanged' && e.before === BEAM_OWNER && e.now === ATTACKER_KEY);
  assert.ok(!deps.calls.includes('send_anon'));
  // The person saw both keys and chose the new owner: it goes ahead, to exactly that key.
  deps = fakeDeps(lying);
  assert.equal((await createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: ATTACKER_KEY, pinnedKey: BEAM_OWNER, acceptedKey: ATTACKER_KEY })).ownerKey, ATTACKER_KEY);
  // Accepting one new key is not accepting any: a third one stops again.
  deps = fakeDeps({ ...lying, view_name: { output: `{"res": {"key": "${FAKE_KEY}","hExpire": 4918184}}` } });
  await assert.rejects(createBans(deps).pay('beam', 0, 12345n, { pinnedKey: BEAM_OWNER, acceptedKey: ATTACKER_KEY }), (e) => e.code === 'nameChanged' && e.now === FAKE_KEY);
  // The same owner as before, or a first payment: no question.
  deps = fakeDeps({ view_name: 'view_name_beam', send_anon: 'pay_beam' });
  assert.equal((await createBans(deps).pay('beam', 0, 12345n, { pinnedKey: BEAM_OWNER })).ownerKey, BEAM_OWNER);
  // What Send asks before Review.
  assert.equal(pinVerdict({ pinned: null, now: BEAM_OWNER }), 'first');
  assert.equal(pinVerdict({ pinned: BEAM_OWNER, now: BEAM_OWNER }), 'same');
  assert.equal(pinVerdict({ pinned: BEAM_OWNER, now: ATTACKER_KEY }), 'changed');
  assert.equal(pinVerdict({ pinned: BEAM_OWNER, now: ATTACKER_KEY, accepted: ATTACKER_KEY }), 'accepted');
  assert.equal(pinVerdict({ pinned: BEAM_OWNER, now: FAKE_KEY, accepted: ATTACKER_KEY }), 'changed');
});

/** "beam" as the payment's message: the name's bytes, zero-padded to 64 (what BANS pay writes, bans/app.cpp). */
const BEAM_MSG = `6265616d${'00'.repeat(60)}`;

test("pay a name: built by BEAM's vault app from the owner key the wallet checked, never re-read from the node during the build (audit D-1)", async () => {
  // A node that answers view_name honestly, and gives the attacker's key to any read made while a payment is built.
  const builds = [];
  const deps = fakeDeps({ view_name: 'view_name_beam', pay: 'pay_beam', send_anon: 'pay_beam' });
  const wrap = (shader, run) => async (a, opts) => {
    const action = /action=([a-z_]+)/.exec(a)[1];
    // Whom the deposit goes to, as each shader's source decides it: BANS `manager pay` reads the owner from the
    // node while it builds (bans/app.cpp ON_METHOD(manager, pay): dn.ReadFromName, then OnUser_send_anon with
    // d.m_pkOwner); vault_anon `user send_anon` takes it as its pkOwner argument and reads nothing (vault_anon/app.cpp).
    const to = shader === 'vaultAnon' ? (/pkOwner=([0-9a-f]+)/.exec(a) || [])[1] : action === 'pay' ? ATTACKER_KEY : null;
    builds.push({ shader, action, to, args: a });
    return run(a, opts);
  };
  const fake = deps.transact;
  deps.transact = wrap('bans', fake);
  deps.transactVault = wrap('vaultAnon', fake);
  const r = await createBans(deps).pay('beam', 0, 12345n, { expectedOwnerKey: BEAM_OWNER });
  assert.equal(r.txId, TXID);
  assert.deepEqual(
    builds.map((b) => [b.shader, b.action, b.to]),
    [['vaultAnon', 'send_anon', BEAM_OWNER]],
    'one build, by the vault app, to the key the wallet checked',
  );
  assert.equal(builds[0].args, `role=user,action=send_anon,cid=${VAULT_ANON_CID},pkOwner=${BEAM_OWNER},aid=0,amount=12345,msg=${BEAM_MSG}`);
});

test('renew: only my own name, within 50 years of the next block', async () => {
  const mine = { output: `{"res": {"key": "${FAKE_KEY}","hExpire": ${TIP + 1000}}}` };
  const deps = fakeDeps({ my_key: 'my_key', view_name: mine, domain_extend: { output: '{}', raw_data: null } });
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_beam' })).extend('beam', 1), (e) => e.refusal === 'ownedByOther');
  await assert.rejects(createBans(fakeDeps({ my_key: 'my_key', view_name: 'view_name_free' })).extend('zzzzz', 1), (e) => e.refusal === 'notRegistered');
  await assert.rejects(createBans(deps).extend('mine', 50), (e) => e.refusal === 'periodTooLong');
  // The register kernel answered to a renew is refused.
  const wrong = fakeDeps({ my_key: 'my_key', view_name: mine, domain_extend: 'register5' });
  await assert.rejects(createBans(wrong).extend('mine', 1), (e) => e.code === 'unexpected');
});

test('through lib/contracts.js: inspect reads the built bytes, a refusal keeps its own code, the sheet gets the intent', async () => {
  const engine = fakeEngine({
    respond: (req, api) => {
      if (req.method === 'invoke_contract') return api.reply(req.id, envelope(/action=my_key/.test(req.params.args) ? 'my_key' : 'register5').result);
      if (req.method === 'process_invoke_data') return engine.askContract(api, req, { comment: 'BANS: registering domain', fee: '0.011', isEnough: false, isSpend: true }, [{ amount: '1162.13166091', assetID: 0, spend: true }]);
      return api.reply(req.id, {});
    },
  });
  bindSession(engine.session);
  const shown = [];
  const unset = setConsentPresenter(async (req) => {
    shown.push(req);
    return false;
  });
  try {
    const app = await nativeApp();
    const bans = createBans({ view: (a) => app.view(a, [0]), transact: (a, o) => app.transact(a, [0], o), status: async () => ({ current_height: TIP, is_in_sync: true }) });
    const cheap = priceEstimate({ usdPerPeriod: 10, periods: 1, medianText: '0.0100' });
    await assert.rejects(bans.register('cfbac2de77099', 1, { estimate: cheap }), (e) => e.code === 'priceMoved');
    assert.equal(shown.length, 0, 'refused before the engine is asked to sign');
    await assert.rejects(bans.register('cfbac2de77099', 1, { estimate: estimate5 }), (e) => e.code === 'rejected');
    assert.equal(shown.length, 1);
    assert.deepEqual(shown[0].intent, { action: 'nameRegister', name: 'cfbac2de77099', periods: 1 });
    assert.equal(shown[0].isEnough, false);
    assert.deepEqual(engine.answers, ['rejected']);
  } finally {
    unset();
    unbindSession();
  }
});
