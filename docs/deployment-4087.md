# Advanced: The EPSG:4087 Dual-TileserverGL Deployment

The default stack ([docker-compose.yaml](../docker-compose.yaml)) runs one TileserverGL container serving EPSG:3857 (Web Mercator) MBTiles, and MapProxy reprojects from that single EPSG:3857 cache to build its EPSG:3395 and EPSG:4326 caches (see [Architecture](architecture.md)).

`docker-compose.4087.yaml` is an alternative deployment that adds a **second** TileserverGL container serving EPSG:4087 (World Equidistant Cylindrical) MBTiles, and repoints MapProxy's EPSG:4326 caches to reproject from that EPSG:4087 cache instead of the EPSG:3857 one. Everything else -- the EPSG:3857 and EPSG:3395 caches/layers, the client-facing layer list, nginx, ports -- stays the same.

## Why this improves EPSG:4326 output

EPSG:3857 (Web Mercator) is angularly distorted away from the equator, so reprojecting it to EPSG:4326 (a linear lat/lon grid) resamples nonlinearly -- the further from the equator, the more the pixels are stretched and resampled.

EPSG:4087 shares EPSG:4326's linear scaling: one degree of latitude or longitude always covers the same number of meters, everywhere on the globe. Its level-0 resolution (`40075016.685578488 m / 512 px = 78271.517 m/px`) is identical to the `geodetic` grid's level-0 resolution (`360deg / 1024 px = 0.703125 deg/px`, which is also `78271.517 m/px`) at every zoom level. Reprojecting EPSG:4087 to EPSG:4326 is therefore a pure unit conversion with no resampling distortion, unlike the EPSG:3857-to-EPSG:4326 hop the default stack uses.

## What's different

- A second TileserverGL container, `tileservergl4087`, mounts `tileserver/data/4087` at `/data` -- the existing `tileservergl` container mounts `tileserver/data/3857` the same way -- while both share the same `tileserver/fonts`, `tileserver/styles`, and `tileserver/config/config.json`. The EPSG:4087 MBTiles must keep the filenames `RBT.mbtiles` and `TERRAIN.mbtiles`, since both containers read the same `config.json`.
- MapProxy runs [mapproxy/config/mapproxy.4087.yaml](../mapproxy/config/mapproxy.4087.yaml) instead of `mapproxy.yaml`. It adds an `equidistant_4087` grid and six `rbt_*_4087_cache`/`rbt_*_4087_source` pairs sourced from `tileservergl4087`, and repoints each `rbt_*_4326_cache` at the matching `rbt_*_4087_cache` instead of `rbt_*_3857_cache`.
- The EPSG:4087 caches are internal only -- MapProxy still publishes the same 18 layers (six styles x EPSG:3857/3395/4326) as the default stack. No client-visible URL changes.
- The optional nginx service ([docker-compose.override.yaml](../docker-compose.override.yaml)) gains a `/tileservergl4087/` path for previewing the second container's styles directly, alongside the existing `/tileservergl/` and `/mapproxy/` paths.

## Deploying

**With the shortcut scripts** (recommended -- also downloads the EPSG:4087 MBTiles):

```bash
# macOS/Linux
./deploy.sh --4087

# Windows 11 (PowerShell)
.\deploy.ps1 -Use4087
```

Set `S3_BUCKET_RBT_4087` and `S3_BUCKET_TERRAIN_4087` (alongside the existing `S3_BUCKET_RBT`/`S3_BUCKET_TERRAIN`) in `.env` first -- see [.env.example](../.env.example). `--4087`/`-Use4087` combine freely with `--no-nginx`/`-NoNginx` and `--force`/`-Force`.

**With Docker Compose directly** (assuming the EPSG:3857 MBTiles are already in `tileserver/data/3857/` and the EPSG:4087 MBTiles are already in `tileserver/data/4087/`):

```bash
docker compose -f docker-compose.4087.yaml up -d                                  # with nginx
docker compose -f docker-compose.4087.yaml -f docker-compose.override.yaml up -d  # same, explicit
docker compose -f docker-compose.4087.yaml up -d --no-deps mapproxy tileservergl tileservergl4087  # without nginx
```

## Verifying it's working

```bash
docker compose -f docker-compose.4087.yaml [-f docker-compose.override.yaml] ps   # all services "running"/"healthy"
curl -fsS http://localhost:${TILESERVER_4087_PORT:-8083}/                        # tileservergl4087 preview UI
curl -fsS http://localhost:8082/tileservergl4087/                                # same, through nginx
```

## Ports

| Service | Env var | Default |
| --- | --- | --- |
| tileservergl4087 | `TILESERVER_4087_PORT` | `8083` |

All other ports (`NGINX_PORT`, `MAPPROXY_PORT`, `TILESERVER_PORT`) are unchanged from the default stack.

## Switching between stacks

`docker-compose.yaml` and `docker-compose.4087.yaml` are alternatives, not additions -- both declare a container named `mapproxy`, `tileservergl`, etc. Stop whichever stack is currently running before switching to the other:

```bash
docker compose down --remove-orphans                                              # if the default stack is running
docker compose -f docker-compose.4087.yaml [-f docker-compose.override.yaml] down --remove-orphans  # if the 4087 stack is running
```
