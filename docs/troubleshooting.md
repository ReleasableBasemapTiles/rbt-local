# Troubleshooting

## "Command not found" Error

This usually means the software isn't installed or isn't in your system's PATH.

- **Solution**: Try reinstalling the software or restart your terminal

## "Permission denied" Error

This means you need administrator privileges.

- **Solution**: Add `sudo` before the command (on Linux, or inside WSL2 on Windows), or on native Windows re-open PowerShell as Administrator (right-click Start menu -> "Terminal (Admin)"). Not needed on macOS -- `deploy.sh` never uses `sudo` there.

## Docker Won't Start

- **macOS**: Make sure Docker Desktop is running (check the menu bar) and has finished starting -- it can take a minute after launch. If this is the first launch since installing, finish any one-time license/privileged-helper prompts in the Docker Desktop window.
- **Windows (native or WSL2)**: Make sure Docker Desktop is running (check the system tray) and has finished starting -- it can take a minute after launch. If you're using Docker Engine directly inside WSL2 instead of Docker Desktop, run `sudo service docker start`.
- **Linux**: Try `sudo systemctl start docker`

## "Port Is Already Allocated" or "Address Already in Use"

`docker compose up` stops with `Bind for 0.0.0.0:8080 failed: port is already allocated` (or similar for 8081, 8082 or 8083) because something else on this machine already listens on that port.

- **Find what is using it**:
  - macOS/Linux: `lsof -nP -iTCP:8080 -sTCP:LISTEN`
  - Windows (PowerShell): `Get-NetTCPConnection -LocalPort 8080 -State Listen | ForEach-Object { Get-Process -Id $_.OwningProcess }`
- **If it is an earlier RBT run**: `docker ps` lists containers named `nginx`, `mapproxy` and `tileservergl` (their names are fixed, so two copies of this repository can't run at once). Run `docker compose down --remove-orphans` in the copy that started them, then deploy again.
- **If it is another program**: give RBT a different port instead. Copy `.env.example` to `.env` and set `TILESERVER_PORT`, `MAPPROXY_PORT`, `NGINX_PORT` or `TILESERVER_4087_PORT` (see [.env.example](../.env.example)), then run the deploy again. On Linux, put the setting in `.env` rather than exporting it, because the deploy script runs Compose through `sudo`, which drops your shell's variables.

## `brew` Not Recognized, Right After `deploy.sh --init` (macOS)

- **Solution**: Open a new Terminal window/tab so it picks up the `PATH` change Homebrew's installer made, or run `eval "$(/opt/homebrew/bin/brew shellenv)"` (Apple Silicon) / `eval "$(/usr/local/bin/brew shellenv)"` (Intel) in the current one.

## `choco` Not Recognized, or the Script Is Blocked by Execution Policy (Native Windows)

- **`choco` / `aws` / `docker` not recognized right after installing them**: Open a new PowerShell window so it picks up the updated `PATH`, or run `refreshenv` in the current one.
- **"running scripts is disabled on this system"**: PowerShell's default execution policy blocks unsigned local scripts. Either run `powershell -ExecutionPolicy Bypass -File .\deploy.ps1`, or run `Set-ExecutionPolicy -Scope Process Bypass` once in that PowerShell session before calling `.\deploy.ps1` directly.
- **`choco install ...` itself fails with an access-denied error**: Confirm you opened PowerShell as Administrator -- installing packages system-wide requires it.

## "Cannot connect to AWS" Error

- **Downloading from the public mirror (the default)**: No credentials are involved, so this is a network problem. Check that this host can reach the mirror -- the `aws s3 ls ... --no-sign-request ...` command under the main README's [Get the Map Data](../README.md#get-the-map-data) tests it directly. If it fails with an SSL certificate error, your network re-signs HTTPS traffic with its own certificate authority: point `AWS_CA_BUNDLE` at that CA's PEM file (in `.env`, or exported) and re-run.
- **Downloading from your own bucket (`S3_BUCKET_*` set)**: Make sure you've configured AWS CLI with `aws configure --profile rbt`, and that the download uses that profile: set `AWS_PROFILE=rbt` in `.env` for the deploy scripts (see [.env.example](../.env.example)), or add `--profile rbt` to `aws s3` commands you run yourself. `aws s3 ls s3://<bucket-path>/ --profile rbt` checks the credentials and the bucket path together.

## Every `/mapproxy/*` Request Returns a 502 Bad Gateway

This means nginx can't reach MapProxy at `mapproxy:5000`: the container is stopped, restarting, or still starting.

- **Solution**: Run `docker compose ps mapproxy` and `docker compose logs mapproxy`. uWSGI exits when MapProxy can't load its configuration, and the log names the file and the error -- fix it, then run `docker compose up -d`. If you've modified `mapproxy/config/uwsgi.ini` (its `http-socket` must stay on port 5000) or the `mapproxy` service in `docker-compose.yaml`, compare against this repository's defaults.

## TileserverGL Shows No Styles, or Styles Render Blank

- **Solution**: Confirm `tileserver/data/3857/TERRAIN.mbtiles` and `tileserver/data/3857/RBT.mbtiles` exist and are fully downloaded (`ls -lh tileserver/data/3857/`). A partial download loads without error but renders blank or incomplete tiles. (With `--4087`/`-Use4087`, also check `tileserver/data/4087/`.) After replacing a file, run `./deploy.sh --refresh` (or `.\deploy.ps1 -Refresh`) so TileserverGL reopens it and nginx drops the blank tiles it cached -- see the next section.

## Maps Still Show Old Data or an Old Style

nginx keeps each map image it serves for 30 days (see [Tile Caching](architecture.md#tile-caching)), and TileserverGL reads MBTiles and styles only at startup, so neither notices when you replace them.

- **Solution**: Run `./deploy.sh --refresh` (or `.\deploy.ps1 -Refresh`), adding `--4087`/`-Use4087` for the EPSG:4087 deployment: it restarts TileserverGL and empties nginx's cache. Browsers and GIS clients keep their own tile caches too -- reload without them (Ctrl+Shift+R in a browser, or clear QGIS's network cache under **Settings -> Options -> Network**).

## The Disk Fills Up, or a Download Was Interrupted

- **The deploy scripts check first**: before each download they compare the file's size on the mirror with the free space on the drive and stop with "Not enough free disk space" instead of filling the disk. They also delete leftover partial files from an interrupted run, and after the download they stop if the file isn't the size the mirror reported (the bad file is removed, so the next run fetches it again). If the mirror's size can't be read, they say so and skip those checks.
- **Check the free space**: `df -h .` on macOS/Linux, or `Get-PSDrive C` in PowerShell. The map data is hundreds of GB, and nginx's tile cache adds up to 10 GB. Inside WSL2, the whole distribution lives in one virtual disk that doesn't shrink on its own -- see [A note on disk space](install-windows.md#a-note-on-disk-space).
- **Replacing a big file needs room for two copies.** The AWS CLI downloads into a temporary file next to the destination and renames it when the transfer finishes, so a re-download of `RBT.mbtiles` briefly needs space for the old and the new copy together. If there isn't enough, stop the stack (`docker compose down --remove-orphans`), delete the old file from `tileserver/data/3857/` (or `4087/`), and run `./deploy.sh --download` (`.\deploy.ps1 -Download`), which downloads whatever is missing.
- **After an interrupted download**: the real file is only created when the transfer completes, so a partial download never replaces a good copy. It leaves a file named like `RBT.mbtiles.a1B2c3D4` in the same folder. Run the download step again: it deletes that leftover (so it doesn't count against the free-space check) and starts the file over, since the AWS CLI can't resume. If you download by hand, delete the leftover yourself.
- **Reclaim Docker's own disk use**: `docker system df` shows what images and build cache use, and [Operating RBT](operations.md#uninstalling-and-reclaiming-disk) lists what each part of RBT takes.

## A Deploy Stops with "Did Not Start or Become Healthy"

The deploy scripts start the stack with `docker compose up -d --wait --wait-timeout 600 --remove-orphans` and give up after 10 minutes. TileserverGL alone is allowed 3 minutes before its first health check counts, because it opens the MBTiles files at startup. The script has already checked, before building anything, that the MBTiles exist and aren't empty, and that `UWSGI_CHEAPER` is lower than `UWSGI_PROCESSES`, so those two causes are ruled out when you get here.

- **Solution**: Run `docker compose ps` to see which service is unhealthy or restarting, then `docker compose logs --tail 50 <service>`. Common causes:
  - `tileservergl` -- the MBTiles are missing or incomplete (see the sections on blank styles and interrupted downloads), or the container ran out of memory (`docker inspect -f '{{.State.OOMKilled}}' tileservergl` prints `true`; see the memory sections below).
  - `mapproxy` -- it couldn't load its configuration (see the 502 section above), or hit the file-permission problem described under "`mapproxy` Container Exits".
  - Any service -- a port conflict (see "Port Is Already Allocated" above).
- Running the deploy again is safe once the cause is fixed.

## Docker Compose Is Too Old

The deploy scripts stop with `Docker Compose X is too old` when the Compose plugin is older than 2.17.0. They use `docker compose up --wait-timeout` (added in 2.17.0) and `docker compose pull --ignore-buildable` (2.15.0); an older Compose rejects those flags with an "unknown flag" error that doesn't mention the version.

- **Check**: `docker compose version`
- **Solution**: Update Docker. On macOS and Windows, update Docker Desktop (**Check for updates** in its menu). On Linux, install the current `docker-compose-plugin` from Docker's own repository -- the Docker steps in [install-linux.md](install-linux.md) set that repository up -- rather than your distribution's older `docker-compose` or `docker-compose-v2` packages (the Ubuntu/Debian install steps remove those). Then run the deploy again.

## Old Containers Are Still Running After Switching Deployments

Going from the [EPSG:4087 stack](deployment-4087.md) to the default one leaves `tileservergl4087` running, and going to a no-nginx deployment leaves `nginx` running. Compose calls these orphans: containers from this project that the files you named no longer define. The deploy scripts remove them (`--deploy` passes `--remove-orphans`), but a plain `docker compose up -d` doesn't.

- **Solution**: Run `./deploy.sh --deploy` (`.\deploy.ps1 -Deploy`) for the deployment you want, or `docker compose down --remove-orphans` first if you start things by hand. See [Switching deployments](operations.md#switching-deployments).

## The 4087 Stack Is Up, but EPSG:4326 Tiles Look Unchanged

This applies to the `--4087`/`-Use4087` stack ([docker-compose.4087.yaml](../docker-compose.4087.yaml)). MapProxy loads the file named by the `MAPPROXY_CONFIG` environment variable, which `docker-compose.4087.yaml` sets to [mapproxy.4087.yaml](../mapproxy/config/mapproxy.4087.yaml). Without it, MapProxy loads the regular `mapproxy.yaml`: containers stay healthy and nothing errors, but the EPSG:4326 caches keep reprojecting from EPSG:3857 and `tileservergl4087` never receives requests from MapProxy.

- **Solution**: Check that the variable is set, and that MapProxy read the file -- it logs each config file it reads at startup (if the log has rotated since then, `docker restart mapproxy` first):

  ```bash
  docker exec mapproxy printenv MAPPROXY_CONFIG
  # expect: /mapproxy/config/mapproxy.4087.yaml
  docker logs mapproxy 2>&1 | grep -o 'reading: .*' | sort -u
  # expect: reading: /mapproxy/config/mapproxy.4087.yaml
  #         reading: /mapproxy/config/mapproxy.yaml       (the file it builds on)
  ```

  On native Windows PowerShell, the same checks are:

  ```powershell
  docker exec mapproxy printenv MAPPROXY_CONFIG
  docker logs mapproxy 2>&1 | Select-String 'reading: .*' | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
  ```

  If `printenv` prints nothing, the stack was started without `docker-compose.4087.yaml`: deploy with `-f docker-compose.yaml -f docker-compose.4087.yaml` (or `--4087`/`-Use4087`). If it prints the path but MapProxy only read `mapproxy.yaml`, the `mapproxy` image predates `MAPPROXY_CONFIG`: rebuild it with `docker compose ... build mapproxy` and recreate the container (the deploy scripts always rebuild it).

  Then confirm MapProxy is actually querying the second tileserver:

  ```bash
  curl -fsS "http://localhost:8081/wmts/rbt_topo_4326/geodetic/2/1/1.png" -o /dev/null
  docker logs --tail 20 tileservergl4087   # expect a /styles/RBT-TOPO/512/... request in the access log
  ```

  ```powershell
  curl.exe -fsS "http://localhost:8081/wmts/rbt_topo_4326/geodetic/2/1/1.png" -o NUL
  docker logs --tail 20 tileservergl4087   # expect a /styles/RBT-TOPO/512/... request in the access log
  ```

  (Both use the default MapProxy port, 8081; use your `MAPPROXY_PORT` if you changed it.)

## `mapproxy` Container Exits, or Can't Write Its Lock Files

On **Linux or WSL2**, this is almost always a file-permission mismatch between the host directories and the container's user (uid/gid `1000`).

- **Solution (Linux/WSL2)**: Re-run the permissions step (`chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks`) from the [Linux](install-linux.md) or [Windows WSL2](install-windows.md#option-b-wsl2) setup instructions, or `./deploy.sh --perm`, then `docker compose restart mapproxy`. If the log shows a configuration error instead, see the 502 section above.
- **Solution (macOS or native Windows)**: There's no uid/gid mismatch to fix here -- Docker Desktop's VM writes to bind-mounted host directories regardless of host file permissions/ACLs. Instead, run `docker compose logs mapproxy` and check Docker Desktop's **Settings -> Resources -> File sharing** includes the drive/volume you cloned this repository onto.

## `git pull` Fails with "unable to create file mapproxy/data/.txt" (Linux/WSL2)

Newer versions of this repository track a placeholder file, `mapproxy/data/.txt`, so that directory exists in a fresh clone (the `locks` and `tile_locks` directories already worked this way). On an older Linux or WSL2 clone, the permissions step gave `mapproxy/data` to uid/gid `1000`, and if you aren't that user, `git pull` can't create the new file in it.

- **Solution**: Take the directory back, pull, then hand it to the container again:

  ```bash
  sudo chown -R "$USER": mapproxy/data
  git pull
  ./deploy.sh --perm
  ```

  The last command runs the same `chown` and `chmod` as the install guides.

## Windows (WSL2): Containers Are Extremely Slow, or Permission Changes Don't Stick

- **Solution**: Confirm the repository is cloned inside your WSL2 filesystem (`~/rbt-local`), not under `/mnt/c/...` (`./deploy.sh` warns when it finds itself under `/mnt/`). See [Clone into the WSL2 filesystem](install-windows.md#step-4-clone-into-the-wsl2-filesystem-not-mntc) in the Windows setup guide. (This doesn't apply to Option A/native Windows, which has no WSL2 filesystem boundary to cross.)

## Windows: Docker Desktop or Its WSL2 Engine Runs Out of Memory

Docker Desktop uses the WSL2 platform's shared utility VM for its engine on Windows, whether you're on Option A (native) or Option B (WSL2) -- so this applies to both.

- **Solution**: (The deploy scripts print a warning, "Docker has only ... of memory", when the engine reports under about 14 GiB.) Increase the `memory` value in `%UserProfile%\.wslconfig` (see [Give WSL2 enough memory](install-windows.md#step-2-give-wsl2-enough-memory) in the Windows setup guide), then run `wsl --shutdown` and reopen Docker Desktop/your terminal.

## macOS: Docker Desktop Runs Out of Memory

- **Solution**: (`./deploy.sh` prints a warning, "Docker has only ... of memory", when the engine reports under about 14 GiB.) Open Docker Desktop's **Settings -> Resources -> Advanced** and increase the memory limit, then apply and restart the engine.

## MapProxy Uses Too Much Memory

MapProxy runs as a pool of uWSGI worker processes, sized by `UWSGI_PROCESSES` (8 by default) and `UWSGI_CHEAPER` (4 by default: how many keep running while idle; the rest start under load). [`mapproxy/config/uwsgi.ini`](../mapproxy/config/uwsgi.ini) restarts a worker once it holds more than 2 GB, so the worst case is about `UWSGI_PROCESSES` x 2 GB (16 GB with the defaults).

- **Solution**: On a smaller machine, lower both in `.env` -- `UWSGI_CHEAPER` must stay below `UWSGI_PROCESSES`, or uWSGI won't start. For example, `UWSGI_PROCESSES=4` with `UWSGI_CHEAPER=2`. See [.env.example](../.env.example), then recreate the container with `docker compose up -d`.

## TileserverGL Uses Too Much Memory, or Renders Slowly Under Load

TileserverGL renders raster tiles with pools of MapLibre renderers: one pool per style, per scale factor (`@2x` tiles have their own) and per request type (tiles and static maps). [`tileserver/config/config.json`](../tileserver/config/config.json) sizes them:

- `minRendererPoolSizes` (`[4, 2]`): renderers each 1x and 2x pool creates at startup and keeps -- 6 styles x 2 request types x (4 + 2) = 72 in total.
- `maxRendererPoolSizes` (`[16, 8]`): how far each pool grows under load before requests queue.
- `maxScaleFactor` (`2`): the largest `@Nx` suffix served; `@3x` and up are rejected. None of the setups in [Connecting GIS Clients](gis-clients.md) requests more than `@2x`.

To tune them:

- **Too much memory**: lower the `maxRendererPoolSizes` entries, and the `minRendererPoolSizes` ones for fewer idle renderers.
- **Slow at the start of a burst**: raise `minRendererPoolSizes` towards `maxRendererPoolSizes`, memory permitting, so fewer renderers are created on demand. TileserverGL's own defaults are `[8, 4, 2]`, `[16, 8, 4]` and `3` (168 renderers at startup here).

Restart TileserverGL after editing (`docker compose restart tileservergl`, plus `tileservergl4087` in the [EPSG:4087 stack](deployment-4087.md)).

## `deploy.sh --init` Times Out Waiting for the Docker Engine (macOS)

- **Cause**: Docker Desktop's very first launch after install can require a one-time GUI step (accepting a license, granting privileged-helper access) that can't be scripted.
- **Solution**: Open Docker Desktop manually, finish any prompts, wait for it to report the engine is running, then re-run `./deploy.sh`.

## uWSGI Fails to Start, or Config Changes Have No Effect

- **Solution (macOS/Linux/WSL2)**: Check for Windows-style line endings: run `file mapproxy/config/uwsgi.ini` and look for `CRLF`. If present, see [A note on Git line endings](install-windows.md#a-note-on-git-line-endings) in the Windows setup guide (this can only happen if the file was edited on, or checked out with, Windows' default `core.autocrlf=true`).
- **Solution (native Windows)**: Run `Get-Content mapproxy/config/uwsgi.ini -Raw` in PowerShell and check whether it contains `` `r`n `` (CRLF) instead of plain `` `n `` -- or simply re-run `.\deploy.ps1 -Prep`, which normalizes this file (and the other config files) to LF automatically.

## Native Windows: Reboot Requested, or `docker` Fails with a Permissions Error Right After Install

- **A reboot prompt appeared during `-Init` / `choco install docker-desktop` / `wsl --install`**: This is expected the first time either the WSL2 platform or Docker Desktop is installed. Restart Windows, then re-run the same `deploy.ps1` command (or the manual step you were on) -- already-installed prerequisites are detected and skipped.
- **`docker` commands fail with a permissions/access-denied error immediately after installing Docker Desktop**: You were added to the local `docker-users` group as part of the install, but Windows only applies new group membership to new sign-ins. Log out and back in (or reboot), then try again.

## Where to Get Help

- Check the sections above, and [Connecting GIS Clients to RBT](gis-clients.md#troubleshooting-gis-client-connections) if the issue is specific to a GIS client connection
- Contact the RBT program manager for support
