#!/usr/bin/env python3
"""Real Fuddle v9 app-shader answers and built transactions, for the web wallet's tests.

What it is: a scripted run of the Fuddle v9 answer service's own test world (the Fuddle repo's
service/test/harness.py World, over its simulator bridge service/test/build/fuddle9_bridge).
The bridge runs the real v9 contract.wasm and app.wasm (Fuddle 8e86b3140, app.wasm sha256
52067c77...e62) in BEAM 7.5.14493's own BVM; the app shader prints exactly what it prints in a
wallet, and the bridge serializes each built kernel as BEAM's ContractInvokeData, the bytes
wallet-api and the wasm engine return as raw_data. Every build below was then submitted and
mined, and the contract accepted it (or the test fails).

Regenerate (needs the Fuddle repo with its bridge built: service/test/build_bridge.sh):

    python3 pwa/test/fixtures/fuddle9_sim.py          # FUDDLE_REPO=~/Desktop/Beam/Fuddle by default

Writes pwa/test/fixtures/fuddle9_sim.json next to this file and nothing else into any git tree
(the world lives in a temporary directory). The dictionaries are the harness's made-up consonant
test strings (service/test/testdict.py): never real words, never written into this repository.
Nothing here touches any network.
"""

import hashlib
import json
import os
import random
import sys

APP_PIN = "52067c773a6f91b8eaadd892b133ccbf131f6df4a1c7d12b7305ff725f724e62"
FUDDLE = os.path.expanduser(os.environ.get("FUDDLE_REPO", "~/Desktop/Beam/Fuddle"))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fuddle9_sim.json")
sys.path.insert(0, os.path.join(FUDDLE, "service"))
sys.path.insert(0, os.path.join(FUDDLE, "service", "test"))

BEAM = 100000000
CONS = "bcdfghjklmnpqrstvxz"


class Rec:
    """The world, plus a record of every view and build made through it."""

    def __init__(self, w, parse):
        self.w = w
        self.parse = parse
        self.views = {}
        self.builds = {}
        self.pending = []          # (name, txid)
        self.rng = random.Random(20261014)

    # ------------------------------------------------------------ chain
    @property
    def h(self):
        return self.w.h

    def mine(self, n=1):
        if n > 0:
            self.w.sim.mine(n)
        self.settle()

    def tick(self):
        self.w.svc.tick()

    def block(self):
        """A block with the service awake: mine, then the service acts."""
        self.mine()
        self.tick()

    def settle(self):
        left = []
        for name, txid in self.pending:
            t = self.w.sim.tx(txid)
            if t["status"] in (1, 0):
                left.append((name, txid))
                continue
            if name is not None and name in self.builds:
                b = self.builds[name]
                b["landed"] = t["status"] == 3
                b["tx"] = {k: t.get(k) for k in ("status", "reason", "landed_h", "fee", "units", "method", "charge", "pays")}
            assert t["status"] == 3, ("did not land", name, t)
        self.pending = left

    # ------------------------------------------------------------ shader calls
    def args(self, action, **kw):
        parts = ["role=user", "action=" + action, "cid=" + self.w.cid]
        parts += ["%s=%s" % (k, v) for k, v in kw.items()]
        return ",".join(parts)

    def run(self, wallet, a):
        r = self.w.sim.invoke(wallet, a)
        assert "shader_error" not in r, (a, r)
        out = self.parse(r["output"])          # strict JSON, as the service reads it
        return r, out

    def view(self, name, wallet, action, err=None, **kw):
        a = self.args(action, **kw)
        r, out = self.run(wallet, a)
        assert "raw" not in r, ("a view built a kernel", a)
        if err is not None:
            assert err in out.get("error", ""), (name, out)
        else:
            assert "error" not in out, (name, out)
        if name:
            assert name not in self.views, name
            self.views[name] = {"wallet": wallet, "args": a, "height": self.h, "output": r["output"]}
        return out

    def send(self, name, wallet, action, notes="", **kw):
        """Builds with the app shader, records it, and submits exactly those bytes."""
        a = self.args(action, **kw)
        r, out = self.run(wallet, a)
        assert "error" not in out and "raw" in r, (name or action, out)
        if name:
            assert name not in self.builds, name
            self.builds[name] = {"wallet": wallet, "args": a, "height": self.h, "output": r["output"],
                                 "raw": r["raw"], "landed": None, "notes": notes}
        txid = self.w.sim.submit(wallet, r["raw"])
        self.pending.append((name, txid))       # unnamed: checked to land, not recorded
        return txid

    # ------------------------------------------------------------ game helpers
    def game(self, tid, idx):
        return self.w.game(tid, idx)

    def my_idx(self, wallet, tid):
        g = self.w.sim.view(wallet, {"role": "user", "action": "view_my_games", "tid": tid})["games"]
        return {x["idx"] for x in g}

    def enter(self, wallet, tid, length, name=None, notes="", tick=True):
        before = self.my_idx(wallet, tid)
        self.send(name, wallet, "enter_game", notes, tid=tid, len=length)
        self.mine()
        if tick:
            self.tick()
        new = sorted(self.my_idx(wallet, tid) - before)
        assert len(new) == 1, (wallet, tid, new)
        return new[0]

    def word(self, tid, idx):
        return self.w.word_of(tid, idx)

    def wrong(self, tid, idx, length):
        word = self.word(tid, idx)
        while True:
            g = "".join(self.rng.choice(CONS) for _ in range(length))
            if g != word:
                return g

    def guess(self, wallet, tid, idx, letters, buy=1, name=None, notes=""):
        att = self.game(tid, idx)["attempts"]
        return self.send(name, wallet, "submit_guess", notes, tid=tid, idx=idx, attempt=att, guess=letters, buy_missing=buy)

    def answer_round(self):
        """Guesses submitted: they land, the service answers, the answers land. No reveal yet."""
        self.mine()
        self.tick()
        self.mine()

    def phase(self, tid, idx):
        return self.game(tid, idx).get("phase")

    def until_phase(self, tid, idx, phase, limit=12):
        for _ in range(limit):
            if self.phase(tid, idx) == phase:
                return
            self.block()
        raise AssertionError("game %d/%d never reached %s: %r" % (tid, idx, phase, self.game(tid, idx)))

    def stock(self, wallet, tid):
        return self.w.sim.view(wallet, {"role": "user", "action": "view_my_tournament", "tid": tid})["me"]["letters"]

    def gview(self, name, tid, idx, phase=None):
        out = self.view(name, "alice", "view_game", tid=tid, idx=idx)
        if phase:
            assert out["game"].get("phase") == phase, (name, out)
        return out["game"]


def main():
    app = open(os.path.join(FUDDLE, "v9", "app.wasm"), "rb").read()
    got = hashlib.sha256(app).hexdigest()
    assert got == APP_PIN, "v9/app.wasm is %s, not the pinned %s" % (got, APP_PIN)

    import harness as H
    from agents import Ctx
    from fuddle_service.walletapi import parse_output

    w = H.World(bond=50 * BEAM, policy={"entry_window_factor": 0.5, "prize_fraction_max": 0.9,
                                        "min_entry": {"0": BEAM, "7": 1}})
    try:
        return scenario(w, H, Ctx(w, seed=3), parse_output)
    finally:
        w.close()


def scenario(w, H, ctx, parse):
    x = Rec(w, parse)
    assert w.sim.app_sha == APP_PIN
    alice, bob = w.player("alice"), w.player("bob")
    w.sim.fund("alice", 100 * BEAM, aid=7)
    w.sim.fund("zed", 10 * BEAM)

    span = 440 + 300                                   # entries for 300 blocks, then MinGameBlocks(20)
    tb = H.accepted_tournament(w, ctx, creator="carol", asset=0, entry=BEAM, letter_price=BEAM // 100,
                               sponsored=3 * BEAM // 10, creator_bps=0, max_open=4, len_mask=7,
                               start_h=w.h + 2, end_h=w.h + 2 + span, game_blocks=440, answer_blocks=20)
    tk = H.accepted_tournament(w, ctx, creator="carol", asset=7, entry=2 * BEAM, letter_price=5000000,
                               sponsored=0, creator_bps=0, max_open=8, len_mask=2,
                               start_h=w.h + 2, end_h=w.h + 2 + span, game_blocks=440, answer_blocks=20)
    tu = w.ntournaments()
    w.create_tournament("zed", start_h=w.h + 2, end_h=w.h + 2 + span, game_blocks=440)
    for _ in range(4):
        x.block()
    assert w.tournament(tu)["phase"] == "awaiting_answerer", w.tournament(tu)
    while w.h < w.tournament(tb)["start_h"] or w.h < w.tournament(tk)["start_h"]:
        x.block()

    me = x.view("my_key", "alice", "my_key")
    pk_bob = x.view(None, "bob", "my_key")["my_pk"]
    assert pk_bob == bob.pk and me["my_pk"] == alice.pk
    x.view("view_state", "alice", "view_state")
    x.view("answerer", "alice", "view_answerer", pk=w.svc_pk)
    x.view("tournament_unaccepted", "alice", "view_tournament", tid=tu)
    x.view("err_enter_unaccepted", "alice", "enter_game", err="has not accepted", tid=tu, len=5)
    x.view("err_game_not_found", "alice", "view_game", err="game not found", tid=999, idx=0)

    # ---------------------------------------------------------------- A: solved, six wrong, tokens
    g1 = x.enter("alice", tb, 5, "enter_beam", "locks 1 BEAM entry + 0.12 BEAM answering fee: one BEAM entry of 1.12; charge 220000")
    x.gview("game_your_move_fresh", tb, g1, "your_move")
    x.send("buy_letters", "alice", "buy_letters", "locks 5 x 0.01 BEAM = 0.05 BEAM (letters q, q, x, z, b)", tid=tb, letters="qxzbq")
    x.block()
    b0 = x.enter("bob", tb, 4)
    k1 = x.enter("alice", tk, 5, "enter_token", "locks 2 (2e8 groth) of asset 7 + 0.12 BEAM answering fee: two funds entries")
    k2 = x.enter("alice", tk, 5)                       # never played: refunded with the final claim
    g2 = x.enter("alice", tb, 6)

    first = "qxzcd" if x.word(tb, g1) != "qxzcd" else "qxzcf"
    x.guess("alice", tb, g1, first, 1, "guess_buy_missing", "q, x, z from stock; buys the 2 missing letters inline: locks 0.02 BEAM")
    x.guess("alice", tk, k1, x.wrong(tk, k1, 5), 1, "guess_token_buy_missing", "no stock: buys all 5 letters inline: locks 5 x 5e6 = 2.5e7 of asset 7")
    x.guess("bob", tb, b0, x.wrong(tb, b0, 4))
    x.mine()
    x.gview("game_waiting_hint", tb, g1, "waiting_hint")
    x.tick()
    x.mine()
    x.gview("game_hinted", tb, g1, "your_move")

    x.guess("alice", tb, g1, x.wrong(tb, g1, 5))
    x.guess("alice", tk, k1, x.word(tk, k1))          # alice solves the token game at attempt 2
    x.guess("bob", tb, b0, x.word(tb, b0))            # bob solves at attempt 2: two scorers
    x.answer_round()

    word = x.word(tb, g1)
    have = list(x.stock("alice", tb))
    need = ""
    for c in word:
        k = ord(c) - 97
        if have[k]:
            have[k] -= 1
        else:
            need += c
    if need:
        x.send(None, "alice", "buy_letters", tid=tb, letters=need)
        x.block()
    x.guess("alice", tb, g1, word, 0, "guess_from_stock", "every letter from stock (buy_missing=0): no funds, the fee only")
    x.answer_round()
    x.gview("game_waiting_reveal_solved", tb, g1, "waiting_reveal")
    x.until_phase(tb, g1, "revealed")
    x.gview("game_revealed_solved", tb, g1)

    for _ in range(6):
        x.guess("alice", tb, g2, x.wrong(tb, g2, 6))
        x.answer_round()
    x.until_phase(tb, g2, "revealed")
    x.gview("game_revealed_unsolved_six", tb, g2)
    for tid, idx in ((tb, b0), (tk, k1)):
        x.until_phase(tid, idx, "revealed")
    x.view("tournament_beam", "alice", "view_tournament", tid=tb)
    x.view("tournament_token", "alice", "view_tournament", tid=tk)

    # ---------------------------------------------------------------- B: idle, silent, unplayed, unrevealed
    g3 = x.enter("alice", tb, 4)                       # one wrong guess, then idle: ends unsolved
    g4 = x.enter("alice", tb, 6)                       # the service never answers: silent
    g5 = x.enter("alice", tb, 5)                       # never played
    g6 = x.enter("alice", tb, 4)                       # solved, then never revealed
    x.view("err_enter_max_open", "alice", "enter_game", err="most open games", tid=tb, len=5)
    x.guess("alice", tb, g3, x.wrong(tb, g3, 4))
    x.guess("alice", tb, g6, x.word(tb, g6))
    x.answer_round()
    ha = x.game(tb, g3)["guesses"][0]["answered_h"]
    assert x.game(tb, g6)["guesses"][0]["answered_h"] == ha
    x.guess("alice", tb, g4, x.wrong(tb, g4, 6))
    x.mine()                                           # from here the service sleeps
    hg4 = x.game(tb, g4)["guesses"][0]["guessed_h"]
    x.mine(hg4 + 21 - x.h)
    x.gview("game_hint_overdue", tb, g4, "hint_overdue")
    x.mine(ha + 62 - x.h)
    x.gview("game_waiting_reveal_idle", tb, g3, "waiting_reveal")
    x.gview("game_reveal_overdue", tb, g6, "reveal_overdue")
    x.gview("game_unplayed_ended", tb, g5, "unplayed_ended")
    x.view("err_refund_playing", "alice", "claim_refund", err="only a failed game", tid=tb, idx=g3)

    x.send("claim_timeout_silent", "alice", "claim_timeout", "unsigned, no funds: ends the unanswered game as silent (verdict 3)", tid=tb, idx=g4)
    x.send("claim_timeout_unrevealed_bob", "bob", "claim_timeout", "anyone (bob) ends alice's unrevealed game (verdict 4); no funds", tid=tb, idx=g6)
    x.send("claim_timeout_unplayed", "alice", "claim_timeout", "unsigned, no funds: ends the never-played game (verdict 5)", tid=tb, idx=g5)
    x.mine()
    x.gview("game_failed_silent", tb, g4, "failed")
    x.gview("game_failed_unrevealed", tb, g6, "failed")
    x.gview("game_ended_unplayed", tb, g5, "ended_unplayed")
    x.send("claim_refund_failed", "alice", "claim_refund", "unlocks entry 1 + letters used 6 x 0.01 + answering fee 0.12 + slash 0.5 = 1.68 BEAM (one BEAM entry)", tid=tb, idx=g4)
    x.send("claim_refund_unplayed", "alice", "claim_refund", "unlocks entry 1 + answering fee 0.12 = 1.12 BEAM, no slash", tid=tb, idx=g5)
    x.mine()
    x.gview("game_refunded", tb, g4, "failed")
    x.gview("game_refunded_unplayed", tb, g5, "ended_unplayed")
    x.view("err_already_refunded", "alice", "claim_refund", err="already refunded", tid=tb, idx=g4)
    x.tick()                                           # the service wakes up and reveals the idle game
    x.until_phase(tb, g3, "revealed", limit=40)
    x.gview("game_revealed_idle", tb, g3)

    # ---------------------------------------------------------------- C: full, eviction, the end
    bs = [x.enter("bob", tb, 5) for _ in range(3)]
    g7 = x.enter("alice", tb, 4)
    x.view("err_enter_full", "alice", "enter_game", err="every slot", tid=tb, len=6)
    x.until_phase(tb, bs[0], "unplayed_ended", limit=60)
    g8 = x.enter("alice", tb, 6, "enter_beam_evict", "tournament full: the shader ends bob's overdue never-played game in the same call; charge 315000; locks 1.12 BEAM")
    assert x.game(tb, bs[0])["phase"] == "ended_unplayed", x.game(tb, bs[0])
    x.view("err_not_your_game", "alice", "submit_guess", err="not your game", tid=tb, idx=bs[1], attempt=0, guess="bcdfg", buy_missing=1)
    x.view("err_claim_not_finalised", "alice", "claim", err="not finalised", tid=tb)
    x.view("my_tournament_open", "alice", "view_my_tournament", tid=tb)
    x.view("tournaments", "alice", "view_tournaments", skip=0, limit=50)
    for idx in (bs[1], bs[2], g7, g8):
        x.until_phase(tb, idx, "unplayed_ended", limit=60)
    for idx in (bs[1], bs[2], g7, g8):
        x.send(None, "bob", "claim_timeout", tid=tb, idx=idx)
    x.send(None, "bob", "claim_timeout", tid=tk, idx=k2)
    x.mine()
    x.view("my_games", "alice", "view_my_games", tid=tb)
    for tid in (tb, tk):
        t = w.tournament(tid)
        assert t["open_games"] == 0, t
    end = max(w.tournament(tb)["end_h"], w.tournament(tk)["end_h"])
    x.mine(end + 1 - x.h)                              # the service sleeps: alice settles herself
    x.view("tournament_beam_ready", "alice", "view_tournament", tid=tb)
    x.send("finalize_beam", "alice", "finalize", "unsigned, no funds: settles the tournament", tid=tb)
    x.send("finalize_token", "alice", "finalize", "unsigned, no funds: settles the token tournament", tid=tk)
    x.mine()
    x.view("tournament_beam_final", "alice", "view_tournament", tid=tb)
    x.view("tournament_token_final", "alice", "view_tournament", tid=tk)
    x.view("my_tournament_final", "alice", "view_my_tournament", tid=tb)
    x.view("my_tournament_token_final", "alice", "view_my_tournament", tid=tk)
    x.view("claimable", "alice", "view_claimable", skip=0, limit=200)
    x.send("claim_beam", "alice", "claim", "unlocks alice's prize share + refunds not taken early (g6 failed: entry, letters, fee, slash; g7, g8 unplayed: entry + fee): one BEAM entry", tid=tb)
    x.send("claim_token", "alice", "claim", "unlocks prize + the unplayed game's entry in asset 7, and its answering fee in BEAM: two funds entries", tid=tk)
    x.mine()
    x.view("my_tournament_claimed", "alice", "view_my_tournament", tid=tb)
    x.view("err_already_claimed", "alice", "claim", err="already claimed", tid=tb)
    x.view("view_state_end", "alice", "view_state")
    n, fails = w.failures()
    assert n == 0, fails

    data = {
        "source": "Fuddle v9 8e86b3140 (app.wasm sha256 %s), run in BEAM 7.5.14493's BVM through the answer "
                  "service's simulator bridge (service/test/build/fuddle9_bridge); words are made-up test strings" % APP_PIN,
        "app_sha256": APP_PIN,
        "cid": w.cid,
        "service_pk": w.svc_pk,
        "players": {"alice": alice.pk, "bob": bob.pk},
        "games": {"tb": tb, "tk": tk, "tu": tu, "g": [g1, g2, g3, g4, g5, g6, g7, g8], "k": [k1, k2], "bob": [b0] + bs},
        "views": x.views,
        "builds": x.builds,
    }
    with open(OUT, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    summary(x, data)


def summary(x, data):
    for name, v in data["views"].items():
        o = json.loads(v["output"])
        g = o.get("game") or o.get("tournament") or o.get("me") or {}
        print("view  %-28s h=%d %s" % (name, v["height"], o.get("error") or " ".join("%s=%s" % (k, g[k]) for k in ("phase", "verdict", "attempts", "solved_at", "refunded", "joined", "claimable") if k in g)))
    for name, b in data["builds"].items():
        t = b.get("tx") or {}
        print("build %-28s h=%d landed=%s charge=%s fee=%s pays=%s" % (name, b["height"], b["landed"], t.get("charge"), t.get("fee"), json.dumps(t.get("pays"))))
    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
