# Keeps non-finite coordinates out of Pillow's mesh transform, which segfaults
# a uWSGI worker on linux/amd64 when it is given one. Imported by app.py, and
# self-tested by Dockerfile.mapproxy at build time.
#
# The problem: MapProxy reprojects a tile by cutting it into small quads and
# asking PROJ where each quad corner lies in the source image
# (mapproxy/image/transform.py, transform_meshes). For a latitude beyond a
# pole, PROJ answers `inf` for EPSG:3857 and EPSG:4087 instead of failing
# loudly. This stack's geodetic (EPSG:4326) grid has 512px tiles and an
# origin in the north-west corner, so its level-0 tile is the whole world at
# 360 degrees tall: it runs from the north pole to 270 degrees south, and its
# lower half lies beyond the south pole. Every EPSG:4326 layer needs that tile
# for a world-sized request, and the `inf` coordinates go into Pillow's MESH
# transform. Python subtracts them while building each quad's coefficients,
# which turns them into NaN. Pillow's bounds check is written as
# `x < 0 || x >= size`, which a NaN passes, so the NaN reaches an integer
# conversion that is undefined in C. arm64 happens to give 0 and the tile
# renders; x86-64 gives INT_MIN, an out-of-bounds read, and the worker dies
# with signal 11 (nginx then answers 502, and the tile is never cached). It
# happens with every conda-forge Pillow from 11.3.0 to 13.0.0, so it is not a
# version to avoid.
#
# The guard drops every quad that has a non-finite source corner, so Pillow
# leaves that part of the tile transparent. In the level-0 tile that is the
# 128 quads beyond the pole, where there is no map to draw, and the 16 in the
# strip along it (rows 224 to 256 of 512, 67.5 to 90 degrees south), which do
# hold some map. arm64 already renders that strip blank, byte for byte on
# every EPSG:4326 tile of levels 0 to 3, and MapProxy leaves the strip along
# the north pole blank at this scale as well, where every coordinate is
# finite, so the world tile is blank within one quad of each pole with or
# without the guard. A request with no non-finite coordinate, which is every
# request except the level-0 tile, gets the meshes MapProxy made, untouched.
#
# Remove this when MapProxy or Pillow handles the case itself: running
# `python mesh_guard.py --unguarded` shows whether they do (it fails if a
# non-finite coordinate reaches Pillow, or segfaults on amd64).

import math
import sys

from PIL import Image

from mapproxy.image import ImageResult
from mapproxy.image import transform as mapproxy_transform
from mapproxy.image.opts import ImageOptions
from mapproxy.srs import SRS


def finite_meshes(meshes):
    """transform_meshes' result without the quads that have a non-finite source corner."""
    return [
        (quad, src_quad)
        for quad, src_quad in meshes
        if all(math.isfinite(value) for value in src_quad)
    ]


def install():
    """Wrap MapProxy's transform_meshes. Safe to call more than once."""
    original = mapproxy_transform.transform_meshes
    if getattr(original, 'drops_non_finite_quads', False):
        return

    def transform_meshes(*args, **kwargs):
        return finite_meshes(original(*args, **kwargs))

    transform_meshes.drops_non_finite_quads = True
    mapproxy_transform.transform_meshes = transform_meshes


def selftest():
    """Reproject a Web Mercator tile into the geodetic level-0 tile, which
    reaches past the south pole, as the EPSG:4326 caches do, and check what
    comes out.

    Unguarded, this segfaults on linux/amd64, which fails the image build
    (exit 139). The assertions after it cover the rest of what the guard has
    to get right: the quads it must keep are kept, the area beyond the pole is
    transparent, and no non-finite coordinate is left in the mesh (arm64 never
    crashes, so the mesh itself is the only thing that shows the guard is
    working there)."""
    world = 20037508.342789244
    world_bbox = (-world, -world, world, world)
    # 90 degrees north to 270 south: the equator is a quarter of the way down,
    # and the south pole halfway.
    tile_bbox = (-180.0, -270.0, 180.0, 90.0)
    web_mercator, geodetic = SRS(3857), SRS(4326)

    source = ImageResult(Image.new('RGBA', (512, 512), (240, 240, 240, 255)))
    result = mapproxy_transform.ImageTransformer(web_mercator, geodetic).transform(
        source, world_bbox, (512, 512), tile_bbox, ImageOptions(resampling='bicubic'))
    image = result.as_image()

    # Rows of the 512px tile, 0.703 degrees each: 60 is 48 north, 128 is the
    # equator, 200 is 51 south, 300 is 121 south (past the pole), 400 is 191.
    for row in (60, 128, 200):
        pixel = image.getpixel((256, row))
        assert pixel == (240, 240, 240, 255), f'row {row} should be drawn, is {pixel}'
    for row in (300, 400):
        pixel = image.getpixel((256, row))
        assert pixel[3] == 0, f'row {row} is beyond the pole and should be transparent, is {pixel}'

    meshes = mapproxy_transform.transform_meshes(
        (512, 512), world_bbox, web_mercator, (512, 512), tile_bbox, geodetic)
    assert meshes, 'the guard left no quads to draw'
    bad = [quad for quad, src_quad in meshes if not all(math.isfinite(v) for v in src_quad)]
    assert not bad, f'{len(bad)} of {len(meshes)} quads still have a non-finite source corner'
    print('mesh_guard self-test passed')


if __name__ == '__main__':
    if '--unguarded' not in sys.argv:
        install()
    selftest()
