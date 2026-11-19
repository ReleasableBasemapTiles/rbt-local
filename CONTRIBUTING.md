# Contributing

This repository keeps [CHANGELOG.md](CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) form. [git-cliff](https://git-cliff.org/) regenerates that file on every push to `main` and on every `v*` tag, from **Conventional Commits**.

## Commit and pull request titles

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
type(scope): short description
```

`type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. `scope` is optional (`deploy`, `mapproxy`, `compose`, `ci`, …).

Examples:

```text
feat(deploy): download MBTiles from the public mirror by default
fix(mapproxy): mount mapproxy.4087.yaml in the --4087 stack
docs: document the four Compose deployments
chore(ci): add git-cliff changelog workflow
```

Breaking changes use a `!` after the type/scope (`feat!: ...`) or a `BREAKING CHANGE:` footer. Those show up in the changelog as **breaking**.

CI rejects pull requests whose title or commits do not match this format (`Lint PR`). Merge commits and `chore(changelog):` commits are ignored.

## Checks

[CI](.github/workflows/ci.yml) runs these on every pull request, alongside `Lint PR` and the docs build. [`scripts/check.sh`](scripts/check.sh) runs the same commands, and CI calls it too, so a green run on your machine means a green run in CI. From the repo root:

```bash
scripts/check.sh          # every group
scripts/check.sh compose  # or just the groups you name: scripts, compose, configs, sync, docs
```

It runs every check in a group even when one fails, so one run lists all the problems, then exits 1 if there were any. These are the groups:

| Group | What it checks | What it needs |
| --- | --- | --- |
| `scripts` | ShellCheck on `deploy.sh`, `.githooks/commit-msg`, `scripts/check.sh` and `.github/scripts/smoke-test.sh`, and a parse of `deploy.ps1` | `shellcheck` and `pwsh` (PowerShell 7) |
| `compose` | Each of the four Compose stacks (`docker compose config`), and `nginx.conf` with `nginx -t` in the nginx image the Compose file pins | Docker, with the daemon running |
| `configs` | Every tracked JSON file is valid, and MapProxy's two configs load and keep the MapProxy rules in [CLAUDE.md](CLAUDE.md) (no storage, `origin: nw`, 512px, only the overlay transparent, one reprojection hop) | The Python virtualenv below |
| `sync` | Facts the repo states in more than one place agree: the image pins, MapProxy's version, the set of styles and the "six styles" and "18 layers" counts, the `style.json` rules, the public mirror, the uWSGI and nginx timeouts, the Docker minimums | The same virtualenv |
| `docs` | The docs site builds with `mkdocs build --strict`, and every relative link points at a file that exists | The virtualenv, with MkDocs |

A check whose tool you don't have is skipped with a warning, because few people have every tool. CI fails instead (it sets `CI=true`), so a skipped check still runs before merge.

The Python groups need MapProxy, PyYAML and MkDocs. Make a virtualenv once:

```bash
python3 -m venv ~/.venvs/rbt-local
~/.venvs/rbt-local/bin/pip install -r requirements-docs.txt "MapProxy==$(sed -n 's/^ARG MAPPROXY_VERSION=//p' Dockerfile.mapproxy)"
```

`scripts/check.sh` finds it there, or in a `.venv/` at the repo root (gitignored) if you'd rather keep one in the repo. To use another Python, set `PYTHON=/path/to/python`. The MapProxy version comes from `Dockerfile.mapproxy`, so the check always runs against the version the image installs.

CI also runs four checks that the script can't, because they need other machines or a running stack:

- `deploy.ps1` in Windows PowerShell 5.1 (the `windows` job): `powershell.exe -NoProfile -ExecutionPolicy Bypass -File deploy.ps1 -Help`, and PSScriptAnalyzer at Error severity.
- `deploy.sh` under the bash 3.2 that macOS ships (the `macos` job): `/bin/bash -n deploy.sh`, and `/bin/bash deploy.sh --help`.
- The workflows themselves, with [actionlint](https://github.com/rhysd/actionlint): `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color`.
- A full-stack smoke test ([smoke.yml](.github/workflows/smoke.yml)), on pull requests that touch the Compose files, `nginx/`, `mapproxy/`, `tileserver/config/`, `tileserver/styles/`, `Dockerfile.mapproxy` or the deploy scripts. It writes tiny fixture MBTiles (the real ones are hundreds of GB), deploys the default and the EPSG:4087 stack with `./deploy.sh --perm --deploy`, runs `./deploy.sh --check`, then asks the stack for tiles: `/healthz`, `styles.json`, all 18 layers in the capabilities, a GetMap that is an nginx `MISS` and then a `HIT`, the reprojected layers, the `/tileservergl` redirect, and a `MISS` again after `./deploy.sh --refresh`. The fixtures draw only each style's background, so it proves the stack works and says nothing about the map data.

To run the smoke test on your own machine, write the fixtures, deploy, and point the script at the stack. It needs Docker and, like any deploy, the ports free:

```bash
python3 .github/scripts/make-fixture-mbtiles.py   # writes tileserver/data/{3857,4087}/*.mbtiles; stops if real data is there
./deploy.sh --deploy                              # add --4087 for the EPSG:4087 stack
.github/scripts/smoke-test.sh                     # add --4087 to match; it ends with ./deploy.sh --refresh
docker compose down --remove-orphans              # same -f flags as the deploy printed, for --4087
rm tileserver/data/*/RBT.mbtiles tileserver/data/*/TERRAIN.mbtiles
```

Remove the fixtures when you are done. The downloader skips a file that is already there (`RBT.mbtiles` unless the mirror's copy is newer, `TERRAIN.mbtiles` always), so a leftover fixture would stop `./deploy.sh --download` from fetching the real data.

Pull requests that change `Dockerfile.mapproxy`, `mapproxy/environment.yml` or `mapproxy/docker/app.py` also build the MapProxy image.

## Prefer squash merge

Squash-merging uses the **PR title** as the commit on `main`, which is the line git-cliff will publish. If you merge with a merge commit instead, keep every commit on the branch conventional -- git-cliff skips `Merge pull request` lines.

## Changelog updates

Do not edit `CHANGELOG.md` by hand for ordinary work. After merge (or after you push a `v*` tag), the Changelog workflow rewrites the file, commits `chore(changelog): update CHANGELOG.md`, and re-runs the Pages workflow, so the docs site's [Release notes](https://releasablebasemaptiles.github.io/rbt-local/release-notes/) page matches the file.

A squash merge copies the message of every commit on the branch into the commit on `main`. If any of them contains `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `[actions skip]`, even in passing, GitHub starts none of the workflows for that merge, this one and Pages included. Leave the brackets off when a message has to mention one. If a merge was skipped, run the Changelog workflow from the Actions tab: it updates the file and re-runs Pages.

GitHub Releases are still created by hand (`gh release create`). Repo tags like `v2.0.0` are the changelog versions; they are independent of the MapProxy image tag (`8.1.0`).

## Local commit-msg hook (optional)

To reject non-conventional commits before they reach GitHub:

```bash
git config core.hooksPath .githooks
```

That only affects this clone. It does not change your global Git config.
