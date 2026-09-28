# Contributing

This repository keeps [CHANGELOG.md](CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) form. [git-cliff](https://git-cliff.org/) regenerates that file on every push to `main` and on every `v*` tag, from **Conventional Commits**.

## Commit and pull request titles

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
type(scope): short description
```

`type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. `scope` is optional (`helm`, `mapproxy`, `compose`, `ci`, …).

Examples:

```text
feat(helm): fetch fonts and styles from S3
fix(mapproxy): mount mapproxy.4087.yaml in the --4087 stack
docs: document the four Compose deployments
chore(ci): add git-cliff changelog workflow
```

Breaking changes use a `!` after the type/scope (`feat!: ...`) or a `BREAKING CHANGE:` footer. Those show up in the changelog as **breaking**.

CI rejects pull requests whose title or commits do not match this format (`Lint PR`). Merge commits and `chore(changelog):` commits are ignored.

## Checks

[CI](.github/workflows/ci.yml) runs these on every pull request, alongside `Lint PR` and the docs build. To run them yourself first, from the repo root:

```bash
shellcheck deploy.sh charts/rbt/sync-files.sh charts/rbt/files/scripts/fetch-s3.sh .githooks/commit-msg

# Every Compose stack (CI checks all four combinations), and nginx.conf in the pinned image
docker compose -f docker-compose.yaml -f docker-compose.4087.yaml -f docker-compose.override.yaml config --quiet
docker run --rm --add-host mapproxy:127.0.0.1 --add-host tileservergl:127.0.0.1 \
  -v "$PWD/nginx/config/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.30-alpine nginx -t

# MapProxy's configs, as the repo files and as the Helm chart ships them --
# needs helm, and MapProxy (pip install MapProxy==7.0.0, in a virtualenv)
python3 .github/scripts/check-mapproxy-config.py

# The Helm chart
./charts/rbt/sync-files.sh --check
helm lint --strict charts/rbt

# The docs site
pip install -r requirements-docs.txt
python3 scripts/prepare_pages.py && mkdocs build --strict
```

After editing anything in `mapproxy/config/` or `tileserver/config/config.json`, run `./charts/rbt/sync-files.sh` to update the chart's copies (see [charts/rbt/README.md](charts/rbt/README.md#why-chartsrbtfiles-duplicates-repo-root-configs)). Pull requests that change `Dockerfile.mapproxy`, `mapproxy/environment.yml` or `mapproxy/docker/app.py` also build the MapProxy image.

## Prefer squash merge

Squash-merging uses the **PR title** as the commit on `main`, which is the line git-cliff will publish. If you merge with a merge commit instead, keep every commit on the branch conventional — git-cliff skips `Merge pull request` lines.

## Changelog updates

Do not edit `CHANGELOG.md` by hand for ordinary work. After merge (or after you push a `v*` tag), the Changelog workflow rewrites the file and commits `chore(changelog): update CHANGELOG.md [skip ci]`.

GitHub Releases are still created by hand (`gh release create`). Repo tags like `v2.0.0` are the changelog versions; they are independent of the Helm chart's version (in `charts/rbt/Chart.yaml`) and the MapProxy image tag (`7.0.0`).

## Local commit-msg hook (optional)

To reject non-conventional commits before they reach GitHub:

```bash
git config core.hooksPath .githooks
```

That only affects this clone. It does not change your global Git config.
