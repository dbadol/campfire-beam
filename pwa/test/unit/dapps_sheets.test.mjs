// What the dApp sheets tell the person before they open, install or let a dApp reach a server.
// The sheets are built inside the screens; this reads each sheet's own code for its words.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const screens = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src', 'screens');
const source = (file) => readFileSync(join(screens, file), 'utf8');

/** The code of `function name(` up to the next function at the same indent. */
function sheet(file, name) {
  const s = source(file);
  const start = s.search(new RegExp(`\\n( *)(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `${file}: ${name}`);
  const indent = /\n( *)/.exec(s.slice(start))[1];
  const next = s.slice(start + 1).search(new RegExp(`\\n${indent}(?:async )?function |\\n${indent}// -{10}`));
  return next < 0 ? s.slice(start) : s.slice(start, start + 1 + next);
}

// A name the browser looks up can lead anywhere, even into the person's own network.
test("the allow-a-server sheet says the server's name can lead to a device on the person's own network", () => {
  assert.match(sheet('dapps.js', 'askNext'), /device on your own network, such as your router/);
});

// wallet_status is open to every dApp without asking (BEAM's own rule, as on the desktop): the
// wallet's total BEAM and token balances. Each way a dApp first reaches the wallet says so.
test('opening and installing from the store say the dApp can see the balance; from a file, that it asks first', () => {
  const balance = /can see your balance/;
  assert.match(sheet('dapps.js', 'prepareSheet'), balance, "BEAM's own dApps: the open sheet");
  assert.match(sheet('dapps.js', 'confirmInstall'), /asks before it sees your balance/, 'a dApp from a file: the install sheet (it asks first)');
  const note = source('dapp_store.js').split('\n').find((l) => l.includes("'data-testid': 'store-item-note'"));
  assert.match(note, balance, "a dApp from BEAM's DApp Store: the note under Install");
});

// A dApp installed from a file asks first (lib/dapps/session.js confirmBalance); More shows the answer.
test('a dApp from a file asks before it sees the balance, and More shows the answer with a way to change it', () => {
  const ask = sheet('dapps.js', 'askBalance');
  assert.match(ask, /Let \$\{name\} see your balance\?/);
  assert.match(ask, /It can send what it sees to any server\./);
  assert.match(sheet('dapps.js', 'fileMoreSheet'), /rec\.store \? null : balanceRow\(/);
  const row = sheet('dapps.js', 'balanceRow');
  assert.match(row, /dapp-balance-row/);
  assert.match(row, /'Remove access'/);
  assert.match(row, /'Ask me again'/);
  assert.match(source('dapps.js'), /confirmBalance: e\.file && !e\.rec\.store \?/);
});
