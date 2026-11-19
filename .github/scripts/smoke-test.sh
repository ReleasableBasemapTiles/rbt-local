#!/usr/bin/env bash
# Smoke test for a running RBT stack: does it come up, route, render and
# cache? It is what .github/workflows/smoke.yml runs after `./deploy.sh
# --deploy` on fixture MBTiles (see make-fixture-mbtiles.py), and it works on
# any running stack, so you can aim it at your own.
#
#   .github/scripts/smoke-test.sh [--4087]
#
# --4087 expects the EPSG:4087 stack (tileservergl4087 as well); without it,
# the default stack with nginx. It reaches the stack on localhost at the ports
# in .env, or the defaults (NGINX_PORT 8082).
#
# It ends by running `./deploy.sh [--4087] --refresh`, to prove a refresh
# purges nginx's cache: that restarts TileserverGL and clears the tile cache of
# the stack you point it at. Don't run it against a stack you can't restart.
#
# What it asserts, and the failure each one stands for:
#   - the expected containers are running (a service that never started)
#   - /healthz answers ok (nginx is up)
#   - styles.json lists every style directory (TileserverGL loaded them)
#   - the WMTS capabilities list every style in every projection (MapProxy
#     loaded its config: styles x 3 layers)
#   - a GetMap returns a PNG, MISS first and HIT second (the request path
#     works end to end and nginx caches it)
#   - layers MapProxy reprojects (EPSG:3395, EPSG:4326) return PNGs, not
#     service exceptions, and the right TileserverGL rendered the tiles: the
#     EPSG:3857 one for the 3857 and 3395 layers, and in the 4087 stack the
#     EPSG:4087 one for the 4326 layer (a MapProxy that ignored the
#     mapproxy.4087.yaml override would still answer, from the wrong container)
#   - /tileservergl, with no trailing slash, redirects to /tileservergl/ with a
#     relative Location (nginx's absolute_redirect off; an absolute one would
#     name the container's host and port, which a client behind a proxy can't use)
#   - which MapProxy config was loaded, and, in the 4087 stack,
#     /tileservergl4087/ answers
#   - after --refresh, the same GetMap is a MISS again
#
# It runs every assertion and exits 1 at the end if any failed, so one run
# lists everything that's wrong. bash 3.2-safe, like the other scripts.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

USE_4087=0
case "${1:-}" in
  "") ;;
  --4087) USE_4087=1 ;;
  *)
    echo "usage: ${BASH_SOURCE[0]} [--4087]" >&2
    exit 2
    ;;
esac

# Ports as docker-compose.yaml reads them: the environment first, then .env.
env_value() {
  local name="$1" default="$2" value=""
  if [ -n "${!name:-}" ]; then
    echo "${!name}"
    return
  fi
  if [ -f .env ]; then
    value="$(sed -n "s/^${name}=//p" .env | tail -1 | tr -d "\"'")"
  fi
  echo "${value:-$default}"
}

NGINX_PORT="$(env_value NGINX_PORT 8082)"
BASE="http://localhost:$NGINX_PORT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A unique parameter makes nginx's cache key (the request URI) one this stack
# hasn't seen, so a re-run against the same stack still starts with a MISS.
RUN_ID="smoke-$$-$RANDOM"

FAILED=0
pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*" >&2
  FAILED=$((FAILED + 1))
}

# fetch URL: curl it, keeping the status in HTTP_CODE, headers in $WORK/headers
# and the body in $WORK/body. Never follows redirects, so a 301 can be asserted.
fetch() {
  HTTP_CODE="$(curl -sS --max-time 120 -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' "$1")" || HTTP_CODE="000"
}

# header NAME: the value of a response header from the last fetch, trimmed.
header() {
  grep -i "^$1:" "$WORK/headers" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//; s/ *$//'
}

is_png() {
  [ "$(head -c 4 "$WORK/body" | tail -c 3)" = "PNG" ]
}

# WMS GetMap URL: LAYER SRS BBOX WIDTH HEIGHT
getmap_url() {
  echo "$BASE/mapproxy/wms?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1&LAYERS=$1&STYLES=&SRS=$2&BBOX=$3&WIDTH=$4&HEIGHT=$5&FORMAT=image/png&rbt_smoke=$RUN_ID"
}

# expect_tile LABEL URL CACHE_STATUS: a 200 PNG whose X-Cache-Status is CACHE_STATUS.
expect_tile() {
  local label="$1" url="$2" want="$3" got
  fetch "$url"
  got="$(header X-Cache-Status)"
  if [ "$HTTP_CODE" != "200" ]; then
    fail "$label: HTTP $HTTP_CODE, expected 200"
  elif [ "$(header Content-Type)" != "image/png" ] || ! is_png; then
    fail "$label: not a PNG (Content-Type: $(header Content-Type)); MapProxy may have returned a service exception"
  elif [ "$got" != "$want" ]; then
    fail "$label: X-Cache-Status is '$got', expected $want"
  else
    pass "$label: PNG, X-Cache-Status $got"
  fi
}

# Every style directory, one per line: what styles.json and the capabilities must list.
style_names() {
  local dir
  for dir in tileserver/styles/RBT-*/; do
    basename "$dir"
  done
}

STYLE_COUNT="$(style_names | wc -l | tr -d ' ')"

# Every grep -q below reads a here-string, not a pipe: with `set -o pipefail`,
# `docker logs | grep -q` fails whenever grep exits at its first match before
# docker has finished writing (SIGPIPE, status 141), so a log with many lines
# reports "not found" for a line that is there.
check_containers() {
  local running name
  running="$(docker ps --format '{{.Names}}')"
  for name in nginx mapproxy tileservergl; do
    if grep -qx "$name" <<<"$running"; then
      pass "$name is running"
    else
      fail "$name is not running"
    fi
  done
  if [ "$USE_4087" -eq 1 ]; then
    if grep -qx tileservergl4087 <<<"$running"; then
      pass "tileservergl4087 is running"
    else
      fail "tileservergl4087 is not running"
    fi
  elif grep -qx tileservergl4087 <<<"$running"; then
    fail "tileservergl4087 is running in the default stack (an orphan from a 4087 stack?)"
  fi
}

# check_styles LABEL URL: styles.json lists every style directory.
check_styles() {
  local label="$1" url="$2" style missing=""
  fetch "$url"
  if [ "$HTTP_CODE" != "200" ]; then
    fail "$label: HTTP $HTTP_CODE, expected 200"
    return
  fi
  for style in $(style_names); do
    grep -q "\"id\": *\"$style\"" "$WORK/body" || missing="$missing $style"
  done
  if [ -n "$missing" ]; then
    fail "$label is missing:$missing"
  else
    pass "$label lists all $STYLE_COUNT styles"
  fi
}

check_capabilities() {
  local found want=$((STYLE_COUNT * 3))
  fetch "$BASE/mapproxy/wmts/1.0.0/WMTSCapabilities.xml"
  if [ "$HTTP_CODE" != "200" ]; then
    fail "WMTS capabilities: HTTP $HTTP_CODE, expected 200"
    return
  fi
  found="$(grep -o '<ows:Identifier>rbt_[a-z0-9_]*</ows:Identifier>' "$WORK/body" | sort -u | wc -l | tr -d ' ')"
  if [ "$found" -eq "$want" ]; then
    pass "WMTS capabilities list $found layers ($STYLE_COUNT styles x 3 projections)"
  else
    fail "WMTS capabilities list $found layers, expected $want ($STYLE_COUNT styles x 3 projections)"
  fi
}

# check_served_by CONTAINER LABEL: CONTAINER's log shows it rendered a 512px style
# tile, which is what MapProxy asks TileserverGL for.
check_served_by() {
  local log
  log="$(docker logs "$1" 2>&1)"
  if grep -q 'GET /styles/RBT-[A-Z]*/512/' <<<"$log"; then
    pass "$1 rendered tiles for $2"
  else
    fail "$1 rendered no tiles for $2 (MapProxy got them from another container)"
  fi
}

check_redirect() {
  fetch "$BASE/tileservergl"
  if [ "$HTTP_CODE" != "301" ]; then
    fail "/tileservergl: HTTP $HTTP_CODE, expected a 301 to /tileservergl/"
  elif [ "$(header Location)" != "/tileservergl/" ]; then
    fail "/tileservergl redirects to '$(header Location)', expected the relative /tileservergl/"
  else
    pass "/tileservergl redirects to /tileservergl/ (relative)"
  fi
}

# Which config MapProxy loaded, from its own log. In the 4087 stack it loads
# mapproxy.4087.yaml, which pulls mapproxy.yaml in through `base:`, so both
# appear; in the default stack only mapproxy.yaml does.
check_mapproxy_config() {
  local reading
  reading="$(docker logs mapproxy 2>&1 | grep -o 'reading: .*' | sort -u)"
  if [ "$USE_4087" -eq 1 ]; then
    if grep -qx 'reading: /mapproxy/config/mapproxy.4087.yaml' <<<"$reading"; then
      pass "MapProxy loaded mapproxy.4087.yaml"
    else
      fail "MapProxy's log doesn't show 'reading: /mapproxy/config/mapproxy.4087.yaml' (found: ${reading:-nothing})"
    fi
  elif grep -q 'mapproxy.4087.yaml' <<<"$reading"; then
    fail "the default stack's MapProxy loaded mapproxy.4087.yaml"
  elif grep -qx 'reading: /mapproxy/config/mapproxy.yaml' <<<"$reading"; then
    pass "MapProxy loaded mapproxy.yaml"
  else
    fail "MapProxy's log doesn't show 'reading: /mapproxy/config/mapproxy.yaml' (found: ${reading:-nothing})"
  fi
}

refresh_stack() {
  local flag=""
  [ "$USE_4087" -eq 1 ] && flag="--4087"
  echo "+ ./deploy.sh ${flag:+$flag }--refresh"
  # The flag is unquoted on purpose: empty means no argument at all.
  # shellcheck disable=SC2086
  ./deploy.sh $flag --refresh || fail "./deploy.sh ${flag:+$flag }--refresh failed"
}

echo "Smoke test against $BASE ($([ "$USE_4087" -eq 1 ] && echo "EPSG:4087 stack" || echo "default stack"), $STYLE_COUNT styles)"

check_containers

fetch "$BASE/healthz"
if [ "$HTTP_CODE" = "200" ] && [ "$(tr -d '\r\n ' <"$WORK/body")" = "ok" ]; then
  pass "/healthz answers ok"
else
  fail "/healthz: HTTP $HTTP_CODE, body '$(head -c 80 "$WORK/body")', expected 200 ok"
fi

check_styles "/tileservergl/styles.json" "$BASE/tileservergl/styles.json"
check_capabilities

TILE_URL="$(getmap_url rbt_topo_3857 EPSG:3857 -20037508.34,-20037508.34,20037508.34,20037508.34 256 256)"
expect_tile "GetMap rbt_topo_3857 (first request)" "$TILE_URL" MISS
expect_tile "GetMap rbt_topo_3857 (same request again)" "$TILE_URL" HIT

# These are built by reprojection (and in the 4087 stack, EPSG:4326 comes from
# the EPSG:4087 container), so they exercise MapProxy's caches, not just the
# EPSG:3857 pass-through.
expect_tile "GetMap rbt_topo_3395 (reprojected)" \
  "$(getmap_url rbt_topo_3395 EPSG:3395 -20037508.34,-20037508.34,20037508.34,20037508.34 256 256)" MISS
expect_tile "GetMap rbt_topo_4326 (reprojected)" \
  "$(getmap_url rbt_topo_4326 EPSG:4326 -180,-90,180,90 512 256)" MISS

check_served_by tileservergl "the EPSG:3857 and EPSG:3395 layers"
if [ "$USE_4087" -eq 1 ]; then
  check_served_by tileservergl4087 "the EPSG:4326 layer, through its EPSG:4087 cache"
fi

check_redirect
check_mapproxy_config

if [ "$USE_4087" -eq 1 ]; then
  check_styles "/tileservergl4087/styles.json" "$BASE/tileservergl4087/styles.json"
  fetch "$BASE/tileservergl4087/"
  if [ "$HTTP_CODE" = "200" ]; then
    pass "/tileservergl4087/ answers"
  else
    fail "/tileservergl4087/: HTTP $HTTP_CODE, expected 200"
  fi
fi

refresh_stack
fetch "$BASE/healthz"
if [ "$HTTP_CODE" = "200" ]; then
  pass "/healthz answers after the refresh"
else
  fail "/healthz after the refresh: HTTP $HTTP_CODE, expected 200"
fi
expect_tile "GetMap rbt_topo_3857 after --refresh (cache purged)" "$TILE_URL" MISS

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED assertion(s) failed." >&2
  exit 1
fi
echo "All assertions passed."
