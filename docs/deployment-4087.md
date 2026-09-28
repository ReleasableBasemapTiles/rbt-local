# Advanced: The EPSG:4087 Dual-TileserverGL Deployment

The default stack ([docker-compose.yaml](../docker-compose.yaml)) runs one TileserverGL container serving EPSG:3857 (Web Mercator) MBTiles, and MapProxy builds its EPSG:3395 and EPSG:4326 layers by reprojecting those EPSG:3857 tiles (see [Architecture](architecture.md)).

[`docker-compose.4087.yaml`](../docker-compose.4087.yaml) is an overlay on `docker-compose.yaml` that adds a **second** TileserverGL container serving EPSG:4087 (World Equidistant Cylindrical) MBTiles, and repoints MapProxy's EPSG:4326 layers to reproject from those EPSG:4087 tiles instead of the EPSG:3857 ones. Everything else -- the EPSG:3857 and EPSG:3395 layers, the client-facing layer list, nginx, ports -- stays the same.

## Why this improves EPSG:4326 output

EPSG:3857 (Web Mercator) is angularly distorted away from the equator, so reprojecting it to EPSG:4326 (a linear lat/lon grid) resamples nonlinearly -- the further from the equator, the more the pixels are stretched and resampled.

EPSG:4087 shares EPSG:4326's linear scaling: one degree of latitude or longitude always covers the same number of meters, everywhere on the globe. Its level-0 resolution (`40075016.685578488 m / 512 px = 78271.517 m/px`) is identical to the `geodetic` grid's level-0 resolution (`360deg / 512 px = 0.703125 deg/px`, which is also `78271.517 m/px`), and both halve at every zoom level. Reprojecting EPSG:4087 to EPSG:4326 is therefore a pure unit conversion with no resampling distortion, unlike the EPSG:3857-to-EPSG:4326 hop the default stack uses.

## What's different

- A second TileserverGL container, `tileservergl4087`, mounts `tileserver/data/4087` at `/data` -- the existing `tileservergl` container mounts `tileserver/data/3857` the same way -- while both share the same `tileserver/fonts`, `tileserver/styles`, and `tileserver/config/config.json`. The EPSG:4087 MBTiles must keep the filenames `RBT.mbtiles` and `TERRAIN.mbtiles`, since both containers read the same `config.json`.
- MapProxy loads [mapproxy/config/mapproxy.4087.yaml](../mapproxy/config/mapproxy.4087.yaml) instead of `mapproxy.yaml`: the overlay sets the `mapproxy` service's `MAPPROXY_CONFIG` environment variable, which the image's WSGI entry point ([mapproxy/docker/app.py](../mapproxy/docker/app.py)) reads. `mapproxy.4087.yaml` starts with `base: mapproxy.yaml`, so MapProxy merges it over the regular config, and it only holds the differences: an `equidistant_4087` grid, six `rbt_*_4087_cache`/`rbt_*_4087_source` pairs sourced from `tileservergl4087`, and a new `sources` for each `rbt_*_4326_cache` (the matching `rbt_*_4087_cache` instead of `rbt_*_3857_cache`). A change to `mapproxy.yaml` applies to both stacks.
- The EPSG:4087 caches are internal only -- MapProxy still publishes the same 18 layers (six styles x EPSG:3857/3395/4326) as the default stack. No client-visible URL changes.
- The optional nginx service ([docker-compose.override.yaml](../docker-compose.override.yaml)) serves the second container's style previews at `/tileservergl4087/`, alongside the existing `/tileservergl/` and `/mapproxy/` paths. After replacing MBTiles or styles, `./deploy.sh --4087 --refresh` (or `.\deploy.ps1 -Use4087 -Refresh`) restarts both TileserverGL containers and empties nginx's cache.

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
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml -f docker-compose.override.yaml up -d  # with nginx
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml up -d                                  # without nginx
```

To make plain `docker compose ...` commands use the 4087 stack without the `-f` flags, set `COMPOSE_FILE` in `.env` -- see [.env.example](../.env.example). The deploy scripts always pass their own `-f` list, which takes precedence over it.

## Verifying it's working

```bash
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml [-f docker-compose.override.yaml] ps   # all services "running"/"healthy"
curl -fsS http://localhost:${TILESERVER_4087_PORT:-8083}/                                                # tileservergl4087 preview UI
curl -fsS http://localhost:8082/tileservergl4087/                                                        # same, through nginx
```

All of the above passing just means the containers are up -- it doesn't confirm MapProxy actually loaded `mapproxy.4087.yaml` rather than the default `mapproxy.yaml` (see [Troubleshooting](troubleshooting.md#the-4087-stack-is-up-but-epsg4326-tiles-look-unchanged)). MapProxy logs each config file it reads at startup:

```bash
docker logs mapproxy 2>&1 | grep -o 'reading: .*' | sort -u
# expect: reading: /mapproxy/config/mapproxy.4087.yaml
#         reading: /mapproxy/config/mapproxy.yaml       (the file it builds on)
```

And to confirm MapProxy is actually querying `tileservergl4087` for EPSG:4326 tiles:

```bash
curl -fsS "http://localhost:${MAPPROXY_PORT:-8081}/wmts/rbt_topo_4326/geodetic/2/1/1.png" -o /dev/null
docker logs --tail 20 tileservergl4087   # expect a /styles/RBT-TOPO/512/... request in the access log
```

## Ports

| Service | Env var | Default |
| --- | --- | --- |
| tileservergl4087 | `TILESERVER_4087_PORT` | `8083` |

All other ports (`NGINX_PORT`, `MAPPROXY_PORT`, `TILESERVER_PORT`) are unchanged from the default stack.

## Switching between stacks

Both stacks are the same Compose project, so switching to the 4087 stack just recreates `mapproxy` and adds `tileservergl4087`. Switching back leaves `tileservergl4087` running as an orphan (neither the plain `docker compose up` nor the deploy scripts remove it), so take the 4087 stack down first:

```bash
docker compose down --remove-orphans   # removes every container in the project, orphans included
./deploy.sh                            # or: docker compose up -d
```
