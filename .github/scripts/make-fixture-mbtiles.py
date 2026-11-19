#!/usr/bin/env python3
"""Write tiny fixture RBT.mbtiles and TERRAIN.mbtiles for the smoke test.

The real MBTiles are hundreds of GB, so CI can't download them. TileserverGL
only needs files it can open, so the smoke test (.github/workflows/smoke.yml)
runs the whole stack on these instead. The fixtures hold one empty vector
tile and one flat terrain tile, so every style draws only its background:
enough to prove the stack starts, the styles load, and a tile is rendered,
proxied and cached, and nothing more. They say nothing about the map data.

Writes tileserver/data/3857/ and tileserver/data/4087/ (both gitignored), the
two places the Compose files mount:

    python3 .github/scripts/make-fixture-mbtiles.py

It never overwrites an MBTiles file it didn't write: an existing file that
isn't one of these fixtures stops the script, so running it on a machine with
the real data can't destroy a download.
"""

from __future__ import annotations

import argparse
import gzip
import json
import sqlite3
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_MARK = "Fixture for CI smoke tests. Not map data."

# Web Mercator's extent, which the real RBT tiles also cover.
BOUNDS = "-180.0,-85.0511,180.0,85.0511"
CENTER = "0,0,0"


def png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """A solid-color RGB PNG, written with the standard library."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    row = b"\x00" + bytes(rgb) * width  # filter type 0 (none), then the pixels
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * height))
        + chunk(b"IEND", b"")
    )


def flat_terrain_tile() -> bytes:
    """A 256px terrain-RGB tile of zero elevation. With config.json's
    `encoding: mapbox`, elevation = -10000 + (R * 65536 + G * 256 + B) * 0.1,
    so 0 m is 100000 = (1, 134, 160)."""
    return png(256, 256, (1, 134, 160))


def is_fixture(path: Path) -> bool:
    """True when `path` is an MBTiles file this script wrote."""
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
            row = db.execute("SELECT value FROM metadata WHERE name = 'description'").fetchone()
    except sqlite3.Error:
        return False
    return bool(row) and row[0] == FIXTURE_MARK


def refuse_real_data(paths: list[Path]) -> None:
    """Stop before writing anything if any of `paths` exists and isn't a fixture.
    Checking them all first keeps a half-written mix of fixtures and real files
    from being left behind."""
    real = [path for path in paths if path.exists() and not is_fixture(path)]
    if real:
        sys.exit(
            "These exist and aren't fixtures this script wrote -- is it the real map data? "
            "Not touching anything. Move them away if you really want the fixtures:\n  "
            + "\n  ".join(str(path) for path in real)
        )


def write_mbtiles(path: Path, metadata: dict[str, str], tile: bytes) -> None:
    """One tile at z0/x0/y0, in the MBTiles schema (tile_row counts from the south)."""
    path.unlink(missing_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)

    db = sqlite3.connect(path)
    try:
        db.execute("CREATE TABLE metadata (name text, value text)")
        db.execute(
            "CREATE TABLE tiles (zoom_level integer, tile_column integer, "
            "tile_row integer, tile_data blob)"
        )
        db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
        db.executemany("INSERT INTO metadata VALUES (?, ?)", sorted(metadata.items()))
        db.execute("INSERT INTO tiles VALUES (0, 0, 0, ?)", (tile,))
        db.commit()
    finally:
        db.close()


def rbt_metadata() -> dict[str, str]:
    return {
        "name": "RBT fixture",
        "description": FIXTURE_MARK,
        "format": "pbf",
        "type": "baselayer",
        "version": "1",
        "minzoom": "0",
        "maxzoom": "0",
        "bounds": BOUNDS,
        "center": CENTER,
        "json": json.dumps({"vector_layers": [{"id": "fixture", "fields": {}}]}),
    }


def terrain_metadata() -> dict[str, str]:
    return {
        "name": "TERRAIN fixture",
        "description": FIXTURE_MARK,
        "format": "png",
        "type": "baselayer",
        "version": "1",
        "minzoom": "0",
        "maxzoom": "0",
        "bounds": BOUNDS,
        "center": CENTER,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=ROOT / "tileserver" / "data",
        help="the directory holding 3857/ and 4087/ (default: tileserver/data)",
    )
    args = parser.parse_args()

    # A vector tile with no layers is a valid, empty tile: zero bytes of
    # protobuf, gzipped the way MBTiles stores them.
    empty_vector_tile = gzip.compress(b"")
    directories = [args.data_dir / projection for projection in ("3857", "4087")]
    refuse_real_data(
        [d / name for d in directories for name in ("RBT.mbtiles", "TERRAIN.mbtiles")]
    )
    for directory in directories:
        write_mbtiles(directory / "RBT.mbtiles", rbt_metadata(), empty_vector_tile)
        write_mbtiles(directory / "TERRAIN.mbtiles", terrain_metadata(), flat_terrain_tile())
        print(f"wrote {directory / 'RBT.mbtiles'} and {directory / 'TERRAIN.mbtiles'}")


if __name__ == "__main__":
    main()
