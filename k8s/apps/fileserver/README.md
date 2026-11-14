# fileserver

Public downloads, an admin page and a CI upload API in one pod. The app: `images/fileserver/README.md`.

| Port | Service | Reached by |
|---|---|---|
| 8080 public | `fileserver-public` | Traefik, `files.portableinfo.cloud` (read-only `public/`) |
| 8081 admin | `fileserver-admin` | the Omni exposer, prefix `files` |
| 8082 upload | `fileserver-upload` | the ARC runners only |

## Upload token

Git creates two empty `fileserver-upload-token` Secrets (`token-secret.yaml`: here and in `arc-runners-system`). On the 1st of
each month the CronJob writes a new token into both (a few lines of `curl` in `cronjob.yaml`; its RBAC is `patch` on that Secret
only) and Reloader restarts the fileserver. The runners read `FILESERVER_TOKEN` when they start; an upload that is running during
a rotation fails and is retried. The admin page shows the token.

## First deploy

1. Cloudflare Zero Trust > Networks > Tunnels > the Traefik tunnel > Public hostname: `files.portableinfo.cloud` to `HTTP localhost:8000`.
2. Fill the token once: `kubectl -n fileserver-system create job --from=cronjob/fileserver-rotate rotate-first`.

## Upload from a workflow

```yaml
- run: |
    echo "::add-mask::$FILESERVER_TOKEN"
    curl --fail --retry 3 --max-time 3600 -T "$FILE" -H "Authorization: Bearer $FILESERVER_TOKEN" \
      -H "X-Content-SHA256: $(sha256sum "$FILE" | cut -d' ' -f1)" "$FILESERVER_URL/v1/files/$(basename "$FILE")"
```

Every job on those runners can read the token, so keep the runners private. Alerts are in `prometheusrule.yaml`.
