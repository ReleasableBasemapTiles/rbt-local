# Releasable Basemap Tiles (RBT)

RBT (Releasable Basemap Tiles) is a web application that provides map tiles for military and coalition partners. Think of it like Google Maps, but designed for military use with maps that can be safely shared internationally -- vector tiles instead of the older raster formats (like CADRG), for smaller files, sharper rendering at any zoom, and easier coalition sharing. See [Architecture](docs/architecture.md) for the full explanation, the technical design, and a diagram.

This guide walks through deploying RBT with **Docker Compose** on a single host (a workstation, VM, or on-premises server) running **macOS**, **Windows 11**, or **Linux**. Don't worry if you're new to any of these tools -- each command below is meant to be copied and pasted, one at a time.

## Requirements

- macOS, Windows 11 (natively, or via WSL2), or Linux
- Both container images this stack uses (`maptiler/tileserver-gl` and `ghcr.io/mapproxy/mapproxy/mapproxy`) publish `linux/amd64` and `linux/arm64` builds, so this runs on Intel/AMD and Arm64 hosts alike (including Apple Silicon)
- Internet connection, for downloading components and the MBTiles data
- Minimum 16GB of RAM and 8 cores CPU recommended
- Disk space: enough for the two MBTiles files described below, **plus** headroom for the MapProxy tile cache it builds over time. Ask the RBT team for current file sizes when you receive your S3 credentials -- the datasets are updated periodically, so we don't pin numbers here that would go stale

## Get S3 Credentials

Before starting, you need special access to download the map data:

1. Email [Tom Boggess](mailto:Thomas.J.Boggess@usace.army.mil) to request S3 credentials
2. Wait for approval and credentials (this may take a few days -- a good first step while you read the rest of this guide)
3. Once you receive credentials, configure AWS CLI by running:
   ```bash
   aws configure --profile rbt
   ```
   Enter the provided Access Key ID, Secret Access Key, and set the region to `us-east-1`

You'll use these credentials to download two files -- `RBT.mbtiles` and `TERRAIN.mbtiles` -- which `tileserver/config/config.json` references by these exact names. The Quickstart below downloads both automatically once your credentials and bucket paths are in place.

## Quickstart

1. **Install Git** if you don't already have it (most Macs and Linux systems do; on Windows 11 try `winget install Git.Git`, or see the per-OS guide below), then clone this repository and open a terminal inside it:

   ```bash
   git clone https://github.com/ReleaseableBasemapTiles/rbt-local.git
   cd rbt-local
   ```

2. **Copy `.env.example` to `.env`**, and fill in `S3_BUCKET_RBT` and `S3_BUCKET_TERRAIN` with the bucket paths the RBT team gave you alongside your credentials.

3. **Run the deploy script for your computer.** Each one installs every remaining prerequisite, downloads the map data, and starts RBT -- no other manual steps required.

   **macOS or Linux:**

   ```bash
   ./deploy.sh
   ```

   **Windows 11**, in PowerShell opened as Administrator:

   ```powershell
   .\deploy.ps1
   ```

Both scripts are safe to re-run: package installs are skipped when already present, `TERRAIN.mbtiles` only downloads once, and `RBT.mbtiles` re-downloads automatically whenever the S3 object is newer than your local copy. Run either with `--help` / `-Help` to see every available flag -- for example `--init`/`-Init` to just install prerequisites, `--no-nginx`/`-NoNginx` to skip the local reverse proxy (see [Advanced: Deploying Without nginx](docs/advanced-deployment.md)), or `--4087`/`-Use4087` to deploy a second TileserverGL container serving EPSG:4087 MBTiles for sharper EPSG:4326 output (see [Advanced: The EPSG:4087 Dual-TileserverGL Deployment](docs/deployment-4087.md)).

Prefer to see, or run, each step by hand instead of via the script? See [Installing on macOS](docs/install-macos.md), [Installing on Linux](docs/install-linux.md), or [Installing on Windows 11](docs/install-windows.md).

## Verifying It's Working

See [Verifying Your Installation](docs/verify.md) for a full checklist. The short version:

```bash
docker compose ps               # all three services should be "running"/"healthy"
curl -fsS http://localhost:8082/healthz   # expect: ok
```

Open `http://localhost:8082/tileservergl/` in a browser to see the TileserverGL style previews.

## Stopping and Restarting

```bash
docker compose down --remove-orphans   # stop
docker compose up -d                   # start again
```

## Connecting GIS Clients

RBT works with QGIS, ArcGIS Pro, and other WMS/WMTS-capable GIS software. See [Connecting GIS Clients to RBT](docs/gis-clients.md) for connection URLs and step-by-step walkthroughs with screenshots.

## Troubleshooting

Something not working? See [Troubleshooting](docs/troubleshooting.md) for common issues and their solutions, or contact the RBT program manager for support.

## Further Reading

- [Architecture](docs/architecture.md) -- what RBT is, why it uses vector tiles, and the technical design
- [Installing on macOS](docs/install-macos.md), [Installing on Linux](docs/install-linux.md), [Installing on Windows 11](docs/install-windows.md) -- manual, step-by-step setup per OS
- [Verifying Your Installation](docs/verify.md)
- [Connecting GIS Clients to RBT](docs/gis-clients.md)
- [Advanced: Deploying Without nginx](docs/advanced-deployment.md) -- for AWS ALB/CloudFront deployments
- [Advanced: The EPSG:4087 Dual-TileserverGL Deployment](docs/deployment-4087.md) -- a second TileserverGL container serving EPSG:4087 MBTiles for sharper EPSG:4326 output
- [Troubleshooting](docs/troubleshooting.md)

## Glossary of Terms

- **CLI**: Command Line Interface - typing commands instead of clicking buttons
- **Docker**: Software that packages applications in containers
- **Container**: A packaged application with all its dependencies
- **Repository/Repo**: A project's code and files stored online
- **Terminal**: The application where you type commands
