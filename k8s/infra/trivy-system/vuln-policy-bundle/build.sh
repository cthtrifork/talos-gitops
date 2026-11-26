#!/bin/sh
# Turns trivyignore.yaml into a Dependency-Track vulnerability policy bundle (one policy per CVE) at /srv/bundle.zip.
set -eu
src=/etc/trivy/.trivyignore.yaml
out=/tmp/policies
mkdir -p "$out"

# A bundle without a policy is not accepted, so keep one that never runs.
cat > "$out/trivyignore-bundle.yaml" <<'EOF'
apiVersion: v1.0
type: Vulnerability Policy
name: trivyignore-bundle
description: Placeholder so the bundle is never empty
author: trivyignore.yaml
operationMode: DISABLED
condition: "false"
analysis:
  state: NOT_AFFECTED
EOF

n=$(yq '.vulnerabilities | length' "$src")
i=0
while [ "$i" -lt "$n" ]; do
  id=$(yq ".vulnerabilities[$i].id" "$src")
  case "$id" in "" | null | *[!A-Za-z0-9-]*) echo "invalid id in entry $i: $id" >&2; exit 1 ;; esac
  ID=$id STMT=$(yq ".vulnerabilities[$i].statement // \"\"" "$src") EXP=$(yq ".vulnerabilities[$i].expired_at // \"\"" "$src") \
    yq -n '
      .apiVersion = "v1.0" | .type = "Vulnerability Policy" | .name = "trivyignore-" + strenv(ID) |
      .description = "From trivyignore.yaml" | .author = "trivyignore.yaml" |
      .condition = "vuln.id == \"" + strenv(ID) + "\"" |
      .analysis.state = "NOT_AFFECTED" | .analysis.details = strenv(STMT) | .analysis.suppress = true |
      (if strenv(EXP) != "" then .validUntil = strenv(EXP) + "T00:00:00Z" else . end)' \
    > "$out/$(echo "$id" | tr 'A-Z' 'a-z').yaml"
  i=$((i + 1))
done

cd "$out"
zip -q -j /srv/bundle.zip ./*.yaml
echo "bundle with $((n + 1)) policies"
