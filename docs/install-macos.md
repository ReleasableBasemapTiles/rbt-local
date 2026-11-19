# Installing on macOS

The automated [`deploy.sh --init`](../deploy.sh) step (see the [Quickstart](../README.md#quickstart) in the main README) installs everything below for you via [Homebrew](https://brew.sh/). This page is the manual, step-by-step equivalent, and also covers Docker Desktop details that apply either way.

## Step 1: Install Homebrew, prerequisites, and Docker Desktop

Open **Terminal** and run:

```bash
# Install Homebrew (skip this if `brew --version` already works)
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install AWS CLI v2 and Git
brew install awscli git

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

**Give Docker Desktop enough memory.** Docker Desktop runs the containers in its own virtual machine, whose memory limit is separate from your Mac's (by default, a fraction of your RAM -- about half). This stack recommends 16GB, so on a 16GB Mac, open Docker Desktop's **Settings -> Resources -> Advanced**, raise the memory limit as far as you can spare, then choose **Apply & restart**. See [Docker Desktop Runs Out of Memory](troubleshooting.md#macos-docker-desktop-runs-out-of-memory) if containers are killed later.

## Step 3: Clone the repository

```bash
git clone https://github.com/ReleasableBasemapTiles/rbt-local.git
cd rbt-local
```

## Step 4: Download the map data and start RBT

Unlike Linux, there's no `chown`/`chmod` permissions step here -- Docker Desktop's VirtioFS file sharing maps your host user into the container regardless of macOS file permissions, and Docker creates any runtime directory that's missing (such as `mapproxy/data`) on first start. Download the map data first with the deploy script's download step. It needs only the AWS CLI from Step 1 -- the data comes from a public mirror, so there are no credentials to set up (see [Get the Map Data](../README.md#get-the-map-data) in the main README).

```bash
# Download the map data into tileserver/data/3857/ (add --4087 for the
# EPSG:4087 deployment), then start the RBT stack from the rbt-local directory.
# --wait makes it wait until every service passes its health check
# (TileserverGL can take a few minutes to open the map data), and fail if one
# doesn't.
./deploy.sh --download
docker compose up -d --wait

# Check logs
docker compose logs -f

# Stop the instance
docker compose down --remove-orphans
```

## A note on Apple Silicon vs. Intel

The `maptiler/tileserver-gl` and `nginx` images publish `linux/amd64` and `linux/arm64` builds, so Docker Desktop pulls the right one automatically on both Apple Silicon and Intel Macs, and it builds the MapProxy image from [`Dockerfile.mapproxy`](../Dockerfile.mapproxy) for your Mac's architecture -- no configuration needed.

## A note on the macOS Firewall

The first time you run `docker compose up -d`, macOS may prompt you to allow incoming network connections, because this stack's ports are published on `0.0.0.0` (every network interface) by default. Choose **Allow** if you want other devices on your network to reach RBT. If you only need RBT on this machine, copy `.env.example` to `.env` and set `BIND_ADDR=127.0.0.1` to avoid the prompt entirely.
