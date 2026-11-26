#!/usr/bin/env python3
"""Render every HelmRelease in this repo with `helm template` to catch bad values.

For each HelmRelease the script finds its chart source (HelmRepository,
OCIRepository or GitRepository in infrastructure/controllers/sources), pulls
the newest chart inside the release's version range, substitutes the
${VARS} from clusters/oke/cluster-settings.yaml (like Flux postBuild),
applies the release's post-renderer patches (kustomize) and renders it.
Charts with a values.schema.json reject unknown keys here.

Needs: python3 + PyYAML, helm, kubectl (for kustomize), git, network.
Usage: scripts/helm-check.py [release-name ...]
"""
import os
import re
import subprocess
import sys
import tempfile
import pathlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_all(path):
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def settings():
    cm = load_all(ROOT / "clusters/oke/cluster-settings.yaml")[0]
    return cm["data"]


def substitute(text, env):
    # ${VAR} and ${VAR:=default}; $VAR (no braces) is left alone, like Flux.
    def rep(m):
        name, default = m.group(1), m.group(3)
        return env.get(name, default if default is not None else "")
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:=([^}]*))?\}", rep, text)


def sources():
    out = {}
    for f in (ROOT / "infrastructure").rglob("*.yaml"):
        if f.name.endswith((".example.yaml", ".sops.yaml")):
            continue
        for d in load_all(f):
            if d.get("kind") in ("HelmRepository", "OCIRepository", "GitRepository"):
                out[(d["kind"], d["metadata"]["name"])] = d
    return out


def releases():
    for f in sorted(ROOT.rglob("*.yaml")):
        if {".git", ".cache"} & set(f.parts) or f.name.endswith((".example.yaml", ".sops.yaml")):
            continue
        try:
            docs = load_all(f)
        except yaml.YAMLError:
            continue
        for d in docs:
            if isinstance(d, dict) and d.get("kind") == "HelmRelease":
                yield f, d


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def fetch_chart(hr, srcs, work):
    spec = hr["spec"]
    if "chartRef" in spec:
        src = srcs[(spec["chartRef"]["kind"], spec["chartRef"]["name"])]
        url = src["spec"]["url"]
        run(["helm", "pull", url, "--untar", "--untardir", work])
        return os.path.join(work, url.rstrip("/").split("/")[-1])
    cs = spec["chart"]["spec"]
    src = srcs[(cs["sourceRef"]["kind"], cs["sourceRef"]["name"])]
    if src["kind"] == "GitRepository":
        repo = os.path.join(work, "git")
        run(["git", "clone", "-q", "--depth", "1", src["spec"]["url"], repo])
        return os.path.join(repo, cs["chart"].lstrip("./"))
    version = cs.get("version", "*")
    # helm wants a constraint, Flux's "42.x" style works for both.
    run(["helm", "pull", "--repo", src["spec"]["url"], cs["chart"],
         "--version", version, "--untar", "--untardir", work])
    return os.path.join(work, cs["chart"])


def post_render(rendered, hr, work):
    patches = []
    for pr in hr["spec"].get("postRenderers", []):
        patches += pr.get("kustomize", {}).get("patches", [])
    if not patches:
        return rendered
    kdir = os.path.join(work, "postrender")
    os.makedirs(kdir, exist_ok=True)
    with open(os.path.join(kdir, "all.yaml"), "w") as fh:
        fh.write(rendered)
    with open(os.path.join(kdir, "kustomization.yaml"), "w") as fh:
        yaml.safe_dump({"resources": ["all.yaml"], "patches": patches}, fh)
    return run(["kubectl", "kustomize", kdir]).stdout


def main(only):
    env = settings()
    srcs = sources()
    failed = 0
    for path, hr in releases():
        name = hr["metadata"]["name"]
        if only and name not in only:
            continue
        hr = yaml.safe_load(substitute(yaml.safe_dump(hr), env))
        with tempfile.TemporaryDirectory() as work:
            try:
                chart = fetch_chart(hr, srcs, work)
                values = os.path.join(work, "values.yaml")
                with open(values, "w") as fh:
                    yaml.safe_dump(hr["spec"].get("values", {}), fh)
                out = run(["helm", "template", hr["spec"].get("releaseName", name), chart,
                           "--namespace", hr["metadata"]["namespace"],
                           "--include-crds", "-f", values]).stdout
                out = post_render(out, hr, work)
                dest = ROOT / ".cache" / "helm" / f"{name}.yaml"
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(out)
                print(f"ok    {name:24} {path.relative_to(ROOT)} -> {dest.relative_to(ROOT)}")
            except subprocess.CalledProcessError as e:
                failed += 1
                print(f"FAIL  {name:24} {path.relative_to(ROOT)}\n{e.stderr or e.stdout}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main(set(sys.argv[1:]))
