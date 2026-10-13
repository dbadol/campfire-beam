// The approve sheet's words for the wallet's own features: BEAM names and
// airdrop codes say what approving does, and "not enough" counts what the
// request itself brings in, as the engine does.
import test from 'node:test';
import assert from 'node:assert/strict';
import { approveLabel, shortfall } from '../../src/screens/consent.js';

const unit = (id) => ({ 0: 'BEAM', 174: 'FOMO' })[id] || `Asset #${id}`;
const req = (intent, spends, receives, fee = 1100000n) => ({ kind: 'contract', intent, fee, spends, receives });

test('names and airdrops: the button says the outcome', () => {
  const beam = (amount) => [{ assetId: 0, amount }];
  assert.equal(approveLabel(req({ action: 'nameRegister', name: 'alice', periods: 1 }, beam(116213166091n), []), unit), 'Pay 1,162.13 BEAM and register alice');
  assert.equal(approveLabel(req({ action: 'nameRenew', name: 'alice', periods: 2 }, beam(232426332182n), []), unit), 'Pay 2,324.26 BEAM and renew alice');
  assert.equal(approveLabel(req({ action: 'namePay', name: 'beam' }, beam(100000n), []), unit), 'Send 0.001 BEAM to beam.beam');
  assert.equal(approveLabel(req({ action: 'airdropCreate', count: 2 }, beam(202000n), [], 12100000n), unit), 'Lock 0.00202 BEAM in 2 codes');
  assert.equal(approveLabel(req({ action: 'airdropCreate', count: 1 }, [{ assetId: 174, amount: 505000000n }], [], 12100000n), unit), 'Lock 5.05 FOMO in 1 code');
  assert.equal(approveLabel(req({ action: 'airdropClaim' }, [], [{ assetId: 174, amount: 500000000n }], 12100000n), unit), 'Claim 5 FOMO');
  assert.equal(approveLabel(req({ action: 'airdropCancel', count: 1 }, [], beam(100000n), 18100000n), unit), 'Take back 0.001 BEAM');
  // Anything other than the expected shape falls back to the plain words.
  assert.equal(approveLabel(req({ action: 'airdropClaim' }, beam(5n), [{ assetId: 174, amount: 500000000n }]), unit), 'Pay 0.00000005 BEAM, get 5 FOMO');
  assert.equal(approveLabel(req({ action: 'nameRegister', name: 'x' }, [], []), unit), 'Approve');
});

test('not enough: what the request brings in of an asset counts towards it', () => {
  const none = () => 0n;
  // Claiming 5 FOMO on an empty wallet: the network fee is the whole need.
  assert.deepEqual(shortfall(req({ action: 'airdropClaim' }, [], [{ assetId: 174, amount: 500000000n }], 12100000n), none), { assetId: 0, need: 12100000n, have: 0n, includesFee: true });
  // Claiming 0.001 BEAM: that much less is needed.
  assert.deepEqual(shortfall(req({ action: 'airdropClaim' }, [], [{ assetId: 0, amount: 100000n }], 12100000n), none), { assetId: 0, need: 12000000n, have: 0n, includesFee: true });
  // A BEAM voucher worth more than the fee pays for itself.
  assert.equal(shortfall(req({ action: 'airdropClaim' }, [], [{ assetId: 0, amount: 50000000n }], 12100000n), none), null);
  // Creating codes: the locked amount plus the fee.
  assert.deepEqual(shortfall(req({ action: 'airdropCreate', count: 2 }, [{ assetId: 0, amount: 202000n }], [], 12100000n), none), { assetId: 0, need: 12302000n, have: 0n, includesFee: true });
});

// Airdrop v3: a create also locks the claim fees paid ahead, a claim also releases one (to pay its
// network fee), a take-back returns them. The sheet says so in one line, and a claim whose code pays
// its own fee is not "not enough" on an empty wallet (what it brings in counts).
test('airdrop v3: claim fees paid ahead are named on the button, and a prepaid claim needs no BEAM', () => {
  const none = () => 0n;
  const fee = 2100000n;
  assert.equal(approveLabel(req({ action: 'airdropCreate', count: 10 }, [{ assetId: 0, amount: 26250000n }, { assetId: 36, amount: 1010000n }], [], 4250000n), unit), 'Lock 0.0101 Asset #36 + 0.2625 BEAM in 10 codes');
  // The voucher's asset names the claim, whatever order the engine lists what arrives in.
  const claim = req({ action: 'airdropClaim', assetId: 36 }, [], [{ assetId: 0, amount: 2200000n }, { assetId: 36, amount: 500000000n }], fee);
  assert.equal(approveLabel(claim, unit), 'Claim 5 Asset #36');
  assert.equal(shortfall(claim, none), null, 'an empty wallet can approve it');
  assert.equal(approveLabel(req({ action: 'airdropClaim', assetId: 0 }, [], [{ assetId: 0, amount: 52200000n }], fee), unit), 'Claim 0.522 BEAM');
  // Without a prepaid fee, the fee is the need.
  assert.deepEqual(shortfall(req({ action: 'airdropClaim', assetId: 36 }, [], [{ assetId: 36, amount: 500000000n }], fee), none), { assetId: 0, need: fee, have: 0n, includesFee: true });
  assert.equal(approveLabel(req({ action: 'airdropCancel', count: 2 }, [], [{ assetId: 36, amount: 200000n }, { assetId: 0, amount: 4400000n }], 1100000n), unit), 'Take back 0.002 Asset #36 + 0.044 BEAM');
  assert.equal(approveLabel(req({ action: 'airdropCancel', count: 2 }, [], [{ assetId: 0, amount: 4400000n }, { assetId: 36, amount: 200000n }], 1100000n), unit), 'Take back 0.002 Asset #36 + 0.044 BEAM', 'whatever order the engine lists them in');
  // Three assets out or something paid on a claim: the plain words.
  assert.equal(approveLabel(req({ action: 'airdropClaim', assetId: 36 }, [], [{ assetId: 0, amount: 1n }, { assetId: 36, amount: 1n }, { assetId: 7, amount: 1n }], fee), unit), 'Approve and get 0.00000001 BEAM + 0.00000001 Asset #36 + 0.00000001 Asset #7');
});
