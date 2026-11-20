# Markdown for the scan PR comment, from the Trivy JSON reports of the new and the old image.
# Usage: jq -r --arg new_ref <ref> --arg old_ref <ref or ""> --arg run_url <url> --slurpfile o old.json -f scan-comment.jq new.json
# The list of everything in the new image comes from scripts/ci/vuln-list.tpl (a Trivy template), appended by the workflow.
# old.json may be {} (a new image, or the old scan failed); new.json may be {} (the scan failed).
def sev_rank: {CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3}[.] // 4;
def icon: {CRITICAL: "🟥", HIGH: "🟧", MEDIUM: "🟨", LOW: "🟦"}[.] // "⬜";
def vulns: [.Results[]?.Vulnerabilities[]?];
def key: "\(.VulnerabilityID)|\(.PkgName)";
def cve: if (.PrimaryURL // "") != "" then "[\(.VulnerabilityID)](\(.PrimaryURL))" else .VulnerabilityID end;
def row: "| \(.Severity | icon) \(.Severity) | \(cve) | `\(.PkgName)` | `\(.InstalledVersion)` | \(if (.FixedVersion // "") == "" then "–" else "`\(.FixedVersion | split(", ")[0])`" end) |";
def table(list; cap):
  "| Severity | CVE | Package | Installed | Fixed in |", "|---|---|---|---|---|",
  (list | sort_by([(.Severity | sev_rank), .VulnerabilityID])[:cap][] | row),
  (if (list | length) > cap then "", "…and \((list | length) - cap) more in the full report." else empty end);
def count(l; s): l | map(select(.Severity == s)) | length;
def fixable(l; s): l | map(select(.Severity == s and ((.FixedVersion // "") != ""))) | length;
def arrow(o; n): if n > o then "⬆️" elif n < o then "⬇️" else "➖" end;

(vulns) as $new
| ($o[0] | vulns) as $old
| (($o[0] | has("Results")) and ($o[0] | length) > 0) as $hasold
| ($new | map(key)) as $newkeys
| ($old | map(key)) as $oldkeys
| [$new[] | select(key as $k | $oldkeys | index($k) | not)] as $added
| [$old[] | select(key as $k | $newkeys | index($k) | not)] as $fixed
| "### `\(if $old_ref != "" then $old_ref else "new image" end)` → `\($new_ref)`",
  "",
  (if (has("Results") | not) then "❌ The scan of the new image failed, so there is nothing to compare. The reason (often a registry rate limit) is in the [job log](\($run_url)); re-run the job." else
    (if $old_ref != "" and ($hasold | not) then "ℹ️ The scan of the old image failed, so there is no comparison.", "" else empty end),
    ("| Severity | Old | New | Fixable | |", "|---|---:|---:|---:|---|"),
    (("CRITICAL", "HIGH") as $s
     | "| \($s | icon) \($s) | \(if $hasold then count($old; $s) else "–" end) | \(count($new; $s)) | \(fixable($new; $s)) | \(if $hasold then arrow(count($old; $s); count($new; $s)) else "" end) |"),
    "",
    (if $hasold and ($added | length) > 0 then "**🆕 New: \($added | length)**", "", table($added; 10), "" else empty end),
    (if $hasold and ($fixed | length) > 0 then "<details><summary>✅ Fixed: \($fixed | length)</summary>", "", table($fixed; 10), "", "</details>", "" else empty end),
    (if ($new | length) == 0 then "No CRITICAL or HIGH vulnerabilities. 🎉", "" else empty end)
  end)
