#!/usr/bin/env python3
"""Fail if a HelmRelease cannot recover from a failed install or upgrade (it would go Stalled until reset by hand).

Each HelmRelease needs spec.upgrade.remediation.retries (non-zero, -1 counts) and either
spec.install.remediation.retries or spec.install.strategy.name == RetryOnFailure.
Usage: check-helmrelease-remediation.py [FILE_OR_DIR...]   (default: k8s; "-" reads a multi-document stream from stdin, e.g. kustomize build)
"""
import pathlib
import sys

import yaml

def problems(hr):
    spec = hr.get("spec") or {}
    out = []
    if not (spec.get("upgrade") or {}).get("remediation", {}).get("retries"):
        out.append("spec.upgrade.remediation.retries is not set (or 0)")
    install = spec.get("install") or {}
    if not (install.get("remediation") or {}).get("retries") and (install.get("strategy") or {}).get("name") != "RetryOnFailure":
        out.append("neither spec.install.remediation.retries nor spec.install.strategy.name: RetryOnFailure is set")
    return out


def documents(root):
    if root == "-":
        yield "<stdin>", sys.stdin.read()
        return
    path = pathlib.Path(root)
    for f in [path] if path.is_file() else sorted(path.rglob("*.y*ml")):
        if "rendered" in f.parts or f.name.endswith(".enc.yaml"):
            continue
        yield str(f), f.read_text()


failed = False
for root in sys.argv[1:] or ["k8s"]:
    for name, text in documents(root):
        try:
            docs = list(yaml.safe_load_all(text))
        except yaml.YAMLError:
            continue  # not plain YAML (yamllint reports syntax errors)
        # kubectl get -o json wraps the objects in a List
        objs = [o for d in docs for o in (d.get("items", []) if isinstance(d, dict) and d.get("kind") == "List" else [d])]
        for doc in objs:
            if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
                continue
            meta = doc.get("metadata") or {}
            ref = f"{meta.get('namespace', 'default')}/{meta.get('name')}"
            for p in problems(doc):
                print(f"ERROR - HelmRelease {ref} ({name}): {p}", file=sys.stderr)
                failed = True
sys.exit(1 if failed else 0)
