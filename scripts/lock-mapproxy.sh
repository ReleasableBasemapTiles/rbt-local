#!/usr/bin/env bash
# Regenerate the MapProxy image's lock files from mapproxy/environment.yml:
#
#   mapproxy/conda-linux-64.lock       (linux/amd64)
#   mapproxy/conda-linux-aarch64.lock  (linux/arm64)
#
#   scripts/lock-mapproxy.sh
#
# Dockerfile.mapproxy installs exactly the packages in these files, not
# whatever conda-forge resolves on the day of the build, so the image is the
# same each time it is built and a conda-forge release can't change what a
# merge ships. Run this after editing mapproxy/environment.yml, or to take
# newer packages on purpose. It is a fresh solve either time: every package
# moves to the newest version the specs allow, so read the diff of the lock
# files before you commit them, and run `docker compose build mapproxy` (its
# smoke tests assert PROJ >= 9.8 and a known EPSG:4087 coordinate) and the
# smoke test (.github/scripts/smoke-test.sh) against the result.
#
# The solve runs inside the same micromamba image the Dockerfile builds on, so
# it needs only Docker, and it solves for both platforms whichever one this
# machine is. It reads conda-forge's package index over the network but
# downloads no packages. Merging the resulting change rebuilds and publishes
# the image, so CLAUDE.md's "Ask first" applies.
#
# Runs under macOS's /bin/bash 3.2 as well as current bash.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

case "${1:-}" in
  -h | --help)
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  "") ;;
  *)
    echo "error: unexpected argument '$1' (try --help)" >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required to run the solver; install it first (README.md)." >&2
  exit 1
fi

# The solver's image is the Dockerfile's base, so the micromamba that locks is
# the micromamba that installs.
image="$(sed -n 's/^FROM //p' Dockerfile.mapproxy)"
if [ -z "$image" ] || [ "$(printf '%s\n' "$image" | wc -l)" -ne 1 ]; then
  echo "error: expected exactly one FROM line in Dockerfile.mapproxy; update this script." >&2
  exit 1
fi

echo "Solving mapproxy/environment.yml for linux-64 and linux-aarch64 in $image ..."

# Runs as root so micromamba can install conda-lock into the image's base
# prefix; the chown at the end hands the results back to you rather than root.
docker run --rm --user root \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
  -v "$ROOT:/work" -w /work \
  "$image" sh -ec '
    micromamba install -y -q -n base -c conda-forge conda-lock
    PATH="$MAMBA_ROOT_PREFIX/bin:$PATH"
    conda-lock lock --micromamba -f mapproxy/environment.yml \
      -p linux-64 -p linux-aarch64 --lockfile /tmp/conda-lock.yml
    conda-lock render -k explicit -p linux-64 -p linux-aarch64 \
      --filename-template "mapproxy/conda-{platform}.lock" /tmp/conda-lock.yml
    python .github/scripts/mapproxy_lock.py stamp mapproxy/environment.yml \
      mapproxy/conda-linux-64.lock mapproxy/conda-linux-aarch64.lock
    chown "$HOST_UID:$HOST_GID" mapproxy/conda-linux-64.lock mapproxy/conda-linux-aarch64.lock
  '

echo
echo "Wrote mapproxy/conda-linux-64.lock and mapproxy/conda-linux-aarch64.lock."
echo "Review the diff, then check the image builds: docker compose build mapproxy"
