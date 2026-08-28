# Architecture

## What is RBT?

RBT (Releasable Basemap Tiles) is a web application that provides map tiles for military and coalition partners. Think of it like Google Maps, but designed for military use with maps that can be safely shared internationally.

### Why RBT is Better Than Older Map Systems

RBT uses **Vector Tiles** instead of the older **Raster Tiles** (like CADRG - Compressed ARC Digitized Raster Graphics) that the military has traditionally used. Here's why this matters:

**Think of it like this:**

- **Raster tiles (old way)** are like digital photographs of maps - they're made of pixels and have a fixed size and quality
- **Vector tiles (RBT's way)** are like digital drawings made of mathematical shapes and text that can be resized perfectly

**Key Advantages of Vector Tiles:**

🎯 **Better Quality at Any Zoom Level**

- Raster: Text becomes blurry when you zoom in (like enlarging a photo)
- Vector: Text and lines stay crisp at any zoom level

📦 **Smaller File Sizes**

- Raster: Large image files that take up lots of storage and bandwidth
- Vector: Compact mathematical descriptions that are 60-80% smaller

🌐 **Works Better Offline**

- Raster: Need to download many large image files for different zoom levels
- Vector: Download once, works smoothly at all zoom levels

⚡ **Faster Loading**

- Raster: Must load new images when zooming or panning
- Vector: Smooth transitions because data is already there

🎨 **Customizable Appearance**

- Raster: Fixed colors and styles (what you see is what you get)
- Vector: Can change colors, hide/show layers, adjust for day/night use

🔄 **Better for Coalition Sharing**

- Smaller files mean faster transfer over military networks
- Single vector dataset works for multiple use cases (instead of separate raster sets)
- Partners can customize the display for their specific needs

This makes RBT particularly valuable for military operations where bandwidth is limited, storage space is precious, and maps need to work reliably in various conditions.

## Why RBT Matters

The Releasable Basemap Tiles (RBT) is important because the capability can be easily shared with international coalition partners and doesn't need to go through the current approval process associated with traditional Limited Distribution (LIMDIS) data. The RBT is based on modern technology and provides access to like-in-kind Standard Map Products such as Topographic Map (TM), Joint Operations Graphic (JOG), and Tactical Pilotage Chart (TPC) in Vector Tiles format. This format enables rapid transfer across a network or accessed offline from a tile cache. By implementing simple changes in how modern maps are produced and accessed, international coalition partners will be able to track plans and activities using the same basemaps as U.S. services without delays associated with release of classified information.

## How It Works (Simple Version)

RBT uses several components working together:

- **TileserverGL**: Serves the map tiles (the actual map images)
- **MapProxy**: Helps convert between different map formats
- **Docker**: Packages everything together so it runs the same on any computer
- **Docker Compose**: The tool that manages and runs the application's containers together

## Technical Architecture

RBT is deployed as a containerized application using [TileserverGL](https://github.com/maptiler/tileserver-gl), which uses [MapLibre GL Native](https://maplibre.org/) for server-side rendering and serves vector and raster tiles in **EPSG:3857** (Web Mercator). Additionally, [MapProxy](https://mapproxy.org/) is deployed in front of TileserverGL to cache those raster tiles, exposing them through standard OGC WMS/WMTS endpoints in **EPSG:3857** and, reprojected from that same cache, **EPSG:3395** (World Mercator) and **EPSG:4326** (WGS 84 / geographic). Its WMS also reprojects on the fly to EPSG:4258, CRS:84, and EPSG:900913.

An alternative deployment ([docs/deployment-4087.md](deployment-4087.md)) adds a second TileserverGL container serving **EPSG:4087** (World Equidistant Cylindrical) MBTiles, and reprojects the EPSG:4326 cache from that EPSG:4087 cache instead of EPSG:3857 -- a pure unit-scale conversion rather than a resample away from EPSG:3857's angular distortion, so EPSG:4326 output is sharper away from the equator.

This guide documents a **Docker Compose** deployment suitable for a single host (a workstation, VM, or on-premises server) running macOS, Windows 11, or Linux. You will need S3 credentials from the RBT team to download the MBTiles data that TileserverGL serves.

![RBT_ARCHITECTURE](../images/rbt_architecture.png)

## Component Reference

- **[deploy.sh](../deploy.sh)** / **[deploy.ps1](../deploy.ps1)**: automate the manual setup steps in [Installing on macOS](install-macos.md), [Installing on Linux](install-linux.md), and [Installing on Windows 11](install-windows.md).
- **[docker-compose.yaml](../docker-compose.yaml)**: defines the `mapproxy` and `tileservergl` services.
- **[docker-compose.override.yaml](../docker-compose.override.yaml)**: adds the optional local `nginx` reverse-proxy/cache in front of them; Compose merges this in automatically unless you opt out (see [Advanced: Deploying Without nginx](advanced-deployment.md)).
- **[docker-compose.4087.yaml](../docker-compose.4087.yaml)**: alternative to `docker-compose.yaml` that adds a second TileserverGL container serving EPSG:4087 MBTiles (see [Advanced: The EPSG:4087 Dual-TileserverGL Deployment](deployment-4087.md)).
- **[mapproxy/config/](../mapproxy/config/)**, **[nginx/config/](../nginx/config/)**, **[tileserver/config/](../tileserver/config/)**: the runtime configuration each service reads. `mapproxy/config/mapproxy.4087.yaml` is the MapProxy config for the `docker-compose.4087.yaml` stack, a sibling of `mapproxy/config/mapproxy.yaml`.
