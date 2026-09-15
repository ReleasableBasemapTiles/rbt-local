#!/usr/bin/env bash
#
# Runs as an init container (see charts/rbt/templates/_tileserver.tpl) to
# populate one TileserverGL instance's mbtiles PVC from S3, mirroring
# deploy.sh's fetch_mbtiles() (see the repo root's deploy.sh) for a single
# Linux/GNU-userland container instead of deploy.sh's macOS + Linux split.
# TERRAIN.mbtiles is only ever downloaded once (it never changes upstream);
# RBT.mbtiles re-downloads whenever the S3 object's LastModified is newer
# than the local copy's mtime, or unconditionally when FORCE_DOWNLOAD=true.
#
# Required env vars: RBT_S3_URI, TERRAIN_S3_URI -- s3://bucket[/prefix] with
# no filename (see charts/rbt/values.yaml's tileservers.<key>.s3.rbtUri/
# terrainUri). Either may be left empty to skip that file (e.g. when
# pointing persistence.existingClaim at a PVC someone else already
# populated). Optional: DATA_DIR (default /data), FORCE_DOWNLOAD (default
# false), AWS_ENDPOINT_URL, AWS_REGION. AWS credentials come from the
# environment (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, or a mounted
# pod-identity token) exactly as `aws s3 cp` picks them up outside this
# script -- nothing here configures them.

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

mkdir -p "$DATA_DIR"

fetch "${RBT_S3_URI:-}" "$DATA_DIR/RBT.mbtiles" 1
fetch "${TERRAIN_S3_URI:-}" "$DATA_DIR/TERRAIN.mbtiles" 0

[[ -s "$DATA_DIR/RBT.mbtiles" ]] || die "$DATA_DIR/RBT.mbtiles is missing or empty -- set tileservers.<key>.s3.rbtUri, or pre-populate the PVC and set persistence.existingClaim"
[[ -s "$DATA_DIR/TERRAIN.mbtiles" ]] || die "$DATA_DIR/TERRAIN.mbtiles is missing or empty -- set tileservers.<key>.s3.terrainUri, or pre-populate the PVC and set persistence.existingClaim"

log "mbtiles ready in $DATA_DIR"
