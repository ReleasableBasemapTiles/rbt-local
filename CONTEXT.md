# RBT Local Deployment

This context defines the language of rbt-local: how the Releasable Basemap Tiles map data becomes WMS/WMTS layers on a single Docker host, and why the stack is built the way it is. The working rules for changing it are in [CLAUDE.md](CLAUDE.md).

## Background

### Why RBT exists

Releasable Basemap Tiles (RBT) lets U.S. services and international coalition partners work from the same basemaps without the approval process that Limited Distribution (LIMDIS) data goes through. It provides like-in-kind versions of Standard Map Products -- Topographic Map (TM), Joint Operations Graphic (JOG), Tactical Pilotage Chart (TPC) -- as vector tiles instead of the raster CADRG the military has traditionally used. Vector tiles are smaller to move over constrained networks, stay sharp at every zoom, work offline from a tile cache, and can be restyled. The map data is derived from OpenStreetMap (ODbL); the hillshade comes from USGS SRTM elevation data. See [docs/architecture.md](docs/architecture.md) and [LICENSE.md](LICENSE.md).

### Who this repo serves

- **Operators** standing RBT up on one workstation, VM or on-premises server running macOS, Windows 11 or Linux, who are often not Docker specialists. Hence deploy scripts that install everything, and guides written to be pasted one command at a time.
- **GIS users** of QGIS, ArcGIS Pro and similar tools, who consume the WMS/WMTS layers, and web clients that use TileserverGL's styles and tiles directly.

### Where it sits

- **ReleasableBasemapTiles/styles** (private) is the source of the six styles. A weekly workflow opens a pull request that syncs `tileserver/styles/` from it.
- **ReleasableBasemapTiles/charts** holds the Helm charts for Kubernetes/OpenShift. They deploy the MapProxy image this repo publishes; this repo covers Docker only.
- **The MapProxy image** is built from `Dockerfile.mapproxy` and published as `ghcr.io/releasablebasemaptiles/rbt-local/mapproxy` (`7.0.0` and `latest` from `main`).
- **The public mirror** is a read-only, S3-compatible (RustFS) endpoint that the deploy scripts download the MBTiles from, anonymously.
- **The docs site**, https://releasablebasemaptiles.github.io/rbt-local/, is built from README, `docs/` and `CHANGELOG.md`.

### Design decisions

- **nginx is the only tile cache.** MapProxy runs every cache with storage disabled and asks TileserverGL for each tile; nginx keeps the rendered images for 30 days, up to 10 GB. Nothing can tell when the data or styles behind a cached image change, so new data needs a Refresh.
- **A custom MapProxy image.** The official image's Debian PROJ 9.1.1 treats EPSG:4087 as spherical; conda-forge's PROJ 9.8 and later is ellipsoidal. MapProxy is pip-installed with `--no-deps` so a PyPI `pyproj` wheel, which bundles its own PROJ, can't undo that, and the build asserts the PROJ version and a known EPSG:4087 coordinate. uWSGI serves HTTP itself (`http-socket`), so nginx or a load balancer can talk to it directly.
- **Reproject instead of re-rendering.** TileserverGL renders each style only in a native projection: EPSG:3857, plus EPSG:4087 in that deployment. MapProxy derives EPSG:3395 and EPSG:4326 by reprojection, each one hop away.
- **The EPSG:4087 deployment.** Reprojecting Web Mercator to EPSG:4326 resamples nonlinearly away from the equator. EPSG:4087 shares EPSG:4326's linear scaling, and their level-0 resolutions match, so 4087 to 4326 is a pure unit conversion and the EPSG:4326 layers come out sharper. The cost is a second TileserverGL and a second pair of MBTiles.
- **nginx is optional.** MapProxy and TileserverGL always publish their own ports, on their native paths. Without nginx those ports are the only way in, ready to sit behind an AWS ALB or CloudFront, which then takes over caching.
- **The deploy scripts do the whole job.** They install the prerequisites for each OS, download the data, and start the stack. Every step is safe to re-run, and each has a manual equivalent in the install guides.
- **LF line endings are enforced.** A `uwsgi.ini` with Windows (CRLF) line endings stops uWSGI, so `.gitattributes` pins LF and `deploy.ps1` repairs clones made before that.

## Language

**Releasable Basemap Tiles (RBT)**:
The program and its map products: vector basemaps that can be released to coalition partners.
_Avoid_: "RBT" for this repository, or for `RBT.mbtiles`

**rbt-local**:
This repository: the single-host Docker Compose deployment of RBT.
_Avoid_: "the chart" (that's ReleasableBasemapTiles/charts)

**MBTiles**:
A single SQLite file that holds a whole tile set. The stack reads exactly two per projection, with fixed names, from `tileserver/data/<epsg>/`.

**Vector Map**:
`RBT.mbtiles`: the OpenStreetMap-derived vector tiles every style draws. It's updated periodically, and the deploy scripts download it again whenever the mirror's copy is newer.
_Avoid_: "the RBT data", "the basemap file"

**Terrain**:
`TERRAIN.mbtiles`: Mapbox-encoded raster-DEM tiles (256px), made from USGS SRTM data, that the styles use for hillshading. Downloaded once; it doesn't change.
_Avoid_: hillshade tiles, DEM file

**Public Mirror**:
The read-only, S3-compatible (RustFS) endpoint that serves the MBTiles anonymously under `s3://mbtiles/3857/` and `s3://mbtiles/4087/`. Setting an `S3_BUCKET_*` variable swaps in the operator's own bucket for one file.
_Avoid_: "the S3 bucket", "AWS" (no AWS account or credentials are involved)

**Style**:
A MapLibre `style.json`, with its sprites, under `tileserver/styles/<NAME>/`, that turns the Vector Map and Terrain into a map. There are six: RBT-TOPO, RBT-LIGHT, RBT-BROWN, RBT-GRAY, RBT-DARK and RBT-OVERLAY. The directory name is also the style's `config.json` key and the name in every URL.
_Avoid_: theme; the `id` inside `style.json` (RBT-CANVAS-LIGHT, RBT-TOPO-3395, ...), which nothing here uses

**Canvas Style**:
RBT-LIGHT, RBT-BROWN or RBT-GRAY: a muted, opaque basemap. Their `style.json` ids say CANVAS.

**Overlay Style**:
RBT-OVERLAY: the only transparent style, drawn on top of imagery.
_Avoid_: "overlay" on its own (see Compose Overlay and MapProxy Overlay)

**TileserverGL**:
The renderer (`maptiler/tileserver-gl`). It serves the styles, fonts, vector tiles and rendered PNG tiles from the MBTiles mounted at `/data`, and reads the MBTiles and styles only at startup. It runs as the `tileservergl` service (EPSG:3857 data) and, in the EPSG:4087 deployments, also as `tileservergl4087` (EPSG:4087 data); the two share one config, style set and font set.
_Avoid_: "tileserver" for the software (that's the directory)

**MapProxy**:
The OGC front end: it republishes TileserverGL's rendered tiles as WMS and WMTS Layers, reprojecting where needed. It runs under uWSGI in the MapProxy Image.

**Source**:
A MapProxy `sources:` entry: the TileserverGL tile URL for one Style in one Native Projection (`rbt_topo_source`, `rbt_topo_4087_source`, ...).
_Avoid_: confusing it with a `style.json` source (`mbtiles://{RBT}`), which is a different thing

**Pass-through Cache**:
A MapProxy `caches:` entry. Every one sets `disable_storage: true`: it ties a Source, or another cache, to a Grid, and other caches can use it as their source, which is how reprojection is chained. It stores nothing.
_Avoid_: "the MapProxy cache" to mean stored tiles; there are none

**Grid**:
A MapProxy tile grid. The published ones are the WMTS TileMatrixSets `webmercator` (EPSG:3857), `world_mercator` (EPSG:3395) and `geodetic` (EPSG:4326); `equidistant_4087` (EPSG:4087) is internal. All use 512px tiles and a north-west origin.

**Layer**:
A published MapProxy WMS/WMTS layer, named `rbt_<style>_<epsg>`: six Styles x EPSG:3857, 3395 and 4326 = 18, the same in every Deployment.
_Avoid_: style layer (an entry in a `style.json`'s `layers` array)

**Native Projection**:
A projection TileserverGL renders directly: always EPSG:3857, and also EPSG:4087 in the EPSG:4087 deployments, where it's internal only (no Layer publishes it).

**Reprojected Projection**:
EPSG:3395 or EPSG:4326, whose Layers MapProxy derives from a Native Projection's cache. The WMS also reprojects on request to EPSG:4258, CRS:84 and EPSG:900913.

**Tile Cache**:
nginx's on-disk cache in `nginx/cache/tile_cache/`: map images only, kept 30 days, up to 10 GB, least recently used evicted first. Each response's `X-Cache-Status` header says how it was served (HIT, MISS, BYPASS, ...). It's the only place tiles are stored.
_Avoid_: "the cache" without saying which

**Refresh**:
Recreating the running TileserverGL containers and emptying the Tile Cache (`./deploy.sh --refresh`, `.\deploy.ps1 -Refresh`, plus the stack's own flags such as `--4087`), so the stack serves the current MBTiles and styles. It runs automatically after a download that fetched something.
_Avoid_: restart (a restart alone leaves stale images in the Tile Cache)

**Deployment**:
One of the four supported Compose file combinations: (1) Default, (2) Without nginx, (3) EPSG:4087, (4) EPSG:4087 without nginx. Chosen with the deploy scripts' flags, with `-f` lists, or with `COMPOSE_FILE` in `.env`. All four publish the same Layers.
_Avoid_: mode, variant, profile (Compose profiles aren't used)

**Default Deployment**:
`docker-compose.yaml` plus `docker-compose.override.yaml`: what `./deploy.sh` with no stack flags deploys, and what a bare `docker compose up -d` starts unless `.env` sets `COMPOSE_FILE`.

**Compose Override**:
`docker-compose.override.yaml`, which adds nginx. Compose merges it in automatically unless `-f` flags or `COMPOSE_FILE` name the files.

**Compose Overlay**:
`docker-compose.4087.yaml`, layered on `docker-compose.yaml`: it adds `tileservergl4087` and points MapProxy at the MapProxy Overlay.

**MapProxy Overlay**:
`mapproxy/config/mapproxy.4087.yaml`: `base: mapproxy.yaml` plus only the EPSG:4087 grid, Sources and caches, and new sources for the EPSG:4326 caches.

**Deploy Step**:
One stage of the deploy scripts, always run in this order: Init, Download, Perm (`deploy.sh`) or Prep (`deploy.ps1`), Refresh, Deploy. With no step flags, all of them run, and Refresh runs only when Download fetched new data.

**Prefix**:
The path nginx routes on and strips (`/mapproxy`, `/tileservergl`, `/tileservergl4087`), then passes back to the backend so the URLs it generates keep it. A request to a service's own port uses its native, unprefixed paths.

**MapProxy Image**:
The custom image built from `Dockerfile.mapproxy`: `rbt-mapproxy:7.0.0` locally, `ghcr.io/releasablebasemaptiles/rbt-local/mapproxy` when published. `7.0.0` is MapProxy's version.

**Release**:
A `v*` tag of this repository (Semantic Versioning), recorded in `CHANGELOG.md` and versioned independently of the MapProxy Image.

## Relationships

- Each **Style** is rendered by **TileserverGL** into one **Source** per **Native Projection**.
- Each **Source** feeds one **Pass-through Cache** on its **Grid**. Each **Reprojected Projection** cache takes a native cache as its source, one hop away.
- Each published cache backs exactly one **Layer**: 6 Styles x 3 projections = 18 Layers in every **Deployment**. The EPSG:4087 caches back no Layer.
- In the EPSG:4087 Deployments only the EPSG:4326 caches change: they reproject from the EPSG:4087 cache instead of the EPSG:3857 one.
- A **Deployment** is `docker-compose.yaml`, plus the **Compose Overlay** for EPSG:4087, plus the **Compose Override** for nginx.
- The **Tile Cache** exists only in the Deployments with nginx. New MBTiles or a changed Style need a **Refresh** either way, because TileserverGL reads them only at startup.
- Each **Native Projection** has its own **Vector Map** and **Terrain** pair, on the **Public Mirror** and in `tileserver/data/<epsg>/`.

## Example dialogue

> **Dev:** "The EPSG:4326 layers look soft near the poles. Should we turn on storage in the MapProxy cache so they render once, at higher quality?"
> **Maintainer:** "Storage wouldn't change the pixels: those are **Pass-through Caches** by design, and nginx's **Tile Cache** already keeps what's rendered. The softness comes from resampling Web Mercator. Use the **EPSG:4087 Deployment** -- its EPSG:4326 **Layers** reproject from EPSG:4087 tiles instead, which is a straight unit conversion."

## Flagged ambiguities

- "overlay" was used for three things: the **Overlay Style** (RBT-OVERLAY), the **Compose Overlay** (`docker-compose.4087.yaml`) and the **MapProxy Overlay** (`mapproxy.4087.yaml`). Always say which.
- "cache" was used for both the **Tile Cache** (nginx; stores images) and a **Pass-through Cache** (MapProxy; stores nothing).
- "4087" was used for the projection EPSG:4087, the EPSG:4087 **Deployment**, the `tileservergl4087` service and `tileserver/data/4087/`.
- "tileserver" was used for the `tileserver/` directory, the `tileservergl` service and TileserverGL itself.
- "source" was used for a MapProxy **Source** and for a `style.json` source; "layer" for a MapProxy **Layer** and for a style layer.
- "default" was used for the **Default Deployment** and for the default values in `.env.example`.
- "RBT" was used for the program, for `RBT.mbtiles` (the **Vector Map**), and for the `RBT` data key in `config.json`.
- A Style's name (RBT-LIGHT: its directory, `config.json` key and URLs) differs from its `style.json` id (RBT-CANVAS-LIGHT). Only the name is used.
- "7.0.0" is MapProxy's version and the MapProxy Image's tag, never a **Release** of this repository.
- `--perm` (`deploy.sh`) and `-Prep` (`deploy.ps1`) sit in the same slot but do different things. Perm creates the runtime directories and, on Linux, hands MapProxy's to uid 1000, the user its container runs as. Prep creates them and converts the config files to LF line endings.
