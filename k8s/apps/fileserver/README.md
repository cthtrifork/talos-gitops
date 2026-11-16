# fileserver

Public downloads, an admin page and a CI upload API in one pod. The app: `images/fileserver/README.md`.

| Port | Service | Reached by |
|---|---|---|
| 8080 public | `fileserver-public` | Traefik, `files.portableinfo.cloud` (read-only `public/`) |
| 8081 admin | `fileserver-admin` | the Omni exposer, prefix `files` |
| 8082 upload | `fileserver-upload` | the ARC runners only |

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
