---
name: govulncheck
description: Check whether a Go vulnerability (golang.org/x/*, stdlib) is really in a cluster image's binary, with trivy and the DataDog trivy-govulncheck plugin. Use before assessing a Go dependency CVE in Dependency-Track or when asked if a Go CVE is reachable.
---

# Go reachability with trivy-govulncheck

`trivy image -f json <image> | trivy-govulncheck --show-suppressed` (plugin: https://github.com/DataDog/trivy-plugin-govulncheck).
The plugin pulls and extracts the image itself and runs `govulncheck -mode binary` on each Go binary. A Trivy finding stays
only if govulncheck finds its vulnerable symbol in the binary; the rest become `not_affected` (source `trivy-govulncheck`).
Binary mode shows the symbol is linked, not that it is called; a missing symbol is `CODE_NOT_PRESENT`.

- Scratch space: `export TMPDIR=<session scratchpad>/gvc TRIVY_CACHE_DIR=<session scratchpad>/gvc/cache` (`mkdir -p`),
  never `/tmp` or `/workspace` (an image is hundreds of MB). `rm -rf` it afterwards. Never run anything extracted.
- Use the live tag from the running pod (`kubectl get pods -A -o jsonpath` on `.spec.containers[*].image`), not an old DT version.
- Scan one image at a time, with `--scanners vuln` and `--pkg-types library` (only Go libraries are filtered).
  A broad scan is slow and downloads the Trivy DB (`ghcr.io`).
- Needs `ghcr.io`, the image's registry and `vuln.go.dev` in the egress allowlist; a hang on connect: see `cilium-drops`.
  Registry credentials come from `$DOCKER_CONFIG` and are never printed.
- Result to Dependency-Track (see `dependency-track`): vulnerable symbol absent from the binary: `NOT_AFFECTED` with
  `CODE_NOT_PRESENT`; present: leave open, the fix is a bump. Say the plugin version and image digest in `analysisDetails`.
- If the plugin cannot read a binary or govulncheck fails, it leaves that result unfiltered: that is "not verified", not "affected".
- Prefer the same image digest the cluster runs: `kubectl get pod ... -o jsonpath='{..imageID}'`.
