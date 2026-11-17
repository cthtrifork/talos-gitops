#!/usr/bin/env python3
"""Check that application manifest filenames identify their Kubernetes resources."""
from pathlib import Path
import re
import sys

import yaml

APP_ROOT = Path("k8s/apps")
INFRA_ROOT = Path("k8s/infra")
# Generated, not hand-written: scripts/ci/update-kubevirt-operators.sh rewrites these vendored release bundles (CRDs, RBAC,
# Deployment) as one file, and nothing deploys them yet (k8s/infra/kubevirt/kustomization.yaml). Every other infra file must conform.
GENERATED_INFRA_FILES = frozenset(
    Path(name)
    for name in (
        "k8s/infra/kubevirt/cdi-operator.yaml",
        "k8s/infra/kubevirt/kubevirt-operator.yaml",
    )
)
ALIASES = {
    "CiliumNetworkPolicy": {"networkpolicy"},
    "OCIRepository": {"helm-repository"},
    "PersistentVolumeClaim": {"pvc"},
    "PodDisruptionBudget": {"pdb"},
}
GROUPED_FILENAMES = {
    "rbac": {
        "ClusterRole",
        "ClusterRoleBinding",
        "Role",
        "RoleBinding",
        "Secret",
        "ServiceAccount",
    },
    "rbac-elevated": {"ClusterRole"},
}


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def filename_matches_kind(filename: str, kind: str) -> bool:
    stem = Path(filename).stem
    if kind in GROUPED_FILENAMES.get(stem, set()):
        return True

    accepted_names = ALIASES.get(kind, {kind})
    normalized_stem = normalize(stem)
    return any(normalize(name) in normalized_stem for name in accepted_names)


def check_kinds(filename: str, kinds: set[str]) -> list[str]:
    if len(kinds) > 1:
        allowed_kinds = GROUPED_FILENAMES.get(Path(filename).stem)
        if allowed_kinds is None or not kinds <= allowed_kinds:
            return sorted(kinds)
    return sorted(kind for kind in kinds if not filename_matches_kind(filename, kind))


def manifest_files(root: Path):
    for path in sorted(root.rglob("*")):
        if path.suffix not in {".yaml", ".yml"}:
            continue
        if "rendered" in path.parts or path.name.endswith((".enc.yaml", ".enc.yml")):
            continue
        yield path


def check_file(path: Path) -> list[str]:
    try:
        documents = yaml.safe_load_all(path.read_text())
        kinds = {
            document["kind"]
            for document in documents
            if isinstance(document, dict) and isinstance(document.get("kind"), str)
        }
    except yaml.YAMLError:
        return []  # Syntax errors are reported by yamllint.

    if not kinds:
        return []
    return check_kinds(path.name, kinds)


def main() -> int:
    failed = False
    paths = [*manifest_files(APP_ROOT)]
    paths += [path for path in manifest_files(INFRA_ROOT) if path not in GENERATED_INFRA_FILES]
    for path in paths:
        mismatched_kinds = check_file(path)
        if mismatched_kinds:
            if len(mismatched_kinds) > 1:
                message = (
                    f"combines resource kinds ({', '.join(mismatched_kinds)}); "
                    "split them into separate files or use the approved rbac.yaml grouping"
                )
            else:
                message = f"filename does not identify resource kind: {mismatched_kinds[0]}"
            print(f"ERROR: {path} {message}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
