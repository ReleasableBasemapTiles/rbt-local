#!/usr/bin/env python3
"""Build site-docs/ for MkDocs without changing the Markdown in git.

Copies docs/*.md, README.md (as index.md), and images/ into site-docs/, then
rewrites link targets so in-site guides stay relative and everything else
points at this repo on GitHub. Fenced code blocks are left alone.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path

REPO_URL = "https://github.com/ReleasableBasemapTiles/rbt-local"
LINK = re.compile(r"(!?\[[^\]]*\]\()([^)\s]+)(\))")
FENCE = re.compile(r"(^```.*?^```)", re.MULTILINE | re.DOTALL)


def github_slug(value: str, separator: str = "-") -> str:
    """Match GitHub heading anchors, including doubled hyphens.

    GitHub drops punctuation and turns each remaining space into a hyphen,
    so "PowerShell + Chocolatey" becomes ``powershell--chocolatey``.
    """
    text = value.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.ASCII)
    return re.sub(r"\s", separator, text)


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


def rewrite_url(url: str, *, from_readme: bool, root: Path) -> str:
    if url.startswith(("http://", "https://", "mailto:", "#")):
        return url
    path, anchor = split_anchor(url)
    if from_readme:
        if path.startswith("docs/"):
            return path.removeprefix("docs/") + anchor
        if path == "":
            return url
        return github_url(root, path) + anchor
    if path == "../README.md":
        return "index.md" + anchor
    if path.startswith("../images/"):
        return "images/" + path.removeprefix("../images/") + anchor
    if path.startswith("../"):
        return github_url(root, path.removeprefix("../")) + anchor
    return url


def rewrite_links(text: str, *, from_readme: bool, root: Path) -> str:
    def replace(match: re.Match[str]) -> str:
        url = rewrite_url(match.group(2), from_readme=from_readme, root=root)
        return f"{match.group(1)}{url}{match.group(3)}"

    return LINK.sub(replace, text)


def rewrite_text(text: str, *, from_readme: bool, root: Path) -> str:
    parts = FENCE.split(text)
    return "".join(
        part if part.startswith("```") else rewrite_links(part, from_readme=from_readme, root=root)
        for part in parts
    )


def prepare(root: Path | None = None) -> Path:
    root = root or repo_root()
    dest = root / "site-docs"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir()
    docs = root / "docs"
    for page in sorted(docs.glob("*.md")):
        text = rewrite_text(page.read_text(), from_readme=False, root=root)
        (dest / page.name).write_text(text)
    readme = rewrite_text((root / "README.md").read_text(), from_readme=True, root=root)
    (dest / "index.md").write_text(readme)
    shutil.copytree(root / "images", dest / "images")
    return dest


def main() -> None:
    dest = prepare()
    print(f"Wrote {dest}")


if __name__ == "__main__":
    main()
