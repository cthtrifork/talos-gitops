#!/usr/bin/env python3
"""Prints the images that OpenVEX documents make statements about, as a JSON array of {doc, ref}.

Usage: vex-images.py [document ...]   (default: every vex/pkg/oci/**/*.openvex.json)

An image product is a PURL `pkg:oci/<name>@<digest>?repository_url=<registry>%2F<repository>`; its scan reference
is `<registry>/<repository>@<digest>`. Products without a digest cannot be pulled and are left out.
"""
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

docs = sys.argv[1:] or sorted(map(str, Path("vex/pkg/oci").rglob("*.openvex.json")))
found = {}
for doc in docs:
    for statement in json.loads(Path(doc).read_text())["statements"]:
        for product in statement["products"]:
            purl = urlsplit(product.get("@id") or product["identifiers"]["purl"])
            digest = purl.path.partition("@")[2]
            repository = parse_qs(purl.query).get("repository_url", [""])[0]
            if digest.startswith("sha256:") and repository:
                found[(doc, f"{unquote(repository)}@{digest}")] = None
print(json.dumps([{"doc": d, "ref": r} for d, r in found], separators=(",", ":")))
