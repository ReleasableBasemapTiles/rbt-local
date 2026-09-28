# Advanced: Deploying Without nginx (AWS ALB / CloudFront)

Everything in the main [Quickstart](../README.md#quickstart) assumes the local nginx service is fronting MapProxy and TileserverGL. If you're deploying to AWS and would rather let an Application Load Balancer and/or CloudFront handle TLS termination, routing, and caching, you can skip nginx entirely -- MapProxy speaks plain HTTP (uWSGI's `http-socket`) exactly like TileserverGL already does, so both are directly reachable by an ALB target group or CloudFront origin.

## To deploy without nginx

```bash
docker compose -f docker-compose.yaml up -d
# or, using deploy.sh:
./deploy.sh --no-nginx
# or, on native Windows, using deploy.ps1:
.\deploy.ps1 -NoNginx
```

nginx normally comes from `docker-compose.override.yaml`, which Docker Compose merges in automatically whenever you run `docker compose ...` with no explicit `-f` flags -- that's why the plain `docker compose up -d` used everywhere else in this guide still includes it. Naming `-f docker-compose.yaml` explicitly (as above) opts out of that auto-merge.

## What changes

- MapProxy and TileserverGL each publish their own port directly (`MAPPROXY_PORT`, default `8081`; `TILESERVER_PORT`, default `8080` -- see [`.env.example`](../.env.example)), reached at their native paths with no `/mapproxy` or `/tileservergl` prefix (the same paths documented under [Direct Access](gis-clients.md#3-direct-access-optional) in the GIS clients guide).
- Neither ALB nor CloudFront rewrite request paths by default, so route by each backend's own path patterns instead of trying to recreate nginx's prefix scheme:
  - MapProxy target/origin: `/wms*`, `/wmts/*`, `/service*`
  - TileserverGL target/origin: everything else, as the default rule -- `/styles/*`, `/data/*`, `/fonts/*`, `/fonts.json`, `/styles.json`, and its web UI at `/`
- You lose nginx's tile cache and gzip compression -- CloudFront's edge caching and compression are the intended replacement. MapProxy stores no tiles itself, so with nothing caching in front of it, TileserverGL renders every request. [Tile Caching](architecture.md#tile-caching) describes the policy nginx applies, which a CloudFront cache behavior can copy.
- If a client needs the exact `example.org/mapproxy/...` / `example.org/tileservergl/...` URLs nginx currently produces, that rewrite has to happen at the ALB/CloudFront layer (e.g. a CloudFront Function) -- it isn't something this repo can do once nginx is out of the path.

## Combining with the EPSG:4087 deployment

`--no-nginx`/`-NoNginx` combines freely with `--4087`/`-Use4087` (see [Advanced: The EPSG:4087 Dual-TileserverGL Deployment](deployment-4087.md)): `./deploy.sh --4087 --no-nginx` deploys `docker-compose.yaml` and the `docker-compose.4087.yaml` overlay without `docker-compose.override.yaml`, publishing `tileservergl4087`'s port (`TILESERVER_4087_PORT`, default `8083`) directly alongside `mapproxy` and `tileservergl`, with no nginx in front of any of them.

This is deployment 4 of the four Compose deployments -- see [Deployment Variants](architecture.md#deployment-variants) for a diagram of each.
