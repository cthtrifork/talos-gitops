# Markdown for the PR comment: what an OpenVEX document suppressed in a Trivy JSON report, and what is left.
# A statement whose CVE the image does not have (a decision from another tag) is not an error.
# Usage: jq -r --arg ref <image> --arg doc <document> --slurpfile d <document> -f vex-comment.jq scan.json
def rows: [.Results[]?.ExperimentalModifiedFindings[]?];
def left(s): [.Results[]?.Vulnerabilities[]? | select(.Severity == s)] | length;
rows as $r
| ($d[0].statements | map(.vulnerability.name)) as $want
| ($r | map(.Finding.VulnerabilityID)) as $applied
| ([.Results[]?.Vulnerabilities[]?.VulnerabilityID]) as $present
# a statement can come from another tag of the image: only a CVE the image has can fail
| ($want - $applied | map(select(. as $c | $present | index($c)))) as $missing
| ($want - $applied - $missing) as $absent
| "### `\($ref)`",
  "",
  (if ($missing | length) == 0 then "✅ Every statement of `\($doc)` that concerns this image is applied." else "❌ Not applied: \($missing | join(", "))" end),
  (if ($absent | length) > 0 then "", "Not in this image: \($absent | join(", "))" else empty end),
  "",
  "| CVE | Package | Status | Statement |",
  "|---|---|---|---|",
  ($r | sort_by(.Finding.VulnerabilityID)[] | "| \(.Finding.VulnerabilityID) | `\(.Finding.PkgName)` | \(.Status) | \((.Statement // "") | gsub("\\|"; "\\|")) |"),
  "",
  "Remaining: CRITICAL \(left("CRITICAL")), HIGH \(left("HIGH"))",
  ""
