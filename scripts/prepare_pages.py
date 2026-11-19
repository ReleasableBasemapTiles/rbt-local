#!/usr/bin/env python3
"""Build site-docs/ for MkDocs without changing the Markdown in git.

Copies docs/*.md, README.md (as index.md), CHANGELOG.md (as release-notes.md)
and images/ into site-docs/, then rewrites link targets so in-site pages stay
relative and everything else points at this repo on GitHub. Fenced code
blocks are left alone.

A relative link to a path that is not in the repo fails the build. Without
that check the rewrite would quietly turn it into a GitHub URL that returns
404, which `mkdocs build --strict` can't catch because it never sees it.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path

REPO_URL = "https://github.com/ReleasableBasemapTiles/rbt-local"
LINK = re.compile(r"(!?\[[^\]]*\]\()([^)\s]+)(\))")
FENCE = re.compile(r"(^```.*?^```)", re.MULTILINE | re.DOTALL)
# Repo-root Markdown files that the site publishes as pages of their own.
ROOT_PAGES = {"README.md": "index.md", "CHANGELOG.md": "release-notes.md"}
# git-cliff's release headings. Everything above the first is its file header.
RELEASE = re.compile(r"^## ", re.MULTILINE)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def split_anchor(url: str) -> tuple[str, str]:
    if url.startswith("#"):
        return "", url
    path, separator, fragment = url.partition("#")
    if separator:
        return path, "#" + fragment
    return path, ""


def github_url(root: Path, rel: str, missing: list[str] | None = None) -> str:
    """The GitHub URL of a repo path. A path that isn't in the repo is added to
    `missing` (when given), so the caller can fail on it."""
    cleaned = rel.strip("/")
    if missing is not None and not (root / cleaned).exists():
        missing.append(cleaned)
    kind = "tree" if (root / cleaned).is_dir() else "blob"
    return f"{REPO_URL}/{kind}/main/{cleaned}"


def rewrite_url(url: str, *, from_root: bool, root: Path, missing: list[str]) -> str:
    if url.startswith(("http://", "https://", "mailto:", "#")):
        return url
    path, anchor = split_anchor(url)
    if from_root:
        if path.startswith("docs/"):
            if not (root / path).exists():
                missing.append(path)
            return path.removeprefix("docs/") + anchor
        if path in ROOT_PAGES:
            return ROOT_PAGES[path] + anchor
        if path == "":
            return url
        return github_url(root, path, missing) + anchor
    if not path.startswith("../"):
        return url
    rel = path.removeprefix("../")
    if rel in ROOT_PAGES:
        return ROOT_PAGES[rel] + anchor
    if rel.startswith("images/"):
        if not (root / rel).exists():
            missing.append(rel)
        return rel + anchor
    return github_url(root, rel, missing) + anchor


def rewrite_links(text: str, *, from_root: bool, root: Path, missing: list[str]) -> str:
    def replace(match: re.Match[str]) -> str:
        url = rewrite_url(match.group(2), from_root=from_root, root=root, missing=missing)
        return f"{match.group(1)}{url}{match.group(3)}"

    return LINK.sub(replace, text)


def rewrite_text(text: str, *, from_root: bool, root: Path, missing: list[str]) -> str:
    parts = FENCE.split(text)
    return "".join(
        part
        if part.startswith("```")
        else rewrite_links(part, from_root=from_root, root=root, missing=missing)
        for part in parts
    )


def release_notes(text: str, *, root: Path, missing: list[str]) -> str:
    """Swap CHANGELOG.md's git-cliff header for an introduction to the page."""
    first = RELEASE.search(text)
    releases = (
        rewrite_text(text[first.start() :], from_root=True, root=root, missing=missing)
        if first
        else ""
    )
    intro = (
        "# Release notes\n"
        "\n"
        "What changed in each release, newest first. Releases are this repository's `v*` tags,"
        " numbered with [Semantic Versioning](https://semver.org/spec/v2.0.0.html); the MapProxy"
        " image has a version number of its own. **Unreleased** lists"
        " what has merged to `main` since the latest release. The same notes are in"
        f" [CHANGELOG.md]({github_url(root, 'CHANGELOG.md')}) on GitHub.\n"
    )
    return f"{intro}\n{releases}" if releases else intro


def prepare(root: Path | None = None) -> Path:
    root = root or repo_root()
    dest = root / "site-docs"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir()
    docs = root / "docs"
    broken: list[str] = []

    def read(path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def write(path: Path, text: str, missing: list[str], source: str) -> None:
        path.write_text(text, encoding="utf-8")
        broken.extend(f"{source}: {target}" for target in sorted(set(missing)))

    for page in sorted(docs.glob("*.md")):
        missing: list[str] = []
        text = rewrite_text(read(page), from_root=False, root=root, missing=missing)
        write(dest / page.name, text, missing, f"docs/{page.name}")
    missing = []
    readme = rewrite_text(read(root / "README.md"), from_root=True, root=root, missing=missing)
    write(dest / ROOT_PAGES["README.md"], readme, missing, "README.md")
    missing = []
    notes = release_notes(read(root / "CHANGELOG.md"), root=root, missing=missing)
    write(dest / ROOT_PAGES["CHANGELOG.md"], notes, missing, "CHANGELOG.md")
    shutil.copytree(root / "images", dest / "images")
    if broken:
        raise SystemExit(
            "Relative links to paths that are not in the repo (fix the link, or add the file):\n  "
            + "\n  ".join(broken)
        )
    return dest


def main() -> None:
    dest = prepare()
    print(f"Wrote {dest}")


if __name__ == "__main__":
    main()
