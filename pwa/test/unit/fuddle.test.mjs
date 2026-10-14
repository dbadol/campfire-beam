// Fuddle v9 (lib/fuddle.js): the gate while the contract is not deployed, the pinned app shader,
// network fees from the declared charges, argument strings and argument bytes, every parser on the
// app shader's real answers, the money (entry, letters, refunds, the final payout), the time-limit
// wording, and every built transaction checked byte for byte, tampered ones never signed.
//
// The answers and transactions are REAL: test/fixtures/fuddle9_sim.json was written by
// test/fixtures/fuddle9_sim.py, which runs the v9 contract.wasm and app.wasm (Fuddle 8e86b3140, app
// sha256 52067c77…) in BEAM 7.5.14493's own BVM through the answer service's simulator bridge; each
// build there was submitted and accepted by the contract. Its words are made-up test strings.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  METHOD, CHARGE, KERNEL, ARGS_SIZE, NO_EVICT, FEES, GAME, VERDICT,
  feeForCharge, firstGuessBlocks, minGameBlocks, scoreOf, lengthsOf, mulDiv, lettersOf, cleanGuess, missingLetters, hintMarks, feedbackFor, letterStates,
  fuddleArgs, encodeArgs, parseMyKey, parseState, parseTournament, parseTournaments, parseTournamentView, parseMyTournament, parseMyGames, parseGame, parseClaimable, parseAnswerer,
  fundsOf, entryCost, guessCost, refundOf, payoutOf, percentText, blocksText, rulesBeforeEntering, gameClock, clockText, gameOutcome, failedReason,
  shaderCodeFor, mapFuddleError, checkBuilt, consentMatches, createFuddle, fuddleFor, fuddleLock, FuddleError,
} from '../../src/lib/fuddle.js';
import { FUDDLE_CID, FUDDLE_SERVICE_PK, fuddleLive } from '../../src/lib/fuddle_id.js';
import { SHADERS } from '../../src/lib/shaders.js';
import { entryFee, readContractTx, fromHex, toHex } from '../../src/lib/contract_tx.js';
import { parseShaderJson } from '../../src/lib/contracts.js';
import { keyHashOf, reservedUseOfKeyMaterial } from '../../src/lib/dapps/policy.js';
import { invokeData, invokeEntry } from './helpers/invoke_builder.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const REPO = join(here, '..', '..', '..');
const FX = JSON.parse(readFileSync(join(here, '..', 'fixtures', 'fuddle9_sim.json'), 'utf8'));
const CID = FX.cid;
const ALICE = FX.players.alice;
const BOB = FX.players.bob;
const out = (name) => parseShaderJson(FX.views[name].output);
const built = (name) => fromHex(FX.builds[name].raw);
const argsOf = (s) => Object.fromEntries(s.split(',').map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
const fundsMap = (pays) => new Map(Object.entries(pays).map(([k, v]) => [Number(k), BigInt(v)]));
const TB = FX.games.tb;
const TK = FX.games.tk;

// ---------------------------------------------------------------- facts

test('not deployed yet: no contract id, so nothing is live and no service is built', () => {
  assert.equal(FUDDLE_CID, null, 'Fuddle v9 is not deployed: FUDDLE_CID stays null until the owner deploys it');
  assert.equal(FUDDLE_SERVICE_PK, null);
  assert.equal(fuddleLive(), false);
  assert.equal(fuddleFor({ client: {} }), null, 'the screens get no service: they say "Fuddle opens soon"');
  assert.throws(() => createFuddle({ cid: null, view: async () => ({}), transact: async () => '' }), RangeError);
  assert.throws(() => fuddleArgs.viewState(null), RangeError, 'no call can be built without the id');
  assert.equal(fuddleLive(CID), true);
  assert.equal(fuddleLive(CID.toUpperCase()), false, 'the id is lower-case hex, as every other contract id here');
  // The app's Dart constant says the same.
  const dart = readFileSync(join(REPO, 'lib', 'wallets', 'beam', 'contracts', 'fuddle', 'fuddle_constants.dart'), 'utf8');
  assert.match(dart, /const String\? kFuddleContractId = null;/);
});

test('deployment checklist: once the id is set, the Dart constant and the dApp policy must follow', async () => {
  if (FUDDLE_CID === null) return; // nothing to check before deployment
  const dart = readFileSync(join(REPO, 'lib', 'wallets', 'beam', 'contracts', 'fuddle', 'fuddle_constants.dart'), 'utf8');
  assert.ok(dart.includes(`'${FUDDLE_CID}'`), 'fuddle_constants.dart names the same contract id');
  assert.match(String(FUDDLE_SERVICE_PK), /^[0-9a-f]{64}0[01]$/, 'the answer service key is set with the id');
  // The player key is {cid, 0}: no dApp may sign with it (lib/dapps/policy.js RESERVED_KEYS).
  assert.ok(await reservedUseOfKeyMaterial(`${FUDDLE_CID}00`), 'the Fuddle player key is a reserved key');
});

test('the app shader is pinned as the v9 README states, in both apps', () => {
  assert.equal(SHADERS.fuddle.file, 'fuddle_app.wasm');
  assert.equal(SHADERS.fuddle.sha256, '52067c773a6f91b8eaadd892b133ccbf131f6df4a1c7d12b7305ff725f724e62');
  assert.equal(SHADERS.fuddle.size, 59518);
  assert.equal(FX.app_sha256, SHADERS.fuddle.sha256, 'the fixtures were made with the pinned shader');
  const bytes = readFileSync(join(REPO, 'assets', 'beam', 'shaders', 'fuddle_app.wasm'));
  assert.equal(createHash('sha256').update(bytes).digest('hex'), SHADERS.fuddle.sha256);
  assert.equal(bytes.length, SHADERS.fuddle.size);
  assert.deepEqual(METHOD, { enterGame: 9, buyLetters: 10, submitGuess: 11, claimTimeout: 14, finalize: 15, claim: 16, claimRefund: 21 });
});

test('network fees: the README table, the core fee rule, and every real build', () => {
  // v9 README "Methods": max(10 groth x charge, 0.01 BEAM) + 0.001 BEAM.
  assert.equal(FEES.enterGame, 2300000n);
  assert.equal(FEES.enterGameEvict, 3250000n);
  assert.equal(FEES.buyLetters, 1630000n);
  assert.equal(FEES.submitGuess, 1660000n);
  assert.equal(FEES.claimTimeout, 2250000n);
  assert.equal(FEES.finalize, 1120000n);
  assert.equal(FEES.claim, 1420000n);
  assert.equal(FEES.claimRefund, 1890000n);
  assert.equal(feeForCharge(50000), 1100000n, 'never below 0.011 BEAM');
  for (const [k, charge] of Object.entries(CHARGE)) {
    const size = ARGS_SIZE[k === 'enterGameEvict' ? 'enterGame' : k];
    for (const spendAssets of [[0], [7, 0], [7]]) assert.equal(FEES[k], entryFee({ argsBytes: size, spendAssets, charge }), `${k} ${spendAssets}`);
  }
  for (const [name, b] of Object.entries(FX.builds)) {
    const d = readContractTx(built(name));
    assert.equal(d.entries[0].charge, b.tx.charge, name);
    assert.equal(d.fee, BigInt(b.tx.fee), `${name}: the fee the simulator charged`);
    assert.equal(d.fee, feeForCharge(b.tx.charge), name);
  }
});

test('clocks and scores: contract.h formulas', () => {
  assert.equal(firstGuessBlocks(20), 40);
  assert.equal(firstGuessBlocks(30), 60);
  assert.equal(firstGuessBlocks(120), 60);
  assert.equal(minGameBlocks(20), 440, 'README: 440 with a 20-block window');
  assert.equal(minGameBlocks(120), 960, 'README: 960 with 120');
  // (1000 + (7 - attempts) x 150) x mult / 100
  assert.equal(scoreOf(4, 1), 1900);
  assert.equal(scoreOf(5, 3), 2000);
  assert.equal(scoreOf(6, 6), 1725);
  assert.equal(scoreOf(5, 0), 0);
  assert.equal(scoreOf(5, 7), 0);
  assert.deepEqual(lengthsOf(7), [4, 5, 6]);
  assert.deepEqual(lengthsOf(2), [5]);
  assert.equal(mulDiv(385410000n, 2000n, 3750n), 205552000n);
  assert.equal(mulDiv(2n ** 63n, 2n ** 63n, 2n ** 63n), 2n ** 63n, 'no overflow');
});

// ---------------------------------------------------------------- letters and hints

test('letters: a..z only; a guess field keeps letters, lower case, at most the word length', () => {
  assert.deepEqual(lettersOf('Crane'), [2, 17, 0, 13, 4]);
  for (const bad of ['cr4ne', 'cr ne', 'crañe', 'a,b', 'a=b']) assert.throws(() => lettersOf(bad), RangeError, bad);
  assert.equal(cleanGuess(' Cr,a=n e7!', 5), 'crane');
  assert.equal(cleanGuess('abcdefgh', 6), 'abcdef');
});

test('missing letters: each position spends one of the stock, as the contract counts', () => {
  const stock = new Array(26).fill(0);
  stock[16] = 2; // q
  stock[23] = 1; // x
  stock[25] = 1; // z
  stock[1] = 1; // b
  // The real build: "qxzcd" after buying "qxzbq" pays 2 letters (c, d).
  assert.equal(missingLetters(stock, 'qxzcd'), 2);
  assert.equal(missingLetters(stock, 'qqqqq'), 3, 'two q in stock, three bought');
  assert.equal(missingLetters(stock, 'bqxzq'), 0);
  assert.equal(missingLetters(new Array(26).fill(0), 'zzzzzz'), 6);
  assert.equal(missingLetters(undefined, 'abcd'), 4);
});

test('hints: the contract two-pass rule, against an independent reference on every string over three letters', () => {
  assert.equal(feedbackFor('crane', 'react'), '11201');
  assert.equal(feedbackFor('speed', 'abide'), '00101', 'a repeated guess letter gets one yellow');
  assert.equal(feedbackFor('eerie', 'there'), '10102', 'a green uses its letter first');
  // Reference: count the word's letters left after greens, then go left to right.
  const ref = (g, w) => {
    const fb = [...g].map((c, i) => (c === w[i] ? 2 : 0));
    const left = {};
    [...w].forEach((c, i) => fb[i] !== 2 && (left[c] = (left[c] || 0) + 1));
    return [...g].map((c, i) => (fb[i] === 2 ? 2 : left[c] ? (left[c]--, 1) : 0)).join('');
  };
  const all = (n) => (n === 0 ? [''] : all(n - 1).flatMap((s) => ['q', 'x', 'z'].map((c) => s + c)));
  for (const w of all(4)) for (const g of all(4)) assert.equal(feedbackFor(g, w), ref(g, w), `${g} vs ${w}`);
  assert.deepEqual(hintMarks('02110'), ['absent', 'correct', 'present', 'present', 'absent']);
  assert.throws(() => hintMarks('03'), RangeError);
});

test('letter states: the best known state of each letter over the answered guesses', () => {
  const g = parseGame(out('game_revealed_unsolved_six'));
  const states = letterStates(g.guesses);
  for (const guess of g.guesses) {
    hintMarks(guess.feedback).forEach((m, i) => {
      const c = guess.letters[i];
      if (m === 'correct') assert.equal(states.get(c), 'correct', c);
      if (m === 'present') assert.notEqual(states.get(c), 'absent', c);
    });
  }
  const unanswered = [{ letters: 'abcde', answered: false }];
  assert.equal(letterStates(unanswered).size, 0, 'a guess still waiting for its hint says nothing');
});

// ---------------------------------------------------------------- args

test('args: exactly the app shader actions the wallet uses, as the real builds were made', () => {
  for (const name of ['enter_beam', 'enter_token', 'buy_letters', 'guess_buy_missing', 'claim_timeout_silent', 'claim_refund_failed', 'finalize_beam', 'claim_beam']) {
    const a = argsOf(FX.builds[name].args);
    const mine = {
      enter_game: () => fuddleArgs.enterGame(CID, { tid: Number(a.tid), len: Number(a.len) }),
      buy_letters: () => fuddleArgs.buyLetters(CID, { tid: Number(a.tid), letters: a.letters }),
      submit_guess: () => fuddleArgs.submitGuess(CID, { tid: Number(a.tid), idx: Number(a.idx), attempt: Number(a.attempt), guess: a.guess }),
      claim_timeout: () => fuddleArgs.claimTimeout(CID, { tid: Number(a.tid), idx: Number(a.idx) }),
      claim_refund: () => fuddleArgs.claimRefund(CID, { tid: Number(a.tid), idx: Number(a.idx) }),
      finalize: () => fuddleArgs.finalize(CID, { tid: Number(a.tid) }),
      claim: () => fuddleArgs.claim(CID, { tid: Number(a.tid) }),
    }[a.action]();
    assert.equal(mine, FX.builds[name].args, name);
  }
  for (const name of ['my_key', 'view_state', 'tournament_beam', 'my_tournament_open', 'game_hinted', 'my_games', 'claimable', 'tournaments', 'answerer']) {
    const a = argsOf(FX.views[name].args);
    const mine = {
      my_key: () => fuddleArgs.myKey(CID),
      view_state: () => fuddleArgs.viewState(CID),
      view_tournament: () => fuddleArgs.viewTournament(CID, { tid: Number(a.tid) }),
      view_my_tournament: () => fuddleArgs.viewMyTournament(CID, { tid: Number(a.tid) }),
      view_game: () => fuddleArgs.viewGame(CID, { tid: Number(a.tid), idx: Number(a.idx) }),
      view_my_games: () => fuddleArgs.viewMyGames(CID, { tid: Number(a.tid) }),
      view_claimable: () => fuddleArgs.viewClaimable(CID),
      view_tournaments: () => fuddleArgs.viewTournaments(CID, { skip: 0, limit: 50 }),
      view_answerer: () => fuddleArgs.viewAnswerer(CID, { pk: a.pk }),
    }[a.action]();
    assert.equal(mine, FX.views[name].args, name);
  }
  // A guess always buys what it lacks; the role is always user.
  assert.match(fuddleArgs.submitGuess(CID, { tid: 0, idx: 1, attempt: 2, guess: 'crane' }), /^role=user,action=submit_guess,.*,buy_missing=1$/);
});

test('args: anything that could add an argument or reach another role is refused before the shader sees it', () => {
  assert.throws(() => fuddleArgs.buyLetters(CID, { tid: 0, letters: 'ab,role=manager' }), RangeError);
  assert.throws(() => fuddleArgs.buyLetters(CID, { tid: 0, letters: 'AB' }), RangeError, 'lower case only (the screens clean it first)');
  assert.throws(() => fuddleArgs.buyLetters(CID, { tid: 0, letters: '' }), RangeError);
  assert.throws(() => fuddleArgs.buyLetters(CID, { tid: 0, letters: 'a'.repeat(257) }), RangeError);
  assert.throws(() => fuddleArgs.submitGuess(CID, { tid: 0, idx: 0, attempt: 0, guess: 'abc' }), RangeError, 'too short');
  assert.throws(() => fuddleArgs.submitGuess(CID, { tid: 0, idx: 0, attempt: 0, guess: 'abcdefg' }), RangeError, 'too long');
  assert.throws(() => fuddleArgs.submitGuess(CID, { tid: 0, idx: 0, attempt: 6, guess: 'abcde' }), RangeError, 'six attempts at most');
  assert.throws(() => fuddleArgs.enterGame(CID, { tid: 0, len: 7 }), RangeError);
  assert.throws(() => fuddleArgs.enterGame(CID, { tid: -1, len: 5 }), RangeError);
  assert.throws(() => fuddleArgs.viewGame(CID, { tid: 0, idx: 2 ** 32 }), RangeError);
  assert.throws(() => fuddleArgs.viewAnswerer(CID, { pk: 'ab,role=manager' }), RangeError);
  assert.throws(() => fuddleArgs.enterGame(`${CID},role=manager`, { tid: 0, len: 5 }), RangeError);
});

test('argument bytes: our encoding of contract.h equals the bytes in every real build', () => {
  const check = (name, enc) => assert.equal(toHex(readContractTx(built(name)).entries[0].args), toHex(enc), name);
  const a = (name) => argsOf(FX.builds[name].args);
  check('enter_beam', encodeArgs.enterGame({ pk: ALICE, tid: 0, len: 5 }));
  check('enter_token', encodeArgs.enterGame({ pk: ALICE, tid: 1, len: 5 }));
  const ev = readContractTx(built('enter_beam_evict')).entries[0].args;
  check('enter_beam_evict', encodeArgs.enterGame({ pk: ALICE, tid: 0, len: 6, evict: ev[42] | (ev[43] << 8) | (ev[44] << 16) | (ev[45] << 24) }));
  assert.ok(FX.games.bob.includes(ev[42]), 'the shader picked one of bob\'s games');
  check('buy_letters', encodeArgs.buyLetters({ pk: ALICE, tid: 0, letters: 'qxzbq' }));
  for (const name of ['guess_buy_missing', 'guess_token_buy_missing', 'guess_from_stock']) {
    const x = a(name);
    check(name, encodeArgs.submitGuess({ pk: ALICE, tid: Number(x.tid), idx: Number(x.idx), attempt: Number(x.attempt), guess: x.guess, buyMissing: Number(x.buy_missing) }));
  }
  check('claim_timeout_silent', encodeArgs.claimTimeout({ tid: 0, idx: 4 }));
  check('claim_timeout_unplayed', encodeArgs.claimTimeout({ tid: 0, idx: 5 }));
  check('claim_refund_failed', encodeArgs.claimRefund({ pk: ALICE, tid: 0, idx: 4 }));
  check('claim_refund_unplayed', encodeArgs.claimRefund({ pk: ALICE, tid: 0, idx: 5 }));
  check('finalize_beam', encodeArgs.finalize({ tid: 0 }));
  check('claim_beam', encodeArgs.claim({ pk: ALICE, tid: 0 }));
  check('claim_token', encodeArgs.claim({ pk: ALICE, tid: 1 }));
  for (const [k, n] of Object.entries(ARGS_SIZE)) assert.ok(n > 0, k);
  assert.equal(encodeArgs.submitGuess({ pk: ALICE, tid: 0, idx: 0, attempt: 0, guess: 'abcd' }).length, ARGS_SIZE.submitGuess, 'letters past the word are zero bytes');
});

// ---------------------------------------------------------------- answers

test('parsers: every real answer reads, with the figures the screens show', () => {
  assert.equal(parseMyKey(out('my_key')), ALICE);
  const st = parseState(out('view_state'));
  assert.equal(st.feeBps, 100);
  assert.equal(st.paused, false);
  assert.equal(st.slash, 50000000n);
  assert.equal(st.answerFee, 12000000n);
  assert.equal(st.dicts.length, 3);
  const tb = parseTournamentView(out('tournament_beam'));
  assert.deepEqual([tb.tid, tb.asset, tb.entry, tb.letterPrice, tb.answerFee, tb.slash, tb.maxOpen, tb.answerBlocks], [0, 0, 100000000n, 1000000n, 12000000n, 50000000n, 4, 20]);
  assert.deepEqual([tb.firstGuessBlocks, tb.idleBlocks, tb.minGameBlocks, tb.entriesCloseH], [40, 60, 440, tb.endH - 440]);
  assert.equal(tb.phase, 'open');
  assert.equal(typeof tb.poolEstimate, 'bigint');
  const tk = parseTournamentView(out('tournament_token'));
  assert.equal(tk.asset, 7);
  assert.deepEqual(lengthsOf(tk.lenMask), [5]);
  assert.equal(parseTournamentView(out('tournament_unaccepted')).phase, 'awaiting_answerer');
  assert.equal(parseTournamentView(out('tournament_beam_ready')).phase, 'ready_to_finalise');
  const fin = parseTournamentView(out('tournament_beam_final'));
  assert.equal(fin.phase, 'finalised');
  assert.equal(typeof fin.pool, 'bigint');
  assert.equal(fin.poolEstimate, undefined);
  const list = parseTournaments(out('tournaments'));
  assert.deepEqual(list.map((x) => x.tid), [0, 1, 2]);
  const open = parseMyTournament(out('my_tournament_open'));
  assert.equal(open.joined, true);
  assert.equal(open.letters.length, 26);
  assert.equal(typeof open.prizeEstimate, 'bigint');
  const final = parseMyTournament(out('my_tournament_final'));
  assert.equal(final.claimable, true);
  assert.equal(final.prize, 260464000n);
  assert.equal(parseMyTournament(out('my_tournament_claimed')).claimed, true);
  const mine = parseMyGames(out('my_games'));
  assert.deepEqual(mine.map((g) => g.idx), FX.games.g.filter((i) => mine.some((g) => g.idx === i)));
  assert.ok(mine.every((g) => g.player === ALICE));
  assert.deepEqual(parseClaimable(out('claimable')).map((c) => [c.tid, c.asset]), [[0, 0], [1, 7]]);
  const ans = parseAnswerer(out('answerer'));
  assert.equal(ans.pk, FX.service_pk);
  assert.equal(ans.enabled, true);
});

test('parsers: every game phase the shader prints, with its clock', () => {
  const want = {
    game_your_move_fresh: ['your_move', GAME.playing, 0],
    game_waiting_hint: ['waiting_hint', GAME.playing, 1],
    game_hint_overdue: ['hint_overdue', GAME.playing, null],
    game_hinted: ['your_move', GAME.playing, 1],
    game_waiting_reveal_solved: ['waiting_reveal', GAME.playing, null],
    game_revealed_solved: ['revealed', GAME.revealed, 3],
    game_revealed_unsolved_six: ['revealed', GAME.revealed, 6],
    game_waiting_reveal_idle: ['waiting_reveal', GAME.playing, 1],
    game_revealed_idle: ['revealed', GAME.revealed, 1],
    game_reveal_overdue: ['reveal_overdue', GAME.playing, null],
    game_unplayed_ended: ['unplayed_ended', GAME.playing, 0],
    game_failed_silent: ['failed', GAME.failed, null],
    game_failed_unrevealed: ['failed', GAME.failed, null],
    game_ended_unplayed: ['ended_unplayed', GAME.ended, 0],
    game_refunded: ['failed', GAME.failed, null],
    game_refunded_unplayed: ['ended_unplayed', GAME.ended, 0],
  };
  for (const [name, [phase, status, attempts]] of Object.entries(want)) {
    const g = parseGame(out(name));
    assert.equal(g.phase, phase, name);
    assert.equal(g.status, status, name);
    if (attempts !== null) assert.equal(g.attempts, attempts, name);
    assert.equal(g.player, ALICE, name);
    assert.equal(g.guesses.length, g.attempts, name);
  }
  const hinted = parseGame(out('game_hinted'));
  assert.equal(hinted.guesses[0].answered, true);
  assert.match(hinted.guesses[0].feedback, /^[012]{5}$/);
  assert.equal(hinted.guessDueH, hinted.guesses[0].answeredH + 60, 'the next guess is due 60 blocks after the hint');
  const fresh = parseGame(out('game_your_move_fresh'));
  assert.ok(fresh.guessDueH > 0);
  const waiting = parseGame(out('game_waiting_hint'));
  assert.equal(waiting.guesses.at(-1).answered, false);
  assert.equal(waiting.hintDueH, waiting.guesses.at(-1).guessedH + 20);
  assert.equal(parseGame(out('game_revealed_solved')).solvedAt, 3);
  assert.equal(parseGame(out('game_failed_silent')).verdict, VERDICT.silent);
  assert.equal(parseGame(out('game_failed_unrevealed')).verdict, VERDICT.unrevealed);
  assert.equal(parseGame(out('game_ended_unplayed')).verdict, VERDICT.unplayed);
  assert.equal(parseGame(out('game_refunded')).refunded, true);
  assert.equal(parseGame(out('game_waiting_reveal_solved')).solved, true);
  assert.equal(parseGame(out('game_waiting_reveal_idle')).solved, false);
});

test('parsers: an answer that disagrees with contract.h, or is malformed, is refused', () => {
  const tweak = (name, path, f) => {
    const o = JSON.parse(FX.views[name].output);
    f(o[path]);
    return o;
  };
  const bad = (o, parse, what) => assert.throws(() => parse(o), (e) => e instanceof FuddleError && e.code === 'unexpected', what);
  bad(tweak('tournament_beam', 'tournament', (x) => (x.first_guess_blocks = 400)), parseTournamentView, 'a first-guess clock other than contract.h');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.idle_blocks = 600)), parseTournamentView, 'an idle clock other than 60');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.min_game_blocks = 100)), parseTournamentView, 'a shorter minimum game');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.entries_close_h += 1)), parseTournamentView, 'a later entry close');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.open_games += 1)), parseTournamentView, 'open games that do not add up');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.phase = 'winners')), parseTournamentView, 'an unknown phase');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.entry = -1)), parseTournamentView, 'a negative amount');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.entry = '18446744073709551616')), parseTournamentView, 'beyond 64 bits');
  bad(tweak('tournament_beam', 'tournament', (x) => (x.answerer = 'zz')), parseTournamentView, 'a broken key');
  bad(tweak('game_hinted', 'game', (x) => (x.guesses[0].feedback = '30000')), parseGame, 'a hint digit 3');
  bad(tweak('game_hinted', 'game', (x) => (x.guesses[0].feedback = '0000')), parseGame, 'a hint shorter than the word');
  bad(tweak('game_hinted', 'game', (x) => (x.guesses[0].letters = 'QXZCD')), parseGame, 'letters outside a..z');
  bad(tweak('game_hinted', 'game', (x) => (x.attempts = 2)), parseGame, 'guesses that are not one per attempt');
  bad(tweak('game_hinted', 'game', (x) => delete x.guess_due_h), parseGame, 'your move without its clock');
  bad(tweak('game_hinted', 'game', (x) => (x.next_attempt = 3)), parseGame, 'a next attempt other than attempts');
  bad(tweak('game_waiting_hint', 'game', (x) => delete x.hint_due_h), parseGame, 'a hint wait without its clock');
  bad(tweak('game_hinted', 'game', (x) => (x.len = 7)), parseGame, 'a seven-letter game');
  bad(tweak('my_tournament_final', 'me', (x) => x.letters.pop()), parseMyTournament, '25 letter counts');
  bad(tweak('my_tournament_final', 'me', (x) => (x.refund_beam_paid = x.refund_beam + 1)), parseMyTournament, 'more refunded than owed');
  bad({ games: {} }, parseMyGames, 'not a list');
  bad(null, parseState, 'no answer');
});

test('the shader\'s refusals: every real one has a code and plain words', () => {
  const codes = {
    err_game_not_found: 'gameNotFound',
    err_enter_unaccepted: 'notAccepted',
    err_enter_max_open: 'tooManyOpen',
    err_enter_full: 'full',
    err_refund_playing: 'notRefundable',
    err_already_refunded: 'alreadyRefunded',
    err_not_your_game: 'notYourGame',
    err_claim_not_finalised: 'notFinalised',
    err_already_claimed: 'alreadyClaimed',
  };
  for (const [name, code] of Object.entries(codes)) {
    const said = out(name).error;
    assert.equal(shaderCodeFor(said), code, name);
    const e = mapFuddleError(Object.assign(new Error(said), { code: 'shader' }));
    assert.ok(e instanceof FuddleError && e.code === code, name);
    assert.ok(!e.message.includes(said), `${name}: the person reads our words, not the shader's`);
  }
  assert.equal(shaderCodeFor('missing or invalid argument: tid'), 'badArgument');
  const other = mapFuddleError(Object.assign(new Error('something new'), { code: 'shader' }));
  assert.match(other.message, /something new/, 'an unknown refusal is still said');
});

// ---------------------------------------------------------------- money

test('entry: the entry and the answering fee, one BEAM entry or two assets, as the real builds lock', () => {
  const tb = parseTournamentView(out('tournament_beam'));
  const tk = parseTournamentView(out('tournament_token'));
  assert.deepEqual(entryCost(tb).funds, fundsMap(FX.builds.enter_beam.tx.pays));
  assert.deepEqual(entryCost(tk).funds, fundsMap(FX.builds.enter_token.tx.pays));
  assert.equal(entryCost(tb).beamTotal, 112000000n + 2300000n);
  assert.equal(entryCost(tk).beamTotal, 12000000n + 2300000n);
  assert.equal(entryCost(tb, { evict: true }).fee, 3250000n);
  assert.deepEqual(fundsOf(0, 5n, 7n), new Map([[0, 12n]]));
  assert.deepEqual(fundsOf(7, 0n, 0n), new Map());
});

test('letters bought with a guess: price x missing, in the tournament asset, as the real builds lock', () => {
  assert.deepEqual(fundsOf(0, guessCost(1000000n, 2).letters, 0n), fundsMap(FX.builds.guess_buy_missing.tx.pays));
  assert.deepEqual(fundsOf(7, guessCost(5000000n, 5).letters, 0n), fundsMap(FX.builds.guess_token_buy_missing.tx.pays));
  assert.deepEqual(fundsOf(0, guessCost(1000000n, 0).letters, 0n), fundsMap(FX.builds.guess_from_stock.tx.pays));
  assert.equal(guessCost(1000000n, 3).fee, 1660000n);
});

test('refunds: a failed game gives entry, letters, answering fee and the slash; an unplayed one entry and fee', () => {
  const tb = parseTournamentView(out('tournament_beam'));
  const failed = parseGame(out('game_failed_silent'));
  const r1 = refundOf(tb, failed);
  assert.deepEqual(r1.funds, fundsMap(FX.builds.claim_refund_failed.tx.pays));
  assert.equal(r1.slash, 50000000n);
  assert.equal(r1.letters, 6000000n, 'six letters used: one 6-letter guess');
  const unplayed = parseGame(out('game_ended_unplayed'));
  const r2 = refundOf(tb, unplayed);
  assert.deepEqual(r2.funds, fundsMap(FX.builds.claim_refund_unplayed.tx.pays));
  assert.equal(r2.slash, 0n, 'no slash: not the service\'s fault');
});

test('the final payout: computed here from the pool and the scores, equal to the shader and to the real claims', () => {
  for (const [tName, meName, build] of [
    ['tournament_beam_final', 'my_tournament_final', 'claim_beam'],
    ['tournament_token_final', 'my_tournament_token_final', 'claim_token'],
  ]) {
    const tour = parseTournamentView(out(tName));
    const me = parseMyTournament(out(meName));
    const p = payoutOf(tour, me);
    assert.equal(p.prize, me.prize, `${tName} prize`);
    assert.equal(p.assetAmount, me.payoutAsset, `${tName} asset`);
    assert.equal(p.beam, me.payoutBeam, `${tName} BEAM`);
    assert.deepEqual(p.funds, fundsMap(FX.builds[build].tx.pays), build);
  }
  // Nobody scored: each player gets back what they paid in, less the refunds owed (paid separately).
  const t0 = { ...parseTournamentView(out('tournament_beam_final')), totalScore: 0n, pool: 0n };
  const me = { ...parseMyTournament(out('my_tournament_final')), score: 0n };
  assert.equal(payoutOf(t0, me).prize, me.paidIn - me.refundAsset);
  assert.throws(() => payoutOf(parseTournamentView(out('tournament_beam')), me), RangeError, 'before finalising there is no payout');
});

test('percentages for the words', () => {
  assert.equal(percentText(100), '1%');
  assert.equal(percentText(50), '0.5%');
  assert.equal(percentText(250), '2.5%');
  assert.equal(percentText(5000), '50%');
  assert.equal(percentText(0), '0%');
});

// ---------------------------------------------------------------- time in words

test('time in words: a block is about a minute', () => {
  const cases = [[0, 'about a minute'], [1, 'about a minute'], [2, 'about 2 minutes'], [40, 'about 40 minutes'], [59, 'about 59 minutes'], [60, 'about an hour'], [89, 'about an hour'], [90, 'about 2 hours'], [440, 'about 7 hours'], [960, 'about 16 hours'], [1439, 'about 24 hours'], [1440, 'about 1 day'], [3000, 'about 2 days']];
  for (const [n, s] of cases) assert.equal(blocksText(n), s, String(n));
});

test('what a player is told before entering: the README\'s sentences, from the tournament\'s own figures', () => {
  const tb = parseTournamentView(out('tournament_beam'));
  const rules = rulesBeforeEntering(tb, { slashText: '0.5 BEAM', priceText: '0.01 BEAM' });
  const by = Object.fromEntries(rules.map((r) => [r.id, r.text]));
  assert.match(by.length, /about 15–20 minutes/);
  assert.match(by.idle, /about an hour/);
  assert.match(by.idle, /ends unsolved and your entry stays in the prize pool/);
  assert.match(by.firstGuess, /within about 40 minutes/);
  assert.match(by.firstGuess, /entry and answering fee come back/);
  assert.match(by.entriesClose, /about 7 hours before the tournament ends/);
  assert.match(by.letters, /0\.01 BEAM/);
  assert.match(by.lettersAhead, /stops taking new games/);
  assert.match(by.fee, /^When the tournament ends, 1% of what was paid in goes to Fuddle/);
  assert.match(by.compensation, /plus 0\.5 BEAM from its bond/);
  // Another tournament's figures change the words: a 120-block answer window, a creator's cut.
  const slow = { ...tb, answerBlocks: 120, firstGuessBlocks: firstGuessBlocks(120), minGameBlocks: minGameBlocks(120), creatorBps: 500 };
  const by2 = Object.fromEntries(rulesBeforeEntering(slow, { slashText: '0.5 BEAM', priceText: '0.01 BEAM' }).map((r) => [r.id, r.text]));
  assert.match(by2.firstGuess, /within about an hour/);
  assert.match(by2.entriesClose, /about 16 hours before/);
  assert.match(by2.fee, /5% to the tournament's creator/);
});

test('the clock of every game phase, and its sentence', () => {
  const want = {
    game_your_move_fresh: ['firstGuess', /first guess within about \d+ minutes?, or the game ends and your entry comes back/],
    game_hinted: ['nextGuess', /next guess within about (an hour|\d+ minutes?), or the game ends unsolved/],
    game_waiting_hint: ['hint', /checking your guess.*within about \d+ minutes?/],
    game_hint_overdue: ['hintLate', /missed its time to answer/],
    game_waiting_reveal_solved: ['reveal', /shows the word on chain within/],
    game_reveal_overdue: ['revealLate', /did not show the word in time/],
    game_unplayed_ended: ['unplayed', /No first guess was made in time/],
    game_revealed_solved: ['over', /^$/],
    game_failed_silent: ['over', /^$/],
  };
  for (const [name, [kind, words]] of Object.entries(want)) {
    const v = FX.views[name];
    const c = gameClock(parseGame(out(name)), v.height);
    assert.equal(c.kind, kind, name);
    assert.match(clockText(c), words, name);
  }
  const fresh = parseGame(out('game_your_move_fresh'));
  const c = gameClock(fresh, FX.views.game_your_move_fresh.height);
  assert.equal(c.blocksLeft, fresh.guessDueH - FX.views.game_your_move_fresh.height);
  assert.equal(gameClock(fresh, fresh.guessDueH + 5).blocksLeft, 0, 'never negative');
});

test('how each game turned out, and what can be done about it', () => {
  const want = {
    game_your_move_fresh: { outcome: 'playing' },
    game_waiting_hint: { outcome: 'playing' },
    game_waiting_reveal_solved: { outcome: 'checking', solved: true },
    game_waiting_reveal_idle: { outcome: 'checking', solved: false },
    game_revealed_solved: { outcome: 'solved', score: scoreOf(parseGame(out('game_revealed_solved')).len, 3) },
    game_revealed_unsolved_six: { outcome: 'unsolved' },
    game_revealed_idle: { outcome: 'stopped' },
    game_hint_overdue: { outcome: 'late', endable: true },
    game_reveal_overdue: { outcome: 'late', endable: true },
    game_unplayed_ended: { outcome: 'abandoned', endable: true },
    game_failed_silent: { outcome: 'failed', refundable: true },
    game_failed_unrevealed: { outcome: 'failed', refundable: true },
    game_ended_unplayed: { outcome: 'unplayed', refundable: true },
    game_refunded: { outcome: 'failed', refundable: false },
    game_refunded_unplayed: { outcome: 'unplayed', refundable: false },
  };
  for (const [name, w] of Object.entries(want)) {
    const o = gameOutcome(parseGame(out(name)));
    for (const [k, v] of Object.entries(w)) assert.equal(o[k], v, `${name}.${k}`);
  }
  assert.equal(gameOutcome(parseGame(out('game_failed_silent')), { claimed: true }).refundable, false, 'after the final claim the refund came with it');
  assert.match(failedReason(VERDICT.silent), /did not answer a guess in time/);
  assert.match(failedReason(VERDICT.unrevealed), /did not reveal the word in time/);
  assert.match(failedReason(VERDICT.lied), /hint was wrong/);
});

// ---------------------------------------------------------------- the built transaction

/** The real build re-encoded with `change` applied to its one decoded entry. */
function tampered(name, change) {
  const e = readContractTx(built(name)).entries[0];
  const x = { contractId: e.contractId, method: e.method, args: [...e.args], sigs: [...e.signatureKeyHashes], charge: e.charge, comment: e.comment, spend: Object.fromEntries([...e.spend].map(([k, v]) => [k, v])) };
  const more = change(x);
  const extra = Array.isArray(more) ? more : [];
  return Uint8Array.from(invokeData([invokeEntry(x), ...extra]));
}

const EXPECT = {
  enter_beam: () => ({ method: METHOD.enterGame, charge: CHARGE.enterGame, comment: KERNEL.enterGame, signatures: 1, args: encodeArgs.enterGame({ pk: ALICE, tid: 0, len: 5 }), funds: entryCost(parseTournamentView(out('tournament_beam'))).funds }),
  enter_token: () => ({ method: METHOD.enterGame, charge: CHARGE.enterGame, comment: KERNEL.enterGame, signatures: 1, args: encodeArgs.enterGame({ pk: ALICE, tid: 1, len: 5 }), funds: entryCost(parseTournamentView(out('tournament_token'))).funds }),
  buy_letters: () => ({ method: METHOD.buyLetters, charge: CHARGE.buyLetters, comment: KERNEL.buyLetters, signatures: 1, args: encodeArgs.buyLetters({ pk: ALICE, tid: 0, letters: 'qxzbq' }), funds: fundsOf(0, 5000000n, 0n) }),
  guess_buy_missing: () => {
    const a = argsOf(FX.builds.guess_buy_missing.args);
    return { method: METHOD.submitGuess, charge: CHARGE.submitGuess, comment: KERNEL.submitGuess, signatures: 1, args: encodeArgs.submitGuess({ pk: ALICE, tid: 0, idx: Number(a.idx), attempt: Number(a.attempt), guess: a.guess }), funds: fundsOf(0, 2000000n, 0n) };
  },
  claim_timeout_silent: () => ({ method: METHOD.claimTimeout, charge: CHARGE.claimTimeout, comment: KERNEL.claimTimeout, signatures: 0, args: encodeArgs.claimTimeout({ tid: 0, idx: 4 }), funds: new Map() }),
  claim_refund_failed: () => ({ method: METHOD.claimRefund, charge: CHARGE.claimRefund, comment: KERNEL.claimRefund, signatures: 1, args: encodeArgs.claimRefund({ pk: ALICE, tid: 0, idx: 4 }), funds: refundOf(parseTournamentView(out('tournament_beam')), parseGame(out('game_failed_silent'))).funds }),
  finalize_beam: () => ({ method: METHOD.finalize, charge: CHARGE.finalize, comment: KERNEL.finalize, signatures: 0, args: encodeArgs.finalize({ tid: 0 }), funds: new Map() }),
  claim_beam: () => ({ method: METHOD.claim, charge: CHARGE.claim, comment: KERNEL.claim, signatures: 1, args: encodeArgs.claim({ pk: ALICE, tid: 0 }), funds: payoutOf(parseTournamentView(out('tournament_beam_final')), parseMyTournament(out('my_tournament_final'))).funds }),
  claim_token: () => ({ method: METHOD.claim, charge: CHARGE.claim, comment: KERNEL.claim, signatures: 1, args: encodeArgs.claim({ pk: ALICE, tid: 1 }), funds: payoutOf(parseTournamentView(out('tournament_token_final')), parseMyTournament(out('my_tournament_token_final'))).funds }),
};

test('kernel checks: every real build passes, re-encoding one changes nothing', () => {
  for (const [name, f] of Object.entries(EXPECT)) {
    const d = checkBuilt(built(name), { cid: CID, ...f(), shaderArgs: FX.builds[name].args });
    assert.equal(d.fee, feeForCharge(f().charge), name);
    assert.equal(toHex(tampered(name, () => {})), FX.builds[name].raw, `${name}: the test encoder writes the core's bytes`);
  }
});

test('kernel checks: a tampered build is refused before signing, whatever was changed', () => {
  const refused = (raw, name, what, detail = null) =>
    assert.throws(
      () => checkBuilt(raw, { cid: CID, ...EXPECT[name](), shaderArgs: FX.builds[name].args }),
      (e) => e instanceof FuddleError && e.code === 'unexpected' && e.nothingSent === true && (!detail || detail.test(e.detail)),
      `${name}: ${what}`,
    );
  const otherCid = 'ab'.repeat(32);
  for (const name of Object.keys(EXPECT)) {
    refused(tampered(name, (x) => (x.contractId = otherCid)), name, 'another contract', /targets/);
    refused(tampered(name, (x) => (x.method += 1)), name, 'another method', /contract method/);
    refused(tampered(name, (x) => (x.charge += 1)), name, 'another charge (and fee)', /BVM charge/);
    refused(tampered(name, (x) => (x.charge = 10000000)), name, 'a much larger fee', /BVM charge/);
    refused(tampered(name, (x) => (x.comment = 'Fuddle v9: something else')), name, 'another comment', /kernel comment/);
    refused(tampered(name, (x) => (x.args[x.args.length - 1] ^= 1)), name, 'one argument bit', /arguments differ/);
    refused(tampered(name, (x) => x.args.push(0)), name, 'a longer argument struct', /arguments differ/);
    refused(tampered(name, (x) => void (x.sigs = x.sigs.length ? [] : ['11'.repeat(32)])), name, 'another signer count', /signing keys/);
    refused(tampered(name, (x) => (x.spend[0] = (x.spend[0] || 0n) + 1n)), name, 'one groth more of BEAM', /moves/);
    refused(tampered(name, (x) => (x.spend[36] = 1n)), name, 'another asset moving', /moves/);
    refused(tampered(name, () => [invokeEntry({ contractId: CID, method: 16, args: [1], charge: 132000, comment: KERNEL.claim })]), name, 'a second call', /one contract call/);
  }
  // The player key is ours: a build for another key is refused.
  refused(tampered('claim_beam', (x) => void x.args.splice(0, 33, ...fromHex(BOB))), 'claim_beam', 'a claim for bob', /arguments differ/);
  refused(tampered('enter_beam', (x) => void x.args.splice(0, 33, ...fromHex(BOB))), 'enter_beam', 'an entry for bob', /arguments differ/);
  // A claim paying less than computed here is refused too: the sheet would show the wrong amount.
  refused(tampered('claim_beam', (x) => (x.spend[0] += 1n)), 'claim_beam', 'a claim one groth short', /moves/);
  // Unreadable bytes.
  refused(Uint8Array.from([0x81, 0x89]), 'enter_beam', 'truncated', /cannot read/);
});

test('the approve sheet must show the built figures to the groth', () => {
  const d = readContractTx(built('claim_token'));
  const match = consentMatches(() => d);
  const req = { kind: 'contract', spends: [], receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
  assert.equal(match(req), null);
  assert.ok(match({ ...req, fee: d.fee + 1n }), 'another fee');
  assert.ok(match({ ...req, receives: req.receives.slice(1) }), 'an asset missing');
  assert.ok(match({ ...req, receives: req.receives.map((r) => ({ ...r, amount: r.amount - 1n })) }), 'one groth less');
  assert.ok(match({ ...req, spends: [{ assetId: 0, amount: 1n }] }), 'something spent');
  assert.ok(match({ ...req, kind: 'send' }), 'a payment instead of a call');
  assert.ok(consentMatches(() => null)(req), 'nothing built');
});

// ---------------------------------------------------------------- the service over a fake contract

/**
 * A fake contract answering from the real fixtures. views: args -> output text (or a function);
 * builds: action -> raw hex. transact runs the module's inspect on the bytes, then the approve
 * sheet's check on what the engine would report, and counts what would have been signed.
 */
function fakeDeps({ views = {}, builds = {}, tamper = null } = {}) {
  const signed = [];
  const asked = [];
  const deps = {
    cid: CID,
    view: async (a) => {
      asked.push(a);
      const v = views[a];
      if (v === undefined) throw new Error(`no fake answer for ${a}`);
      const text = typeof v === 'function' ? v() : v;
      const o = parseShaderJson(text);
      if (o && o.error) throw Object.assign(new Error(o.error), { code: 'shader' });
      return o;
    },
    transact: async (a, { inspect, expect, intent }) => {
      const action = argsOf(a).action;
      let raw = fromHex(builds[action]);
      if (tamper) raw = tamper(raw);
      await inspect(raw, {});
      const d = readContractTx(raw);
      const req = { kind: 'contract', spends: [...d.pays].map(([assetId, amount]) => ({ assetId, amount })), receives: [...d.receives].map(([assetId, amount]) => ({ assetId, amount })), fee: d.fee };
      const problem = expect(req);
      if (problem) throw Object.assign(new Error(problem.message), problem);
      signed.push({ a, intent });
      return 'ee'.repeat(16);
    },
  };
  return { deps, signed, asked };
}

const V = (name) => [FX.views[name].args, FX.views[name].output];
const stockView = () => {
  const o = JSON.parse(FX.views.my_tournament_open.output);
  o.me.letters = new Array(26).fill(0);
  o.me.letters[16] = 2;
  o.me.letters[23] = 1;
  o.me.letters[25] = 1;
  o.me.letters[1] = 1;
  return JSON.stringify(o);
};
const gameAs = (name, change) => {
  const o = JSON.parse(FX.views[name].output);
  change(o.game);
  return JSON.stringify(o);
};

test('service: enter, guess, refund and claim on the real builds reach signing with the right intent', async () => {
  const a = argsOf(FX.builds.guess_buy_missing.args);
  const yourMove = gameAs('game_your_move_fresh', (g) => {
    g.idx = Number(a.idx);
  });
  const views = Object.fromEntries([
    V('my_key'),
    V('tournament_beam'),
    [fuddleArgs.viewGame(CID, { tid: 0, idx: Number(a.idx) }), yourMove],
    [fuddleArgs.viewMyTournament(CID, { tid: 0 }), stockView()],
    V('game_failed_silent'),
  ]);
  const { deps, signed } = fakeDeps({ views, builds: { enter_game: FX.builds.enter_beam.raw, submit_guess: FX.builds.guess_buy_missing.raw, claim_refund: FX.builds.claim_refund_failed.raw } });
  const svc = createFuddle(deps);
  const e = await svc.enter({ tid: 0, len: 5 });
  assert.equal(e.cost.fee, FEES.enterGame);
  assert.equal(e.evicted, null);
  const g = await svc.guess({ tid: 0, idx: Number(a.idx), word: a.guess.toUpperCase() });
  assert.equal(g.cost.missing, 2);
  assert.equal(g.cost.letters, 2000000n);
  views[fuddleArgs.viewMyTournament(CID, { tid: 0 })] = FX.views.my_tournament_open.output;
  const r = await svc.refund({ tid: 0, idx: 4 });
  assert.equal(r.refund.beam, 12000000n + 50000000n);
  assert.deepEqual(signed.map((s) => s.intent.action), ['fuddleEnter', 'fuddleGuess', 'fuddleRefund']);
  assert.equal(signed[1].intent.word, a.guess.toUpperCase());

  // The final claim, BEAM and token.
  const v2 = Object.fromEntries([V('my_key'), V('tournament_beam_final'), V('my_tournament_final'), V('tournament_token_final'), V('my_tournament_token_final')]);
  const f2 = fakeDeps({ views: v2, builds: { claim: FX.builds.claim_beam.raw } });
  const svc2 = createFuddle(f2.deps);
  const c = await svc2.claim({ tid: 0 });
  assert.equal(c.payout.assetAmount + c.payout.beam, 650464000n);
  const f3 = fakeDeps({ views: v2, builds: { claim: FX.builds.claim_token.raw } });
  const c3 = await createFuddle(f3.deps).claim({ tid: 1 });
  assert.deepEqual([c3.payout.assetAmount, c3.payout.beam], [447500000n, 12000000n]);
});

test('service: an entry that ends an abandoned game declares the larger charge, and only a game that really is abandoned', async () => {
  const ev = readContractTx(built('enter_beam_evict')).entries[0].args;
  const idx = ev[42];
  const abandoned = gameAs('game_unplayed_ended', (g) => {
    g.idx = idx;
    g.player = BOB;
  });
  const views = Object.fromEntries([V('my_key'), V('tournament_beam'), [fuddleArgs.viewGame(CID, { tid: 0, idx }), abandoned]]);
  const ok = fakeDeps({ views, builds: { enter_game: FX.builds.enter_beam_evict.raw } });
  const r = await createFuddle(ok.deps).enter({ tid: 0, len: 6 });
  assert.equal(r.evicted, idx);
  assert.equal(r.cost.fee, FEES.enterGameEvict);
  // The same build when that game is in play: refused, never signed.
  views[fuddleArgs.viewGame(CID, { tid: 0, idx })] = gameAs('game_hinted', (g) => {
    g.idx = idx;
  });
  const bad = fakeDeps({ views, builds: { enter_game: FX.builds.enter_beam_evict.raw } });
  await assert.rejects(createFuddle(bad.deps).enter({ tid: 0, len: 6 }), (e) => e.code === 'unexpected' && e.nothingSent === true);
  assert.equal(bad.signed.length, 0);
  // An eviction declared with the small charge: refused.
  const cheap = fakeDeps({ views, builds: { enter_game: FX.builds.enter_beam_evict.raw }, tamper: () => tampered('enter_beam_evict', (x) => (x.charge = CHARGE.enterGame)) });
  await assert.rejects(createFuddle(cheap.deps).enter({ tid: 0, len: 6 }), (e) => e.code === 'unexpected');
  assert.equal(cheap.signed.length, 0);
});

test('service: tampered builds and changed stock are never signed', async () => {
  const a = argsOf(FX.builds.guess_buy_missing.args);
  const views = Object.fromEntries([
    V('my_key'),
    V('tournament_beam'),
    [fuddleArgs.viewGame(CID, { tid: 0, idx: Number(a.idx) }), gameAs('game_your_move_fresh', (g) => (g.idx = Number(a.idx)))],
    [fuddleArgs.viewMyTournament(CID, { tid: 0 }), FX.views.my_tournament_open.output], // no letters in stock now: 5 missing
  ]);
  const f = fakeDeps({ views, builds: { submit_guess: FX.builds.guess_buy_missing.raw } });
  await assert.rejects(createFuddle(f.deps).guess({ tid: 0, idx: Number(a.idx), word: a.guess }), (e) => e.code === 'unexpected', 'the build pays 2 letters, the stock says 5');
  assert.equal(f.signed.length, 0);
  const g = fakeDeps({ views: Object.fromEntries([V('my_key'), V('tournament_beam')]), builds: { enter_game: FX.builds.enter_beam.raw }, tamper: (raw) => tampered('enter_beam', (x) => (x.spend[0] += 100000000n)) });
  await assert.rejects(createFuddle(g.deps).enter({ tid: 0, len: 5 }), (e) => e.code === 'unexpected');
  assert.equal(g.signed.length, 0);
  // A build for another length than asked.
  const h = fakeDeps({ views: Object.fromEntries([V('my_key'), V('tournament_beam')]), builds: { enter_game: FX.builds.enter_beam.raw } });
  await assert.rejects(createFuddle(h.deps).enter({ tid: 0, len: 4 }), (e) => e.code === 'unexpected');
  assert.equal(h.signed.length, 0);
});

test('service: refusals before building, in plain words', async () => {
  const views = Object.fromEntries([V('my_key'), V('tournament_token'), V('tournament_beam'), V('my_tournament_open'), V('game_refunded')]);
  const { deps, signed } = fakeDeps({ views });
  const svc = createFuddle(deps);
  const game0 = fuddleArgs.viewGame(CID, { tid: 0, idx: 0 });
  await assert.rejects(svc.enter({ tid: 1, len: 4 }), (e) => e.code === 'badLength', 'a 4-letter game in a 5-letter tournament');
  views[game0] = FX.views.game_waiting_hint.output;
  await assert.rejects(svc.guess({ tid: 0, idx: 0, word: 'abcde' }), (e) => e.code === 'notYourMove' && /still waiting for its hint/.test(e.message));
  views[game0] = FX.views.game_revealed_solved.output;
  await assert.rejects(svc.guess({ tid: 0, idx: 0, word: 'abcde' }), (e) => e.code === 'notYourMove' && /takes no more guesses/.test(e.message));
  views[game0] = FX.views.game_hinted.output;
  await assert.rejects(svc.guess({ tid: 0, idx: 0, word: 'abc' }), (e) => e.code === 'badGuess');
  await assert.rejects(svc.endGame({ tid: 0, idx: 0 }), (e) => e.code === 'notOverdue');
  await assert.rejects(svc.refund({ tid: 0, idx: 4 }), (e) => e.code === 'alreadyRefunded');
  await assert.rejects(svc.settle({ tid: 0 }), (e) => e.code === 'notReady', 'still open');
  await assert.rejects(svc.claim({ tid: 0 }), (e) => e.code === 'notFinalised');
  views[fuddleArgs.viewTournament(CID, { tid: 0 })] = FX.views.tournament_beam_final.output;
  await assert.rejects(svc.settle({ tid: 0 }), (e) => e.code === 'notReady' && /already settled/.test(e.message));
  views[fuddleArgs.viewMyTournament(CID, { tid: 0 })] = FX.views.my_tournament_claimed.output;
  await assert.rejects(svc.claim({ tid: 0 }), (e) => e.code === 'alreadyClaimed');
  // The shader's own refusal reaches the person in plain words.
  views[fuddleArgs.viewGame(CID, { tid: 999, idx: 0 })] = FX.views.err_game_not_found.output;
  await assert.rejects(svc.game(999, 0), (e) => e.code === 'gameNotFound');
  assert.equal(signed.length, 0);
  // Checks before entering (the contract would refuse these on landing).
  const tb = parseTournamentView(out('tournament_beam'));
  assert.equal(svc.entryProblem(tb, { height: tb.startH + 1 }), null);
  assert.match(svc.entryProblem(tb, { height: tb.entriesCloseH }), /Entries for this tournament are closed/, 'a transaction built at the last height lands after it');
  assert.match(svc.entryProblem(tb, { height: tb.startH - 30 }), /not started yet\. Entries open in about 30 minutes/);
  assert.match(svc.entryProblem(tb, { height: tb.startH + 1, me: { openGames: 4 } }), /4 games open/);
  assert.match(svc.entryProblem(tb, { height: tb.startH + 1, paused: true }), /paused/);
  assert.match(svc.entryProblem({ ...tb, accepted: false }, { height: tb.startH + 1 }), /has not agreed to run it yet/);
});

test('service: one transaction at a time', async () => {
  const lock = fuddleLock();
  let release;
  const first = lock.run(() => new Promise((r) => (release = r)));
  await assert.rejects(lock.run(async () => 1), (e) => e.code === 'busy');
  assert.equal(lock.busy, true);
  release();
  await first;
  assert.equal(lock.busy, false);
});

test('the dApp policy can reserve the player key once the id is known', async () => {
  // keyHashOf is what RESERVED_KEYS holds: SHA-256("bvm.m.key\0" || cid || 00).
  const h = await keyHashOf(`${CID}00`);
  assert.match(h, /^[0-9a-f]{64}$/);
  assert.equal(await reservedUseOfKeyMaterial(`${CID}00`), null, 'the simulator\'s id is nobody\'s');
});
