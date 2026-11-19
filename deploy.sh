#!/usr/bin/env bash
#
# Bootstrap a macOS or Linux (Ubuntu/Debian or Fedora/RHEL) host and deploy
# the RBT Docker Compose stack. See docs/install-macos.md or
# docs/install-linux.md for the manual equivalent of each step, or run with
# --help.
#
#   ./deploy.sh

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

# Public, read-only mirror of the MBTiles on an S3-compatible (RustFS)
# endpoint. Used for every file whose S3_BUCKET_* variable is unset, with
# anonymous (unsigned) requests, so no AWS credentials are needed.
PUBLIC_S3_ENDPOINT="https://rustfs-rbt-agc-dev.apps.kubic.dev.ngaxc.net"
PUBLIC_S3_REGION="us-east-1"
PUBLIC_S3_PREFIX_3857="s3://mbtiles/3857"
PUBLIC_S3_PREFIX_4087="s3://mbtiles/4087"

FORCE_DOWNLOAD=0
WITH_NGINX=1
USE_4087=0
# Set by fetch_mbtiles whenever it actually downloads a file, so the refresh
# step knows the running tileservers (and nginx's tile cache) are now stale.
DATA_UPDATED=0
# 1 when the steps that need root must go through sudo -- set in "Main".
NEED_SUDO=0

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Runs "$@" as root: via sudo when NEED_SUDO=1, else directly (already root,
# or macOS, where nothing needs it). A function rather than a "${SUDO[@]}"
# array prefix because expanding an empty array under `set -u` is an
# "unbound variable" error in bash < 4.4 -- which is what macOS ships as
# /bin/bash.
as_root() {
  if [[ "$NEED_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# sudo resets the environment, so an exported DEBIAN_FRONTEND never reaches
# apt-get through it -- pass it on the command line instead.
apt_get() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# The oldest Docker Compose the script's own commands work with:
# `up --wait-timeout` arrived in 2.17.0 and `pull --ignore-buildable` in
# 2.15.0. Older Compose rejects the flag with an "unknown flag" error that
# doesn't say the real problem is the version.
MIN_COMPOSE_VERSION="2.17.0"

# The memory RBT recommends giving Docker, in bytes (14 GiB: the README asks
# for 16 GB of RAM, and the engine's reported total is a little under the
# amount configured). Below it, uWSGI's workers and the renderer pools can be
# killed for lack of memory, which looks like a service that restarts forever.
MIN_DOCKER_MEMORY_BYTES=$((14 * 1024 * 1024 * 1024))

# True when running inside WSL2 (the kernel release names Microsoft).
is_wsl() {
  [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease
}

# True when dotted version $1 is at least dotted version $2. Takes only the
# leading digits and dots of $1, so "v2.29.1-desktop.1" counts as 2.29.1.
# Pure bash, because `sort -V` isn't in every sort macOS has shipped.
version_at_least() {
  local have="${1#v}" need="$2" i h n
  have="${have%%[!0-9.]*}"
  local -a have_parts need_parts
  IFS=. read -r -a have_parts <<<"$have"
  IFS=. read -r -a need_parts <<<"$need"
  for (( i = 0; i < ${#need_parts[@]}; i++ )); do
    h="${have_parts[i]:-0}"
    n="${need_parts[i]}"
    if (( 10#${h:-0} > 10#$n )); then return 0; fi
    if (( 10#${h:-0} < 10#$n )); then return 1; fi
  done
  return 0
}

# Prints a byte count the way people read it: "1.4 GiB", "850 MiB".
format_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GiB", b / 1073741824
    else if (b >= 1048576) printf "%.0f MiB", b / 1048576
    else printf "%d bytes", b
  }'
}

usage() {
  cat <<'EOF'
deploy.sh - Bootstrap a macOS or Linux host and deploy the RBT Docker Compose stack.

With no step flags, --init, --download, --perm, and --deploy run in order
(plus --refresh whenever --download fetched new data). Pass one or more
step flags to run only those steps (still in the order listed here,
regardless of the order given on the command line):

  --init      Install prerequisites: AWS CLI v2, Docker (Docker Desktop on
              macOS; Docker Engine + Compose plugin on Linux), and git.
              Uses Homebrew on macOS, apt on Ubuntu/Debian, or dnf on
              Fedora/RHEL, whichever this host's /etc/os-release identifies.
  --download  Download RBT.mbtiles/TERRAIN.mbtiles into
              tileserver/data/3857/ -- from the public RBT mirror (no AWS
              credentials needed) unless S3_BUCKET_RBT/S3_BUCKET_TERRAIN
              point at your own bucket (see below). Before each download it
              checks that the disk has room, and afterwards that the file is
              the size the mirror reports. Whenever this actually fetches a
              file, --refresh runs too.
  --perm      Fix mapproxy/nginx runtime directory permissions (a no-op on
              macOS -- see below).
  --refresh   Make the stack serve the current data: recreate any running
              tileservergl container (it reads MBTiles and styles only at
              startup) and empty nginx's tile cache, restarting nginx if it
              is running. Run this yourself after changing MBTiles or
              styles by hand.
  --deploy    Start Docker if it isn't running, then run
              `docker compose up -d --wait --remove-orphans`, failing if any
              service doesn't become healthy. --remove-orphans also removes
              containers left over from a different deployment, such as
              tileservergl4087 after leaving the --4087 stack.

The modifiers below are not steps, so on their own they still mean "run every
step" -- including installing prerequisites and downloading map data. Pair
them with a step, such as --deploy.

  --force     Re-download mbtiles even if already present (only relevant
              together with --download, or with no step flags).
  --no-nginx  Deploy mapproxy and tileservergl only, without the local
              nginx reverse-proxy/cache -- use this when something else
              (e.g. an AWS ALB and/or CloudFront) talks HTTP directly to
              mapproxy (port ${MAPPROXY_PORT:-8081}) and tileservergl
              (port ${TILESERVER_PORT:-8080}) instead. Only relevant with
              --deploy, or with no step flags.
  --4087      Also deploy docker-compose.4087.yaml, an overlay on
              docker-compose.yaml that adds a second TileserverGL container
              (tileservergl4087) serving EPSG:4087 MBTiles, and points
              mapproxy at mapproxy.4087.yaml so its EPSG:4326 caches
              reproject from EPSG:4087 instead of EPSG:3857 (see
              docs/deployment-4087.md).
              Combines with --no-nginx and --force. With --download (or no
              step flags), also downloads the EPSG:4087 RBT.mbtiles/
              TERRAIN.mbtiles into tileserver/data/4087/.

Usage:
  ./deploy.sh                       # full run, data from the public mirror
  ./deploy.sh --init                # just install prerequisites
  ./deploy.sh --download --perm     # just refresh data + permissions
  ./deploy.sh --refresh             # reload styles/MBTiles, purge cache
  ./deploy.sh --deploy              # just (re)start the stack
  ./deploy.sh --force               # full run, force re-download
  ./deploy.sh --no-nginx            # full run, skip the local nginx
  ./deploy.sh --4087                # full run, EPSG:4087 dual-tileserver stack
  ./deploy.sh --4087 --no-nginx     # same, without the local nginx

Run this as your normal (non-root) user, not via `sudo`. On Linux it
escalates internally with sudo only for the specific steps that need root
(apt/dnf, installing/starting Docker, chown, docker compose). Because sudo
drops your shell's variables, put Compose settings such as NGINX_PORT in
.env rather than exporting them. On macOS nothing here uses
sudo -- Homebrew and Docker Desktop both install and run as your normal
user.

Where the data comes from: by default, each MBTiles file is downloaded
anonymously from the public RBT mirror (an S3-compatible endpoint, see
PUBLIC_S3_* at the top of this script) -- no AWS credentials or .env
needed. Setting a file's S3_BUCKET_* variable below downloads that file
from your own bucket instead, and those downloads run unprivileged with
your own AWS credential chain (env vars, ~/.aws/credentials, AWS_PROFILE,
or an EC2/ECS instance role) exactly as `aws s3 cp` would outside this
script -- nothing here configures AWS credentials for you.

Optional environment variables (each overrides the public mirror for one
file; a value already set in the environment takes precedence over the
same key in .env):
  S3_BUCKET_RBT      Bucket (optionally with a prefix), no filename, e.g.
                      "my-bucket" or "s3://my-bucket/exports". Must contain
                      RBT.mbtiles.
  S3_BUCKET_TERRAIN  Same, but must contain TERRAIN.mbtiles.
  S3_BUCKET_RBT_4087      Same as S3_BUCKET_RBT, but for the EPSG:4087
                           RBT.mbtiles (only used with --4087).
  S3_BUCKET_TERRAIN_4087  Same as S3_BUCKET_TERRAIN, but for the EPSG:4087
                           TERRAIN.mbtiles (only used with --4087).

Re-running this script is safe: package installs are skipped when already
present. TERRAIN.mbtiles is only downloaded once (it never changes upstream).
RBT.mbtiles is re-downloaded automatically whenever the S3 object's
LastModified time is newer than the local copy's -- pass --force to
re-download either file unconditionally. Either way, a download that
fetched anything is followed by --refresh.
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
    # Tolerate a .env saved with Windows (CRLF) line endings.
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"

    # Parse the value the way Compose does, so the script and Compose agree
    # on what a line means. A quoted value ends at its closing quote, and
    # anything after it may only be an inline comment (`KEY="a b" # note`).
    # An unquoted value ends at the first ` #`, and its surrounding
    # whitespace is trimmed. A closing quote followed by other text isn't a
    # quoted value at all, so it falls back to the old rule (strip one
    # layer of quotes from the whole value) rather than guessing.
    if [[ "$value" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      # `${value%%[[:space:]]#*}` cuts at the first whitespace-then-# pair;
      # a `#` that touches the value (a URL fragment, a password) stays.
      value="${value%%[[:space:]]#*}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
    fi

    # Not `[[ ... ]] && export`: as the loop's last command, a false test
    # would make this function return 1, which `set -e` turns into a silent
    # exit whenever the last key in .env is already set in the environment.
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
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
      # Skip when git is already there (Apple's Command Line Tools ship one):
      # a second, Homebrew copy only adds a version to keep track of.
      if command -v git >/dev/null 2>&1; then
        log "Git already installed; skipping"
      else
        log "Installing Git (brew package: git)"
        brew install git
      fi
      ;;
    fedora)
      log "Installing base packages"
      as_root dnf install -y unzip git
      ;;
    ubuntu)
      log "Updating apt package lists"
      apt_get update
      log "Installing base packages"
      apt_get install -y ca-certificates curl gnupg unzip git
      ;;
    *)
      die "Don't know how to install prerequisites on this OS. See docs/install-macos.md, docs/install-linux.md, or docs/install-windows.md for manual install instructions, or install aws, docker (with the Compose plugin), and git yourself and re-run with --download --perm --deploy."
      ;;
  esac
}

install_aws_cli_linux() {
  log "Installing AWS CLI v2"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # $tmp_dir is intentionally expanded now, not at trap-fire time. A RETURN
  # trap outlives the function that set it (it fires again when the caller
  # returns), so it also clears itself.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'; trap - RETURN" RETURN
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp_dir/awscliv2.zip"
  unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir"
  as_root "$tmp_dir/aws/install"
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
    as_root usermod -aG docker "$target_user"
    warn "Added $target_user to the docker group -- log out/in (or run 'newgrp docker') to run docker without sudo outside this script."
  fi
}

# Prints "<distro> <suite>" for Docker's apt repository. Ubuntu and its
# derivatives (Pop!_OS, Linux Mint, ...) use Docker's ubuntu repo with the
# Ubuntu base's codename -- a derivative's own codename (Mint's "wilma") isn't
# one Docker publishes. Debian and its derivatives use the debian repo.
docker_apt_repo() (
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
    echo "ubuntu $UBUNTU_CODENAME"
  else
    echo "debian ${DEBIAN_CODENAME:-${VERSION_CODENAME:?/etc/os-release has no VERSION_CODENAME}}"
  fi
)

# Starts the Docker service now and at every boot. A WSL2 distribution that
# isn't running systemd has no service manager to enable it with (and
# `systemctl` there fails with "System has not been booted with systemd"),
# so the engine is started with `service` instead -- which lasts only until
# that WSL2 session ends.
enable_docker_service() {
  log "Enabling the Docker service"
  if [[ -d /run/systemd/system ]]; then
    as_root systemctl enable --now docker
  elif is_wsl; then
    warn "This WSL2 distribution isn't running systemd, so Docker can't start by itself. Starting it with 'service docker start'; run that again in each new WSL2 session, or turn systemd on (docs/install-windows.md, Option B) so it starts automatically."
    as_root service docker start
  else
    die "systemd isn't running on this host, so the Docker service can't be enabled automatically. Start the Docker daemon yourself, then re-run ./deploy.sh."
  fi
}

install_docker_linux_apt() {
  local repo distro suite
  repo="$(docker_apt_repo)"
  read -r distro suite <<<"$repo"

  # Docker's own list of packages that conflict with docker-ce. Only the
  # installed ones are named: one name apt has never heard of (such as
  # docker-compose-v2 on an older release) fails the whole `apt-get remove`
  # with "Unable to locate package", and an `|| true` to hide that would also
  # hide the removal of every conflicting package that is installed.
  log "Removing old/conflicting Docker packages (if any)"
  local pkg old_packages=()
  for pkg in docker docker-engine docker.io docker-doc docker-compose \
    docker-compose-v2 podman-docker containerd runc; do
    if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null)" == ii* ]]; then
      old_packages+=("$pkg")
    fi
  done
  if (( ${#old_packages[@]} > 0 )); then
    apt_get remove -y "${old_packages[@]}"
  fi

  log "Adding Docker's official apt repository (linux/$distro $suite)"
  as_root mkdir -m 0755 -p /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" |
    as_root gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  as_root chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $suite stable" |
    as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  log "Installing Docker Engine and the Compose plugin"
  apt_get update
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  enable_docker_service
}

# Prints which of Docker's rpm repositories fits this host: fedora or rhel
# for those distros themselves, centos for the RHEL rebuilds (CentOS Stream,
# Rocky Linux, AlmaLinux, ...), and fedora for anything else Fedora-like.
docker_dnf_repo_distro() (
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    fedora|rhel) echo "$ID" ;;
    *)
      case " ${ID_LIKE:-} " in
        *" rhel "*|*" centos "*) echo "centos" ;;
        *) echo "fedora" ;;
      esac
      ;;
  esac
)

install_docker_linux_dnf() {
  local distro repo_url
  distro="$(docker_dnf_repo_distro)"
  repo_url="https://download.docker.com/linux/$distro/docker-ce.repo"

  log "Removing old/conflicting Docker packages (if any)"
  as_root dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine || true

  log "Adding Docker's official dnf repository (linux/$distro)"
  # dnf5 (the default dnf from Fedora 41) replaced config-manager's
  # --add-repo with `addrepo --from-repofile`.
  if command -v dnf5 >/dev/null 2>&1; then
    as_root dnf5 -y install dnf5-plugins
    as_root dnf5 config-manager addrepo --overwrite --from-repofile="$repo_url"
  else
    as_root dnf -y install dnf-plugins-core
    as_root dnf config-manager --add-repo "$repo_url"
  fi

  log "Installing Docker Engine and the Compose plugin"
  as_root dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  enable_docker_service
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

# Makes sure the Docker engine answers before any compose call. --init only
# starts it right after installing it, so a host whose prerequisites were
# already present may still have it stopped -- Docker Desktop not launched
# yet, or dockerd not enabled at boot.
ensure_docker_running() {
  command -v docker >/dev/null 2>&1 ||
    die "docker is not installed -- run ./deploy.sh --init first (or install Docker and its Compose plugin yourself)."
  if as_root docker info >/dev/null 2>&1; then
    return
  fi

  if [[ "$OS_FAMILY" == "macos" ]]; then
    start_docker_desktop_and_wait_macos
    return
  fi

  if [[ -d /run/systemd/system ]]; then
    log "Starting the Docker service"
    as_root systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    # No systemd: WSL2 without it, or a minimal container-style host.
    log "Starting the Docker service (no systemd here, so with 'service')"
    as_root service docker start || true
  fi
  as_root docker info >/dev/null 2>&1 ||
    die "The Docker engine isn't running and couldn't be started automatically. Start it (e.g. 'sudo systemctl start docker', or Docker Desktop with WSL integration when running under WSL2), then re-run."
}

prereqs_installed() {
  command -v aws >/dev/null 2>&1 &&
    command -v docker >/dev/null 2>&1 &&
    docker compose version >/dev/null 2>&1 &&
    command -v git >/dev/null 2>&1
}

install_prereqs() {
  if prereqs_installed; then
    log "All prerequisites already installed (aws, docker, docker compose, git); skipping setup"
    return
  fi

  install_base_packages
  install_aws_cli
  install_docker
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

# Runs `aws "$@"` against the public mirror (anonymous, on its own endpoint)
# when $1 is 1, else with your own AWS config and credential chain. The
# mirror's settings go on the command line so they beat any AWS_ENDPOINT_URL
# or region in the environment, and so an older AWS CLI that ignores
# AWS_ENDPOINT_URL can't send s3://mbtiles to a same-named AWS bucket. A
# function rather than a flags array for the same bash < 4.4 reason as
# as_root.
s3_aws() {
  local public="$1"
  shift
  if [[ "$public" -eq 1 ]]; then
    aws --no-sign-request --endpoint-url "$PUBLIC_S3_ENDPOINT" --region "$PUBLIC_S3_REGION" "$@"
  else
    aws "$@"
  fi
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
    # -u so Linux prints UTC like the macOS branch, not the host's zone.
    date -u -d "@$1"
  fi
}

file_size_bytes() {
  if [[ "$OS_FAMILY" == "macos" ]]; then
    stat -f %z "$1"
  else
    stat -c %s "$1"
  fi
}

# Prints the bytes free on the filesystem holding directory $1, or nothing
# (with a non-zero exit) if df's output isn't understood. `df -P` is the
# POSIX layout on both GNU and BSD; counting fields from the right keeps it
# right when a network filesystem's name contains spaces, and printf avoids
# awk's scientific notation for large numbers.
free_bytes() {
  local free
  free="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $(NF - 2) * 1024 }')" || return 1
  [[ "$free" =~ ^[0-9]+$ ]] || return 1
  echo "$free"
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

# Prints "<LastModified as epoch seconds> <size in bytes>" for an S3 object
# on stdout, or nothing (with a non-zero exit) if it can't be read -- e.g.
# missing object, or an IAM policy that allows GetObject but not this
# HeadObject call. One call answers both "is the mirror's copy newer?" and
# "how much room does the download need, and did all of it arrive?". $1 is
# s3_aws's public flag.
remote_object_info() {
  local public="$1" remote_uri="$2" info last_modified size epoch
  info="$(s3_aws "$public" s3api head-object \
    --bucket "$(s3_bucket_name "$remote_uri")" \
    --key "$(s3_object_key "$remote_uri")" \
    --query '[LastModified, ContentLength]' --output text 2>/dev/null)" || return 1
  read -r last_modified size <<<"$info"
  [[ -n "$last_modified" && "$last_modified" != "None" && "$size" =~ ^[0-9]+$ ]] || return 1
  epoch="$(parse_iso8601_epoch "$last_modified")" || return 1
  echo "$epoch $size"
}

# Deletes the temporary files an interrupted `aws s3 cp` leaves next to
# $1. The AWS CLI downloads to "<name>.<8 hex digits>" and renames it into
# place only when the whole file has arrived; it can't resume, so a leftover
# one is just disk space (several hundred GB of it) that the retry would
# need on top of its own. Only that exact suffix is matched, so SQLite's
# -journal/-wal/-shm companions (which use a hyphen) and the real file are
# never touched.
remove_partial_downloads() {
  local dest="$1" partial
  for partial in "$dest".*; do
    [[ -e "$partial" ]] || continue
    [[ "${partial##*.}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    warn "Removing the leftover partial download $partial from an interrupted run"
    rm -f "$partial"
  done
}

# Stops before a download that can't fit. The AWS CLI writes the new file
# next to any existing one and replaces it at the end, so a re-download needs
# the full size free even though the old copy is about to go.
check_free_space() {
  local dir="$1" needed="$2" filename="$3" free
  if ! free="$(free_bytes "$dir")"; then
    warn "Couldn't read the free disk space for $dir, so the room check for $filename is skipped"
    return 0
  fi
  if (( free < needed )); then
    die "Not enough free disk space for $filename: it needs $(format_bytes "$needed") and $dir has $(format_bytes "$free") free. Free up space (a re-download needs room for the new copy while the old one is still in place), then re-run ./deploy.sh --download. See docs/troubleshooting.md."
  fi
}

# Removes the file and stops when it isn't the size the mirror reported: a
# truncated copy can pass for a finished one (the next run would see a file
# newer than the mirror's and skip it), and the tileserver would fail on it
# much later and less clearly.
verify_downloaded_size() {
  local dest="$1" expected="$2" actual
  [[ -n "$expected" ]] || return 0
  actual="$(file_size_bytes "$dest")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$dest"
    die "$dest is $actual bytes but the mirror's copy is $expected, so it was removed. Re-run ./deploy.sh --download to fetch it again."
  fi
}

# check_remote=1 re-downloads whenever the S3 object's LastModified is newer
# than the local file's mtime (used for RBT.mbtiles, which is updated
# periodically). check_remote=0 just downloads once and leaves the local
# file alone afterwards (used for TERRAIN.mbtiles, which never changes).
# --force always re-downloads regardless of check_remote. public_prefix is
# the public mirror's s3:// prefix for this file, used when bucket_var is
# unset. Before a download it clears partial files and checks the disk has
# room; after it, that the size matches. If the mirror's metadata can't be
# read those two checks are skipped with a warning rather than blocking a
# download that would have worked.
fetch_mbtiles() {
  local bucket_var="$1" dest="$2" check_remote="$3" public_prefix="$4"
  local filename prefix remote_uri need_download public source
  local remote_info remote_epoch remote_size="" info_read=0

  filename="$(basename "$dest")"
  if [[ -n "${!bucket_var:-}" ]]; then
    prefix="$(normalize_s3_uri "${!bucket_var}")"
    public=0
    source="$bucket_var"
  else
    prefix="$public_prefix"
    public=1
    source="the public mirror at $PUBLIC_S3_ENDPOINT"
  fi
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
    local local_epoch
    info_read=1
    if remote_info="$(remote_object_info "$public" "$remote_uri")"; then
      read -r remote_epoch remote_size <<<"$remote_info"
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

  # The size is needed whichever way this got here; read it now unless the
  # up-to-date check above already did (or already failed to).
  if [[ "$info_read" -eq 0 ]] && remote_info="$(remote_object_info "$public" "$remote_uri")"; then
    read -r remote_epoch remote_size <<<"$remote_info"
  fi

  remove_partial_downloads "$dest"
  if [[ -n "$remote_size" ]]; then
    check_free_space "$(dirname "$dest")" "$remote_size" "$filename"
    log "Downloading $filename ($(format_bytes "$remote_size")) from $remote_uri ($source)"
  else
    warn "Couldn't read $filename's size from $source, so the free-space and size checks are skipped"
    log "Downloading $filename from $remote_uri ($source)"
  fi
  s3_aws "$public" s3 cp "$remote_uri" "$dest" ||
    die "Downloading $filename failed. Re-run ./deploy.sh --download to try again -- the AWS CLI starts the file over, and the partial copy is removed first."
  verify_downloaded_size "$dest" "$remote_size"
  DATA_UPDATED=1
}

download_mbtiles() {
  command -v aws >/dev/null 2>&1 ||
    die "The AWS CLI (aws) isn't installed. Run ./deploy.sh --init to install it, or install it yourself (docs/install-macos.md, docs/install-linux.md), then re-run."
  mkdir -p "$DATA_DIR_3857"

  fetch_mbtiles S3_BUCKET_RBT "$RBT_FILE_3857" 1 "$PUBLIC_S3_PREFIX_3857"
  fetch_mbtiles S3_BUCKET_TERRAIN "$TERRAIN_FILE_3857" 0 "$PUBLIC_S3_PREFIX_3857"

  [[ -s "$RBT_FILE_3857" ]] || die "$RBT_FILE_3857 is missing or empty after download"
  [[ -s "$TERRAIN_FILE_3857" ]] || die "$TERRAIN_FILE_3857 is missing or empty after download"

  # The --4087 stack still runs the EPSG:3857 tileservergl container too
  # (see docker-compose.4087.yaml), so the downloads above always run;
  # this just adds the second container's EPSG:4087 MBTiles alongside them.
  if [[ "$USE_4087" -eq 1 ]]; then
    mkdir -p "$DATA_DIR_4087"

    fetch_mbtiles S3_BUCKET_RBT_4087 "$RBT_FILE_4087" 1 "$PUBLIC_S3_PREFIX_4087"
    fetch_mbtiles S3_BUCKET_TERRAIN_4087 "$TERRAIN_FILE_4087" 0 "$PUBLIC_S3_PREFIX_4087"

    [[ -s "$RBT_FILE_4087" ]] || die "$RBT_FILE_4087 is missing or empty after download"
    [[ -s "$TERRAIN_FILE_4087" ]] || die "$TERRAIN_FILE_4087 is missing or empty after download"
  fi
}

# ---------------------------------------------------------------------------
# Permissions (see docs/install-linux.md -- mapproxy's image runs as uid/gid 1000)
# ---------------------------------------------------------------------------

fix_permissions() {
  log "Setting mapproxy/nginx runtime directory permissions"
  mkdir -p mapproxy/data mapproxy/locks mapproxy/tile_locks nginx/cache

  if [[ "$OS_FAMILY" == "macos" ]]; then
    log "Skipping chown/chmod on macOS -- Docker Desktop's VirtioFS file sharing maps the host user into the container, so there's no uid/gid mismatch to fix"
    return
  fi

  as_root chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks
  # 775 directories, 664 files. Git tracks the executable bit, so the old
  # `chmod -R 775` showed the locks dirs' .txt placeholders as modified (and
  # made `git pull` abort on a change to one); a-x repairs those clones.
  as_root chmod -R a-x,ug+rwX,o+rX mapproxy/data mapproxy/locks mapproxy/tile_locks
  # nginx's master process runs as root and creates (and chowns) whatever it
  # needs inside this itself, so only the top level matters -- recursing
  # into nginx/cache would walk every cached tile on every run.
  as_root chmod 775 nginx/cache
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# `docker compose` with this run's -f list (COMPOSE_FILES, set in "Main"),
# as root where needed.
compose() {
  as_root docker compose "${COMPOSE_FILES[@]}" "$@"
}

# The `docker compose ...` prefix to show in the hints printed at the end:
# bare for the default stack (Compose auto-discovers docker-compose.yaml +
# docker-compose.override.yaml by itself), else with this run's -f list. A
# COMPOSE_FILE in the environment or .env changes what bare `docker compose`
# means, so then the -f list is always spelled out.
compose_hint() {
  if [[ "$USE_4087" -eq 0 && "$WITH_NGINX" -eq 1 && -z "${COMPOSE_FILE:-}" ]]; then
    echo "docker compose"
    return
  fi
  local name hint="docker compose"
  for name in "${COMPOSE_FILE_NAMES[@]}"; do
    hint="$hint -f $name"
  done
  echo "$hint"
}

# Prints the host port Compose published for service $1's container port $2,
# or $3 when that can't be read (e.g. the service isn't running). Asking
# Compose beats echoing $NGINX_PORT etc.: under sudo, Compose never sees a
# value exported in this shell, only .env's.
published_port() {
  local port
  port="$(compose port "$1" "$2" 2>/dev/null | sed -n '1s/.*://p')" || true
  echo "${port:-$3}"
}

# Dies when the Docker Compose plugin is older than MIN_COMPOSE_VERSION. The
# version is only readable once `docker` exists; if it can't be read, say so
# and carry on rather than block a deploy that might work.
check_compose_version() {
  local version
  version="$(docker compose version --short 2>/dev/null)" || version=""
  if [[ -z "$version" ]]; then
    warn "Couldn't read the Docker Compose version, so it wasn't checked against the minimum ($MIN_COMPOSE_VERSION)."
    return 0
  fi
  version_at_least "$version" "$MIN_COMPOSE_VERSION" ||
    die "Docker Compose $version is too old: this script needs $MIN_COMPOSE_VERSION or newer (for 'up --wait-timeout' and 'pull --ignore-buildable'). Update Docker, then re-run -- see the \"Docker Compose Is Too Old\" section of docs/troubleshooting.md."
}

# Warns when the engine has less memory than the stack needs. Docker Desktop
# (and WSL2) cap it well below the host's RAM by default, and the symptom of
# too little is a container that restarts without a clear error.
warn_if_docker_memory_low() {
  local mem
  mem="$(as_root docker info --format '{{.MemTotal}}' 2>/dev/null)" || return 0
  [[ "$mem" =~ ^[0-9]+$ ]] || return 0
  if (( mem < MIN_DOCKER_MEMORY_BYTES )); then
    warn "Docker has only $(format_bytes "$mem") of memory for its containers; RBT is built for 16 GB. Raise it in Docker Desktop (Settings > Resources) or, under WSL2, in %UserProfile%\\.wslconfig (docs/install-windows.md). Containers that are killed for lack of memory show up as restarting -- see docs/troubleshooting.md."
  fi
}

# Dies when the effective uWSGI worker settings can't start, before Docker
# spends minutes building and then reports an unhealthy mapproxy. Mirrors
# the defaults in docker-compose.yaml; UWSGI_CHEAPER=0 turns cheaper mode off.
check_uwsgi_settings() {
  local processes="${UWSGI_PROCESSES:-8}" cheaper="${UWSGI_CHEAPER:-4}"
  if ! [[ "$processes" =~ ^[0-9]+$ && "$cheaper" =~ ^[0-9]+$ ]]; then
    die "UWSGI_PROCESSES ($processes) and UWSGI_CHEAPER ($cheaper) must be whole numbers -- check .env."
  fi
  if (( cheaper != 0 && cheaper >= processes )); then
    die "UWSGI_CHEAPER ($cheaper) must be lower than UWSGI_PROCESSES ($processes), or uWSGI won't start. Change them in .env (UWSGI_CHEAPER=0 keeps every worker running)."
  fi
}

# Dies before building or starting anything if the stack's MBTiles aren't
# there: a tileservergl without data never becomes healthy, which would
# otherwise be reported only after the full build and a 10-minute wait.
require_mbtiles() {
  local file missing="" files=("$RBT_FILE_3857" "$TERRAIN_FILE_3857")
  if [[ "$USE_4087" -eq 1 ]]; then
    files+=("$RBT_FILE_4087" "$TERRAIN_FILE_4087")
  fi
  for file in "${files[@]}"; do
    if [[ ! -s "$file" ]]; then
      missing="$missing
  $file"
    fi
  done
  if [[ -n "$missing" ]]; then
    die "These map data files are missing or empty:$missing
Download them with ./deploy.sh --download (add --4087 for the EPSG:4087 stack), or see the README's 'Get the Map Data'."
  fi
}

# True when a tileservergl4087 container is running. As root only when this
# run already uses sudo for Docker (refresh/deploy); a download-only run
# stays unprivileged and just looks without it.
tileservergl4087_running() {
  local names
  if [[ "$RUN_REFRESH" -eq 1 || "$RUN_DEPLOY" -eq 1 ]]; then
    names="$(as_root docker ps --filter 'name=^tileservergl4087$' --format '{{.Names}}' 2>/dev/null)" || return 1
  else
    names="$(docker ps --filter 'name=^tileservergl4087$' --format '{{.Names}}' 2>/dev/null)" || return 1
  fi
  [[ -n "$names" ]]
}

# Warns, once, up front, when the EPSG:4087 stack is running but this run
# wasn't given --4087. Each step would otherwise treat it differently without
# saying so: --download skips its files, --refresh leaves it serving old
# data, and --deploy removes it as an orphan.
warn_if_unselected_4087_running() {
  [[ "$USE_4087" -eq 0 ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  tileservergl4087_running || return 0

  local effects=""
  if [[ "$RUN_DOWNLOAD" -eq 1 ]]; then
    effects="$effects
  - the download fetches only the EPSG:3857 data, not the EPSG:4087 files"
  fi
  if [[ "$RUN_REFRESH" -eq 1 || "$RUN_DOWNLOAD" -eq 1 ]]; then
    effects="$effects
  - a refresh leaves tileservergl4087 serving the old data"
  fi
  if [[ "$RUN_DEPLOY" -eq 1 ]]; then
    effects="$effects
  - the deploy removes tileservergl4087 (as an orphan), ending the EPSG:4087 stack"
  fi
  [[ -n "$effects" ]] || return 0
  warn "tileservergl4087 (the EPSG:4087 stack) is running, but this run wasn't given --4087:$effects
Press Ctrl+C now and re-run with --4087 to keep it, or let this run switch to the default stack."
}

# Warns when COMPOSE_FILE (environment or .env) lists different files from
# this run's -f list. -f overrides it, so this run is unaffected, but a
# plain `docker compose` typed afterwards follows COMPOSE_FILE and may act on
# a different deployment than the one just deployed.
warn_if_compose_file_differs() {
  [[ -n "${COMPOSE_FILE:-}" ]] || return 0
  local entry entries configured="" expected="${COMPOSE_FILE_NAMES[*]}"
  IFS="${COMPOSE_PATH_SEPARATOR:-:}" read -r -a entries <<<"$COMPOSE_FILE"
  for entry in "${entries[@]}"; do
    configured="${configured:+$configured }${entry##*/}"
  done
  if [[ "$configured" != "$expected" ]]; then
    warn "COMPOSE_FILE is set to '$COMPOSE_FILE', but this run uses $expected, and -f overrides COMPOSE_FILE. A plain 'docker compose' you type yourself follows COMPOSE_FILE, so it may act on a different deployment. The commands printed at the end include explicit -f flags."
  fi
}

# Prints what this run will do, so a bare ./deploy.sh (which installs
# packages and downloads hundreds of GB) never starts without saying so.
describe_run() {
  local steps="" stack="the default deployment (EPSG:3857)" nginx="with nginx"
  if [[ "$RUN_INIT" -eq 1 ]]; then steps="$steps init"; fi
  if [[ "$RUN_DOWNLOAD" -eq 1 ]]; then steps="$steps download"; fi
  if [[ "$RUN_PERM" -eq 1 ]]; then steps="$steps perm"; fi
  if [[ "$RUN_REFRESH" -eq 1 ]]; then
    steps="$steps refresh"
  elif [[ "$RUN_DOWNLOAD" -eq 1 ]]; then
    steps="$steps (refresh, if the download fetches anything)"
  fi
  if [[ "$RUN_DEPLOY" -eq 1 ]]; then steps="$steps deploy"; fi
  if [[ "$USE_4087" -eq 1 ]]; then stack="the EPSG:4087 deployment"; fi
  if [[ "$WITH_NGINX" -eq 0 ]]; then nginx="without nginx"; fi

  log "This run: steps${steps:- (none)}; $stack, $nginx"
  if [[ "$STEP_SELECTED" -eq 0 ]]; then
    echo "    No step flag was given, so every step runs: installing missing prerequisites,"
    echo "    downloading any missing or newer map data, and deploying. To run only some"
    echo "    of them, name them, such as ./deploy.sh --deploy (see --help)."
  fi
}

# nginx caches tiles for 30 days (see nginx/config/nginx.conf) and can't tell
# when the MBTiles or styles behind them change, and tileservergl only reads
# both at startup. So after either changes, this recreates whichever
# tileserver containers are running and empties nginx's tile cache,
# restarting nginx around the purge if it's running. Services that aren't
# running are left for --deploy (or you) to start with the new data.
refresh_stack() {
  local running="" svc nginx_running=0 did_something=0
  local recreate=()

  # With the engine stopped nothing can be running, and only the on-disk
  # nginx cache below needs clearing.
  if as_root docker info >/dev/null 2>&1; then
    check_compose_version
    running="$(compose ps --status running --services 2>/dev/null || true)"
  fi

  for svc in "${TILESERVER_SERVICES[@]}"; do
    if grep -qx "$svc" <<<"$running"; then
      recreate+=("$svc")
    fi
  done
  if [[ ${#recreate[@]} -gt 0 ]]; then
    log "Recreating ${recreate[*]} to load the new data"
    compose up -d --no-deps --force-recreate --wait --wait-timeout 600 "${recreate[@]}" ||
      die "${recreate[*]} did not become healthy again -- see '$(compose_hint) logs ${recreate[*]}'."
    did_something=1
  fi

  if [[ "$WITH_NGINX" -eq 1 ]] && grep -qx nginx <<<"$running"; then
    nginx_running=1
    # Stopped while its cache is emptied; the restart also makes it
    # re-resolve the recreated tileserver containers' addresses.
    compose stop nginx
  fi

  local cache_dir="$SCRIPT_DIR/nginx/cache/tile_cache"
  if [[ -d "$cache_dir" ]]; then
    log "Purging the nginx tile cache ($cache_dir)"
    as_root find "$cache_dir" -mindepth 1 -delete
    did_something=1
  fi

  if [[ "$nginx_running" -eq 1 ]]; then
    log "Restarting nginx"
    compose up -d --no-deps --wait --wait-timeout 600 nginx ||
      die "nginx did not become healthy again -- see '$(compose_hint) logs nginx'."
    did_something=1
  fi

  if [[ "$did_something" -eq 0 ]]; then
    log "Nothing to refresh: no tileserver or nginx is running and nginx has no tile cache yet"
  fi
}

deploy_stack() {
  if [[ "$WITH_NGINX" -eq 0 ]]; then
    log "Deploying without nginx -- mapproxy and tileservergl publish their own ports directly"
  fi
  # The checks that need no Docker run first, so a mistake costs seconds
  # rather than a build and a 10-minute wait.
  require_mbtiles
  check_uwsgi_settings
  ensure_docker_running
  check_compose_version
  warn_if_docker_memory_low

  log "Building the mapproxy image"
  compose build mapproxy

  log "Pulling remaining images"
  compose pull --ignore-buildable

  # --wait blocks until every service passes its healthcheck, so a service
  # that can't start fails the deploy here instead of hiding behind "Done.".
  # --remove-orphans removes containers that belong to this project but not
  # to this run's -f list: after leaving the --4087 stack, tileservergl4087
  # would otherwise keep running, holding its memory and port 8083, with
  # nothing in the new stack using it.
  log "Starting the RBT stack and waiting for it to become healthy"
  if ! compose up -d --wait --wait-timeout 600 --remove-orphans; then
    compose ps || true
    die "The RBT stack did not start or become healthy within 10 minutes. See the service status above, then '$(compose_hint) logs <service>' for the one that is unhealthy or exited. 'port is already allocated' means another program (or an older deployment) holds one of the ports 8080-8083 -- see the \"Port Is Already Allocated\" section of docs/troubleshooting.md."
  fi

  log "Current service status"
  compose ps
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

load_env_file

RUN_INIT=0
RUN_DOWNLOAD=0
RUN_PERM=0
RUN_REFRESH=0
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
    --refresh)
      RUN_REFRESH=1
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

# No step flags given -- run the whole thing (--refresh is added below only if
# the download step fetches new data).
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
  NEED_SUDO=0
elif [[ $EUID -eq 0 ]]; then
  NEED_SUDO=0
else
  command -v sudo >/dev/null 2>&1 || die "This script needs root privileges for some steps. Install sudo or run as root."
  NEED_SUDO=1
fi

if is_wsl && [[ "$SCRIPT_DIR" == /mnt/* ]]; then
  warn "This copy of rbt-local is on a Windows drive ($SCRIPT_DIR). Bind mounts there are very slow, and the chown/chmod that --perm runs is silently ignored. Clone the repository into your Linux home directory instead (docs/install-windows.md, Option B)."
fi

if [[ "$OS_FAMILY" == "unknown" ]]; then
  warn "Could not identify this host as macOS, Ubuntu/Debian, or Fedora/RHEL. --init will stop with an error if it doesn't know how to install prerequisites here; --download, --perm, --refresh, and --deploy should still work as long as aws, docker (with the Compose plugin), and git are already installed."
fi

# The compose files (and tileserver services) this run's stack is made of, in
# merge order: docker-compose.yaml, then the docker-compose.4087.yaml overlay
# (--4087), then docker-compose.override.yaml (nginx, unless --no-nginx).
COMPOSE_FILE_NAMES=(docker-compose.yaml)
TILESERVER_SERVICES=(tileservergl)
if [[ "$USE_4087" -eq 1 ]]; then
  COMPOSE_FILE_NAMES+=(docker-compose.4087.yaml)
  TILESERVER_SERVICES+=(tileservergl4087)
fi
if [[ "$WITH_NGINX" -eq 1 ]]; then
  COMPOSE_FILE_NAMES+=(docker-compose.override.yaml)
fi
COMPOSE_FILES=()
for name in "${COMPOSE_FILE_NAMES[@]}"; do
  [[ -f "$SCRIPT_DIR/$name" ]] ||
    die "$name not found next to this script -- run it from inside the rbt-local repo checkout."
  COMPOSE_FILES+=(-f "$SCRIPT_DIR/$name")
done

describe_run
warn_if_compose_file_differs
warn_if_unselected_4087_running

if [[ "$RUN_INIT" -eq 1 ]]; then
  install_prereqs
fi
if [[ "$RUN_DOWNLOAD" -eq 1 ]]; then
  download_mbtiles
  if [[ "$DATA_UPDATED" -eq 1 ]]; then
    RUN_REFRESH=1
  fi
fi
if [[ "$RUN_PERM" -eq 1 ]]; then
  fix_permissions
fi
if [[ "$RUN_REFRESH" -eq 1 ]]; then
  refresh_stack
fi
if [[ "$RUN_DEPLOY" -eq 1 ]]; then
  deploy_stack
fi

log "Done."
if [[ "$RUN_DEPLOY" -eq 1 ]]; then
  compose_cmd="$(compose_hint)"
  echo "  Logs:     $compose_cmd logs -f"
  if [[ "$WITH_NGINX" -eq 1 ]]; then
    nginx_port="$(published_port nginx 8082 "${NGINX_PORT:-8082}")"
    echo "  Open:     http://localhost:$nginx_port/tileservergl/   (the six style previews)"
    echo "  Health:   curl -fsS http://localhost:$nginx_port/healthz"
    echo "  WMTS:     http://localhost:$nginx_port/mapproxy/wmts/1.0.0/WMTSCapabilities.xml"
    if [[ "$USE_4087" -eq 1 ]]; then
      echo "  Tiles (4087): curl -fsS http://localhost:$nginx_port/tileservergl4087/"
    fi
  else
    tileserver_port="$(published_port tileservergl 8080 "${TILESERVER_PORT:-8080}")"
    echo "  Open:     http://localhost:$tileserver_port/   (the six style previews)"
    echo "  MapProxy: curl -fsS http://localhost:$(published_port mapproxy 5000 "${MAPPROXY_PORT:-8081}")/wmts/1.0.0/WMTSCapabilities.xml"
    echo "  Tiles:    curl -fsS http://localhost:$tileserver_port/"
    if [[ "$USE_4087" -eq 1 ]]; then
      echo "  Tiles (4087): curl -fsS http://localhost:$(published_port tileservergl4087 8080 "${TILESERVER_4087_PORT:-8083}")/"
    fi
  fi
  echo "  Stop:     $compose_cmd down --remove-orphans"
  echo "  Next:     docs/verify.md has the checks that confirm the stack serves tiles"
fi
