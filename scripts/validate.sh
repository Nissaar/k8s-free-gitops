#!/usr/bin/env bash
# Offline checks, the same ones CI runs (.github/workflows/validate.yml):
#   1. kustomize build of every path a Flux Kustomization points at
#   2. kubeconform (Kubernetes + CRD schemas from the datreeio catalog;
#      schemas/ first, for CRDs where the catalog is behind, see
#      scripts/crd-schema.py) on the built output and on docs/examples
#   3. if the flux-operator CLI is installed: render the previews ResourceSet
#      with mock PR inputs (scripts/testdata) and validate what it generates
# Needs: kubectl (built-in kustomize), kubeconform, network for schemas.
# Run `trivy config .` and scripts/helm-check.py separately.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
out=${OUT_DIR:-$ROOT/.cache/rendered}
mkdir -p "$out"
rm -f "$out"/*.yaml

# Every spec.path of a Flux Kustomization under clusters/, plus clusters/oke.
mapfile -t paths < <(
  { echo "./clusters/oke"
    grep -rhE '^\s+path: \./' clusters/ | awk '{print $2}'; } | sort -u)

status=0
for p in "${paths[@]}"; do
  f="$out/$(echo "${p#./}" | tr '/' '_').yaml"
  # Sealed secrets carry a top-level "sops:" block that is not part of the
  # Secret schema (Flux strips it when decrypting); drop it for kubeconform.
  if kubectl kustomize "$p" | awk '/^sops:/{skip=1; next} skip && /^[^ ]/{skip=0} !skip' > "$f"; then
    echo "kustomize ok   $p ($(grep -c '^kind:' "$f") objects)"
  else
    echo "kustomize FAIL $p"; status=1
  fi
done
[ "$status" -eq 0 ] || exit 1

if command -v flux-operator > /dev/null; then
  # Postbuild variables get example values, as Flux would substitute them.
  # shellcheck disable=SC2016 # the ${...} below are literal Flux variables, not shell expansions
  flux-operator build resourceset \
      -f infrastructure/configs/previews/resourceset.yaml \
      --inputs-from scripts/testdata/preview-inputs.yaml \
    | sed -e 's/\${BASE_DOMAIN}/example.com/g' -e 's/\${HOME_TAILNET_FQDN}/chatops.example.ts.net/g' \
          -e 's/\${NTFY_TOPIC}/cluster/g' > "$out/previews-generated.yaml"
  echo "resourceset ok previews ($(grep -c '^kind:' "$out/previews-generated.yaml") objects from 2 mock PRs)"
else
  echo "flux-operator CLI not found: skipping the ResourceSet template check"
fi

# Kinds with no schema anywhere (none at the time of writing) would go in
# SKIP_KINDS, comma separated; keep the list explicit, never -ignore-missing-schemas.
SKIP_KINDS=${SKIP_KINDS:-}
kubeconform \
  -strict -summary -output text \
  ${SKIP_KINDS:+-skip "$SKIP_KINDS"} \
  -schema-location default \
  -schema-location "$ROOT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$out"/*.yaml docs/examples/*.yaml
