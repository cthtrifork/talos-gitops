#!/usr/bin/env python3
"""Check that application manifest filenames identify their Kubernetes resources."""
from pathlib import Path
import re
import sys

import yaml

APP_ROOT = Path("k8s/apps")
ALIASES = {
    "CiliumNetworkPolicy": {"networkpolicy"},
    "OCIRepository": {"helm-repository"},
    "PersistentVolumeClaim": {"pvc"},
    "PodDisruptionBudget": {"pdb"},
}
GROUPED_FILENAMES = {
    "admission": {"ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"},
    "external-secrets": {"ExternalSecret", "GithubAccessToken"},
    "helm-release": {"HelmRelease", "PersistentVolumeClaim"},
    "helm-release-podman": {"HelmRelease", "ConfigMap"},
    "ingressroute": {"IngressRoute", "Middleware"},
    "postgres-certificates": {"Certificate", "Issuer"},
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
    return sorted(kind for kind in kinds if not filename_matches_kind(path.name, kind))


def main() -> int:
    failed = False
    for path in manifest_files(APP_ROOT):
        mismatched_kinds = check_file(path)
        if mismatched_kinds:
            print(
                f"ERROR: {path} filename does not identify resource kind(s): "
                f"{', '.join(mismatched_kinds)}",
                file=sys.stderr,
            )
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
