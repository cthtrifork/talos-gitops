# fileserver

A small file server. First use: `homeserver-bootc` uploads its disk images here instead of to Azure. The application and its
design are in `images/fileserver/README.md`; this directory deploys it.

```
internet -> Cloudflare -> tunnel -> Traefik (rateLimit, inFlightReq) -> fileserver-public :8080        read-only, public/ only
operator -> Omni service exposer ------------------------------------> fileserver-admin  :8081        whole volume, shows the token
ARC runner (arc-runners-system) -------------------------------------> fileserver-upload :8082        whole volume, bearer token
CronJob fileserver-rotate (busybox shell + curl) --> Kubernetes API --> Secret fileserver-upload-token in
                                                       fileserver (admin, upload mount it) and arc-runners-system (runners get $FILESERVER_TOKEN)
```

| File | What |
|---|---|
| `namespace.yaml` | `fileserver`, pod security `restricted` |
| `pvc.yaml` | 20 Gi on the default node-local class (the size is a hint: watch the real free space) |
| `deployment.yaml` | one pod, three containers (public, admin, upload) from one image, `subPath` mounts, `Recreate` |
| `service.yaml` | one Service per port; the admin one carries the Omni exposer annotations (prefix `files`, port 50093) |
| `ingressroute.yaml` | `files.portableinfo.cloud` to the public port only, with rate limit, in-flight limit and headers |
| `cronjob.yaml`, `rotate-token.sh`, `rbac.yaml` | the token rotation (below) |
| `networkpolicy.yaml` | default deny; per door: Traefik to 8080, the Omni exposer to 8081, the runners to 8082; the job reaches only the API |
| `podmonitor.yaml`, `prometheusrule.yaml` | metrics from the three health ports and five alerts |

## Token rotation

The app never writes the Secret and has no Kubernetes API token. The CronJob does it with `curlimages/curl` (a busybox shell
plus curl): `rotate-token.sh` reads the Secret through the API, rotates it when it is missing or older than 30 days, and writes
the same data to the fileserver and runner namespaces (the second one is what the ARC runners read as `FILESERVER_TOKEN`). It
runs daily, so a deleted or edited copy is repaired the next night. The previous token stays valid for 24 hours so a job that
started before a rotation can still upload. The token is shown in the admin page and is never printed in the job's log.

RBAC (`rbac.yaml`): `get` and `update` on the one Secret name, and `create`, in those two namespaces. `create` cannot be limited
to a name, so the job can create other Secrets there; it can read or change none of the existing ones.

The script is tested without a cluster: `python3 scripts/ci/test-rotate-token.py` runs it against a fake Secrets API (first
creation, no-op inside the period, repair of a deleted or edited copy, rotation keeping `previous`, no token in the output).
CI runs it and shellchecks the script.

## First deploy

1. **Image.** `deployment.yaml` references `ghcr.io/cthtrifork/talos-gitops/fileserver:v0.0.0`, a placeholder. Release the image
   (`docs/releasing.md`), then put the released tag and digest there. If the package is private, the namespace also needs an image
   pull secret (SOPS, as `claude-system/ghcr-pull`).
2. **Tunnel hostname.** Cloudflare Zero Trust > Networks > Tunnels > the Traefik tunnel > Public hostname: `files.portableinfo.cloud`
   with service `HTTP` `localhost:8000`.
3. **First token.** The pod starts without the Secret (it is optional) and refuses uploads until it exists:
   `kubectl -n fileserver create job --from=cronjob/fileserver-rotate rotate-first`, then
   `kubectl -n fileserver logs job/rotate-first`.
4. **Runners.** The two runner scale sets in `arc-runner/` read the token at pod start. Restart idle runners once after the first
   token, or wait for the next job.

## Using it from a workflow

On `runs-on: arc-ubuntu` the runner has `FILESERVER_URL` and `FILESERVER_TOKEN`:

```yaml
- run: |
    echo "::add-mask::$FILESERVER_TOKEN"
    SUM=$(sha256sum "$FILE" | cut -d" " -f1)
    curl --fail --retry 3 --retry-all-errors --max-time 3600 -T "$FILE" \
      -H "Authorization: Bearer $FILESERVER_TOKEN" -H "X-Content-SHA256: $SUM" \
      "$FILESERVER_URL/v1/files/$(basename "$FILE")?visibility=private"
```

Every job on those runners can read the token, not only one repository. Keep the runners private.

## Alerts

`FileserverTokenRotationOverdue` (over 32 days), `FileserverNoToken`, `FileserverRotationJobFailed`, `FileserverDiskLow` (under
9 GiB free: a file is at most 8 GiB and an overwrite needs a temporary copy), `FileserverDown`. There is no Alertmanager; read them
from Prometheus.

## Check

```sh
kubectl -n fileserver get pods,cronjob,pvc
kubectl -n fileserver get secret fileserver-upload-token -o jsonpath='{.metadata.labels}'
kubectl -n arc-runners-system get secret fileserver-upload-token
curl -sI https://files.portableinfo.cloud/does-not-exist   # 404 from the app
```
