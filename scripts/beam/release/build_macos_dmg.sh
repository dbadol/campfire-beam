#!/usr/bin/env bash
# Builds BEAM Campfire for macOS (Apple Silicon) from the COMMITTED tree and
# packages a DMG.
#
#   scripts/beam/release/build_macos_dmg.sh [version] [build-number]
#
# Works in a clean clone reset to HEAD (release_tree.sh), so unfinished files
# in the working tree never reach a build. The BEAM core ships inside the app
# as one library, BEAM Campfire.app/Contents/Frameworks/libbeam_core.dylib
# (wallet-api and the node run as threads of the app; no wallet-api,
# beam-node or beam-wallet program is bundled). It is staged from
# beam-core-build/out with its pinned SHA-256 checked against both
# scripts/beam/core/lib/manifest.json and the pin compiled into the app.
#
# The app is signed ad hoc (no Developer ID yet), so the first launch needs
# right-click -> Open. Output: $CFB_ARTIFACTS_DIR (default
# ~/Desktop/Beam/cfb-artifacts/release-<version>).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSION="${1:-1.0.0}"; BUILD="${2:-1}"
OUT_DIR="${CFB_ARTIFACTS_DIR:-$HOME/Desktop/Beam/cfb-artifacts/release-$VERSION}"
FLUTTER="${FLUTTER:-$HOME/development/flutter-3.47.2/bin/flutter}"
# Campfire's configure step calls `dart` and `flutter` by name.
export PATH="$(dirname "$FLUTTER"):$PATH"
. "$REPO/scripts/beam/release/release_tree.sh"
ENTITLEMENTS=scripts/beam/release/campfire_beam_unsandboxed.entitlements

prepare_release_tree
cd "$REL"
PIN="$(dart_core_pin macos-arm64)"

(cd scripts && echo yes | ./build_app.sh -v "$VERSION" -b "$BUILD" -p macos -a campfire -d) > /dev/null
# The core is the library, not executables: configure's stage_binaries.sh
# leaves every assets/beam/bin folder empty for macOS. Checked, not assumed.
if [[ -n "$(find assets/beam/bin -type f)" ]]; then
  find assets/beam/bin -type f >&2
  die "assets/beam/bin holds files; a macOS build bundles no BEAM executables"
fi
# lib/external_api_keys.dart is git-ignored; prebuild writes it with empty
# keys (exchange features are off in this build), as CI does.
(cd scripts && ./prebuild.sh) > /dev/null
"$FLUTTER" build macos --release

APP="build/macos/Build/Products/Release/BEAM Campfire.app"
# Never "Campfire.app": dragged to /Applications it would replace Firo's Campfire.
[[ -d "$APP" ]] || { echo "no BEAM Campfire.app produced:"; ls build/macos/Build/Products/Release/; exit 1; }
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
LIB="$APP/Contents/Frameworks/libbeam_core.dylib"
links_before="$(otool -L "$EXE" | tail -n +2)"
# An incremental build keeps the bundle, and with it the library staged last
# time; step 1 would re-sign that copy. It is staged afresh in step 2.
rm -f "$LIB"

# 0. Debug-map entries (stabs: build and pub-cache source paths, under the
# account's home) out of the app's own Mach-O files. strip -S removes only
# debugging symbols; the signatures it breaks are redone in step 1.
while IFS= read -r -d '' f; do
  if [[ "$(file -b "$f")" == Mach-O* ]]; then strip -S "$f" 2>/dev/null; fi
done < <(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f -print0)

# 1. Everything Flutter built, re-signed ad hoc without the sandbox.
log "re-signing $(basename "$APP") ad hoc, without the sandbox"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"

# 2. The core. It carries its own ad hoc signature, and those bytes are what
# is pinned: re-signing it (step 1's --deep) would change its SHA-256 and the
# app would refuse it. So it goes in after step 1 and is never re-signed.
scripts/beam/core/lib/stage_lib.sh macos "$APP/Contents/Frameworks"
[[ "$(sha256_of "$LIB")" == "$PIN" ]] \
  || die "libbeam_core.dylib is not the pin compiled into the app ($PIN)"

# 3. Seal the bundle with the library inside (main executable re-signed,
# nested code recorded as it is).
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$LIB"
[[ "$(sha256_of "$LIB")" == "$PIN" ]] || die "signing changed libbeam_core.dylib"
[[ "$(otool -L "$EXE" | tail -n +2)" == "$links_before" ]] \
  || die "the app executable's linked libraries changed while packaging"
log "libbeam_core.dylib in Frameworks, sha256 $PIN (the app's pin)"

# No BEAM executables anywhere in the bundle.
found="$(find "$APP" -type f \( -name wallet-api -o -name beam-node -o -name beam-wallet \))"
[[ -z "$found" ]] || die "BEAM executables in the app: $found"

# Nothing from this machine (account name, home path) may ship in the app.
check_no_account_name "$APP"

# 4. It starts. The app runs once from a fresh, empty home (CFFIXED_USER_HOME
# moves ~/Library, where its data lives, so the wallets of an installed copy
# are never opened) and must still be running, with no unhandled exception,
# after 30 s. 1.3.0's first trial build passed every test and opened as a
# black window: BEAM's themes crashed startup while being stored.
# CFB_SKIP_START_CHECK=1 skips it (a machine with no screen).
if [[ "${CFB_SKIP_START_CHECK:-}" != 1 ]]; then
  start_home="$(mktemp -d)"
  start_log="$start_home/start.log"
  # Before the app runs at all: the redirect must reach Foundation's Library
  # lookup (where the app's data and the core's node and wallets live), or the
  # app would open the real ~/Library/campfirebeam.
  probe="$(CFFIXED_USER_HOME="$start_home" osascript -l JavaScript -e \
    'ObjC.import("Foundation"); $.NSSearchPathForDirectoriesInDomains($.NSLibraryDirectory, $.NSUserDomainMask, true).objectAtIndex(0).js')"
  # Compared as resolved paths: Foundation writes /private/tmp as /tmp.
  [[ "$(basename "$probe")" == Library \
     && "$(cd "$(dirname "$probe")" 2>/dev/null && pwd -P)" == "$(cd "$start_home" && pwd -P)" ]] \
    || die "CFFIXED_USER_HOME is not honoured here ($probe); the start check would use the real data"
  CFFIXED_USER_HOME="$start_home" "$EXE" >"$start_log" 2>&1 &
  start_pid=$!
  start_ok=1
  for _ in $(seq 30); do
    sleep 1
    if ! kill -0 "$start_pid" 2>/dev/null; then start_ok=0; break; fi
    if grep -q "Unhandled Exception" "$start_log"; then start_ok=0; break; fi
  done
  kill "$start_pid" 2>/dev/null || true; sleep 2; kill -9 "$start_pid" 2>/dev/null || true
  if [[ $start_ok != 1 ]]; then
    grep -m1 -A8 "Unhandled Exception" "$start_log" >&2 || tail -20 "$start_log" >&2
    die "the app did not start cleanly from an empty home (log above)"
  fi
  [[ -d "$start_home/Library/campfirebeam" ]] \
    || die "the start check's app did not use its empty home; refusing to trust it"
  rm -rf "$start_home"
  log "the app starts from an empty home: running after 30 s, no unhandled exception"
fi

mkdir -p "$OUT_DIR" dist && rm -rf dist/stage && mkdir dist/stage
cp -R "$APP" dist/stage/ && ln -s /Applications dist/stage/Applications
DMG="$OUT_DIR/BEAM-Campfire-${VERSION}-${BUILD}-macos-arm64${SUFFIX}.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "BEAM Campfire" -srcfolder dist/stage -ov -format UDZO "$DMG"
rm -rf dist/stage
log "DMG: $DMG ($(du -h "$DMG" | cut -f1)), sha256 $(sha256_of "$DMG")"
