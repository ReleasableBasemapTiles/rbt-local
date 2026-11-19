# Verifying Your Installation

Run these checks from the machine running Docker -- Terminal on macOS/Linux, inside WSL2 on Windows Option B, or directly in PowerShell on native Windows Option A. Each command's expected result is listed underneath it. The `bash` examples below work as-is on macOS, Linux, and WSL2; on native Windows PowerShell, run the same `docker compose`/`curl.exe` commands (PowerShell 5.1 aliases bare `curl` to `Invoke-WebRequest`, which takes different flags, so use `curl.exe` explicitly there).

## The quick way: let the script check

The deploy script has a read-only step that runs most of the checks below for you, and prints one `PASS`, `WARN` or `FAIL` line for each. It changes nothing, so it is safe to run whenever you are unsure:

```bash
./deploy.sh --check
```

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Check
```

Add the flags you deployed with (`--4087` and/or `--no-nginx`; `-Use4087` and/or `-NoNginx` on Windows) so it checks the same deployment.

Expect, for a healthy stack: `PASS` for each service (`nginx`, `mapproxy`, `tileservergl`, plus `tileservergl4087` in the EPSG:4087 deployment) running and healthy, `PASS` for nginx's `/healthz` and for the WMTS capabilities document, and the line `Check finished: ... 0 failed` (exit status 0). A `WARN` is worth reading but doesn't fail the check: a map data file that the mirror has replaced with a newer one, say, or a service whose health check is still starting.

The check does not draw a tile, so it can't tell you the styles render, and it doesn't see what an nginx cache hit looks like. The commands below do, and are also what to run to see the real output behind a `FAIL`.

## The checks by hand

```bash
docker compose ps
```

Expect: all three services (`mapproxy`, `nginx`, `tileservergl`) `running`, moving to `healthy` once their healthchecks pass. TileserverGL can take a few minutes to report healthy while it opens the MBTiles files -- this is normal.

```bash
curl -fsS http://localhost:8082/healthz
```

Expect: `ok`

```bash
curl -fsS http://localhost:8082/tileservergl/styles.json
```

Expect: a JSON array listing `RBT-TOPO`, `RBT-LIGHT`, `RBT-BROWN`, `RBT-GRAY`, `RBT-DARK`, and `RBT-OVERLAY`.

```bash
curl -fsS "http://localhost:8082/mapproxy/wmts/1.0.0/WMTSCapabilities.xml" | head -20
```

On native Windows PowerShell, the equivalent is:

```powershell
(curl.exe -fsS "http://localhost:8082/mapproxy/wmts/1.0.0/WMTSCapabilities.xml") -split "`n" | Select-Object -First 20
```

Expect: an XML document starting with `<Capabilities` that lists one layer per style and projection: `rbt_topo_3857`, `rbt_light_3857`, `rbt_brown_3857`, `rbt_gray_3857`, `rbt_dark_3857`, and `rbt_overlay_3857`, plus the matching `_3395` and `_4326` layers.

```bash
curl -sD - -o /dev/null "http://localhost:8082/mapproxy/wms?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1&LAYERS=rbt_topo_3857&STYLES=&SRS=EPSG:3857&BBOX=-20037508.34,-20037508.34,20037508.34,20037508.34&WIDTH=256&HEIGHT=256&FORMAT=image/png"
```

Expect: `HTTP/1.1 200 OK` and `Content-Type: image/png`, with an `X-Cache-Status: MISS` header on this first request: nginx passed it to MapProxy, which had TileserverGL render the tile. Run the exact same command again -- the second response should show `X-Cache-Status: HIT`, confirming nginx served it from its cache without asking MapProxy again (see [Tile Caching](architecture.md#tile-caching)). (`curl -sD - -o /dev/null` prints the headers of an ordinary GET request; `curl -I` would send a HEAD request instead.)

If you'd rather check by eye: open `http://localhost:8082/tileservergl/` in a browser to see the TileserverGL style previews. Direct (bypassing nginx entirely) access is also available on each service's own port:

- TileserverGL: `http://localhost:8080`
- MapProxy: `http://localhost:8081/wmts/1.0.0/WMTSCapabilities.xml`

## Other deployments

The checks above are for the default deployment. For the others (see [Deployment Options](../README.md#deployment-options)):

- **Without nginx** (`--no-nginx`/`-NoNginx`): `docker compose -f docker-compose.yaml ps` lists only `mapproxy` and `tileservergl`. Nothing listens on port 8082, so skip `/healthz` and run the other checks against each service's own port, without the path prefix -- `http://localhost:8080/styles.json` and `http://localhost:8081/wmts/1.0.0/WMTSCapabilities.xml`, say. Responses have no `X-Cache-Status` header, since nothing is cached.
- **EPSG:4087** (`--4087`/`-Use4087`): run `docker compose ps` with the same `-f` flags you deployed with; it also lists `tileservergl4087`. Then check that MapProxy loaded `mapproxy.4087.yaml` -- see [Verifying it's working](deployment-4087.md#verifying-its-working) in the EPSG:4087 guide.

## Next steps

- [Connecting GIS Clients to RBT](gis-clients.md)
- [Troubleshooting](troubleshooting.md), if any of the checks above didn't come back as expected

## Stopping and restarting

```bash
docker compose down --remove-orphans   # stop
docker compose up -d                   # start again
```
