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
