---
name: govulncheck
description: Check whether a Go vulnerability (golang.org/x/*, stdlib) is really in a cluster image's binary with govulncheck. Use before assessing a Go dependency CVE in Dependency-Track or when asked if a Go CVE is reachable.
---

# Go reachability with govulncheck

`govulncheck-image <image> <path-in-image> [govulncheck flags]` (script in the runner image) extracts that one file with `crane export`, runs
`govulncheck -mode=binary` on it and deletes it. Output lists the vulnerable symbols found in the binary (GO-ids with CVE aliases);
exit 3 means findings. Binary mode shows a symbol is linked, not that it is called; a missing symbol is `CODE_NOT_PRESENT`.

- Extra flags go to govulncheck: `-show verbose` also lists vulnerabilities in modules present but not called (a CVE missing from the default output may be there). Never call `crane export` or `govulncheck` on an image yourself.
- Find the binary: `crane config <image> | jq '.config.Entrypoint,.config.Cmd'`, or the Trivy report's `target`/path (`kubectl get vulnerabilityreport`). Distroless images symlink `/bin` to `usr/bin`: the path is then `usr/bin/<name>`.
  Use the live tag and digest from the running pod (`kubectl get pod -o jsonpath='{..imageID}'`), not an old DT version.
- Scratch: `export TMPDIR=<session scratchpad>/gvc` (`mkdir -p`), never `/tmp` or `/workspace`. One image at a time. Never run the extracted file.
- Needs the image's registry and `vuln.go.dev` in the egress allowlist; a hang on connect: see `cilium-drops`. Registry
  credentials come from `$DOCKER_CONFIG` and are never printed. `crane export` is allowed only through this script.
- Result to Dependency-Track (see `dependency-track`): vulnerable symbol absent: `NOT_AFFECTED` with `CODE_NOT_PRESENT`;
  present: leave it open, the fix is a bump. Name the govulncheck version and the image digest in `analysisDetails`.
- Failure (not a Go binary, stripped, DB unreachable) is "not verified", not "affected".
- Inspired by https://github.com/DataDog/trivy-plugin-govulncheck (archived, not used).
