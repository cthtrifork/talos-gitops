#!/usr/bin/env python3
"""Fail if a YAML file uses an anchor (&name) or an alias (*name). Generated rendered/ files and encrypted files are skipped."""
import pathlib
import sys

import yaml

ROOTS = sys.argv[1:] or ["k8s", "scripts", "images", "bootstrap.yaml", ".github"]
failed = False
for root in ROOTS:
    path = pathlib.Path(root)
    for f in [path] if path.is_file() else sorted(path.rglob("*.y*ml")):
        if "rendered" in f.parts or f.name.endswith(".enc.yaml"):
            continue
        try:
            events = list(yaml.parse(f.read_text(), Loader=yaml.SafeLoader))
        except yaml.YAMLError:
            continue  # not plain YAML (yamllint reports syntax errors)
        for ev in events:
            if isinstance(ev, yaml.AliasEvent) or getattr(ev, "anchor", None):
                print(f"ERROR - YAML anchor or alias: {f}:{ev.start_mark.line + 1}", file=sys.stderr)
                failed = True
sys.exit(1 if failed else 0)
