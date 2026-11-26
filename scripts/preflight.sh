#!/usr/bin/env bash
# preflight.sh: READ-ONLY check of your copy before Flux is installed (and, with --cluster, of the running cluster).
# It changes nothing: no file is written, no kubectl command except get/list, no GitHub setting is touched.
#
#   scripts/preflight.sh                 tools, settings in the files, optional layers, repository state
#   scripts/preflight.sh --validate      also runs scripts/validate.sh (kustomize build + kubeconform; downloads schemas)
#   scripts/preflight.sh --cluster       also asks the cluster your kubeconfig points at: nodes, Flux, ExternalSecrets (read-only)
#   scripts/preflight.sh --offline       skip every check that needs the network (GitHub)
#
# Exit code 0 = nothing to fix (warnings are advice), 1 = at least one FAIL, with what to do about it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFLINE=false
VALIDATE=false
CLUSTER=false
for a in "$@"; do
  case $a in
    --offline) OFFLINE=true ;;
    --validate) VALIDATE=true ;;
    --cluster) CLUSTER=true ;;
    -h | --help) sed -n 2,11p "$0"; exit 0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

fails=0
warns=0
ok() { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
setting() { sed -n -E "s/^  ${1}: *(.*)$/\1/p" "$ROOT/clusters/oke/cluster-settings.yaml" | head -n1; }
layer_on() { grep -qE "^[[:space:]]*-[[:space:]]+${2}[[:space:]]*$" "$ROOT/$1"; }
suspended() { awk -v t="$1" '/^---/ { cur = "" } /^  name: / { cur = $2 } cur == t && /^  suspend:/ { print $2 }' "$ROOT/clusters/oke/infrastructure.yaml"; }

section "1. Tools on this machine"
for t in git jq kubectl sops age; do
  if have "$t"; then ok "$t"; else fail "$t is not installed (docs/WHAT-YOU-DO.md step 1)"; fi
done
if have flux; then ok "flux CLI"; else warn "the flux CLI is not installed: only needed to inspect and reconcile (docs/WHAT-YOU-DO.md)"; fi
if have kubeconform; then ok "kubeconform"; else warn "kubeconform is not installed: scripts/validate.sh needs it (https://github.com/yannh/kubeconform)"; fi
if have gh; then ok "gh"; else warn "the GitHub CLI (gh) is not installed: the repository checks below are skipped"; fi
for t in helm trivy shellcheck; do
  if have "$t"; then ok "$t (optional)"; else warn "$t not installed: optional (scripts/helm-check.py, trivy config, shellcheck)"; fi
done

section "2. Your settings (files in this repository)"
# required: flux-instance.yaml url, .sops.yaml recipient, BASE_DOMAIN, OCI_REGION
url=$(sed -n -E 's/^    url: *(.*)$/\1/p' "$ROOT/clusters/oke/flux-instance.yaml" | head -n1)
if [[ $url == *"<"* || $url == *">"* || -z $url ]]; then fail "clusters/oke/flux-instance.yaml: spec.sync.url is still a placeholder ($url): scripts/configure.sh sets it from GITHUB_REPO"
elif [[ $url =~ ^ssh://git@github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+\.git$ ]]; then ok "Flux follows $url"
else fail "clusters/oke/flux-instance.yaml: spec.sync.url '$url' is not ssh://git@github.com/<owner>/<name>.git"; fi
if grep -q 'age1REPLACE_WITH_YOUR_PUBLIC_KEY' "$ROOT/.sops.yaml"; then fail ".sops.yaml still has the placeholder age recipient: set AGE_PUBLIC_KEY in cluster.env and run scripts/configure.sh (age-keygen -y <keyfile> prints the public key)"
elif grep -qE '^ +- age1[02-9ac-hj-np-z]{58}$' "$ROOT/.sops.yaml"; then ok ".sops.yaml has an age recipient"
else fail ".sops.yaml has no valid age public key (age1 + 58 characters)"; fi
if grep -rIlE '^AGE-SECRET-KEY-1[0-9A-Z]{58}[[:space:]]*$' "$ROOT" --exclude-dir=.git --exclude-dir=.cache 2> /dev/null | grep -q .; then fail "an age PRIVATE key (AGE-SECRET-KEY-) is stored in this folder: remove it, never commit it"; else ok "no age private key in this folder"; fi
v=$(setting BASE_DOMAIN)
if [ -z "$v" ] || [[ $v == *"<"* ]] || [ "$v" = example.com ]; then fail "clusters/oke/cluster-settings.yaml: BASE_DOMAIN is not set ($v): scripts/configure.sh writes it from cluster.env"; else ok "BASE_DOMAIN = $v"; fi
for k in OCI_REGION OCI_NAMESPACE OCI_TENANCY_OCID OCI_VAULT_OCID OCI_VAULT_READER_OCID; do
  v=$(setting "$k")
  if [ -z "$v" ] || [[ $v == *"<"* ]]; then warn "cluster-settings.yaml: $k is still a placeholder: oracle-always-free's scripts/make-reader-key.sh fills it (docs/WHAT-YOU-DO.md step 19), or set it in cluster.env: Flux needs it before it can read the vault"; else ok "$k is set"; fi
done
ntfy_layers=false
if [ "$(suspended infra-security)" = false ] || [ "$(suspended infra-monitoring)" = false ] || layer_on infrastructure/configs/tailscale/kustomization.yaml egress-ntfy-home.yaml || layer_on infrastructure/configs/kustomization.yaml restore-test || layer_on infrastructure/configs/kustomization.yaml previews; then ntfy_layers=true; fi
if [ "$ntfy_layers" = true ]; then
  v=$(setting HOME_TAILNET_FQDN)
  if [[ $v == *"<"* ]]; then warn "an optional layer that talks to ntfy is on, but HOME_TAILNET_FQDN is still a placeholder (cluster-settings.yaml)"; else ok "HOME_TAILNET_FQDN is set"; fi
fi

section "3. Optional layers (what will run)"
for l in monitoring security; do
  s=$(suspended "infra-$l")
  if [ "$s" = true ]; then ok "infra-$l: off (suspended)"; else warn "infra-$l: ON: its secrets must exist in OCI Vault first (docs/RECIPES.md), otherwise it shows errors (it blocks nothing else)"; fi
done
for l in previews restore-test; do
  if layer_on infrastructure/configs/kustomization.yaml "$l"; then warn "$l: ON: read docs/RECIPES.md first ($l is written for the original author's setup and needs secrets)"; else ok "$l: off"; fi
done
if layer_on infrastructure/configs/kustomization.yaml image-automation; then
  warn "image automation: ON: Flux commits new image digests to main, so its deploy key has WRITE access to your repository and you cannot require pull requests on main. Turn it off with LAYER_IMAGE_AUTOMATION=false (README, security notes)"
else
  ok "image automation: off (the deploy key can be read-only)"
fi
for f in egress-ntfy-home.yaml rbac-chatops.yaml; do
  if layer_on infrastructure/configs/tailscale/kustomization.yaml "$f"; then warn "$f: ON (optional integration with a home server)"; else ok "$f: off"; fi
done
if grep -rn -E 'validationActions: *\[Audit\]|value: \[Audit\]' "$ROOT/infrastructure/configs/kyverno-policies/kustomization.yaml" > /dev/null 2>&1; then warn "Kyverno policies are in Audit (report only, nothing is blocked): switch to Deny after checking kubectl get policyreports -A (docs/WHAT-YOU-DO.md step 14)"; else ok "Kyverno policies are not in Audit"; fi

section "4. Files of this repository"
if [ -n "$(cd "$ROOT" && git ls-files '*.plain.yaml' '*.secret.yaml' '*.dec.yaml' '*.agekey' 'keys.txt' '.env' 2> /dev/null)" ]; then fail "a plaintext secret or key file is tracked by git: git rm --cached it"; else ok "no plaintext secret or key file is tracked by git"; fi
sops_bad=""
while IFS= read -r f; do
  if ! grep -q '^sops:' "$ROOT/$f" 2> /dev/null; then sops_bad="$sops_bad $f"; fi
done < <(cd "$ROOT" && git ls-files '*.sops.yaml' 2> /dev/null | grep -v '^\.sops\.yaml$')
if [ -z "$sops_bad" ]; then ok "every *.sops.yaml in git is encrypted (or there is none yet)"; else fail "not encrypted:$sops_bad"; fi
if [ -f "$ROOT/infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml" ]; then ok "the Vault reader key is sealed (oci-vault-reader.sops.yaml)"; else warn "no oci-vault-reader.sops.yaml yet: oracle-always-free's scripts/make-reader-key.sh creates it (docs/WHAT-YOU-DO.md step 19)"; fi
if [ "$VALIDATE" = true ]; then
  if have kubeconform && have kubectl; then
    if "$ROOT/scripts/validate.sh" > /dev/null 2>&1; then ok "scripts/validate.sh passes (kustomize build and kubeconform)"; else fail "scripts/validate.sh fails: run it to see why"; fi
  else
    warn "--validate: kubectl or kubeconform missing"
  fi
else
  warn "scripts/validate.sh was not run (add --validate; it downloads schemas)"
fi

section "5. Repository settings (network)"
if [ "$OFFLINE" = true ] || ! have gh; then
  warn "repository settings not checked (--offline, or gh missing)"
elif ! gh auth status > /dev/null 2>&1; then
  fail "gh is not logged in: gh auth login"
else
  slug=$(sed -n -E 's#^    url: *ssh://git@github\.com/(.*)\.git$#\1#p' "$ROOT/clusters/oke/flux-instance.yaml" | head -n1)
  if [ -z "$slug" ] || [[ $slug == *"<"* ]]; then
    warn "no repository named in flux-instance.yaml yet"
  else
    priv=$(gh repo view "$slug" --json isPrivate,isFork --jq '"\(.isPrivate) \(.isFork)"' 2> /dev/null || true)
    case $priv in
      "true false") ok "$slug is private and is not a fork" ;;
      "true true") warn "$slug is a private fork: prefer a clone pushed to a new private repository" ;;
      "false"*) fail "$slug is PUBLIC: Flux's deploy key and your cluster layout belong in a PRIVATE repository" ;;
      *) warn "could not read $slug (does it exist yet? are you logged in as its owner?)" ;;
    esac
    pol=$(gh api "repos/$slug/actions/permissions/workflow" --jq .default_workflow_permissions 2> /dev/null || true)
    case $pol in
      read) ok "Actions default token permission is read" ;;
      write) fail "Actions default token permission is write: Settings -> Actions -> General -> Workflow permissions -> Read repository contents" ;;
      *) warn "could not read the Actions workflow permissions (verify in Settings -> Actions -> General)" ;;
    esac
    fpr=$(gh api "repos/$slug/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2> /dev/null || true)
    if [ "$fpr" = all_external_contributors ]; then ok "fork pull requests need approval from you"; else warn "fork pull request approval is '${fpr:-unknown}': set Settings -> Actions -> General -> Fork pull request workflows -> Require approval for all external contributors (verify)"; fi
    keys=$(gh api "repos/$slug/keys" --jq '.[] | "\(.title)|\(.read_only)"' 2> /dev/null || true)
    if [ -z "$keys" ]; then warn "no deploy key on $slug yet (oracle-always-free's scripts/put-flux-secrets.sh adds it) or the keys could not be listed"
    else
      if grep -q '|false$' <<< "$keys"; then
        if layer_on infrastructure/configs/kustomization.yaml image-automation; then ok "a deploy key with write access exists (needed by image automation)"; else warn "a deploy key with WRITE access exists but image automation is off: make it read-only (FLUX_DEPLOY_KEY_WRITE=false ./scripts/put-flux-secrets.sh ... in oracle-always-free) and delete the old one"; fi
      else ok "the deploy key(s) are read-only"; fi
    fi
    br=$(gh api "repos/$slug/branches/main/protection" --jq .url 2> /dev/null || true)
    if [ -n "$br" ]; then ok "branch main is protected"; else warn "branch main has no protection (or the plan does not offer it on private repositories): see the README security notes for what to do"; fi
  fi
fi

if [ "$CLUSTER" = true ]; then
  section "6. The cluster (read-only kubectl)"
  if ! have kubectl; then fail "kubectl is not installed"
  elif ! kubectl version --request-timeout=10s > /dev/null 2>&1; then fail "kubectl cannot reach a cluster: tailscale configure kubeconfig oke-free (or the Bastion session of flux-bootstrap.yml, docs/WHAT-YOU-DO.md)"
  else
    n=$(kubectl get nodes --no-headers 2> /dev/null | grep -c ' Ready' || true)
    if [ "${n:-0}" -ge 1 ]; then ok "$n node(s) Ready"; else fail "no Ready node"; fi
    fi_ready=$(kubectl -n flux-system get fluxinstance flux -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || true)
    if [ "$fi_ready" = True ]; then ok "FluxInstance flux is Ready"; else fail "FluxInstance flux is not Ready (flux-bootstrap.yml in oracle-always-free installs it): kubectl -n flux-system describe fluxinstance flux"; fi
    notready=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2> /dev/null | awk '$4 == "False" {print $2}' | tr '\n' ' ' || true)
    if [ -z "$notready" ]; then ok "every Flux Kustomization is Ready (or none exists yet)"; else fail "not Ready:$notready (flux logs --kind=Kustomization --name=<name> -n flux-system)"; fi
    bad=$(kubectl get externalsecrets.external-secrets.io -A --no-headers 2> /dev/null | awk '$5 != "SecretSynced" && $5 != "Valid" && $5 != "" {print $1"/"$2}' | tr '\n' ' ' || true)
    if [ -z "$bad" ]; then ok "every ExternalSecret is synced (or none exists yet)"; else warn "ExternalSecrets not synced:$bad (kubectl -n <ns> describe externalsecret <name>)"; fi
  fi
fi

section "Result"
if [ "$fails" -eq 0 ]; then
  printf '  Nothing to fix (%d warning(s)). Next: README, "Use it".\n' "$warns"
  exit 0
fi
printf '  %d thing(s) to fix (the [FAIL] lines above), %d warning(s). Nothing was changed by this script.\n' "$fails" "$warns"
exit 1
