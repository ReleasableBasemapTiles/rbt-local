# Verifying Your Installation

Run these checks from the machine running Docker -- Terminal on macOS/Linux, inside WSL2 on Windows Option B, or directly in PowerShell on native Windows Option A. Each command's expected result is listed underneath it. The `bash` examples below work as-is on macOS, Linux, and WSL2; on native Windows PowerShell, run the same `docker compose`/`curl.exe` commands (PowerShell 5.1 aliases bare `curl` to `Invoke-WebRequest`, which takes different flags, so use `curl.exe` explicitly there).

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

Expect: an XML document starting with `<Capabilities` that lists one layer per style and projection: `rbt_topo_3857`, `rbt_light_3857`, `rbt_brown_3857`, `rbt_gray_3857`, `rbt_dark_3857`, and `rbt_overlay_3857`, plus the matching `_3395` layers.

```bash
curl -sD - -o /dev/null "http://localhost:8082/mapproxy/wms?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1&LAYERS=rbt_topo_3857&STYLES=&SRS=EPSG:3857&BBOX=-20037508.34,-20037508.34,20037508.34,20037508.34&WIDTH=256&HEIGHT=256&FORMAT=image/png"
```

Expect: `HTTP/1.1 200 OK` with an `X-Cache-Status: MISS` header on this first request, since MapProxy has to fetch from TileserverGL and cache the result. Run the exact same command again -- the second response should show `X-Cache-Status: HIT`, confirming nginx served it from cache without asking MapProxy again. (Use `curl -sD -` rather than `curl -sI` here -- a HEAD request is a different request method and some WMS servers, MapProxy included, respond to it with an error rather than an actual capabilities-appropriate response.)

If you'd rather check by eye: open `http://localhost:8082/tileservergl/` in a browser to see the TileserverGL style previews. Direct (bypassing nginx entirely) access is also available on each service's own port:

- TileserverGL: `http://localhost:8080`
- MapProxy: `http://localhost:8081/wmts/1.0.0/WMTSCapabilities.xml`

## Next steps

- [Connecting GIS Clients to RBT](gis-clients.md)
- [Troubleshooting](troubleshooting.md), if any of the checks above didn't come back as expected

## Stopping and restarting

```bash
docker compose down --remove-orphans   # stop
docker compose up -d                   # start again
```
