# rbt Helm Chart

Deploys the same three containers as [docker-compose.4087.yaml](../../docker-compose.4087.yaml) run via `docker compose -f docker-compose.4087.yaml up -d` -- MapProxy plus two TileserverGL instances (EPSG:3857 and EPSG:4087), **with no nginx** (`docker-compose.override.yaml` is never part of this chart) -- onto Kubernetes/OpenShift. See [docs/deployment-openshift.md](../../docs/deployment-openshift.md) in the repo root for the full picture, including why EPSG:4087 improves EPSG:4326 output (the same reasoning as [docs/deployment-4087.md](../../docs/deployment-4087.md)).

This chart targets **OpenShift** specifically -- every Deployment's `securityContext` is written for OpenShift's `restricted-v2` SCC (see [OpenShift compatibility](#openshift-compatibility) below). It also renders on plain Kubernetes, with one caveat noted there.

## Before you install

Two things have no safe generic default and must be set per-environment:

1. **An assets image.** `tileserver/fonts` (114MB) and `tileserver/styles` (5MB) are binary, static assets -- too large and the wrong shape for a ConfigMap. Build and push [Dockerfile.assets](../../Dockerfile.assets) from the repo root first:

   ```bash
   docker build -f Dockerfile.assets -t <registry>/<repo>/rbt-assets:<tag> .
   docker push <registry>/<repo>/rbt-assets:<tag>
   ```

   `helm template`/`install` fails immediately with a clear error if `assets.image.repository`/`assets.image.tag` are left unset, rather than deploying a pod with a broken `image: ":"` reference.

2. **RBT.mbtiles/TERRAIN.mbtiles**, one pair per enabled projection. Either:
   - Set `tileservers.<key>.s3.rbtUri`/`s3.terrainUri` (and S3 credentials -- see [S3 credentials](#s3-credentials) below) so the init container downloads them, mirroring [deploy.sh](../../deploy.sh)'s own download step, or
   - Pre-populate a PVC yourself (e.g. `oc rsync`) and set `tileservers.<key>.persistence.existingClaim` to its name, leaving `s3.rbtUri`/`s3.terrainUri` blank.

## Installing

From a checkout of this repo (`charts/rbt`), or from GHCR after
[`.github/workflows/helm-chart.yml`](../../.github/workflows/helm-chart.yml)
publishes the chart (`Chart.yaml` version `0.1.0`):

```bash
# Private package -- once per machine / CI job
echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u USERNAME --password-stdin

helm install rbt oci://ghcr.io/releasablebasemaptile/rbt-local/rbt --version 0.1.0 \
  --set assets.image.repository=<registry>/<repo>/rbt-assets \
  --set assets.image.tag=<tag> \
  --set s3.accessKeyId=<key> \
  --set s3.secretAccessKey=<secret> \
  --set tileservers.epsg3857.s3.rbtUri=s3://my-bucket/exports \
  --set tileservers.epsg3857.s3.terrainUri=s3://my-bucket/exports \
  --set tileservers.epsg4087.s3.rbtUri=s3://my-bucket-4087/exports \
  --set tileservers.epsg4087.s3.terrainUri=s3://my-bucket-4087/exports
```

Or from the chart directory:

```bash
helm install rbt charts/rbt \
  --set assets.image.repository=<registry>/<repo>/rbt-assets \
  --set assets.image.tag=<tag> \
  --set s3.accessKeyId=<key> \
  --set s3.secretAccessKey=<secret> \
  --set tileservers.epsg3857.s3.rbtUri=s3://my-bucket/exports \
  --set tileservers.epsg3857.s3.terrainUri=s3://my-bucket/exports \
  --set tileservers.epsg4087.s3.rbtUri=s3://my-bucket-4087/exports \
  --set tileservers.epsg4087.s3.terrainUri=s3://my-bucket-4087/exports
```

(Prefer a `-f myvalues.yaml` file over a wall of `--set` flags for anything beyond a quick test -- see `values.yaml` for every available key and its default.)

`helm install`/`upgrade` prints a NOTES block with rollout-status commands, Route URLs, and the same "did MapProxy load the right config" check [docs/deployment-4087.md](../../docs/deployment-4087.md) documents for the Compose deployment. Run `helm test rbt` afterwards to fetch WMTS capabilities from MapProxy in-cluster as a smoke test.

## Single-TileserverGL mode

Set `tileservers.epsg4087.enabled=false` to deploy the plain-`mapproxy.yaml` equivalent of [docker-compose.yaml](../../docker-compose.yaml) instead (one TileserverGL instance, EPSG:4326 reprojected from EPSG:3857) -- the Kubernetes/OpenShift analog of [docs/advanced-deployment.md](../../docs/advanced-deployment.md)'s no-nginx deployment. Everything else (Routes, PVCs, S3 config) works the same way, just without the `epsg4087` instance.

## S3 credentials

The `fetch-mbtiles` init container on each TileserverGL pod authenticates to S3 the same way `aws s3 cp` always does -- from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in its environment. By default the chart templates a Secret from `s3.accessKeyId`/`s3.secretAccessKey`; set `s3.existingSecret` to the name of a Secret you created yourself (with `access-key-id`/`secret-access-key` keys) to skip that. `s3.endpointUrl`/`s3.region` cover an S3-compatible store other than AWS itself.

If every `tileservers.<key>.s3.rbtUri`/`s3.terrainUri` is blank (e.g. both instances use `persistence.existingClaim` instead), the init container's fetch script no-ops before ever using these credentials -- you don't need real values in that case, the templated Secret's blank defaults are enough.

## OpenShift compatibility

Every pod's `securityContext` (see `podSecurityContext`/`containerSecurityContext` in `values.yaml`) deliberately omits `runAsUser`/`fsGroup`. OpenShift's `restricted-v2` SCC injects both from the namespace's allocated range *before* the kubelet's `runAsNonRoot` check runs, so this works regardless of what user each image's own `Dockerfile` declares -- including the upstream `mapproxy`/`tileserver-gl` images (named non-root users, `mapproxy`/`node`) and the `aws-cli` image (root by default) alike. The one image this chart builds (`Dockerfile.assets`) uses a numeric `USER 1001` and group-owns its files (`chgrp -R 0 && chmod -R g=u`) per [OpenShift's image guidelines](https://docs.openshift.com/container-platform/latest/openshift_images/create-images.html#images-create-guide-openshift_create-images) -- volumes (PVCs, `emptyDir`) need no such treatment, since the SCC's `fsGroup` strategy makes them group-writable automatically.

### Vanilla Kubernetes (without an SCC)

Without an SCC to inject `runAsUser`, `containerSecurityContext.runAsNonRoot: true` (the default) makes the kubelet refuse to start any container whose *effective* user resolves to root -- including the `mapproxy`/`tileserver-gl`/`aws-cli` containers above, if their images happen to default to root or a user Kubernetes can't already tell is non-zero. You'll need to set `containerSecurityContext.runAsUser` (and `podSecurityContext.fsGroup`, so mounted volumes are writable by that UID) to a concrete numeric UID yourself -- Kubernetes' `runAsUser` field takes a number, not the `mapproxy`/`node` usernames those two Dockerfiles declare, and there's no single value this chart can default to that's guaranteed correct for every image and cluster. Recent tags of both upstream images run their main process as UID `1000` (macOS Docker Desktop tolerates this transparently, which is why the Compose deployment never had to think about it) -- check `docker image inspect --format '{{.Config.User}}' <image>` against a real container run if you need the current values.

## Assets image

See [Before you install](#before-you-install) above for the build command. Rebuild and push a new tag whenever `tileserver/fonts` or `tileserver/styles` change -- nothing in this repo automates that for you. The chart runs this image as an init container that copies `/assets/fonts` and `/assets/styles` into a shared `emptyDir`, since Kubernetes has no "mount this other image's filesystem into that container" primitive the way a Compose bind mount does.

## Why `charts/rbt/files/` duplicates repo-root configs

Helm's `.Files.Get` can only read files inside the chart directory, and its loader skips symlinks -- so `charts/rbt/files/mapproxy/*` and `charts/rbt/files/tileserver/config.json` are plain copies of `mapproxy/config/*` and `tileserver/config/config.json`, not references to them. Run `./charts/rbt/sync-files.sh` after editing any of those five source files, then re-run `helm template`/`helm lint` to confirm the change took effect; `./charts/rbt/sync-files.sh --check` diffs instead of copying (non-zero exit on drift), for a future CI gate.

`mapproxy.yaml`/`mapproxy.4087.yaml`'s hardcoded `http://tileservergl:8080/...`/`http://tileservergl4087:8080/...` source URLs *are* rewritten at template time (see `templates/configmap-mapproxy.yaml`) to whatever `tileservers.epsg3857/epsg4087.serviceName`/`containerPort` are actually set to -- that part doesn't need hand-editing after a sync.

## Known limitations

- **Service names are literal, not release-scoped.** `tileservers.epsg3857/epsg4087.serviceName` default to the exact `tileservergl`/`tileservergl4087` container names `docker-compose.4087.yaml` uses, unprefixed by the release name (unlike every other resource this chart creates) -- MapProxy's rewritten source URLs need a fixed hostname to target, and this keeps that hostname identical to the Compose deployment's. Two `rbt` releases in the same namespace will collide on these two Service names; set `tileservers.<key>.serviceName` on one of them if you need that.
- **No Compose-style `depends_on: condition: service_healthy` equivalent.** MapProxy's Deployment doesn't wait for either TileserverGL Deployment to be healthy before starting. This matches how MapProxy actually behaves, though: it doesn't eagerly connect to its tile sources at startup, so it comes up fine regardless of ordering and only 502s the specific tiles it can't yet fetch, self-healing once TileserverGL is ready -- no crash-loop risk. `oc logs` on `mapproxy` if tiles 502 for longer than TileserverGL's own startup should reasonably take (its `startupProbe` allows up to 240s).
- **`networkPolicy.enabled` (default `false`) is a starting point, not a hardened default** -- see the comment in `templates/networkpolicy.yaml` for the one gap it knowingly leaves (it can't reliably `podSelector`-match every OpenShift router's namespace, so Route-exposed ports stay open to any source rather than guessing at those labels).
- **PVC sizes (`tileservers.<key>.persistence.size`, default `200Gi`) are a starting point, not a measured figure** -- ask the RBT team for current `RBT.mbtiles`/`TERRAIN.mbtiles` sizes (see the repo root README's "Get S3 Credentials" section) and size accordingly; the datasets are updated periodically.
- **MapProxy's tile cache is an ephemeral `emptyDir`**, not a PVC -- it rebuilds from the TileserverGL sources on every pod restart. See the comment above `cache` in `templates/deployment-mapproxy.yaml` if you'd rather it survive restarts (swap for a PVC and change `strategy: RollingUpdate` to `Recreate` if that PVC is ReadWriteOnce).
