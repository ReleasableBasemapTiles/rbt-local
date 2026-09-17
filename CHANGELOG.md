# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Update README to include release history and contribution guidelines

## [2.0.0] - 2026-09-17

### Added

- Add native Windows 11 PowerShell deploy script (Chocolatey, no WSL2)
- Add macOS/Fedora support to deploy.sh, .env loading, and split docs by OS
- Add EPSG:4087 dual-TileserverGL deployment for sharper EPSG:4326 output
- Add a Helm chart for OpenShift/Kubernetes deployment

### Changed

- Init
- Expose the three canvas styles through MapProxy
- Advertise EPSG:3395 on the WMS service
- Make the docs describe the projections MapProxy actually serves
- Expose every style natively in EPSG:4326 through MapProxy
- Update LICENSE.md to remove references to the Army Geospatial Center (AGC) and streamline attribution details for Releasable Basemap Tiles (RBT) Styles. Adjusted example attribution link and clarified licensing terms for design features and sprites.
- Document all four deployment options and fix a with/without-nginx mixup
- Update README.md to clarify EPSG layer mappings in flowchart
- Update client connections in README
- Update MapProxy and TileserverGL configurations for improved performance and accuracy
- Refactor deployment scripts to build and pull Docker images for MapProxy
- Refactor Helm chart for S3 integration and remove Dockerfile.assets

### Fixed

- Fix the --4087 stack silently ignoring mapproxy.4087.yaml

[unreleased]: https://github.com/ReleasableBasemapTiles/rbt-local/compare/v2.0.0..HEAD
[2.0.0]: https://github.com/ReleasableBasemapTiles/rbt-local/releases/tag/v2.0.0

