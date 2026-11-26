#!/usr/bin/env python3
"""Write kubeconform JSON schemas from CRD manifests into schemas/.

Only for CRDs whose schema in the datreeio CRDs-catalog is older than the
version we use (kubeconform tries schemas/ first, then the catalog).
Today: ResourceSet (the catalog copy predates spec.steps).

Usage: scripts/crd-schema.py <crds.yaml or URL> <kind> [<kind> ...]
  e.g. helm pull oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --untar -d /tmp/fo
       scripts/crd-schema.py /tmp/fo/flux-operator/templates/crds.yaml ResourceSet
"""
import json
import pathlib
import sys
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def strict(node):
    """Mimic openapi2jsonschema --strict: objects reject unknown keys."""
    if isinstance(node, dict):
        if node.pop("x-kubernetes-int-or-string", False):
            node.pop("type", None)
            node["oneOf"] = [{"type": "string"}, {"type": "integer"}]
        if ("properties" in node and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def main(src, kinds):
    if src.startswith("http"):
        text = urllib.request.urlopen(src, timeout=60).read().decode()
    else:
        text = pathlib.Path(src).read_text()
    # Helm templates: drop lines with template actions so the YAML parses.
    text = "\n".join(l for l in text.splitlines() if "{{" not in l)
    for doc in yaml.safe_load_all(text):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        if spec["names"]["kind"] not in kinds:
            continue
        for v in spec["versions"]:
            schema = strict(v["schema"]["openAPIV3Schema"])
            out = ROOT / "schemas" / spec["group"] / f'{spec["names"]["kind"].lower()}_{v["name"]}.json'
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
            print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], set(sys.argv[2:]))
