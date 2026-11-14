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
| `cronjob.yaml`, `rotate-token.sh`, `rbac.yaml`, `token-secret.yaml` | the token rotation (below) |
| `networkpolicy.yaml` | default deny; per door: Traefik to 8080, the Omni exposer to 8081, the runners to 8082; the job reaches only the API |
| `podmonitor.yaml`, `prometheusrule.yaml` | metrics from the three health ports and five alerts |

## Token rotation

The app never writes the Secret and has no Kubernetes API token. Git creates the Secrets, empty (`token-secret.yaml`, one in
the fileserver namespace and one in the runner namespace, which the ARC runners read as `FILESERVER_TOKEN`), with the Flux
annotations `ssa: IfNotPresent` (created if missing, never updated by Flux, so Flux and the job never fight over the data) and
`prune: disabled` (removing the file from Git does not delete a live token). They hold no data, so they need no SOPS encryption.

The CronJob fills them with `curlimages/curl` (a busybox shell plus curl): `rotate-token.sh` reads the Secret, rotates when the
token is missing or older than 30 days, and patches the same three keys (`current`, `previous`, `rotated-at`) into both
namespaces with a JSON merge patch, so Flux's annotations and labels stay. It runs daily, so an edited copy is repaired the next
night. A Secret that was deleted by hand comes back empty at the next Flux reconcile (30 minutes) and the next run rotates it;
until then the job fails with a message saying so. The previous token stays valid for 24 hours so a job that started before a
rotation can still upload. The token is shown in the admin page and is never printed in the job's log.

RBAC (`rbac.yaml`): `get` and `patch` on the one Secret name, in those two namespaces, and nothing else. The job cannot create
a Secret, and it can read or change no other one.

The script is tested without a cluster: `python3 scripts/ci/test-rotate-token.py` runs it against a fake Secrets API (first fill
of the empty Secrets, no-op inside the period, repair of an edited copy, rotation keeping `previous`, metadata kept, a missing
Secret is an error and nothing is created, no token in the output). CI runs it and shellchecks the script.

## First deploy

1. **Image.** `deployment.yaml` pins `ghcr.io/cthtrifork/talos-gitops/fileserver:v0.12.0@sha256:c7cdcecf...` (built from the
   release commit, signed by `build-image.yaml`). The package is public, so there is no pull secret. A new release changes the
   tag and digest (Renovate proposes it).
2. **Tunnel hostname.** Cloudflare Zero Trust > Networks > Tunnels > the Traefik tunnel > Public hostname: `files.portableinfo.cloud`
   with service `HTTP` `localhost:8000`.
3. **First token.** Flux creates the Secrets empty. The pod starts without a token and refuses uploads until the job has filled it:
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
