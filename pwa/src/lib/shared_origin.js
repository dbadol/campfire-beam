// Where BEAM Campfire must not keep a wallet: a web address other sites share (audit E-3).
// On <user>.github.io every GitHub Pages project of that user (github.com/<user>/<repository>) is
// one origin, so any of them could read this app's storage and use its passkeys (a passkey belongs
// to the host). The copy published there (vsnation.github.io/beam-campfire-pwa/) exists so that
// installed apps can still fetch signed updates when their own address is gone; the wallet is used
// at BEAM Campfire's own address. Only adding a wallet is refused: one already on such a copy keeps
// working, so nobody is locked out of their coins. No imports: lib/session.js and the screens use it.

export const SHARED_HOST_SUFFIXES = Object.freeze(['.github.io']);

// BEAM Campfire's own address, where wallets are created, restored and imported.
export const HOME_HOST = 'pwa.buybeam.my';
export const HOME_URL = `https://${HOME_HOST}/`;

/** Whether a host name is one other sites share. */
export function isSharedOrigin(hostname) {
  const h = String(hostname || '').toLowerCase().replace(/\.$/, '');
  return SHARED_HOST_SUFFIXES.some((s) => h.endsWith(s));
}

/** Whether this page runs on such an address. */
export function onSharedOrigin() {
  return typeof location !== 'undefined' && location !== null && isSharedOrigin(location.hostname);
}

export class SharedOriginError extends Error {
  constructor() {
    super(`This copy of BEAM Campfire is at an address other websites share, so it does not keep new wallets. Create, restore or import your wallet at ${HOME_HOST}.`);
    this.code = 'shared_origin';
  }
}

/** Throws SharedOriginError on a shared address: called before a wallet is created, restored or imported. */
export function refuseOnSharedOrigin() {
  if (onSharedOrigin()) throw new SharedOriginError();
}
