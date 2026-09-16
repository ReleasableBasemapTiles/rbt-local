#!/usr/bin/env bash
#
# Bootstrap a macOS or Linux (Ubuntu/Debian or Fedora/RHEL) host and deploy
# the RBT Docker Compose stack. See README.md for the manual equivalent of
# each step, or run with --help.
#
#   S3_BUCKET_RBT=my-bucket S3_BUCKET_TERRAIN=my-other-bucket ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATA_DIR="$SCRIPT_DIR/tileserver/data"
DATA_DIR_3857="$DATA_DIR/3857"
RBT_FILE_3857="$DATA_DIR_3857/RBT.mbtiles"
TERRAIN_FILE_3857="$DATA_DIR_3857/TERRAIN.mbtiles"
DATA_DIR_4087="$DATA_DIR/4087"
RBT_FILE_4087="$DATA_DIR_4087/RBT.mbtiles"
TERRAIN_FILE_4087="$DATA_DIR_4087/TERRAIN.mbtiles"

FORCE_DOWNLOAD=0
WITH_NGINX=1
USE_4087=0

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
deploy.sh - Bootstrap a macOS or Linux host and deploy the RBT Docker Compose stack.

With no flags, all four steps below run in order. Pass one or more step
flags to run only those steps (still in the order listed here, regardless
of the order given on the command line):

  --init      Install prerequisites: AWS CLI v2, Docker (Docker Desktop on
              macOS; Docker Engine + Compose plugin on Linux), git/git-lfs.
              Uses Homebrew on macOS, apt on Ubuntu/Debian, or dnf on
              Fedora/RHEL, whichever this host's /etc/os-release identifies.
  --download  Download RBT.mbtiles/TERRAIN.mbtiles from S3 into
              tileserver/data/3857/.
  --perm      Fix mapproxy/nginx runtime directory permissions (a no-op on
              macOS -- see below).
  --deploy    Run `docker compose up -d`.
  --force     Re-download mbtiles even if already present (only relevant
              together with --download, or with no step flags).
  --no-nginx  Deploy mapproxy and tileservergl only, without the local
              nginx reverse-proxy/cache -- use this when something else
              (e.g. an AWS ALB and/or CloudFront) talks HTTP directly to
              mapproxy (port ${MAPPROXY_PORT:-8081}) and tileservergl
              (port ${TILESERVER_PORT:-8080}) instead. Only relevant with
              --deploy, or with no step flags.
  --4087      Deploy docker-compose.4087.yaml instead of docker-compose.yaml
              -- adds a second TileserverGL container (tileservergl4087)
              serving EPSG:4087 MBTiles, and points mapproxy at
              mapproxy.4087.yaml so its EPSG:4326 caches reproject from
              EPSG:4087 instead of EPSG:3857 (see docs/deployment-4087.md).
              Combines with --no-nginx and --force. With --download (or no
              step flags), also downloads the EPSG:4087 RBT.mbtiles/
              TERRAIN.mbtiles into tileserver/data/4087/.

Usage:
  S3_BUCKET_RBT=my-bucket S3_BUCKET_TERRAIN=my-other-bucket ./deploy.sh
  ./deploy.sh --init                # just install prerequisites
  ./deploy.sh --download --perm     # just refresh data + permissions
  ./deploy.sh --deploy              # just (re)start the stack
  ./deploy.sh --force               # full run, force re-download
  ./deploy.sh --no-nginx            # full run, skip the local nginx
  ./deploy.sh --4087                # full run, EPSG:4087 dual-tileserver stack
  ./deploy.sh --4087 --no-nginx     # same, without the local nginx

Run this as your normal (non-root) user, not via `sudo`. On Linux it
escalates internally with sudo only for the specific steps that need root
(apt/dnf, installing/starting Docker, chown). On macOS nothing here uses
sudo -- Homebrew and Docker Desktop both install and run as your normal
user. Either way, running it unprivileged means `aws s3 cp` uses your own
AWS credential chain (env vars, ~/.aws/credentials, AWS_PROFILE, or an
EC2/ECS instance role) exactly as it would outside this script -- nothing
here configures AWS credentials for you.

Required environment variables (only enforced when the download step runs;
a value already set in the environment takes precedence over the same key
in .env):
  S3_BUCKET_RBT      Bucket (optionally with a prefix), no filename, e.g.
                      "my-bucket" or "s3://my-bucket/exports". Must contain
                      RBT.mbtiles.
  S3_BUCKET_TERRAIN  Same, but must contain TERRAIN.mbtiles.

Additional environment variables (only enforced when the download step
runs together with --4087):
  S3_BUCKET_RBT_4087      Same as S3_BUCKET_RBT, but for the EPSG:4087
                           RBT.mbtiles.
  S3_BUCKET_TERRAIN_4087  Same as S3_BUCKET_TERRAIN, but for the EPSG:4087
                           TERRAIN.mbtiles.

Re-running this script is safe: package installs are skipped when already
present. TERRAIN.mbtiles is only downloaded once (it never changes upstream).
RBT.mbtiles is re-downloaded automatically whenever the S3 object's
LastModified time is newer than the local copy's -- pass --force to
re-download either file unconditionally.
EOF
}

# ---------------------------------------------------------------------------
# Environment file (.env)
# ---------------------------------------------------------------------------

# Loads simple KEY=VALUE lines from .env (if present) into the environment,
# the same file docker-compose.yaml/docker-compose.override.yaml already
# auto-load via Compose's own .env support. Comments and blank lines are
# skipped, one layer of surrounding quotes is stripped, and a key already
# set in the environment is left alone -- shell exports always win over
# .env, matching Compose's own precedence.
load_env_file() {
  local env_file="$SCRIPT_DIR/.env"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"

    if [[ "$value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < "$env_file"
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Prints "macos", "ubuntu", "fedora", or "unknown". Debian/Ubuntu and
# Fedora/RHEL derivatives are grouped by /etc/os-release's ID_LIKE so close
# relatives (e.g. Pop!_OS, Rocky Linux) still get a supported prereqs path.
detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
    return
  fi

  if [[ -f /etc/os-release ]]; then
    local ids
    # shellcheck disable=SC1091
    ids="$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}")"
    case " $ids " in
      *" fedora "*|*" rhel "*) echo "fedora"; return ;;
      *" debian "*|*" ubuntu "*) echo "ubuntu"; return ;;
    esac
  fi

  echo "unknown"
}

install_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi

  log "Installing Homebrew (brew.sh)"
  # Official bootstrap command from https://brew.sh -- runs a trusted,
  # versioned installer script served from Homebrew's own repo.
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  command -v brew >/dev/null 2>&1 || die "Homebrew install appears to have failed -- 'brew' is still not on PATH."
}

install_base_packages() {
  case "$OS_FAMILY" in
    macos)
      install_homebrew
      log "Installing Git and Git LFS (brew packages: git, git-lfs)"
      brew install git git-lfs
      ;;
    fedora)
      log "Installing base packages"
      "${SUDO[@]}" dnf install -y unzip git-all git-lfs
      ;;
    ubuntu)
      log "Updating apt package lists"
      export DEBIAN_FRONTEND=noninteractive
      "${SUDO[@]}" apt-get update
      log "Installing base packages"
      "${SUDO[@]}" apt-get install -y ca-certificates curl gnupg lsb-release unzip git git-lfs
      ;;
    *)
      die "Don't know how to install prerequisites on this OS. See docs/install-macos.md, docs/install-linux.md, or docs/install-windows.md for manual install instructions, or install aws, docker, git, and git-lfs yourself and re-run with --download --perm --deploy."
      ;;
  esac
}

install_aws_cli_linux() {
  log "Installing AWS CLI v2"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # $tmp_dir is intentionally expanded now, not at trap-fire time.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp_dir/awscliv2.zip"
  unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir"
  "${SUDO[@]}" "$tmp_dir/aws/install"
}

install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI already installed ($(aws --version 2>&1)); skipping"
    return
  fi

  if [[ "$OS_FAMILY" == "macos" ]]; then
    log "Installing AWS CLI v2 (brew package: awscli)"
    brew install awscli
  else
    install_aws_cli_linux
  fi
}

# Group membership only takes effect in new sessions, so this is a
# convenience for future logins -- docker compose below still runs via
# sudo so this script works correctly on the very first run. Uses `id -un`
# rather than $SUDO_USER/$USER so this still works when neither is set.
add_current_user_to_docker_group() {
  local target_user="${SUDO_USER:-$(id -un)}"
  if ! id -nG "$target_user" | grep -qw docker; then
    "${SUDO[@]}" usermod -aG docker "$target_user"
    warn "Added $target_user to the docker group -- log out/in (or run 'newgrp docker') to run docker without sudo outside this script."
  fi
}

install_docker_linux_apt() {
  log "Removing old/conflicting Docker packages (if any)"
  "${SUDO[@]}" apt-get remove -y docker docker-engine docker.io containerd runc || true

  log "Adding Docker's official apt repository"
  "${SUDO[@]}" mkdir -m 0755 -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    "${SUDO[@]}" gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  "${SUDO[@]}" chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |
    "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null

  log "Installing Docker Engine and the Compose plugin"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Enabling the Docker service"
  "${SUDO[@]}" systemctl enable --now docker
}

install_docker_linux_dnf() {
  log "Removing old/conflicting Docker packages (if any)"
  "${SUDO[@]}" dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine || true

  log "Adding Docker's official dnf repository"
  "${SUDO[@]}" dnf -y install dnf-plugins-core
  "${SUDO[@]}" dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

  log "Installing Docker Engine and the Compose plugin"
  "${SUDO[@]}" dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Enabling the Docker service"
  "${SUDO[@]}" systemctl enable --now docker
}

# Docker Desktop's first launch after install may need a one-time,
# non-scriptable GUI step (accepting the license, granting privileged-helper
# access) -- if the engine isn't up within the timeout, we bail with
# instructions to finish that manually and re-run, the same way deploy.ps1
# handles the equivalent first-run prompt on Windows.
start_docker_desktop_and_wait_macos() {
  if docker info >/dev/null 2>&1; then
    log "Docker engine is already running"
    return
  fi

  log "Starting Docker Desktop (first start can take a minute or two)"
  open -a Docker || warn "Could not launch Docker Desktop automatically; start it from Launchpad if it is not already running."

  local max_wait_seconds=180 waited=0
  while (( waited < max_wait_seconds )); do
    if docker info >/dev/null 2>&1; then
      log "Docker engine is up"
      return
    fi
    sleep 5
    waited=$((waited + 5))
  done

  die "Docker engine did not become ready within ${max_wait_seconds}s. Open Docker Desktop manually (finishing any first-run setup prompts), wait for it to report 'Engine running', then re-run ./deploy.sh."
}

install_docker_desktop_macos() {
  log "Installing Docker Desktop (brew cask: docker-desktop)"
  brew install --cask docker-desktop
  start_docker_desktop_and_wait_macos
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + Compose plugin already installed ($(docker --version)); skipping"
    return
  fi

  case "$OS_FAMILY" in
    macos)
      install_docker_desktop_macos
      ;;
    fedora)
      install_docker_linux_dnf
      add_current_user_to_docker_group
      ;;
    *)
      install_docker_linux_apt
      add_current_user_to_docker_group
      ;;
  esac
}

prereqs_installed() {
  command -v aws >/dev/null 2>&1 &&
    command -v docker >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1 &&
    command -v git >/dev/null 2>&1 &&
    command -v git-lfs >/dev/null 2>&1
}

install_prereqs() {
  if prereqs_installed; then
    log "All prerequisites already installed (aws, docker, docker compose, git, git-lfs); skipping setup"
    return
  fi

  install_base_packages
  install_aws_cli
  install_docker

  "${SUDO[@]}" git lfs install --system
}

# ---------------------------------------------------------------------------
# Map data
# ---------------------------------------------------------------------------

normalize_s3_uri() {
  local value="${1%/}"
  [[ "$value" == s3://* ]] && echo "$value" || echo "s3://$value"
}

s3_bucket_name() {
  local uri="${1#s3://}"
  echo "${uri%%/*}"
}

s3_object_key() {
  local uri="${1#s3://}"
  case "$uri" in
    */*) echo "${uri#*/}" ;;
    *) echo "" ;;
  esac
}

# Portable stat/date helpers -- GNU coreutils (Linux) and BSD (macOS) accept
# different flags for both. `file_mtime_epoch`/`format_epoch` cover the
# stat/date-formatting direction; `parse_iso8601_epoch` covers parsing S3's
# LastModified timestamp back into epoch seconds.

file_mtime_epoch() {
  if [[ "$OS_FAMILY" == "macos" ]]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

format_epoch() {
  if [[ "$OS_FAMILY" == "macos" ]]; then
    TZ=UTC date -j -f %s "$1"
  else
    date -d "@$1"
  fi
}

# Converts an S3 LastModified timestamp (e.g. "2026-08-20T12:34:56+00:00" or
# "...Z") to epoch seconds. GNU `date -d` parses this directly; BSD/macOS
# `date -j -f` can't parse the trailing offset, so strip fractional seconds
# and the timezone suffix and parse the remainder as UTC -- S3 LastModified
# is always UTC regardless of which suffix style it's rendered with.
parse_iso8601_epoch() {
  local input="$1"
  if [[ "$OS_FAMILY" == "macos" ]]; then
    local stripped="${input%%.*}"
    stripped="${stripped%%+*}"
    stripped="${stripped%Z}"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s
  else
    date -d "$input" +%s
  fi
}

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
  parse_iso8601_epoch "$last_modified"
}

# check_remote=1 re-downloads whenever the S3 object's LastModified is newer
# than the local file's mtime (used for RBT.mbtiles, which is updated
# periodically). check_remote=0 just downloads once and leaves the local
# file alone afterwards (used for TERRAIN.mbtiles, which never changes).
# --force always re-downloads regardless of check_remote.
fetch_mbtiles() {
  local bucket_var="$1" dest="$2" check_remote="$3"
  local filename prefix remote_uri need_download

  filename="$(basename "$dest")"
  prefix="$(normalize_s3_uri "${!bucket_var}")"
  remote_uri="$prefix/$filename"
  need_download=1

  if [[ "$FORCE_DOWNLOAD" -eq 1 ]]; then
    need_download=1
  elif [[ ! -s "$dest" ]]; then
    need_download=1
  elif [[ "$check_remote" -eq 0 ]]; then
    log "$filename already present at $dest; skipping (use --force to re-download)"
    need_download=0
  else
    local remote_epoch local_epoch
    if remote_epoch="$(remote_mtime_epoch "$remote_uri")"; then
      local_epoch="$(file_mtime_epoch "$dest")"
      if [[ "$remote_epoch" -gt "$local_epoch" ]]; then
        log "$filename in S3 was modified $(format_epoch "$remote_epoch") (newer than the local copy); re-downloading"
        need_download=1
      else
        log "$filename is already up to date with S3; skipping (use --force to re-download)"
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

download_mbtiles() {
  mkdir -p "$DATA_DIR_3857"

  fetch_mbtiles S3_BUCKET_RBT "$RBT_FILE_3857" 1
  fetch_mbtiles S3_BUCKET_TERRAIN "$TERRAIN_FILE_3857" 0

  [[ -s "$RBT_FILE_3857" ]] || die "$RBT_FILE_3857 is missing or empty after download"
  [[ -s "$TERRAIN_FILE_3857" ]] || die "$TERRAIN_FILE_3857 is missing or empty after download"

  # The --4087 stack still runs the EPSG:3857 tileservergl container too
  # (see docker-compose.4087.yaml), so the downloads above always run;
  # this just adds the second container's EPSG:4087 MBTiles alongside them.
  if [[ "$USE_4087" -eq 1 ]]; then
    mkdir -p "$DATA_DIR_4087"

    fetch_mbtiles S3_BUCKET_RBT_4087 "$RBT_FILE_4087" 1
    fetch_mbtiles S3_BUCKET_TERRAIN_4087 "$TERRAIN_FILE_4087" 0

    [[ -s "$RBT_FILE_4087" ]] || die "$RBT_FILE_4087 is missing or empty after download"
    [[ -s "$TERRAIN_FILE_4087" ]] || die "$TERRAIN_FILE_4087 is missing or empty after download"
  fi
}

# ---------------------------------------------------------------------------
# Permissions (see docs/install-linux.md -- mapproxy's image runs as uid/gid 1000)
# ---------------------------------------------------------------------------

fix_permissions() {
  log "Setting mapproxy/nginx runtime directory permissions"
  mkdir -p mapproxy/data mapproxy/locks mapproxy/tile_locks nginx/cache nginx/logs nginx/run

  if [[ "$OS_FAMILY" == "macos" ]]; then
    log "Skipping chown/chmod on macOS -- Docker Desktop's VirtioFS file sharing maps the host user into the container, so there's no uid/gid mismatch to fix"
    return
  fi

  "${SUDO[@]}" chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks
  "${SUDO[@]}" chmod -R 775 mapproxy/data mapproxy/locks mapproxy/tile_locks nginx/cache nginx/logs nginx/run
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# Prints the base compose file path -- docker-compose.4087.yaml with --4087,
# else docker-compose.yaml. docker-compose.override.yaml (nginx) layers on
# top of either one identically, since both declare the same service names.
base_compose_file() {
  if [[ "$USE_4087" -eq 1 ]]; then
    echo "$SCRIPT_DIR/docker-compose.4087.yaml"
  else
    echo "$SCRIPT_DIR/docker-compose.yaml"
  fi
}

deploy_stack() {
  local compose_files=(-f "$(base_compose_file)")
  if [[ "$WITH_NGINX" -eq 1 ]]; then
    compose_files+=(-f "$SCRIPT_DIR/docker-compose.override.yaml")
  else
    log "Deploying without nginx -- mapproxy and tileservergl publish their own ports directly"
  fi

  log "Building the mapproxy image"
  "${SUDO[@]}" docker compose "${compose_files[@]}" build mapproxy

  log "Pulling remaining images"
  "${SUDO[@]}" docker compose "${compose_files[@]}" pull --ignore-buildable

  log "Starting the RBT stack"
  "${SUDO[@]}" docker compose "${compose_files[@]}" up -d

  log "Current service status"
  "${SUDO[@]}" docker compose "${compose_files[@]}" ps
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

load_env_file

RUN_INIT=0
RUN_DOWNLOAD=0
RUN_PERM=0
RUN_DEPLOY=0
STEP_SELECTED=0

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --init)
      RUN_INIT=1
      STEP_SELECTED=1
      ;;
    --download)
      RUN_DOWNLOAD=1
      STEP_SELECTED=1
      ;;
    --perm)
      RUN_PERM=1
      STEP_SELECTED=1
      ;;
    --deploy)
      RUN_DEPLOY=1
      STEP_SELECTED=1
      ;;
    --force)
      FORCE_DOWNLOAD=1
      ;;
    --no-nginx)
      WITH_NGINX=0
      ;;
    --4087)
      USE_4087=1
      ;;
    *)
      die "Unknown argument: $arg (use --help for usage)"
      ;;
  esac
done

# No step flags given -- run the whole thing.
if [[ "$STEP_SELECTED" -eq 0 ]]; then
  RUN_INIT=1
  RUN_DOWNLOAD=1
  RUN_PERM=1
  RUN_DEPLOY=1
fi

OS_FAMILY="$(detect_os)"

if [[ "$OS_FAMILY" == "macos" ]]; then
  # Homebrew and Docker Desktop both install and run as the normal user;
  # nothing in the macOS code paths below needs (or should use) sudo.
  SUDO=()
elif [[ $EUID -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "This script needs root privileges for some steps. Install sudo or run as root."
  SUDO=(sudo)
fi

if [[ "$OS_FAMILY" == "unknown" ]]; then
  warn "Could not identify this host as macOS, Ubuntu/Debian, or Fedora/RHEL. --init will stop with an error if it doesn't know how to install prerequisites here; --download, --perm, and --deploy should still work as long as aws, docker, git, and git-lfs are already installed."
fi

[[ -f "$SCRIPT_DIR/docker-compose.yaml" ]] ||
  die "docker-compose.yaml not found next to this script -- run it from inside the rbt-local repo checkout."
if [[ "$USE_4087" -eq 1 ]]; then
  [[ -f "$SCRIPT_DIR/docker-compose.4087.yaml" ]] ||
    die "docker-compose.4087.yaml not found next to this script -- run it from inside the rbt-local repo checkout."
fi

if [[ "$RUN_DOWNLOAD" -eq 1 ]]; then
  : "${S3_BUCKET_RBT:?Set S3_BUCKET_RBT to the bucket (and optional prefix) containing RBT.mbtiles, e.g. S3_BUCKET_RBT=my-bucket -- or add it to .env (see .env.example)}"
  : "${S3_BUCKET_TERRAIN:?Set S3_BUCKET_TERRAIN to the bucket (and optional prefix) containing TERRAIN.mbtiles -- or add it to .env (see .env.example)}"
  if [[ "$USE_4087" -eq 1 ]]; then
    : "${S3_BUCKET_RBT_4087:?Set S3_BUCKET_RBT_4087 to the bucket (and optional prefix) containing the EPSG:4087 RBT.mbtiles -- or add it to .env (see .env.example)}"
    : "${S3_BUCKET_TERRAIN_4087:?Set S3_BUCKET_TERRAIN_4087 to the bucket (and optional prefix) containing the EPSG:4087 TERRAIN.mbtiles -- or add it to .env (see .env.example)}"
  fi
fi

if [[ "$RUN_INIT" -eq 1 ]]; then
  install_prereqs
fi
if [[ "$RUN_DOWNLOAD" -eq 1 ]]; then
  download_mbtiles
fi
if [[ "$RUN_PERM" -eq 1 ]]; then
  fix_permissions
fi
if [[ "$RUN_DEPLOY" -eq 1 ]]; then
  deploy_stack
fi

log "Done."
if [[ "$RUN_DEPLOY" -eq 1 && "$WITH_NGINX" -eq 0 ]]; then
  base_file="$(base_compose_file)"
  echo "  Logs:      docker compose -f $base_file logs -f"
  echo "  MapProxy:  curl -fsS http://localhost:\${MAPPROXY_PORT:-8081}/wmts/1.0.0/WMTSCapabilities.xml"
  echo "  Tiles:     curl -fsS http://localhost:\${TILESERVER_PORT:-8080}/"
  if [[ "$USE_4087" -eq 1 ]]; then
    echo "  Tiles (4087): curl -fsS http://localhost:\${TILESERVER_4087_PORT:-8083}/"
  fi
  echo "  Stop:      docker compose -f $base_file down --remove-orphans"
elif [[ "$RUN_DEPLOY" -eq 1 && "$USE_4087" -eq 1 ]]; then
  # docker compose only auto-discovers docker-compose.yaml/.override.yaml,
  # not docker-compose.4087.yaml, so -f must stay explicit here.
  base_file="$(base_compose_file)"
  echo "  Logs:   docker compose -f $base_file -f docker-compose.override.yaml logs -f"
  echo "  Health: curl -fsS http://localhost:\${NGINX_PORT:-8082}/healthz"
  echo "  Tiles (4087): curl -fsS http://localhost:\${NGINX_PORT:-8082}/tileservergl4087/"
  echo "  Stop:   docker compose -f $base_file -f docker-compose.override.yaml down --remove-orphans"
elif [[ "$RUN_DEPLOY" -eq 1 ]]; then
  echo "  Logs:   docker compose logs -f"
  echo "  Health: curl -fsS http://localhost:\${NGINX_PORT:-8082}/healthz"
  echo "  Stop:   docker compose down --remove-orphans"
fi
