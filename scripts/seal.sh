#!/usr/bin/env bash
# Turn a filled copy of a *.example.yaml Secret into the encrypted
# *.sops.yaml next to the example, and list it in that folder's
# kustomization.yaml so Flux applies it.
#
# Since secrets moved to OCI Vault (External Secrets), only one file is
# sealed: external-secrets/oci-vault-reader, and oracle-always-free's
# scripts/make-reader-key.sh calls this script for it. By hand it would be:
#   scripts/seal.sh /tmp/oci-vault-reader.yaml infrastructure/controllers/external-secrets/oci-vault-reader.example.yaml
#   shred -u /tmp/oci-vault-reader.yaml
#
# The second argument may also be the target *.sops.yaml path itself.
# Plaintext never touches the repo: sops reads /tmp/... and writes ciphertext.
# To change one value later:  sops <path>.sops.yaml  (opens decrypted in $EDITOR)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "seal.sh: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: scripts/seal.sh <filled-secret.yaml> <path/to/name.example.yaml|name.sops.yaml>"
filled=$1
target=$2
command -v sops > /dev/null || die "sops is not installed (see your age/sops notes/scripts/install-tools.sh)"
[ -f "$filled" ] || die "$filled not found"

case "$target" in
  *.example.yaml) target=${target%.example.yaml}.sops.yaml ;;
  *.sops.yaml) ;;
  *) die "target must end in .example.yaml or .sops.yaml" ;;
esac
case "$target" in /*) ;; *) target=$ROOT/$target ;; esac
dir=$(cd "$(dirname "$target")" && pwd) || die "folder of $target does not exist"
target=$dir/$(basename "$target")
case "$target" in "$ROOT"/*) ;; *) die "target must be inside this repo" ;; esac

# The filled file must not sit in the repo where a git add could catch it.
filled_abs=$(cd "$(dirname "$filled")" && pwd)/$(basename "$filled")
case "$filled_abs" in
  "$ROOT"/*)
    git -C "$ROOT" check-ignore -q "$filled_abs" \
      || die "$filled is inside the repo and not git-ignored; keep it in /tmp instead" ;;
esac

grep -q 'age1REPLACE_WITH_YOUR_PUBLIC_KEY' "$ROOT/.sops.yaml" \
  && die ".sops.yaml still has the placeholder recipient; put your age public key there first (docs/WHAT-YOU-DO.md step 2)"
grep -q '^kind: Secret' "$filled" || die "$filled is not a Kubernetes Secret manifest"
grep -vE '^[[:space:]]*#' "$filled" | grep -qiE 'dummy|replace[-_]me' \
  && die "$filled still contains dummy values (dummy/replace-me); fill every key first"

tmp=$(mktemp "$dir/.seal.XXXXXX")
trap 'rm -f "$tmp"' EXIT
sops --config "$ROOT/.sops.yaml" encrypt --filename-override "$target" \
  --input-type yaml --output-type yaml "$filled" > "$tmp"
grep -q '^sops:' "$tmp" || die "sops produced no encrypted output"
mv "$tmp" "$target"
trap - EXIT
echo "sealed -> ${target#"$ROOT"/}"

# Make kustomize pick it up: uncomment "# - name.sops.yaml" or append it.
kfile=$dir/kustomization.yaml
name=$(basename "$target")
if [ -f "$kfile" ]; then
  if grep -qE "^[[:space:]]*-[[:space:]]+${name}[[:space:]]*$" "$kfile"; then
    :
  elif grep -qE "^[[:space:]]*#[[:space:]]*-[[:space:]]+${name}[[:space:]]*$" "$kfile"; then
    sed -i -E "s|^([[:space:]]*)#[[:space:]]*-[[:space:]]+${name}[[:space:]]*$|\1- $name|" "$kfile"
    echo "listed in ${kfile#"$ROOT"/}"
  else
    echo "add '- $name' under resources: in ${kfile#"$ROOT"/}" >&2
  fi
fi
echo "now delete the plaintext: shred -u $filled"
