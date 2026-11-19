#!/usr/bin/env python3
"""Load MapProxy's configs the way the image does, failing on any error.

Checks mapproxy/config/mapproxy.yaml and mapproxy.4087.yaml. Needs MapProxy
(the version Dockerfile.mapproxy installs). Besides loading them, it checks
the MapProxy rules in CLAUDE.md's "Invariants", on each config as MapProxy
merges it:

- every cache sets `disable_storage: true`, so MapProxy stores nothing and
  nginx stays the only tile cache;
- every grid is `origin: nw` with 512px tiles (WMTS silently drops other
  origins; 512px matches TileserverGL's /styles/<ID>/512/ URLs);
- only the overlay sources are `transparent: true`;
- the EPSG:3395 and EPSG:4326 caches reproject in one hop from the matching
  EPSG:3857 cache (EPSG:4326 from the matching EPSG:4087 cache in the 4087
  config), never through each other.

    python3 .github/scripts/check-mapproxy-config.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from mapproxy.config.loader import load_configuration, load_configuration_file

ROOT = Path(__file__).resolve().parents[2]
CONFIG_DIR = ROOT / "mapproxy" / "config"

REPROJECTED_CACHE = re.compile(r"rbt_(?P<style>[a-z]+)_(?P<srs>3395|4326)_cache")


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


def invariant_problems(config: dict, *, srs4326_from: str) -> list[str]:
    """Where `config` breaks one of CLAUDE.md's MapProxy invariants.

    `srs4326_from` is the EPSG code (3857 or 4087) whose caches feed the
    EPSG:4326 ones in this config.
    """
    problems = []

    for name, cache in config["caches"].items():
        if cache.get("disable_storage") is not True:
            problems.append(
                f"cache {name}: needs disable_storage: true (MapProxy stores nothing; "
                "nginx is the only tile cache)"
            )

    for name, grid in config["grids"].items():
        if grid.get("origin") != "nw":
            problems.append(f"grid {name}: origin must be nw (WMTS silently drops the others)")
        if list(grid.get("tile_size") or []) != [512, 512]:
            problems.append(
                f"grid {name}: tile_size must be [512, 512] to match TileserverGL's 512px URLs"
            )

    for name, source in config["sources"].items():
        overlay = name.startswith("rbt_overlay_")
        transparent = source.get("transparent") is True
        if overlay and not transparent:
            problems.append(f"source {name}: the overlay source must set transparent: true")
        if transparent and not overlay:
            problems.append(f"source {name}: only the overlay sources may set transparent: true")

    reprojected = 0
    for name, cache in config["caches"].items():
        match = REPROJECTED_CACHE.fullmatch(name)
        if not match:
            continue
        reprojected += 1
        parent = srs4326_from if match["srs"] == "4326" else "3857"
        expected = [f"rbt_{match['style']}_{parent}_cache"]
        if cache.get("sources") != expected:
            problems.append(
                f"cache {name}: sources must be {expected} (one reprojection hop, never "
                f"through EPSG:3395), found {cache.get('sources')}"
            )
    if not reprojected:
        problems.append("no rbt_<style>_3395_cache or _4326_cache caches found to check")

    return problems


def check(path: Path, label: str, *, srs4326_from: str) -> None:
    # ignore_warnings=False turns unknown or misplaced keys into errors, and
    # configured_services() builds every grid, source, cache and layer.
    load_configuration(str(path), ignore_warnings=False).configured_services()
    config = merged(path)
    duplicates = duplicate_items(config)
    if duplicates:
        sys.exit(f"{label}: duplicate list items: {'; '.join(duplicates)}")
    problems = invariant_problems(config, srs4326_from=srs4326_from)
    if problems:
        sys.exit(f"{label}:\n  " + "\n  ".join(problems))
    print(f"OK {label}: {len(config['layers'])} layers, {len(config['caches'])} caches")


def main() -> None:
    check(
        CONFIG_DIR / "mapproxy.4087.yaml",
        "mapproxy/config/mapproxy.4087.yaml",
        srs4326_from="4087",
    )
    check(CONFIG_DIR / "mapproxy.yaml", "mapproxy/config/mapproxy.yaml", srs4326_from="3857")


if __name__ == "__main__":
    main()
