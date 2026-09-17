#!/usr/bin/env bash
#
# Runs as an init container (see charts/rbt/templates/_tileserver.tpl) to
# populate one TileserverGL instance's PVC from S3: RBT.mbtiles /
# TERRAIN.mbtiles plus the shared fonts/ and styles/ trees. Mirrors
# deploy.sh's fetch_mbtiles() for the two MBTiles files (Linux/GNU
# userland, not deploy.sh's macOS + Linux split). Fonts and styles are
# `aws s3 sync`'d so only changed objects are downloaded on later
# restarts -- they live on the PVC next to the MBTiles, not an emptyDir.
#
# TERRAIN.mbtiles is only ever downloaded once (it never changes upstream);
# RBT.mbtiles re-downloads whenever the S3 object's LastModified is newer
# than the local copy's mtime, or unconditionally when FORCE_DOWNLOAD=true.
# Fonts/styles always sync (cheap when already current); FORCE_DOWNLOAD=true
# adds --delete so local files removed from S3 are dropped too.
#
# Required env vars: RBT_S3_URI, TERRAIN_S3_URI -- s3://bucket[/prefix] with
# no filename (see charts/rbt/values.yaml's tileservers.<key>.s3.rbtUri/
# terrainUri). FONTS_S3_URI / STYLES_S3_URI -- s3://bucket[/prefix] of the
# fonts/ or styles/ tree (see s3.fontsUri/stylesUri). Any of these may be
# left empty to skip that fetch (e.g. when persistence.existingClaim
# points at a PVC someone else already populated). Optional: DATA_DIR
# (default /data), FORCE_DOWNLOAD (default false), AWS_ENDPOINT_URL,
# AWS_REGION. AWS credentials come from the environment
# (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, or a mounted pod-identity
# token) exactly as `aws s3 cp`/`sync` pick them up outside this script --
# nothing here configures them.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-false}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

s3_bucket_name() { local uri="${1#s3://}"; echo "${uri%%/*}"; }
s3_object_key()  { local uri="${1#s3://}"; case "$uri" in */*) echo "${uri#*/}" ;; *) echo "" ;; esac; }

# Prints the epoch seconds of an S3 object's LastModified time on stdout, or
# nothing (with a non-zero exit) if it can't be read -- e.g. missing object,
# or an IAM policy that allows GetObject but not this HeadObject call.
remote_mtime_epoch() {
  local remote_uri="$1" last_modified
  last_modified="$(aws s3api head-object \
    --bucket "$(s3_bucket_name "$remote_uri")" \
    --key "$(s3_object_key "$remote_uri")" \
    --query 'LastModified' --output text 2>/dev/null)" || return 1
  [[ -n "$last_modified" && "$last_modified" != "None" ]] || return 1
  date -d "$last_modified" +%s
}

# check_remote=1 re-downloads whenever the S3 object's LastModified is newer
# than the local file's mtime (used for RBT.mbtiles, which is updated
# periodically). check_remote=0 just downloads once and leaves the local
# file alone afterwards (used for TERRAIN.mbtiles, which never changes).
# FORCE_DOWNLOAD=true always re-downloads regardless of check_remote.
fetch() {
  local uri_prefix="$1" dest="$2" check_remote="$3" filename remote_uri need_download

  if [[ -z "$uri_prefix" ]]; then
    warn "No S3 URI configured for $dest; leaving whatever is already in the PVC (if anything) alone"
    return 0
  fi

  filename="$(basename "$dest")"
  remote_uri="${uri_prefix%/}/$filename"
  need_download=1

  if [[ "$FORCE_DOWNLOAD" == "true" ]]; then
    need_download=1
  elif [[ ! -s "$dest" ]]; then
    need_download=1
  elif [[ "$check_remote" -eq 0 ]]; then
    log "$filename already present at $dest; skipping (set FORCE_DOWNLOAD=true to re-download)"
    need_download=0
  else
    local remote_epoch local_epoch
    if remote_epoch="$(remote_mtime_epoch "$remote_uri")"; then
      local_epoch="$(stat -c %Y "$dest")"
      if [[ "$remote_epoch" -gt "$local_epoch" ]]; then
        log "$filename in S3 was modified more recently than the local copy; re-downloading"
        need_download=1
      else
        log "$filename is already up to date with S3; skipping (set FORCE_DOWNLOAD=true to re-download)"
        need_download=0
      fi
    else
      warn "Could not read S3 metadata for $remote_uri; re-downloading $filename to be safe"
      need_download=1
    fi
  fi

  [[ "$need_download" -eq 1 ]] || return 0

  log "Downloading $filename from $remote_uri"
  aws s3 cp "$remote_uri" "$dest"
}

# Recursive prefix sync for fonts/ and styles/. aws s3 sync only transfers
# objects that differ, so a populated PVC is cheap on later pod starts.
fetch_tree() {
  local uri="$1" dest="$2" label="$3"
  local -a sync_args=(s3 sync)

  if [[ -z "$uri" ]]; then
    warn "No S3 URI configured for $label; leaving whatever is already in $dest (if anything) alone"
    return 0
  fi

  mkdir -p "$dest"
  if [[ "$FORCE_DOWNLOAD" == "true" ]]; then
    sync_args+=(--delete)
    log "Syncing $label from $uri to $dest (--delete, FORCE_DOWNLOAD=true)"
  else
    log "Syncing $label from $uri to $dest"
  fi
  aws "${sync_args[@]}" "${uri%/}/" "$dest/"
}

dir_has_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -n "$(find "$dir" -type f -print -quit)" ]]
}

mkdir -p "$DATA_DIR"

fetch "${RBT_S3_URI:-}" "$DATA_DIR/RBT.mbtiles" 1
fetch "${TERRAIN_S3_URI:-}" "$DATA_DIR/TERRAIN.mbtiles" 0
fetch_tree "${FONTS_S3_URI:-}" "$DATA_DIR/fonts" "fonts"
fetch_tree "${STYLES_S3_URI:-}" "$DATA_DIR/styles" "styles"

[[ -s "$DATA_DIR/RBT.mbtiles" ]] || die "$DATA_DIR/RBT.mbtiles is missing or empty -- set tileservers.<key>.s3.rbtUri, or pre-populate the PVC and set persistence.existingClaim"
[[ -s "$DATA_DIR/TERRAIN.mbtiles" ]] || die "$DATA_DIR/TERRAIN.mbtiles is missing or empty -- set tileservers.<key>.s3.terrainUri, or pre-populate the PVC and set persistence.existingClaim"
dir_has_files "$DATA_DIR/fonts" || die "$DATA_DIR/fonts is missing or empty -- set s3.fontsUri, or pre-populate the PVC and set persistence.existingClaim"
dir_has_files "$DATA_DIR/styles" || die "$DATA_DIR/styles is missing or empty -- set s3.stylesUri, or pre-populate the PVC and set persistence.existingClaim"

log "mbtiles, fonts, and styles ready in $DATA_DIR"
