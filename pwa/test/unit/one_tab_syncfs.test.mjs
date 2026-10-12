// One tab at a time at the engine's file system (lib/engine.js guardSyncfs): every FS.syncfs - the
// app's own and the engine's (CreateWallet and DeleteWallet call FS.syncfs themselves) - first asks
// whether this tab still holds the wallet. A tab that let it go, or lost it, writes nothing: its copy
// of /beam_wallet is older, and IDBFS would write it over the newer files and delete the rest.
import test from 'node:test';
import assert from 'node:assert/strict';
import { guardSyncfs, tabGuard } from '../../src/lib/engine.js';

function fakeModule() {
  const calls = [];
  const FS = {
    syncfs(populate, callback) {
      calls.push(populate);
      setImmediate(() => callback(null));
    },
  };
  return { M: { FS }, calls };
}

test('a flush goes through while this tab holds the wallet, and is refused (not run) once it does not', async () => {
  const ok = { value: true };
  const { M, calls } = fakeModule();
  guardSyncfs(M, { confirmWrite: async () => ok.value });
  const run = (...a) => new Promise((resolve) => M.FS.syncfs(...a, (err) => resolve(err)));
  assert.equal(await run(false), null);
  assert.equal(await new Promise((resolve) => M.FS.syncfs((err) => resolve(err))), null, 'syncfs(callback), as the engine calls it');
  assert.deepEqual(calls, [false, false]);
  ok.value = false;
  const before = tabGuard.refused;
  const err = await run(false);
  assert.equal(err && err.code, 'other_tab');
  assert.equal(tabGuard.refused, before + 1);
  assert.deepEqual(calls, [false, false], 'the real syncfs did not run');
  guardSyncfs(M, { confirmWrite: async () => true });
  assert.equal(await run(false) && 'refused', 'refused', 'wrapped once: a second guard does not replace the first');
});
