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

## Source mode (call traces): the `govulncheck source scan` workflow

The pod has no Go toolchain, so source mode runs in GitHub Actions (`.github/workflows/govulncheck-source.yaml`, `workflow_dispatch`).
It copies the binary out of the image (never runs it), reads module, revision, Go version, tags and GOOS/GOARCH/CGO from its build info, checks out that source and scans the binary's own package.

- Run: `gh workflow run govulncheck-source.yaml -R cthtrifork/talos-gitops -f image=<repo:tag@digest> -f binary=<path in image> [-f omit-tags=a,b] [--ref <branch>]`, then `gh run view <id> -R ... --log` (give `-R` when the cwd is not a clone). Wait with a Monitor on `gh run view --json status`, never a sleep loop.
  The job summary table has one row per GO id: `not_affected` (`vulnerable_code_not_present` or `..._not_in_execute_path`) or `affected`; the log has the call traces.
- `-f binary=` is needed when the image has no entrypoint (the juicefs mount image: `/usr/local/bin/juicefs`). cgo build tags whose C headers the runner lacks (juicefs: `ceph,fdb,gluster`) fail the package load: pass them in `omit-tags`.
- Source mode beats binary mode. Binary mode only checks that the advisory's module is present and printed symbols the binary cannot contain (coredns v1.4.0: `plugin/pkg/proxy`, which does not exist in that version). Do not record from a binary-mode "present" or "absent" when source mode disagrees.
- `not_affected` is recordable (`CODE_NOT_PRESENT` or `CODE_NOT_REACHABLE`); name the tool version, the source revision and the run URL.
- `affected` only means some path from `main` exists. Example traces are over-approximated (interface dispatch: `fmt.Sprintf` to every Stringer, `Fprintf` to `tls.Conn.Write`, `init` OnceFuncs), and only one trace per symbol is shown. A multi-command binary (juicefs: mount, format, gateway, webdav, sync, warmup...) is "affected" through commands the pod never runs.
  Check each against the source at the revision and the deployment (the exact command, the metaurl and storage URLs, listeners, network policy) before recording or leaving open; a record must state the checked fact, not the trace.
- A module-level advisory can flag only package `init` functions of helper packages (coredns: `dnsutil`, `msg`, `response`); read what the package holds before calling it affected.
- Inspired by https://github.com/DataDog/trivy-plugin-govulncheck (archived, not used).
