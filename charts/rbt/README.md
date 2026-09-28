# rbt Helm Chart

Deploys the same three containers as the Compose EPSG:4087 stack ([docker-compose.yaml](../../docker-compose.yaml) plus the [docker-compose.4087.yaml](../../docker-compose.4087.yaml) overlay, run via `docker compose -f docker-compose.yaml -f docker-compose.4087.yaml up -d`) -- MapProxy plus two TileserverGL instances (EPSG:3857 and EPSG:4087), **with no nginx** (`docker-compose.override.yaml` is never part of this chart) -- onto Kubernetes/OpenShift. See [docs/deployment-openshift.md](../../docs/deployment-openshift.md) in the repo root for the full picture, including why EPSG:4087 improves EPSG:4326 output (the same reasoning as [docs/deployment-4087.md](../../docs/deployment-4087.md)).

This chart targets **OpenShift** specifically -- every Deployment's `securityContext` is written for OpenShift's `restricted-v2` SCC (see [OpenShift compatibility](#openshift-compatibility) below). It also renders on plain Kubernetes, with one caveat noted there.

## Before you install

Fonts, styles, and MBTiles have no safe generic default and must be set per-environment. Either:

- Set `s3.fontsUri`/`s3.stylesUri` (the shared trees both TileserverGL instances use) and `tileservers.<key>.s3.rbtUri`/`s3.terrainUri` (one pair per enabled projection), plus S3 credentials -- see [S3 credentials](#s3-credentials) below -- so the `fetch-s3` init container downloads them, or
- Pre-populate a PVC yourself (e.g. `oc rsync` of `RBT.mbtiles`, `TERRAIN.mbtiles`, `fonts/`, and `styles/`) and set `tileservers.<key>.persistence.existingClaim` to its name, leaving those URIs blank.

Upload the font and style trees with:

```bash
aws s3 sync tileserver/fonts  s3://my-bucket/fonts
aws s3 sync tileserver/styles s3://my-bucket/styles
```

## Installing

The MapProxy image is a private GHCR package (built by
[`.github/workflows/mapproxy-image.yml`](../../.github/workflows/mapproxy-image.yml)),
so the cluster needs a pull secret for it. Create one in the release's
namespace from a GitHub token with the `read:packages` scope (`kubectl create`
takes the same arguments):

```bash
oc create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<token>
```

Then install the chart from GHCR, where
[`.github/workflows/helm-chart.yml`](../../.github/workflows/helm-chart.yml)
publishes it (`Chart.yaml` version `0.3.0`):

```bash
# Private package -- once per machine / CI job
echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u USERNAME --password-stdin

helm install rbt oci://ghcr.io/releasablebasemaptiles/rbt-local/rbt --version 0.3.0 \
  --set 'imagePullSecrets[0].name=ghcr-pull' \
  --set s3.accessKeyId=<key> \
  --set s3.secretAccessKey=<secret> \
  --set s3.fontsUri=s3://my-bucket/fonts \
  --set s3.stylesUri=s3://my-bucket/styles \
  --set tileservers.epsg3857.s3.rbtUri=s3://my-bucket/exports \
  --set tileservers.epsg3857.s3.terrainUri=s3://my-bucket/exports \
  --set tileservers.epsg4087.s3.rbtUri=s3://my-bucket-4087/exports \
  --set tileservers.epsg4087.s3.terrainUri=s3://my-bucket-4087/exports
```

Or from the chart directory:

```bash
helm install rbt charts/rbt \
  --set 'imagePullSecrets[0].name=ghcr-pull' \
  --set s3.accessKeyId=<key> \
  --set s3.secretAccessKey=<secret> \
  --set s3.fontsUri=s3://my-bucket/fonts \
  --set s3.stylesUri=s3://my-bucket/styles \
  --set tileservers.epsg3857.s3.rbtUri=s3://my-bucket/exports \
  --set tileservers.epsg3857.s3.terrainUri=s3://my-bucket/exports \
  --set tileservers.epsg4087.s3.rbtUri=s3://my-bucket-4087/exports \
  --set tileservers.epsg4087.s3.terrainUri=s3://my-bucket-4087/exports
```

(Prefer a `-f myvalues.yaml` file over a wall of `--set` flags for anything beyond a quick test -- see `values.yaml` for every available key and its default.)

`helm install`/`upgrade` prints a NOTES block with rollout-status commands, Route URLs, and a "did MapProxy load the right config" check (see [docs/troubleshooting.md](../../docs/troubleshooting.md#the-4087-stack-is-up-but-epsg4326-tiles-look-unchanged)). Run `helm test rbt --logs` afterwards as a smoke test: in-cluster, it fetches MapProxy's WMTS capabilities plus one EPSG:3857 and one EPSG:4326 tile, so it fails if MapProxy can't reach a TileserverGL instance, not only if MapProxy itself is down.

## Single-TileserverGL mode

Set `tileservers.epsg4087.enabled=false` to deploy the plain-`mapproxy.yaml` equivalent of [docker-compose.yaml](../../docker-compose.yaml) on its own instead (one TileserverGL instance, EPSG:4326 reprojected from EPSG:3857) -- the Kubernetes/OpenShift analog of [docs/advanced-deployment.md](../../docs/advanced-deployment.md)'s no-nginx deployment. Everything else (Routes, PVCs, S3 config) works the same way, just without the `epsg4087` instance.

## S3 credentials

The `fetch-s3` init container on each TileserverGL pod authenticates to S3 the same way `aws s3 cp`/`sync` always do -- from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in its environment. By default the chart templates a Secret from `s3.accessKeyId`/`s3.secretAccessKey`; set `s3.existingSecret` to the name of a Secret you created yourself (with `access-key-id`/`secret-access-key` keys) to skip that. `s3.endpointUrl`/`s3.region` cover an S3-compatible store other than AWS itself.

If every `tileservers.<key>.s3.rbtUri`/`s3.terrainUri` and `s3.fontsUri`/`s3.stylesUri` is blank (e.g. both instances use `persistence.existingClaim` instead), the init container's fetch script no-ops before ever using these credentials -- you don't need real values in that case, the templated Secret's blank defaults are enough.

## OpenShift compatibility

Every pod's `securityContext` (see `podSecurityContext`/`containerSecurityContext` in `values.yaml`) deliberately omits `runAsUser`/`fsGroup`. OpenShift's `restricted-v2` SCC injects both from the namespace's allocated range *before* the kubelet's `runAsNonRoot` check runs, so this works regardless of what user each image's own `Dockerfile` declares -- this repo's MapProxy image (`USER 1000`), the `tileserver-gl` image (the named user `node`), and the `aws-cli` and `busybox` images (root by default) alike. Volumes (PVCs, `emptyDir`) need no extra `chgrp` treatment, since the SCC's `fsGroup` strategy makes them group-writable automatically.

### Vanilla Kubernetes (without an SCC)

Without an SCC to inject `runAsUser`, `runAsNonRoot: true` (the default) makes the kubelet refuse to start any container it can't prove runs as a non-root UID. The `aws-cli` init containers and the `busybox` test pod run as root, and the `tileserver-gl` image's `USER node:node` is a name the kubelet can't check (it fails with `CreateContainerConfigError`). Only this repo's MapProxy image declares a numeric `USER 1000`. So set a non-root `containerSecurityContext.runAsUser` and `podSecurityContext.fsGroup` yourself -- `1000` for both, say. Any non-root UID works, as OpenShift's arbitrary per-namespace UIDs show: the chart points `HOME` at `/tmp`, and `fsGroup` makes the mounted volumes writable by that UID.

## Why `charts/rbt/files/` duplicates repo-root configs

Helm's `.Files.Get` can only read files inside the chart directory, and its loader skips symlinks -- so `charts/rbt/files/mapproxy/*` and `charts/rbt/files/tileserver/config.json` are plain copies of `mapproxy/config/*` and `tileserver/config/config.json`, not references to them. Run `./charts/rbt/sync-files.sh` after editing any of those five source files, then re-run `helm template`/`helm lint` to confirm the change took effect; `./charts/rbt/sync-files.sh --check` diffs instead of copying (non-zero exit on drift), for a future CI gate.

`mapproxy.yaml`/`mapproxy.4087.yaml`'s hardcoded `http://tileservergl:8080/...`/`http://tileservergl4087:8080/...` source URLs *are* rewritten at template time (see `templates/configmap-mapproxy.yaml`) to whatever `tileservers.epsg3857/epsg4087.serviceName`/`containerPort` are actually set to -- that part doesn't need hand-editing after a sync.

The MapProxy image loads `/mapproxy/config/mapproxy.yaml`, so with `tileservers.epsg4087.enabled` the ConfigMap ships `mapproxy.4087.yaml` under that name, and the plain `mapproxy.yaml` it includes (via `base:`) as `mapproxy.base.yaml`. Compose selects `mapproxy.4087.yaml` with the image's `MAPPROXY_CONFIG` variable instead, but the chart doesn't rely on it: the image tag is reused and pulled `IfNotPresent`, and an older image left on a node ignores `MAPPROXY_CONFIG`.

## Known limitations

- **Service names are literal, not release-scoped.** `tileservers.epsg3857/epsg4087.serviceName` default to the exact `tileservergl`/`tileservergl4087` container names the Compose stacks use, unprefixed by the release name (unlike every other resource this chart creates) -- MapProxy's rewritten source URLs need a fixed hostname to target, and this keeps that hostname identical to the Compose deployment's. Two `rbt` releases in the same namespace will collide on these two Service names; set `tileservers.<key>.serviceName` on one of them if you need that.
- **No Compose-style `depends_on: condition: service_healthy` equivalent.** MapProxy's Deployment doesn't wait for either TileserverGL Deployment to be healthy before starting. This matches how MapProxy actually behaves, though: it doesn't eagerly connect to its tile sources at startup, so it comes up fine regardless of ordering and only fails the specific requests it can't yet fetch a source tile for (HTTP 500 for a WMTS tile), self-healing once TileserverGL is ready -- no crash-loop risk. `oc logs` on `mapproxy` if tiles keep failing for longer than TileserverGL's own startup should reasonably take (its `startupProbe` allows up to 240s).
- **`networkPolicy.enabled` (default `false`) is a starting point, not a hardened default.** Each pod accepts traffic from this release's own pods. MapProxy and each Route-enabled TileserverGL also accept their own port from any source, since Route traffic comes from the router and this chart can't reliably `podSelector`-match every OpenShift router's namespace (see the comment in `templates/networkpolicy.yaml`). Egress isn't restricted.
- **PVC sizes (`tileservers.<key>.persistence.size`, default `200Gi`) are a starting point, not a measured figure** -- ask the RBT team for current `RBT.mbtiles`/`TERRAIN.mbtiles` sizes (see the repo root README's "Get S3 Credentials" section) and size accordingly; the datasets are updated periodically.
- **No tile cache.** MapProxy stores no tiles (every cache in `mapproxy.yaml` sets `disable_storage`), and the Compose deployment's nginx cache isn't part of this chart, so TileserverGL renders every request. For heavy traffic, put a CDN or caching reverse proxy in front of the MapProxy Route -- `nginx/config/nginx.conf` shows the cache policy the Compose deployment uses.
