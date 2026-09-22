"""MkDocs hook loaded by file path, not as an installed package."""

from __future__ import annotations

import re


def github_slug(value: str, separator: str = "-") -> str:
    """Match GitHub heading anchors, including doubled hyphens.

    GitHub drops punctuation and turns each remaining space into a hyphen,
    so "PowerShell + Chocolatey" becomes ``powershell--chocolatey``.
    """
    text = value.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.ASCII)
    return re.sub(r"\s", separator, text)


def on_config(config):
    config.mdx_configs.setdefault("toc", {})["slugify"] = github_slug
    return config
