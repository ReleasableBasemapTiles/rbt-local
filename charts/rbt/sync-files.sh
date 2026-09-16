#!/usr/bin/env bash
#
# Copies mapproxy/config/* and tileserver/config/config.json from the repo
# root into charts/rbt/files/ -- Helm's .Files.Get can only read files
# inside the chart directory (charts/rbt/), so these are plain copies, not
# symlinks (Helm's loader skips symlinks -- see charts/rbt/README.md
# "Why these files are duplicated"). Re-run this after editing any of the
# five source files below, then re-run `helm template`/`helm lint` on
# charts/rbt to confirm the change took effect in the rendered manifests.
#
#   ./charts/rbt/sync-files.sh          # copy repo configs into the chart
#   ./charts/rbt/sync-files.sh --check  # diff instead of copy (exits 1 on drift, for CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHART_FILES="$SCRIPT_DIR/files"

# "source path:dest path" pairs, repo root to chart files/.
PAIRS=(
  "$REPO_ROOT/mapproxy/config/mapproxy.yaml:$CHART_FILES/mapproxy/mapproxy.yaml"
  "$REPO_ROOT/mapproxy/config/mapproxy.4087.yaml:$CHART_FILES/mapproxy/mapproxy.4087.yaml"
  "$REPO_ROOT/mapproxy/config/uwsgi.ini:$CHART_FILES/mapproxy/uwsgi.ini"
  "$REPO_ROOT/mapproxy/config/logging.ini:$CHART_FILES/mapproxy/logging.ini"
  "$REPO_ROOT/tileserver/config/config.json:$CHART_FILES/tileserver/config.json"
)

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

drifted=0
for pair in "${PAIRS[@]}"; do
  src="${pair%%:*}"
  dest="${pair#*:}"

  if [[ "$CHECK" -eq 1 ]]; then
    if ! diff -q "$src" "$dest" >/dev/null 2>&1; then
      echo "DRIFT: $dest is out of date with $src" >&2
      drifted=1
    fi
  else
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "Copied $src -> $dest"
  fi
done

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "$drifted" -eq 1 ]]; then
    echo "Run charts/rbt/sync-files.sh (without --check) to fix, then commit the result." >&2
    exit 1
  fi
  echo "charts/rbt/files/ is in sync with the repo configs it mirrors."
fi
