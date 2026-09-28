#!/usr/bin/env python3
"""Load MapProxy's configs the way the image does, failing on any error.

Checks mapproxy/config/mapproxy.yaml and mapproxy.4087.yaml, then the Helm
chart's rendering of them (charts/rbt/templates/configmap-mapproxy.yaml)
with tileservers.epsg4087.enabled on and off, which must merge to the same
config as the repo file it ships. Needs MapProxy (the version
Dockerfile.mapproxy installs) and helm on PATH.

    python3 .github/scripts/check-mapproxy-config.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import yaml
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


def render_chart(enabled: bool, dest: Path) -> Path:
    """Writes the chart's MapProxy ConfigMap files to dest, as the pod sees them."""
    rendered = subprocess.run(
        ["helm", "template", "ci", str(ROOT / "charts" / "rbt"),
         "--show-only", "templates/configmap-mapproxy.yaml",
         "--set", f"tileservers.epsg4087.enabled={str(enabled).lower()}"],
        check=True, capture_output=True, text=True,
    ).stdout
    for name, text in yaml.safe_load(rendered)["data"].items():
        (dest / name).write_text(text)
    return dest / "mapproxy.yaml"


def main() -> None:
    repo_configs = {
        True: check(CONFIG_DIR / "mapproxy.4087.yaml", "mapproxy/config/mapproxy.4087.yaml"),
        False: check(CONFIG_DIR / "mapproxy.yaml", "mapproxy/config/mapproxy.yaml"),
    }
    for enabled, expected in repo_configs.items():
        label = f"chart with tileservers.epsg4087.enabled={str(enabled).lower()}"
        with tempfile.TemporaryDirectory() as tmp:
            if check(render_chart(enabled, Path(tmp)), label) != expected:
                sys.exit(f"{label}: mapproxy.yaml doesn't merge to the same config as the repo file")


if __name__ == "__main__":
    main()
