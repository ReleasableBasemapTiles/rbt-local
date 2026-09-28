#!/usr/bin/env python3
"""Build site-docs/ for MkDocs without changing the Markdown in git.

Copies docs/*.md, README.md (as index.md), CHANGELOG.md (as release-notes.md)
and images/ into site-docs/, then rewrites link targets so in-site pages stay
relative and everything else points at this repo on GitHub. Fenced code
blocks are left alone.
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


def github_url(root: Path, rel: str) -> str:
    cleaned = rel.strip("/")
    kind = "tree" if (root / cleaned).is_dir() else "blob"
    return f"{REPO_URL}/{kind}/main/{cleaned}"


def rewrite_url(url: str, *, from_root: bool, root: Path) -> str:
    if url.startswith(("http://", "https://", "mailto:", "#")):
        return url
    path, anchor = split_anchor(url)
    if from_root:
        if path.startswith("docs/"):
            return path.removeprefix("docs/") + anchor
        if path in ROOT_PAGES:
            return ROOT_PAGES[path] + anchor
        if path == "":
            return url
        return github_url(root, path) + anchor
    if not path.startswith("../"):
        return url
    rel = path.removeprefix("../")
    if rel in ROOT_PAGES:
        return ROOT_PAGES[rel] + anchor
    if rel.startswith("images/"):
        return rel + anchor
    return github_url(root, rel) + anchor


def rewrite_links(text: str, *, from_root: bool, root: Path) -> str:
    def replace(match: re.Match[str]) -> str:
        url = rewrite_url(match.group(2), from_root=from_root, root=root)
        return f"{match.group(1)}{url}{match.group(3)}"

    return LINK.sub(replace, text)


def rewrite_text(text: str, *, from_root: bool, root: Path) -> str:
    parts = FENCE.split(text)
    return "".join(
        part if part.startswith("```") else rewrite_links(part, from_root=from_root, root=root)
        for part in parts
    )


def release_notes(text: str, *, root: Path) -> str:
    """Swap CHANGELOG.md's git-cliff header for an introduction to the page."""
    first = RELEASE.search(text)
    releases = rewrite_text(text[first.start() :], from_root=True, root=root) if first else ""
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
    for page in sorted(docs.glob("*.md")):
        text = rewrite_text(page.read_text(), from_root=False, root=root)
        (dest / page.name).write_text(text)
    readme = rewrite_text((root / "README.md").read_text(), from_root=True, root=root)
    (dest / ROOT_PAGES["README.md"]).write_text(readme)
    notes = release_notes((root / "CHANGELOG.md").read_text(), root=root)
    (dest / ROOT_PAGES["CHANGELOG.md"]).write_text(notes)
    shutil.copytree(root / "images", dest / "images")
    return dest


def main() -> None:
    dest = prepare()
    print(f"Wrote {dest}")


if __name__ == "__main__":
    main()
