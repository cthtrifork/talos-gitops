# fileserver

Public downloads, an admin page and a CI upload API in one pod. The app: `images/fileserver/README.md`.

| Port | Service | Reached by |
|---|---|---|
| 8080 public | `fileserver-public` | Traefik, `files.portableinfo.cloud` (read-only `public/`) |
| 8081 admin | `fileserver-admin` | the Omni exposer, prefix `files` |
| 8082 upload | `fileserver-upload` | the ARC runners only |

## Downloads from R2

The `r2-sync` container copies `public/` to a Cloudflare R2 bucket every minute (`rclone sync`, so a file deleted or moved to
private here is removed from the bucket too). Cloudflare serves the bucket on `shared-files.portableinfo.cloud`, so downloads never reach
the pod, Traefik or the node disk. It stays idle until the Secret `fileserver-r2` exists.

1. Cloudflare > R2: create a bucket, an API token with Object Read & Write on that bucket only, and note the account's S3 endpoint.
2. Add `fileserver-r2.enc.yaml` (SOPS, like the other `*.enc.yaml`) with `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
   `R2_ENDPOINT` (`https://<account-id>.r2.cloudflarestorage.com`) and `R2_BUCKET`, and list it in `kustomization.yaml`.
   Reloader restarts the pod. The pod is the source of truth: a file deleted or made private here disappears from the bucket
   within a minute or two. A sync that would delete more than 50 files fails (`--max-delete 50`) and is retried; raise it for a bulk clean-up.
3. Check `kubectl -n fileserver-system logs deploy/fileserver -c r2-sync` until the first sync has finished.
4. Cut over: bucket > Settings > Custom domains > add `shared-files.portableinfo.cloud` (it can run next to the tunnel hostname
   `files.portableinfo.cloud`, so compare both, then remove the tunnel hostname). Add a
   WAF rate-limiting rule and a Transform Rule for HSTS (the Traefik middlewares no longer apply). A follow-up PR removes the
   `public` container, the `fileserver-public` Service and the IngressRoute, and points `PUBLIC_URL` at the new host.

## Upload token

External Secrets generates the token (`k8s/infra/secret-store/generated-secrets.yaml`, a Password generator and a PushSecret
that replaces it every 30 days) in the namespace `secret-store`. An ExternalSecret in `fileserver-system` and one in
`arc-runners-system` (`external-secrets.yaml`) copy it into the Secret `fileserver-upload-token` within 15 minutes, and Reloader
restarts the fileserver. The runners read `FILESERVER_TOKEN` when they start; an upload that is running during
a rotation fails and is retried. The admin page shows the token.

## First deploy

1. Cloudflare Zero Trust > Networks > Tunnels > the Traefik tunnel > Public hostname: `files.portableinfo.cloud` to `HTTP localhost:8000`.
2. The token needs no action: External Secrets creates it on the first sync. To rotate it now, delete the key `current`
   in the Secret `secret-store/fileserver-upload-token`, or wait for the next 30 days.

## Upload from a workflow

```yaml
- run: |
    echo "::add-mask::$FILESERVER_TOKEN"
    curl --fail --retry 3 --max-time 3600 -T "$FILE" -H "Authorization: Bearer $FILESERVER_TOKEN" \
      -H "X-Content-SHA256: $(sha256sum "$FILE" | cut -d' ' -f1)" "$FILESERVER_URL/v1/files/$(basename "$FILE")"
```

Every job on those runners can read the token, so keep the runners private. Alerts are in `prometheusrule.yaml`.
