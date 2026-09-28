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

[CI](.github/workflows/ci.yml) runs these on every pull request, alongside `Lint PR` and the docs build. To run them yourself first, from the repo root:

```bash
shellcheck deploy.sh .githooks/commit-msg

# Every Compose stack (CI checks all four combinations), and nginx.conf in the pinned image
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml -f docker-compose.override.yaml config --quiet
docker run --rm --add-host mapproxy:127.0.0.1 --add-host tileservergl:127.0.0.1 \
  -v "$PWD/nginx/config/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.30-alpine nginx -t

# MapProxy's configs -- needs MapProxy (pip install MapProxy==7.0.0, in a
# virtualenv)
python3 .github/scripts/check-mapproxy-config.py

# The docs site
pip install -r requirements-docs.txt
python3 scripts/prepare_pages.py && mkdocs build --strict
```

Pull requests that change `Dockerfile.mapproxy`, `mapproxy/environment.yml` or `mapproxy/docker/app.py` also build the MapProxy image.

## Prefer squash merge

Squash-merging uses the **PR title** as the commit on `main`, which is the line git-cliff will publish. If you merge with a merge commit instead, keep every commit on the branch conventional — git-cliff skips `Merge pull request` lines.

## Changelog updates

Do not edit `CHANGELOG.md` by hand for ordinary work. After merge (or after you push a `v*` tag), the Changelog workflow rewrites the file, commits `chore(changelog): update CHANGELOG.md`, and re-runs the Pages workflow, so the docs site's [Release notes](https://releasablebasemaptiles.github.io/rbt-local/release-notes/) page matches the file.

A squash merge copies the message of every commit on the branch into the commit on `main`. If any of them contains `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `[actions skip]`, even in passing, GitHub starts none of the workflows for that merge, this one and Pages included. Leave the brackets off when a message has to mention one. If a merge was skipped, run the Changelog workflow from the Actions tab: it updates the file and re-runs Pages.

GitHub Releases are still created by hand (`gh release create`). Repo tags like `v2.0.0` are the changelog versions; they are independent of the MapProxy image tag (`7.0.0`).

## Local commit-msg hook (optional)

To reject non-conventional commits before they reach GitHub:

```bash
git config core.hooksPath .githooks
```

That only affects this clone. It does not change your global Git config.
