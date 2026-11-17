# fileserver

Public downloads, an admin page and a CI upload API in one static Go binary with no dependencies. State is the directory a file is
in, so there is no database. It runs as three containers in one pod (`k8s/apps/fileserver`).

| Mode | Port | Mounts | What it does |
|---|---|---|---|
| `--mode=public` | 8080 | `public/` read-only | `GET /<name>`, no listing. Behind Traefik and the Cloudflare tunnel |
| `--mode=admin` | 8081 | everything | List, upload, download, delete, move between public and private, show the upload token. No login: only Omni reaches it |
| `--mode=upload` | 8082 | everything | `PUT /v1/files/<name>?visibility=public\|private` with the bearer token. Cluster-internal |

```mermaid
flowchart TB
    NET["Internet<br/>files.portableinfo.cloud"] --> CF["Cloudflare"] --> TR["Traefik<br/>rateLimit, inFlightReq"]
    OP["Operator"] --> OMNI["Omni service exposer"]
    RUN["ARC runner (arc-runners-system)<br/>env FILESERVER_TOKEN"]
    CJ["CronJob, monthly<br/>curl: new token"]
    RL["Reloader"]
    subgraph POD["Pod fileserver (fileserver-system)"]
        PUB["public :8080<br/>public/ read-only"]
        ADM["admin :8081<br/>shows the token"]
        UPL["upload :8082<br/>checks the token"]
    end
    S1[("Secret fileserver-system/<br/>fileserver-upload-token")]
    S2[("Secret arc-runners-system/<br/>fileserver-upload-token")]
    subgraph PVC["PVC 20 GiB"]
        D1["public/"]
        D2["private/"]
        D3[".tmp/"]
    end
    TR -->|":8080"| PUB
    OMNI -->|":8081"| ADM
    RUN -->|":8082"| UPL
    CJ --> S1 & S2
    S1 -.-> ADM & UPL
    S2 -.-> RUN
    RL -.->|"restarts the pod when its Secret changes"| POD
    PUB --> D1
    ADM --> D1 & D2
    UPL --> D1 & D2 & D3
```

## Rules

- **Names** are one plain name: `fs.ValidPath`, at most 255 bytes, no `/` or `\`, no control characters, not starting with `.`.
  Every access goes through `os.Root`, so a name cannot leave its directory.
- **Visibility is the directory.** A name lives in only one of `public/` and `private/` (409 otherwise). Uploading the same name with
  the same visibility replaces the file. Uploads default to private.
- **Writes are atomic**: streamed to `.tmp/`, `fsync`ed every 64 MiB, renamed into place. An optional `X-Content-SHA256` header is
  checked before the rename (422 on a mismatch).
- **Limits**: `MAX_FILE_BYTES` per file (413), `MIN_FREE_BYTES` must stay free (507).
- **Downloads are never pages**: `application/octet-stream`, `attachment`, `nosniff`, `CSP: sandbox`.
- **The admin page loads no third-party script.** It is built with htm and Preact, bundled in the binary as `web/htm-preact.js`
  (htm 3.1.1, which includes Preact 10; served unguarded at `/htm-preact.js` because a module script cannot send
  `X-Requested-With`), so its CSP stays `script-src 'self'`: the page shows the upload token and can delete files. To update the
  bundle, take `preact/standalone.module.js` from the `htm` npm package. Renovate does not track it.

## Upload token

A CronJob writes a new token into the Secret every month (`current` and `rotated-at`); Reloader restarts the pod. The app only
reads the mounted files. Only the upload API accepts the token, and the admin page shows it.

## Metrics

`/metrics` and `/healthz` are on `HEALTH_ADDR`, which Traefik and Omni do not route to: requests, uploads by result, files, free disk
and the last token rotation.

## Configuration

| Variable | Default | Modes |
|---|---|---|
| `DATA_DIR` | `/data` | admin, upload |
| `PUBLIC_DIR` | `$DATA_DIR/public` | public |
| `LISTEN_ADDR` | `:8080`, `:8081`, `:8082` | all |
| `HEALTH_ADDR` | `:9102` | all |
| `MAX_FILE_BYTES` | 8 GiB | admin, upload |
| `MIN_FREE_BYTES` | 256 MiB | admin, upload |
| `TOKEN_DIR` | `/var/run/fileserver-token` | admin, upload |
| `PUBLIC_URL` | none: "Copy link" for public files | admin |
| `UPLOAD_URL` | none: "Copy curl" for the token | admin |

Run the tests with `go test -race ./...`.
