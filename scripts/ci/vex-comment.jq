# Markdown for the PR comment: what an OpenVEX document suppressed in a Trivy JSON report, and what is left.
# Usage: jq -r --arg ref <image> --arg doc <document> --slurpfile d <document> -f vex-comment.jq scan.json
def rows: [.Results[]?.ExperimentalModifiedFindings[]?];
def left(s): [.Results[]?.Vulnerabilities[]? | select(.Severity == s)] | length;
rows as $r
| ($d[0].statements | map(.vulnerability.name)) as $want
| ($want - ($r | map(.Finding.VulnerabilityID))) as $missing
| "### `\($ref)`",
  "",
  (if ($missing | length) == 0 then "✅ Every statement of `\($doc)` is applied." else "❌ Not applied: \($missing | join(", "))" end),
  "",
  "| CVE | Package | Status | Statement |",
  "|---|---|---|---|",
  ($r | sort_by(.Finding.VulnerabilityID)[] | "| \(.Finding.VulnerabilityID) | `\(.Finding.PkgName)` | \(.Status) | \((.Statement // "") | gsub("\\|"; "\\|")) |"),
  "",
  "Remaining: CRITICAL \(left("CRITICAL")), HIGH \(left("HIGH"))",
  ""
