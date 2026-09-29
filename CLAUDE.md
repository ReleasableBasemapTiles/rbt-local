# CLAUDE.md

Working notes for Claude Code in this repository: the commands, the rules that span files, and what to ask about first. [CONTEXT.md](CONTEXT.md) holds the background and the domain vocabulary -- styles, layers, the two kinds of "cache", the three meanings of "overlay". Read it before changing MapProxy, Compose or nginx config, or writing user-facing docs. Explanations for users belong in [README.md](README.md) and [docs/](docs/), not here.

## What this repo is

The single-host Docker Compose deployment of Releasable Basemap Tiles (RBT). There is no application code: it's Compose files, service config, two bootstrap/deploy scripts, a custom MapProxy image, and MkDocs guides published to GitHub Pages. Kubernetes/OpenShift lives in [ReleasableBasemapTiles/charts](https://github.com/ReleasableBasemapTiles/charts); the styles come from the private ReleasableBasemapTiles/styles repo.

Request path, with default ports: client -> `nginx` :8082 (optional; the only tile cache) -> `mapproxy` :8081 (uWSGI on :5000 inside; WMS/WMTS and reprojection; stores nothing) -> `tileservergl` :8080 (renders 512px PNGs from `tileserver/data/3857/`). The EPSG:4087 stack adds `tileservergl4087` :8083, reading `tileserver/data/4087/`.

## Repo map

| Path | What it is |
| --- | --- |
| `docker-compose.yaml` | Base stack: `mapproxy` and `tileservergl` |
| `docker-compose.override.yaml` | `nginx`; Compose merges it in automatically unless `-f` flags are given |
| `docker-compose.4087.yaml` | Overlay: adds `tileservergl4087` and points MapProxy at `mapproxy.4087.yaml` |
| `mapproxy/config/mapproxy.yaml` | 18 layers: 6 styles x EPSG:3857/3395/4326 |
| `mapproxy/config/mapproxy.4087.yaml` | `base: mapproxy.yaml` plus only the EPSG:4087 differences |
| `mapproxy/config/uwsgi.ini`, `logging.ini` | uWSGI and logging settings, mounted read-only |
| `Dockerfile.mapproxy`, `mapproxy/environment.yml`, `mapproxy/docker/app.py` | The custom MapProxy image (see [Ask first](#ask-first)) |
| `nginx/config/nginx.conf` | Routing, prefix headers, tile-cache policy |
| `tileserver/config/config.json` | TileserverGL's data (`RBT`, `TERRAIN`) and style registry |
| `tileserver/styles/RBT-*/` | The six styles, synced from upstream |
| `tileserver/fonts/` | Pre-built PBF glyph ranges: generated, never hand-edited |
| `tileserver/data/{3857,4087}/` | The MBTiles: gitignored, hundreds of GB |
| `deploy.sh`, `deploy.ps1` | Bootstrap and deploy: macOS/Linux/WSL2, and native Windows 11 |
| `docs/`, `README.md`, `CHANGELOG.md`, `images/` | The guides. `scripts/prepare_pages.py` copies them into `site-docs/` and `mkdocs` builds `site/` (both gitignored) |
| `.github/` | CI, MapProxy image publishing, Pages, changelog, weekly style sync |
| `nginx/cache/`, `mapproxy/{data,locks,tile_locks}/` | Runtime bind mounts; git tracks at most a placeholder file in each |

## Checks

There are no unit tests. These are the checks CI runs ([ci.yml](.github/workflows/ci.yml), [pages.yml](.github/workflows/pages.yml)); [CONTRIBUTING.md](CONTRIBUTING.md) walks contributors through most of them. Run the ones covering what you changed:

```bash
shellcheck deploy.sh .githooks/commit-msg
pwsh -NoProfile -Command '$t = $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD/deploy.ps1", [ref]$t, [ref]$e); if ($e) { $e | ForEach-Object { "deploy.ps1:$($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }'

docker compose -f docker-compose.yaml config --quiet
docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --quiet
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml config --quiet
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml -f docker-compose.override.yaml config --quiet

docker run --rm --add-host mapproxy:127.0.0.1 --add-host tileservergl:127.0.0.1 \
  -v "$PWD/nginx/config/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --images | grep '^nginx:')" nginx -t

git ls-files '*.json' | ( bad=0; while IFS= read -r f; do python3 -m json.tool "$f" >/dev/null || { echo "bad JSON: $f"; bad=1; }; done; exit $bad )
```

The `nginx -t` line reads the image tag from the Compose files, as CI does, so it keeps up with Dependabot's bumps. The JSON check runs in a `( ... )` subshell so its `exit` can't close an interactive zsh.

The MapProxy config check and the docs build need Python packages. Keep the virtualenv outside the repo (`.venv` isn't gitignored):

```bash
python3 -m venv ~/.venvs/rbt-local
~/.venvs/rbt-local/bin/pip install -r requirements-docs.txt "MapProxy==$(sed -n 's/^ARG MAPPROXY_VERSION=//p' Dockerfile.mapproxy)"

~/.venvs/rbt-local/bin/python .github/scripts/check-mapproxy-config.py
~/.venvs/rbt-local/bin/python scripts/prepare_pages.py && ~/.venvs/rbt-local/bin/mkdocs build --strict
```

`docker compose build mapproxy` builds the MapProxy image under the name the Compose file gives it, and runs the Dockerfile's PROJ/EPSG:4087 and WSGI smoke tests. It's slow; CI builds it on pull requests that touch its inputs.

### Running the stack

The stack only becomes healthy with the MBTiles in `tileserver/data/3857/` (and `tileserver/data/4087/` for that stack), so check they're there first.

```bash
./deploy.sh --deploy              # build, pull, start, wait for healthy; add --4087 and/or --no-nginx for the other stacks
./deploy.sh --refresh             # after editing a style or replacing MBTiles; add the running stack's flags (--4087)
docker compose logs -f mapproxy
docker compose down --remove-orphans
```

Plain `docker compose` means the default stack, unless `.env` sets `COMPOSE_FILE`. For the others, pass the same `-f` list the deploy script prints at the end. [docs/verify.md](docs/verify.md) has the smoke checks, including the `X-Cache-Status` MISS-then-HIT test.

## Ask first

- **Deploy steps that change the machine or fetch data**:
  - `--init`/`-Init` installs packages and Docker, through Homebrew, apt/dnf under sudo, or Chocolatey as Administrator.
  - `--download` and `--force` fetch hundreds of GB of MBTiles; the README's `aws s3 ls` command shows the current sizes.
  - `--perm` runs sudo chown.
  - A run with no step flag does all of the above. The modifiers `--4087`, `--no-nginx` and `--force` (`-Use4087`, `-NoNginx`, `-Force`) are not step flags, so `./deploy.sh --4087` on its own is a full run. Always pair a modifier with a step: `./deploy.sh --4087 --deploy`.
  - `--deploy`, `--refresh` and `docker compose` are fine when the task needs a running stack. On Linux they run through sudo too.
- **The MapProxy image inputs**: `Dockerfile.mapproxy`, `mapproxy/environment.yml`, `mapproxy/docker/app.py` and `.github/workflows/mapproxy-image.yml`. Merging a change to any of them rebuilds and pushes `ghcr.io/releasablebasemaptiles/rbt-local/mapproxy:7.0.0` and `:latest`, which the charts repo deploys. `environment.yml` isn't fully pinned, so even a comment-only edit ships whatever conda-forge resolves that day. Their stale Helm chart comments are known and were left alone on purpose (commit ef05eb4).
- **`tileserver/styles/RBT-*/`**: owned by ReleasableBasemapTiles/styles. The weekly Sync styles pull request replaces local edits, so style changes belong upstream.
- **Anything outward-facing**: pushing, opening pull requests, `v*` tags and GitHub Releases, and `gh workflow run` (dispatching `mapproxy-image.yml` publishes an image -- as `7.0.0` and `latest` when run on `main` -- and `sync-styles.yml` opens a pull request).

## Keep in sync

These facts are stated in more than one place. When you change one, grep for the old value and update the rest.

| If you change | Also update |
| --- | --- |
| A `deploy.sh` flag, step or behavior | `deploy.ps1` (`--4087` is `-Use4087`, `--no-nginx` is `-NoNginx`, and `--perm`/`-Prep` are different steps), both usage texts, the manual steps in `docs/install-*.md`, and every other mention in README, `docs/` and config comments (`git grep -n -e --no-nginx -e -NoNginx`, say) |
| A port, service name or path prefix | The Compose files (ports and healthchecks), `.env.example`, `uwsgi.ini` (port 5000), `nginx.conf`, MapProxy source URLs, both scripts (usage texts, service lists, closing hints), the `--add-host` names in `ci.yml`, CONTRIBUTING and this file, README "Endpoints", and `docs/verify.md`, `gis-clients.md`, `advanced-deployment.md`, `deployment-4087.md`, `troubleshooting.md`, `architecture.md` (diagrams included) |
| The set of styles | The style directory, `config.json`, `mapproxy.yaml` (a source, three caches, three layers), `mapproxy.4087.yaml` (a 4087 source and cache, and the 4326 cache's source), `sync-styles.yml`'s sparse-checkout list, and every style list or "six styles"/"18 layers" count in README, `gis-clients.md`, `verify.md`, `deployment-4087.md`, `troubleshooting.md` |
| nginx's cache policy (30 days, 10 GB, what's cached) | `docs/architecture.md` "Tile Caching", `gis-clients.md`, `troubleshooting.md`, README "Requirements" |
| MapProxy's WMS `srs` list | `docs/architecture.md`, `docs/gis-clients.md` |
| An image pin | `tileserver-gl` is pinned in both `docker-compose.yaml` and `docker-compose.4087.yaml` (keep them equal). The nginx tag is also in CONTRIBUTING's `nginx -t` line. MapProxy's version is `ARG MAPPROXY_VERSION` in `Dockerfile.mapproxy`, where CI reads it, and it's repeated in the `rbt-mapproxy:7.0.0` image name in `docker-compose.yaml`, the GHCR tag in `mapproxy-image.yml` (which the charts repo deploys), CONTRIBUTING, and the `7.0.0` mentions in this file and CONTEXT.md |
| The public mirror | `PUBLIC_S3_*` in `deploy.sh`, `$script:PublicS3*` in `deploy.ps1`, README "Get the Map Data" |
| TileserverGL's renderer pool sizes | `docs/troubleshooting.md` |
| Added a docs page | `mkdocs.yml` `nav` -- `mkdocs build --strict` fails otherwise |
| Added a config file that must stay LF | `.gitattributes`, and `Repair-ConfigLineEndings` in `deploy.ps1` |
| The commit conventions | CONTRIBUTING.md, `.cursor/rules/conventional-commits.mdc`, `.githooks/commit-msg`, `commitlint.config.mjs`, `.github/workflows/lint-pr.yml`, `cliff.toml` (how types map to changelog sections), `.github/dependabot.yml` (its commit prefixes), `.github/pull_request_template.md`, this file |

## Invariants

Each of these is explained in a comment where it lives. Keep those comments.

**Compose**
- No `-f` flags means base plus override (the default stack), unless `.env` sets `COMPOSE_FILE`; any `-f` drops the override. CI validates all four combinations.
- Switching away from a 4087 stack leaves `tileservergl4087` running as an orphan, so run `docker compose down --remove-orphans` first.
- The `x-logging` block is repeated in each file because YAML anchors don't cross files. Keep the copies identical.
- `container_name`s are fixed, and services reach each other by name on `rbt-network`.

**MapProxy**
- Every cache sets `disable_storage: true`. MapProxy stores nothing; nginx is the only tile cache.
- The EPSG:3395 and EPSG:4326 caches each take the matching EPSG:3857 cache as their source, one reprojection hop; in the 4087 stack, the EPSG:4326 caches take the matching EPSG:4087 cache instead. Don't chain 4326 through 3395.
- `mapproxy.4087.yaml` merges over `mapproxy.yaml` through `base:`. Mappings merge key by key. Lists named `sources`, `grids`, `bbox`, `tile_size`, `res` or `max_output_pixels` replace the base's, `layers` merge by `name`, an empty list deletes the base's, and every other list is appended. The source of truth is `merge_dict` in MapProxy 7.0.0's `mapproxy/config/loader.py`. Never restate a list such as `services.wms.srs` there; `check-mapproxy-config.py` fails on duplicates.
- `services.wms.srs` replaces MapProxy's default list, so it repeats the five defaults next to EPSG:3395.
- Every grid is `origin: nw` (WMTS silently drops the others) with 512px tiles, matching TileserverGL's `/styles/<ID>/512/{z}/{x}/{y}.png` URLs.
- Only the overlay sources are `transparent: true`.
- `UWSGI_CHEAPER` must stay below `UWSGI_PROCESSES` or uWSGI won't start. uWSGI's `harakiri` (75 s) stays below nginx's `proxy_read_timeout` (80 s).

**nginx**
- Never add `proxy_set_header` inside a `location`: one there silently discards all the server-level ones.
- Backends are named through a variable (`set $rbt_backend ...; proxy_pass http://$rbt_backend;`), so Docker's DNS resolves them per request. That's what lets nginx start in stacks without `tileservergl4087`. In each location, every `set` comes before `rewrite ... break`.
- The stripped prefix goes back to the backends as `X-Script-Name` (MapProxy) and `X-Forwarded-Path` (TileserverGL), so the URLs they generate keep it.

**TileserverGL and styles**
- TileserverGL reads MBTiles and styles only at startup, and nginx can't tell they changed. After changing either, run `./deploy.sh --refresh` with the running stack's flags; without `--4087` it leaves `tileservergl4087` serving the old data.
- The data files are always named `RBT.mbtiles` and `TERRAIN.mbtiles`. Both TileserverGL containers share the config, styles and fonts; only `/data` differs.
- A `style.json` must point its sources at `mbtiles://{RBT}` (plus `mbtiles://{TERRAIN}` if it uses the terrain), its sprite at `{styleJsonFolder}/sprite` and its glyphs at `{fontstack}/{range}.pbf`. The weekly sync (`sync-styles.py`) rewrites upstream styles to these, but nothing checks a hand edit.
- URLs use the `config.json` key, which is the directory name (`RBT-LIGHT`), never the `id` inside `style.json` (`RBT-CANVAS-LIGHT`).

**deploy.sh**
- It runs under macOS's `/bin/bash` 3.2 with `set -euo pipefail`. That rules out `mapfile`, associative arrays, `${var,,}`, and expanding an array that may be empty; wrap that in a function, as `as_root` and `s3_aws` do.
- GNU and BSD `stat` and `date` differ: use `file_mtime_epoch`, `format_epoch` and `parse_iso8601_epoch`.
- On Linux, Compose runs through `sudo`, which drops exported variables, so Compose settings belong in `.env`. Downloads run unprivileged, with the user's own AWS credential chain.
- Every step must stay safe to re-run, and the script must stay shellcheck-clean.

**deploy.ps1**
- It must work in Windows PowerShell 5.1 under `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. Check native commands with `$LASTEXITCODE`. Around one that writes to stderr, set a local `$ErrorActionPreference = 'Continue'`, because 5.1 turns that stderr into a terminating error.
- Only `-Init` needs an elevated session.

**Docs and comments**
- Readers may be new to Docker: give copy-pasteable commands, explain terms, and state the expected result.
- The docs and comments write a dash as ` -- `, not an em dash.
- Link with ordinary relative paths (`docs/x.md` from README, `../README.md#anchor` from `docs/`); `prepare_pages.py` rewrites them for the site. Anchors are GitHub-style slugs, and `pages_hooks.py` makes the site generate the same ones.
- Keep the Mermaid diagrams in README and `docs/architecture.md` matching the Compose files.
- Comments in configs and scripts explain *why*: the constraint, or the failure they prevent, often at length. Match that when you edit, and don't strip the existing rationale.

## Git and pull requests

- Every commit subject and pull request title is a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`, where type is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. The scope is optional: CONTRIBUTING suggests `deploy`, `mapproxy`, `compose` and `ci`, and the history also has `styles`, `pages` and `deps`. Don't use `chore(changelog)` or `chore(release)`, because git-cliff leaves those commits out of the changelog. A breaking change takes `!` (`refactor!: ...`) or a `BREAKING CHANGE:` footer.
- The Lint PR workflow checks the title and every commit on the branch. Commits go through commitlint's conventional config: no line over 100 characters (URLs included), and a subject that starts lower-case and has no trailing period.
- Commit bodies are prose: what changed and why, with bullets for lists. `git log` shows the style.
- Pull requests are squash-merged, so the title becomes the changelog line. Fill in the template's Summary and Test plan.
- Never put `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `[actions skip]` in a commit message, not even quoted. A squash merge that carries one runs no workflows: no CI, no Pages, no changelog.
- Don't edit `CHANGELOG.md`. The Changelog workflow regenerates it from the commits.
- `v*` tags version this repository, independently of the MapProxy image's `7.0.0`. GitHub Releases are made by hand.
- `git config core.hooksPath .githooks` turns on the local commit-msg check.

When a term, a sync point or a rule here changes, update this file and CONTEXT.md in the same pull request.
