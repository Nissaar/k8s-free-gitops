#!/usr/bin/env bash
# configure.sh: write YOUR settings into the few files that hold them, so you edit one small file (cluster.env) instead of five.
#
#   cp cluster.env.example cluster.env && $EDITOR cluster.env     # git-ignored; every variable is documented in docs/CONFIGURATION.md
#   scripts/configure.sh --check                                  # shows the diff it WOULD make; changes nothing
#   scripts/configure.sh                                          # writes the files; review with git diff, commit them by name
#
# Settings come from the environment or from the file named by --env-file (default: cluster.env when it exists); the environment wins.
#   required   GITHUB_REPO     owner/name of YOUR private copy of this repository      -> clusters/oke/flux-instance.yaml (spec.sync.url)
#              BASE_DOMAIN     your Cloudflare zone (the apps are <name>.<BASE_DOMAIN>)  -> clusters/oke/cluster-settings.yaml
#              AGE_PUBLIC_KEY  the PUBLIC key of your SOPS age key (age1...)             -> .sops.yaml
#   optional   OCI_REGION, OCI_NAMESPACE, CLUSTER_NAME, POD_CIDR, HOME_TAILNET_FQDN, NTFY_TOPIC   -> clusters/oke/cluster-settings.yaml
#              (oracle-always-free scripts/make-reader-key.sh also fills OCI_REGION, OCI_NAMESPACE and the three OCIDs for you)
#   layers     LAYER_MONITORING, LAYER_SECURITY       true|false  (default false)  -> suspend: in clusters/oke/infrastructure.yaml
#              LAYER_PREVIEWS, LAYER_RESTORE_TEST     true|false  (default false)  -> infrastructure/configs/kustomization.yaml
#              LAYER_IMAGE_AUTOMATION                 true|false  (default true)   -> infrastructure/configs/kustomization.yaml
#              LAYER_HOME_NTFY_EGRESS, LAYER_CHATOPS_RBAC  true|false  (default false) -> infrastructure/configs/tailscale/kustomization.yaml
# A layer variable you do not set is left as it is in the files. Nothing here is secret: secrets live in OCI Vault (docs/WHAT-YOU-DO.md).
# Safe to run again. Needs: bash, sed, awk, diff.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK=false
ENVFILE=""
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=true ;;
    --env-file) ENVFILE=${2:?--env-file needs a file}; shift ;;
    -h | --help) sed -n 2,19p "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$ENVFILE" ] && [ -f "$ROOT/cluster.env" ]; then ENVFILE=$ROOT/cluster.env; fi

die() { echo "configure.sh: $*" >&2; exit 1; }

# Read KEY=value lines of the env file without executing it; a variable already in the environment wins.
if [ -n "$ENVFILE" ]; then
  [ -f "$ENVFILE" ] || die "$ENVFILE not found"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'* ) continue ;; esac
    [[ $line =~ ^[A-Z_][A-Z0-9_]*= ]] || die "$ENVFILE: not a KEY=value line: ${line%%=*}"
    key=${line%%=*}
    val=${line#*=}
    val=${val%%[[:space:]]#*}   # trailing comment after whitespace
    val=${val%"${val##*[![:space:]]}"}   # trailing spaces
    val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
    [ -n "${!key+x}" ] || printf -v "$key" '%s' "$val"
  done < "$ENVFILE"
fi

# Work on a copy in --check mode so nothing is touched.
if [ "$CHECK" = true ]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  for f in clusters/oke/flux-instance.yaml clusters/oke/cluster-settings.yaml clusters/oke/infrastructure.yaml .sops.yaml \
    infrastructure/configs/kustomization.yaml infrastructure/configs/tailscale/kustomization.yaml; do
    mkdir -p "$WORK/$(dirname "$f")"
    cp "$ROOT/$f" "$WORK/$f"
  done
  TARGET=$WORK
else
  TARGET=$ROOT
fi

req() { [ -n "${!1:-}" ] || die "$1 is required (cluster.env.example explains it; docs/CONFIGURATION.md lists every variable)"; }
bool() { case ${!1:-} in '' | true | false) ;; *) die "$1 must be true or false, got '${!1}'" ;; esac; }
no_placeholder() { case ${!1:-} in *'<'* | *'>'* ) die "$1 still has a <placeholder>" ;; esac; }

# set_key FILE KEY VALUE: replace "  KEY: ..." in a ConfigMap data block
set_key() {
  grep -qE "^  $2: " "$TARGET/$1" || die "$1 has no key $2 (the file changed shape?)"
  local v=$3
  sed -i -E "s|^(  $2: ).*|\\1${v//|/\\|}|" "$TARGET/$1"
}
# layer_resource FILE NAME true|false: comment or uncomment "- NAME" in a kustomization's resources
layer_resource() {
  local f=$TARGET/$1 name=$2
  grep -qE "^[[:space:]]*(#[[:space:]]*)?-[[:space:]]+${name}[[:space:]]*$" "$f" || die "$1 has no resource line for $name (the file changed shape?)"
  if [ "$3" = true ]; then
    sed -i -E "s|^([[:space:]]*)#[[:space:]]*-[[:space:]]+${name}[[:space:]]*$|\\1- $name|" "$f"
  else
    sed -i -E "s|^([[:space:]]*)-[[:space:]]+${name}[[:space:]]*$|\\1# - $name|" "$f"
  fi
}
# layer_suspend NAME true|false: the suspend: line of a Flux Kustomization (true = layer OFF)
layer_suspend() {
  local f=$TARGET/clusters/oke/infrastructure.yaml suspend=$2 tmp
  grep -qE "^  name: $1\$" "$f" || die "clusters/oke/infrastructure.yaml has no Kustomization $1"
  tmp=$(mktemp)
  awk -v target="$1" -v val="$suspend" '
    /^---/ { cur = "" }
    /^  name: / { cur = $2 }
    cur == target && /^  suspend:/ { sub(/suspend: .*/, "suspend: " val) }
    { print }' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ---- required
req GITHUB_REPO; req BASE_DOMAIN; req AGE_PUBLIC_KEY
[[ $GITHUB_REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]] || die "GITHUB_REPO must look like owner/name (your private copy), got '$GITHUB_REPO'"
[[ $BASE_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "BASE_DOMAIN must be your domain in lower case (for example mydomain.org), got '$BASE_DOMAIN'"
case $BASE_DOMAIN in example.com | example.net | example.org) die "BASE_DOMAIN is a placeholder; use your own zone" ;; esac
[[ $AGE_PUBLIC_KEY =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || die "AGE_PUBLIC_KEY must be an age PUBLIC key (age1 and 58 characters; age-keygen -y <keyfile>), never the AGE-SECRET-KEY"

# ---- optional
[ -z "${OCI_REGION:-}" ] || [[ $OCI_REGION =~ ^[a-z]{2,3}-[a-z]+-[0-9]+$ ]] || die "OCI_REGION must look like eu-frankfurt-1"
[ -z "${OCI_NAMESPACE:-}" ] || [[ $OCI_NAMESPACE =~ ^[a-z0-9]{3,63}$ ]] || die "OCI_NAMESPACE is the Object Storage namespace (letters and digits)"
[ -z "${CLUSTER_NAME:-}" ] || [[ $CLUSTER_NAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "CLUSTER_NAME must be a DNS label"
[ -z "${POD_CIDR:-}" ] || [[ $POD_CIDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "POD_CIDR must be an IPv4 CIDR (the pod network of the cluster)"
[ -z "${HOME_TAILNET_FQDN:-}" ] || [[ $HOME_TAILNET_FQDN =~ ^[a-z0-9.-]+\.ts\.net$ ]] || die "HOME_TAILNET_FQDN must be a MagicDNS name ending in .ts.net"
[ -z "${NTFY_TOPIC:-}" ] || [[ $NTFY_TOPIC =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "NTFY_TOPIC must be a topic name (letters, digits, - and _)"
for v in OCI_REGION OCI_NAMESPACE CLUSTER_NAME POD_CIDR HOME_TAILNET_FQDN NTFY_TOPIC; do no_placeholder "$v"; done
for v in LAYER_MONITORING LAYER_SECURITY LAYER_PREVIEWS LAYER_RESTORE_TEST LAYER_IMAGE_AUTOMATION LAYER_HOME_NTFY_EGRESS LAYER_CHATOPS_RBAC; do bool "$v"; done

# ---- write
sed -i -E "s|^(    url: ).*|\\1ssh://git@github.com/$GITHUB_REPO.git|" "$TARGET/clusters/oke/flux-instance.yaml"
grep -q "ssh://git@github.com/$GITHUB_REPO.git" "$TARGET/clusters/oke/flux-instance.yaml" || die "clusters/oke/flux-instance.yaml has no spec.sync.url line (the file changed shape?)"
sed -i -E "0,/^ {10}- age1[A-Za-z0-9_]+/ s/^( {10}- )age1[A-Za-z0-9_]+/\\1$AGE_PUBLIC_KEY/" "$TARGET/.sops.yaml"   # the first recipient only
grep -q "$AGE_PUBLIC_KEY" "$TARGET/.sops.yaml" || die ".sops.yaml has no age recipient line (the file changed shape?)"
set_key clusters/oke/cluster-settings.yaml BASE_DOMAIN "$BASE_DOMAIN"
for v in OCI_REGION OCI_NAMESPACE CLUSTER_NAME POD_CIDR HOME_TAILNET_FQDN NTFY_TOPIC; do
  [ -z "${!v:-}" ] || set_key clusters/oke/cluster-settings.yaml "$v" "${!v}"
done
[ -z "${LAYER_MONITORING:-}" ] || layer_suspend infra-monitoring "$([ "$LAYER_MONITORING" = true ] && echo false || echo true)"
[ -z "${LAYER_SECURITY:-}" ] || layer_suspend infra-security "$([ "$LAYER_SECURITY" = true ] && echo false || echo true)"
[ -z "${LAYER_PREVIEWS:-}" ] || layer_resource infrastructure/configs/kustomization.yaml previews "$LAYER_PREVIEWS"
[ -z "${LAYER_RESTORE_TEST:-}" ] || layer_resource infrastructure/configs/kustomization.yaml restore-test "$LAYER_RESTORE_TEST"
[ -z "${LAYER_IMAGE_AUTOMATION:-}" ] || layer_resource infrastructure/configs/kustomization.yaml image-automation "$LAYER_IMAGE_AUTOMATION"
[ -z "${LAYER_HOME_NTFY_EGRESS:-}" ] || layer_resource infrastructure/configs/tailscale/kustomization.yaml egress-ntfy-home.yaml "$LAYER_HOME_NTFY_EGRESS"
[ -z "${LAYER_CHATOPS_RBAC:-}" ] || layer_resource infrastructure/configs/tailscale/kustomization.yaml rbac-chatops.yaml "$LAYER_CHATOPS_RBAC"

if [ "$CHECK" = true ]; then
  echo "configure.sh --check: what would change (nothing was written):"
  changed=false
  for f in clusters/oke/flux-instance.yaml clusters/oke/cluster-settings.yaml clusters/oke/infrastructure.yaml .sops.yaml \
    infrastructure/configs/kustomization.yaml infrastructure/configs/tailscale/kustomization.yaml; do
    if ! diff -u --label "a/$f" --label "b/$f" "$ROOT/$f" "$WORK/$f"; then changed=true; fi
  done
  [ "$changed" = true ] || echo "  (no change: the files already hold these settings)"
  exit 0
fi
echo "configure.sh: settings written. Review with:  git diff --stat"
echo "Next: scripts/preflight.sh, then commit BY NAME:"
echo "  git add .sops.yaml clusters/oke/flux-instance.yaml clusters/oke/cluster-settings.yaml clusters/oke/infrastructure.yaml infrastructure/configs/kustomization.yaml infrastructure/configs/tailscale/kustomization.yaml"
