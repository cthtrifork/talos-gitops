# Avoiding passwords

Order of preference: client certificate (mTLS), then short-lived or projected tokens, then a generated password only when the software has nothing else.
Reference implementation: `k8s/apps/harper-pad/` (own cert-manager Issuer, `pg_hba` `hostssl ... cert`, CN equals the role name, no password on the role).

## Candidates

| Where | Today | Proposal | Effort / blocker |
|---|---|---|---|
| `juicefs-system` `juicefs-meta` (CNPG) | CNPG-generated app password in the meta URL | Copy harper-pad: Issuer, server/client certs, `pg_hba` cert rule. JuiceFS passes `sslmode`, `sslcert`, `sslkey`, `sslrootcert` in the Postgres meta URL | Low. Verify the JuiceFS `postgres://` URL accepts the cert parameters before the PR |
| `dependency-track-system` `dependency-track-db` (CNPG) | `dependency-track-db-app` password in the JDBC URL | Same CNPG pattern; pgJDBC reads `sslcert`/`sslkey` | Medium. pgJDBC wants a PKCS#8 DER key, so cert-manager needs `privateKey.encoding: PKCS8` and the key converted (init container or `sslfactory`). Check the chart exposes extra volumes |
| Valkey `renovate-valkey` | ACL user `renovate` with a password, server TLS already on, `clientAuth.mode: Disabled` | Set `clientAuth: Required` and use cert users | Blocked: the Renovate cluster-cache client applies TLS only to discovery (comment in `renovate-operator/helm-release.yaml`). Revisit when upstream fixes it |
| `fileserver` upload token, `vm-upgrade-tokens` (`Password` generators in `secret-store`) | Bearer tokens rotated every 30 days | Traefik `TLSOption` with `clientAuth` and a cert-manager client cert per caller (ARC runners, claude-vm-upgrade) | Medium. Needs an internal entrypoint; the fileserver is behind Cloudflare, so this fits only for in-cluster callers |
| `adguard` exporter (`ADGUARD_PASSWORDS`) | HTTP basic against AdGuard Home | None: AdGuard Home has no client-cert auth. Keep the password, or drop the exporter's login if the API allows unauthenticated reads | Not a candidate |
| zot | No auth on the registry, server TLS only | Optional: `http.tls.cacert` in `zot.json` to require client certs, with certs for the runners and nodes pulling from it | Low value while the registry has no auth by design. Nodes pulling via containerd mirror would need client certs in the Talos registry patch |
| Garage S3 keys (`garage-*`, `juicefs-garage-*`) | Generated access key pairs | None: S3 signing keys, Garage has no mTLS | Not a candidate. They are generated, never typed or stored by hand |
| Cilium workload-to-workload | NetworkPolicy only | Cilium mutual auth (SPIFFE) as a policy layer | Optional; not a password replacement by itself |

## Not passwords

`redpanda-connect` calls to the Kubernetes API use projected ServiceAccount tokens (short-lived); keep them. ghcr and GitHub tokens are upstream credentials and cannot be replaced with mTLS.

## Suggested order

1. `juicefs-meta` (smallest, same technology as harper-pad).
2. `dependency-track-db` once the PKCS#8 question is settled.
3. Revisit Valkey when Renovate's cache client supports TLS beyond discovery.
