# Patches the upstream MapProxy image's bundled PROJ. The 7.0.0-nginx tag
# ships pyproj 3.7.2 (PROJ 9.5.1), which predates the EPSG:4087 ellipsoidal
# fix (OSGeo/PROJ#4654, fixed in #4656, released in PROJ 9.8.0). EPSG:4087
# is registered under EPSG's ellipsoidal Equidistant Cylindrical method
# (1028), but PROJ before 9.8.0 always applied the spherical formula (1029)
# instead -- tiles reprojected from the EPSG:4087 caches (see
# docker-compose.4087.yaml) into EPSG:4326 land north of where they should,
# by an amount that grows with latitude. pyproj 3.8.0 bundles PROJ 9.8.1.
FROM ghcr.io/mapproxy/mapproxy/mapproxy:7.0.0-nginx
RUN pip install --upgrade pyproj==3.8.0
