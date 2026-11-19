#!/usr/bin/env bash
# Run the repository's checks: the same commands CI runs, so a green local run
# means a green CI run. CI calls this script too, which is what keeps the two
# from drifting apart. CLAUDE.md's "Checks" and CONTRIBUTING.md's "Checks"
# describe it.
#
#   scripts/check.sh [GROUP ...]       no GROUP means all
#
#   scripts   ShellCheck on the shell scripts, and a parse of deploy.ps1
#   compose   every Compose stack, and nginx.conf in the pinned nginx image
#   configs   every tracked JSON file, and MapProxy's configs (the MapProxy rules)
#   sync      the facts the repo states in more than one place (check-sync.py)
#   docs      the docs site build (mkdocs build --strict)
#   all       every group above
#
# A check whose tool is missing is skipped with a warning when you run it
# locally, since few people have every tool. With CI=true (GitHub Actions sets
# it) a missing tool is a failure instead, so a runner that loses a tool can't
# turn a check into a silent pass.
#
# Python: the `configs`, `sync` and `docs` groups need MapProxy, PyYAML and
# MkDocs. They use $PYTHON if you set it, else the python in
# ~/.venvs/rbt-local or in the repo's own .venv (gitignored) if either exists,
# else python3. CONTRIBUTING.md shows how to make the virtualenv.
#
# This runs under macOS's /bin/bash 3.2 as well as current bash, so no mapfile,
# associative arrays or ${var,,}, and no expanding an array that may be empty.
# It deliberately doesn't use `set -e`: every check in a group should run, so
# one run reports every problem instead of the first.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if [ -n "${PYTHON:-}" ]; then
  PY="$PYTHON"
elif [ -x "$HOME/.venvs/rbt-local/bin/python" ]; then
  PY="$HOME/.venvs/rbt-local/bin/python"
elif [ -x "$ROOT/.venv/bin/python" ]; then
  PY="$ROOT/.venv/bin/python"
else
  PY="python3"
fi

FAILED=0
SKIPPED=""

# The header comment above, without its leading "# ".
usage() {
  sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"
}

section() {
  echo
  echo "==> $1"
}

fail() {
  echo "error: $*" >&2
  FAILED=$((FAILED + 1))
}

# Print the command, run it, and count a failure without stopping. Returns the
# command's status, so `run a && run b` skips b when a fails.
run() {
  echo "+ $*"
  "$@" && return 0
  fail "failed: $*"
  return 1
}

# missing WHAT HINT: a check can't run for lack of WHAT (see the header).
missing() {
  if [ "${CI:-}" = "true" ]; then
    fail "$1 is not installed, and CI has to run every check"
  else
    echo "warning: skipped -- $1 is not installed ($2). CI runs this check." >&2
    SKIPPED="${SKIPPED:+$SKIPPED, }$1"
  fi
}

# have_tool TOOL HINT: true when TOOL is on PATH; otherwise records it as missing.
have_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  missing "$1" "$2"
  return 1
}

# The venv recipe CONTRIBUTING.md gives, as a hint for the Python checks.
python_hint() {
  echo "python3 -m venv ~/.venvs/rbt-local && ~/.venvs/rbt-local/bin/pip install -r requirements-docs.txt \"MapProxy==\$(sed -n 's/^ARG MAPPROXY_VERSION=//p' Dockerfile.mapproxy)\""
}

# have_python_modules WHAT MODULE...: true when $PY can import every MODULE.
# Name a module the repo has no directory of: `python -c` puts the current
# directory first on sys.path, and `import mapproxy` would succeed from the
# repo's own mapproxy/ directory (a namespace package) with MapProxy absent.
have_python_modules() {
  local what="$1" module
  shift
  if ! command -v "$PY" >/dev/null 2>&1; then
    missing "$PY" "install Python 3"
    return 1
  fi
  for module in "$@"; do
    if ! "$PY" -c "import $module" >/dev/null 2>&1; then
      missing "$what (Python package, for $PY)" "$(python_hint)"
      return 1
    fi
  done
  return 0
}

# The PowerShell parser's errors, as `deploy.ps1:LINE: message`, or as GitHub
# annotations on the file under Actions. Exits 1 when there are any. It is
# PowerShell, so the $ signs are meant to reach pwsh unexpanded.
# shellcheck disable=SC2016
PS_PARSE_DEPLOY='
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$PWD/deploy.ps1", [ref]$tokens, [ref]$errors)
foreach ($e in $errors) {
  if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Output "::error file=deploy.ps1,line=$($e.Extent.StartLineNumber)::$($e.Message)"
  } else {
    Write-Output "deploy.ps1:$($e.Extent.StartLineNumber): $($e.Message)"
  }
}
if ($errors) { exit 1 }
'

check_scripts() {
  section "scripts"
  if have_tool shellcheck "brew install shellcheck, or apt install shellcheck"; then
    run shellcheck deploy.sh .githooks/commit-msg scripts/check.sh scripts/lock-mapproxy.sh \
      .github/scripts/smoke-test.sh
  fi
  if have_tool pwsh "brew install --cask powershell, or https://aka.ms/powershell"; then
    echo "+ pwsh -NoProfile -Command <parse deploy.ps1>"
    pwsh -NoProfile -Command "$PS_PARSE_DEPLOY" || fail "deploy.ps1 doesn't parse (see above)"
  fi
}

# nginx.conf, in the nginx image docker-compose.override.yaml pins (read from
# the Compose files so it follows Dependabot's bumps). mapproxy and
# tileservergl always exist when nginx starts; tileservergl4087 only in the
# 4087 stack, so nginx.conf must not need its address at startup.
check_nginx() {
  local image
  if ! image="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --images | grep '^nginx:')"; then
    fail "can't read the nginx image from docker-compose.override.yaml"
    return
  fi
  run docker run --rm \
    --add-host mapproxy:127.0.0.1 \
    --add-host tileservergl:127.0.0.1 \
    -v "$ROOT/nginx/config/nginx.conf:/etc/nginx/nginx.conf:ro" \
    "$image" nginx -t
}

check_compose() {
  section "compose"
  have_tool docker "install Docker, https://docs.docker.com/get-docker/" || return 0
  # Any -f drops docker-compose.override.yaml, so CI validates all four combinations.
  run docker compose -f docker-compose.yaml config --quiet
  run docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --quiet
  run docker compose -f docker-compose.yaml -f docker-compose.4087.yaml config --quiet
  run docker compose -f docker-compose.yaml -f docker-compose.4087.yaml -f docker-compose.override.yaml config --quiet
  # nginx -t starts a container, so it needs the Docker daemon, not just the CLI.
  if docker info >/dev/null 2>&1; then
    check_nginx
  else
    missing "a running Docker daemon" "start Docker Desktop or the docker service"
  fi
}

check_json() {
  local files file bad=0
  echo "+ python -m json.tool on every tracked *.json"
  # Listed first, so a failed `git ls-files` can't pass as "no files to check".
  if ! files="$(git ls-files '*.json')" || [ -z "$files" ]; then
    fail "no tracked JSON files found (is this a git checkout?)"
    return
  fi
  while IFS= read -r file; do
    if ! "$PY" -m json.tool "$file" >/dev/null; then
      echo "invalid JSON: $file" >&2
      [ "${GITHUB_ACTIONS:-}" = "true" ] && echo "::error file=$file::invalid JSON"
      bad=1
    fi
  done <<<"$files"
  [ "$bad" -eq 0 ] || fail "invalid JSON (see above)"
}

check_configs() {
  section "configs"
  if have_python_modules "JSON" json; then
    check_json
  fi
  if have_python_modules "MapProxy" mapproxy.config.loader yaml; then
    run "$PY" .github/scripts/check-mapproxy-config.py
  fi
}

check_sync() {
  section "sync"
  if have_python_modules "PyYAML" yaml; then
    run "$PY" .github/scripts/check-sync.py
  fi
}

check_docs() {
  section "docs"
  if have_python_modules "MkDocs" mkdocs material; then
    run "$PY" scripts/prepare_pages.py && run "$PY" -m mkdocs build --strict
  fi
}

[ $# -eq 0 ] && set -- all

for group in "$@"; do
  case "$group" in
    -h | --help)
      usage
      exit 0
      ;;
    scripts | compose | configs | sync | docs | all) ;;
    *)
      echo "error: unknown group '$group' (scripts, compose, configs, sync, docs or all)" >&2
      exit 2
      ;;
  esac
done

for group in "$@"; do
  case "$group" in
    scripts) check_scripts ;;
    compose) check_compose ;;
    configs) check_configs ;;
    sync) check_sync ;;
    docs) check_docs ;;
    all)
      check_scripts
      check_compose
      check_configs
      check_sync
      check_docs
      ;;
    *) fail "unknown group '$group'" ;;
  esac
done

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed." >&2
  exit 1
fi
if [ -n "$SKIPPED" ]; then
  echo "Passed, but skipped (not installed): $SKIPPED" >&2
  echo "CI runs those too, so install them for a full local run." >&2
else
  echo "All checks passed."
fi
