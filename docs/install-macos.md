# Installing on macOS

The automated [`deploy.sh --init`](../deploy.sh) step (see the [Quickstart](../README.md#quickstart) in the main README) installs everything below for you via [Homebrew](https://brew.sh/). This page is the manual, step-by-step equivalent, and also covers Docker Desktop details that apply either way.

## Step 1: Install Homebrew, prerequisites, and Docker Desktop

Open **Terminal** and run:

```bash
# Install Homebrew (skip this if `brew --version` already works)
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install AWS CLI v2, Git, and Git LFS
brew install awscli git git-lfs
git lfs install --global

# Install Docker Desktop
brew install --cask docker-desktop
```

## Step 2: Start Docker Desktop and confirm it's running

Launch **Docker Desktop** from Launchpad (or run `open -a Docker`), and wait for its menu-bar icon to report the engine is running. The very first launch may prompt you to accept a license and grant the app privileged-helper access -- this one-time step needs a GUI and can't be scripted, so finish it before continuing (`deploy.sh --init` will wait up to 3 minutes for the engine to come up, then tell you to do this and re-run).

Confirm from Terminal:

```bash
docker --version
docker compose version
```

## Step 3: Clone the repository

```bash
git lfs install
git clone https://github.com/ReleaseableBasemapTiles/rbt-local.git
cd rbt-local
```

## Step 4: Download the map data and start RBT

Unlike Linux, there's no `chown`/`chmod` permissions step here -- Docker Desktop's VirtioFS file sharing maps your host user into the container regardless of macOS file permissions, so the runtime directories (`mapproxy/data`, `nginx/cache`, etc.) just need to exist.

```bash
# Download the map data (see "Get S3 Credentials" in the main README) before
# continuing, then start the RBT stack from the rbt-local directory
docker compose up -d

# Check logs
docker compose logs -f

# Stop the instance
docker compose down --remove-orphans
```

## A note on Apple Silicon vs. Intel

Both container images this stack uses (`maptiler/tileserver-gl` and `ghcr.io/mapproxy/mapproxy/mapproxy`) publish `linux/amd64` and `linux/arm64` builds, so Docker Desktop pulls the right one automatically on both Apple Silicon and Intel Macs -- no configuration needed.

## A note on the macOS Firewall

The first time you run `docker compose up -d`, macOS may prompt you to allow incoming network connections, because this stack's ports are published on `0.0.0.0` (every network interface) by default. Choose **Allow** if you want other devices on your network to reach RBT. If you only need RBT on this machine, copy `.env.example` to `.env` and set `BIND_ADDR=127.0.0.1` to avoid the prompt entirely.
