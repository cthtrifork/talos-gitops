# ingress-system

Traefik with a cloudflared sidecar: public traffic arrives through a Cloudflare tunnel and reaches Traefik on `localhost:8000` (plain HTTP).

## Tunnel

A remotely managed tunnel whose token is the SOPS Secret `cloudflared-tunnel-token` (key `token`) in `traefik-system` (`traefik/cloudflared-tunnel-token.enc.yaml`; command: "Secrets (SOPS)" in the root `readme.md`).

Each public hostname is added in the tunnel's **Public hostname** tab with service `HTTP` `localhost:8000`. The hostnames in use and what sits in front of them are described where they are routed: `k8s/infra/flux-system/README.md` (the Flux webhook), `k8s/infra/dependency-track-system/README.md` and `k8s/apps/harper-pad/README.md`.
