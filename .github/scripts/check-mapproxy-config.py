#!/usr/bin/env python3
"""Load MapProxy's configs the way the image does, failing on any error.

Checks mapproxy/config/mapproxy.yaml and mapproxy.4087.yaml. Needs MapProxy
(the version Dockerfile.mapproxy installs).

    python3 .github/scripts/check-mapproxy-config.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from mapproxy.config.loader import load_configuration, load_configuration_file

ROOT = Path(__file__).resolve().parents[2]
CONFIG_DIR = ROOT / "mapproxy" / "config"


def merged(path: Path) -> dict:
    """The config after MapProxy resolves `base:`, minus the loader's own keys."""
    config = load_configuration_file([path.name], str(path.parent))
    config.pop("__config_files__", None)
    config.pop("base", None)
    return config


def duplicate_items(node: object, where: str = "") -> list[str]:
    """Strings listed twice in one list. MapProxy appends most lists an
    overlay restates (services.wms.srs, say) to the base file's."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            found += duplicate_items(value, f"{where}.{key}" if where else str(key))
    elif isinstance(node, list):
        strings = [item for item in node if isinstance(item, str)]
        found += [f"{where}: {item}" for item in sorted(set(strings)) if strings.count(item) > 1]
        for index, item in enumerate(node):
            found += duplicate_items(item, f"{where}[{index}]")
    return found


def check(path: Path, label: str) -> dict:
    # ignore_warnings=False turns unknown or misplaced keys into errors, and
    # configured_services() builds every grid, source, cache and layer.
    load_configuration(str(path), ignore_warnings=False).configured_services()
    config = merged(path)
    duplicates = duplicate_items(config)
    if duplicates:
        sys.exit(f"{label}: duplicate list items: {'; '.join(duplicates)}")
    print(f"OK {label}: {len(config['layers'])} layers, {len(config['caches'])} caches")
    return config


def main() -> None:
    check(CONFIG_DIR / "mapproxy.4087.yaml", "mapproxy/config/mapproxy.4087.yaml")
    check(CONFIG_DIR / "mapproxy.yaml", "mapproxy/config/mapproxy.yaml")


if __name__ == "__main__":
    main()
