#!/usr/bin/env bash
# Quick compile check while moving text into lib/l10n: copies lib/, test/
# and l10n.yaml into the host-test copy of the tree (CFB_HOST_WORKDIR, set up
# once by `scripts/beam/host_test.sh --no-analyze --no-test`), merges every
# lib/l10n/parts/*.arb fragment into that copy's app_en.arb (the real tree is
# not touched), regenerates AppLocalizations and analyzes only the paths given.
#
#   CFB_HOST_WORKDIR=/private/tmp/cfb-i18n scripts/beam/l10n_check.sh lib/pages/beam/dex lib/widgets/beam/dex
#
# Several people can run it at once: a lock directory serialises the runs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/development/flutter-3.47.2}"
WORK="${CFB_HOST_WORKDIR:-/private/tmp/cfb-host}"
export PATH="$FLUTTER_ROOT/bin:$PATH"

[ -f "$WORK/pubspec.yaml" ] || {
  echo "$WORK is not set up: run CFB_HOST_WORKDIR=$WORK scripts/beam/host_test.sh --no-analyze --no-test"
  exit 2
}
[ $# -gt 0 ] || { echo "usage: $0 <path>..."; exit 2; }

LOCK="$WORK/.l10n_check.lock"
for _ in $(seq 1 600); do
  if mkdir "$LOCK" 2>/dev/null; then break; fi
  sleep 1
done
[ -d "$LOCK" ] || { echo "could not take $LOCK"; exit 2; }
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

rsync -a --delete \
  --exclude '/l10n/generated/' --exclude '/app_config.g.dart' --exclude '/wl_gen/generated/' \
  --exclude '/external_api_keys.dart' \
  "$REPO/lib/" "$WORK/lib/"
rsync -a --delete --exclude 'failures/' "$REPO/test/" "$WORK/test/"
cp "$REPO/l10n.yaml" "$WORK/l10n.yaml"

python3 -I "$REPO/scripts/beam/l10n_merge.py" --root "$WORK" --write --lenient
rm -rf "$WORK/lib/l10n/parts"
(cd "$WORK" && flutter gen-l10n > "$WORK/.beam-logs/gen_l10n.log" 2>&1) || {
  cat "$WORK/.beam-logs/gen_l10n.log"; exit 1;
}
cd "$WORK"
# Errors and warnings only (the upstream files carry many old infos);
# L10N_CHECK_INFOS=1 shows the infos too.
set +e
flutter analyze --no-fatal-infos --no-fatal-warnings "$@" > "$WORK/.beam-logs/l10n_check.log" 2>&1
RC=$?
if [ "${L10N_CHECK_INFOS:-0}" = 1 ]; then
  grep -E ' • ' "$WORK/.beam-logs/l10n_check.log"
else
  grep -E '^ *(error|warning) • ' "$WORK/.beam-logs/l10n_check.log"
fi
echo "errors: $(grep -cE '^ *error • ' "$WORK/.beam-logs/l10n_check.log")," \
  "warnings: $(grep -cE '^ *warning • ' "$WORK/.beam-logs/l10n_check.log")," \
  "infos: $(grep -cE '^ *info • ' "$WORK/.beam-logs/l10n_check.log")"
exit "$RC"
