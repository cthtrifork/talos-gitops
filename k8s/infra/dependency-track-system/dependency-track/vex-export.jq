# Input: the CycloneDX VEX of one Dependency-Track project (one image tag).
# Arguments: $product = the image repository as a PURL without version (pkg:oci/<name>?repository_url=<host>/<repo>),
# $alias = the same repository under the registry the pod and CI use (Trivy's PURLs name the zot mirror).
# Output: OpenVEX statements, one per decided vulnerability.

# Dependency-Track justification -> OpenVEX justification
def justifications: {
  code_not_present: "vulnerable_code_not_present",
  code_not_reachable: "vulnerable_code_not_in_execute_path",
  requires_configuration: "vulnerable_code_cannot_be_controlled_by_adversary",
  requires_dependency: "vulnerable_code_cannot_be_controlled_by_adversary",
  requires_environment: "vulnerable_code_cannot_be_controlled_by_adversary",
  protected_by_compiler: "inline_mitigations_already_exist",
  protected_at_runtime: "inline_mitigations_already_exist",
  protected_at_perimeter: "inline_mitigations_already_exist",
  protected_by_mitigating_control: "inline_mitigations_already_exist"
};

# { "<bom-ref>": "<purl>" } of all components
def purls_by_bom_ref:
  (.components // [])
  | map(select(."bom-ref" != null and (.purl // "") != "") | {key: ."bom-ref", value: .purl})
  | from_entries;

def is_decision:
  .analysis.state | IN("not_affected", "false_positive", "resolved");

# The affected components that have a purl. Without one a statement would cover the whole image.
def subcomponents($purls):
  [.affects[]?.ref | $purls[.] // empty | {"@id": .}];

def status_fields:
  if .analysis.state == "resolved" then
    {status: "fixed"}
  else
    justifications[.analysis.justification // ""] as $justification
    | {status: "not_affected"}
    + (if $justification then {justification: $justification} else {} end)
    + {impact_statement: (.analysis.detail // "Marked \(.analysis.state) in Dependency-Track")}
  end;

def statement($product; $alias; $purls):
  subcomponents($purls) as $subcomponents
  | select($subcomponents | length > 0)
  | {
      vulnerability: {name: .id},
      products: ([$product, $alias] | unique | map({"@id": ., subcomponents: $subcomponents}))
    }
    + status_fields;

purls_by_bom_ref as $purls

| [.vulnerabilities[]? | select(is_decision) | statement($product; $alias; $purls)]
