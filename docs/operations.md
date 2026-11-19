# Operating RBT

Once RBT is running (see the [Quickstart](../README.md#quickstart)), this page covers what comes next: getting updates, switching between deployments, removing RBT, and collecting details for a support request. Run every command from the `rbt-local` folder.

Most commands below are written for the default deployment. If you deployed with `--4087` (`-Use4087` on Windows) or `--no-nginx` (`-NoNginx`), add the same flags to the `deploy` commands, and the same `-f` flags to the `docker compose` ones (the last lines the deploy script printed show them). The [README](../README.md#deployment-options) compares the four deployments.

> **Always pair a flag like `--4087` or `--no-nginx` with a step.** Those flags only choose the deployment; on their own, `./deploy.sh --4087` is a *full run* -- it also installs prerequisites and downloads any map data the mirror has a newer copy of. For a routine update, write `./deploy.sh --4087 --deploy`.

## Updating RBT

New versions of this repository change the Compose files, configuration, styles and scripts. [Release notes](release-notes.md) lists what changed.

```bash
git pull
./deploy.sh --refresh --deploy
```

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Refresh -Deploy
```

- `git pull` stops with an error if you've edited tracked files. Keep your changes aside (`git stash`) or undo them (`git restore <file>`), then pull again. Settings that belong to you -- ports, bind address, worker counts -- go in `.env`, which Git ignores.
- `--refresh` makes TileserverGL reload its styles (it reads them, and the map data, only at startup) and empties nginx's tile cache, so nobody is served tiles drawn with an old style. `--deploy` rebuilds the MapProxy image, pulls the other images, and recreates whatever changed.
- A `git pull` that changed only documentation doesn't need `--refresh`, but it does no harm: the tile cache just refills as tiles are requested.

## Updating the map data

The map data is updated periodically on the public mirror.

```bash
./deploy.sh --download        # add --4087 for the EPSG:4087 deployment
```

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Download   # add -Use4087 for the EPSG:4087 deployment
```

This downloads `RBT.mbtiles` only if the mirror's copy is newer than yours (`TERRAIN.mbtiles` is downloaded once and then left alone), and when it fetched anything it runs the refresh step for you. See [How the deploy scripts download it](../README.md#how-the-deploy-scripts-download-it). Replacing the files by some other means? Run `./deploy.sh --refresh` yourself afterwards.

## Switching deployments

Say you ran the [EPSG:4087 deployment](deployment-4087.md) and want the default one again, or want to start using `--no-nginx`. All four deployments are one Compose project, so containers from the old one can be left behind (Compose calls them *orphans*). The deploy scripts clean them up: `--deploy` runs `docker compose up -d --wait --remove-orphans`, so you only need to run the deployment you want next:

```bash
./deploy.sh --deploy                     # the deployment you want next, e.g. add --no-nginx
```

Pair `--4087` and `--no-nginx` with a step like `--deploy`. On their own they still mean "run every step", including installing software and downloading the map data.

If the old deployment is running and the new run doesn't name it (for example you're leaving `--4087`), the script warns at the start about what will happen, so you can stop with Ctrl+C and change the flags.

A plain `docker compose up -d` does *not* remove orphans. If you start deployments by hand, take the old one down first, naming the same files you started it with (the deploy scripts print them at the end):

```bash
docker compose down --remove-orphans     # a deployment started with plain `docker compose`
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml down --remove-orphans   # one started with --4087
```

## Uninstalling and reclaiming disk

Here is what RBT uses, so you can decide what to remove:

| What | Where | How much |
| --- | --- | --- |
| Map data | `tileserver/data/3857/` (and `4087/`) | Hundreds of GB: the `aws s3 ls` command in [Get the Map Data](../README.md#get-the-map-data) lists the sizes |
| nginx tile cache | `nginx/cache/tile_cache/` | Up to 10 GB |
| Docker images | Docker's own storage | `docker system df` shows it; the MapProxy image is built on your machine |
| Container logs | Docker's own storage | At most 3 x 10 MB per container |

**To stop RBT and remove its containers and images:**

```bash
docker compose down --remove-orphans --rmi all
```

Add the same `-f` flags you deployed with if you used `--4087` or `--no-nginx`. `--rmi all` also deletes the images the containers used, including the locally built MapProxy image. `docker builder prune` deletes Docker's build cache too.

**To free the disk the data and cache use:**

```bash
rm tileserver/data/*/*.mbtiles      # the map data: the next ./deploy.sh downloads it again
sudo rm -rf nginx/cache/tile_cache  # root owns it on Linux; on macOS drop the sudo
```

```powershell
Remove-Item tileserver\data\*\*.mbtiles
Remove-Item -Recurse -Force nginx\cache\tile_cache
```

**To remove everything**, delete the `rbt-local` folder after the steps above. The `--init` step also installed Docker, the AWS CLI and Git; remove them with your package manager only if nothing else on the machine needs them (for example `brew uninstall --cask docker-desktop` on macOS, or `choco uninstall docker-desktop` on Windows). Inside WSL2, deleting files doesn't shrink the distribution's virtual disk -- see [A note on disk space](install-windows.md#a-note-on-disk-space).

## Collecting diagnostics for support

When you contact the RBT program manager, these details answer most of the first questions. Run them from the `rbt-local` folder, with the same `-f` flags as your deployment if it isn't the default one.

```bash
git rev-parse --short HEAD               # which version of this repository you have
git status --short                       # any files you've changed
./deploy.sh --check > rbt-check.txt 2>&1 # what the deploy script finds wrong (read-only; add --4087 and/or --no-nginx)
docker version
docker compose version
docker compose ps                        # which services run, and whether they're healthy
ls -lh tileserver/data/3857 tileserver/data/4087     # the map data files and their sizes
docker compose logs --no-color --tail 200 > rbt-logs.txt
```

```powershell
git rev-parse --short HEAD
git status --short
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Check | Out-File -Encoding utf8 rbt-check.txt
docker version
docker compose version
docker compose ps
Get-ChildItem tileserver\data\3857, tileserver\data\4087 | Format-Table Name, Length, LastWriteTime
docker compose logs --no-color --tail 200 | Out-File -Encoding utf8 rbt-logs.txt
```

Attach `rbt-check.txt`, `rbt-logs.txt` and the output of the other commands. Two cautions: the logs include the IP addresses of the clients that requested tiles, and `.env` may name a private bucket, so share them only as your organization's rules allow, and check `.env` before sending it.
