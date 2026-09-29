# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Download MBTiles from the public RBT mirror by default ([#22](https://github.com/ReleasableBasemapTiles/rbt-local/pull/22))

### Changed

- Publish the guides on GitHub Pages ([#16](https://github.com/ReleasableBasemapTiles/rbt-local/pull/16))
- Add a release notes page to the docs site ([#20](https://github.com/ReleasableBasemapTiles/rbt-local/pull/20))
- Bump the github-actions group with 6 updates ([#19](https://github.com/ReleasableBasemapTiles/rbt-local/pull/19))
- Let the changelog workflow run by hand ([#21](https://github.com/ReleasableBasemapTiles/rbt-local/pull/21))
- Explain the public-mirror download and drop the credentials request
- [**breaking**] Remove the Helm chart, which now lives in its own repo
- Match the install guides' chmod to deploy.sh

### Fixed

- Load heading slugs from a hook file ([#17](https://github.com/ReleasableBasemapTiles/rbt-local/pull/17))
- Review fixes across deploy scripts, nginx, mapproxy, tileserver, chart, ci and docs ([#18](https://github.com/ReleasableBasemapTiles/rbt-local/pull/18))

## [2.0.1] - 2026-09-22

### Changed

- Update README to include release history and contribution guidelines
- Sync matching styles from upstream
- Sync matching styles from upstream ([#15](https://github.com/ReleasableBasemapTiles/rbt-local/pull/15))

### Fixed

- Read style.json on the Actions Python ([#14](https://github.com/ReleasableBasemapTiles/rbt-local/pull/14))

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

[unreleased]: https://github.com/ReleasableBasemapTiles/rbt-local/compare/v2.0.1..HEAD
[2.0.1]: https://github.com/ReleasableBasemapTiles/rbt-local/compare/v2.0.0..v2.0.1
[2.0.0]: https://github.com/ReleasableBasemapTiles/rbt-local/releases/tag/v2.0.0

