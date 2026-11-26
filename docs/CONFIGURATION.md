# Configuration: every variable of this repository

Everything that is yours (repository, domain, keys) or a matter of taste (which optional layers run) is a variable. Nothing of the
original author is left in the defaults. Flux reads the values from the ConfigMap `cluster-settings` (substituted as `${NAME}` into
manifests); a few values live in other files. To avoid editing five files by hand, put your settings into **`cluster.env`** and run
**`scripts/configure.sh`** (it shows a diff with `--check` first); **`scripts/preflight.sh`** checks the result (read-only).
Examples use placeholders only: `<your-...>`.

Where a value is set:

| Where | How |
|---|---|
| **cluster.env** | `cp cluster.env.example cluster.env` (git-ignored), then `scripts/configure.sh`; it writes the files below, which you commit |
| **cluster-settings** | `clusters/oke/cluster-settings.yaml`: a ConfigMap whose keys Flux substitutes as `${NAME}` into every Kustomization layer. Not secret |
| **file** | another file in this repository (named in the table) |
| **Vault secret** | OCI Vault (oracle-always-free `scripts/put-secret.sh <name> <file.json>`); read through External Secrets. Secret: never in git |

## 1. What you MUST set (nothing else is needed for the first sync)

| Name | Meaning | Written to | Example |
|---|---|---|---|
| `GITHUB_REPO` | YOUR private copy of this repository: the repository Flux follows | `clusters/oke/flux-instance.yaml` (`spec.sync.url`, an `ssh://git@github.com/<owner>/<name>.git` URL) | `<your-github-user>/<your-private-repo>` |
| `BASE_DOMAIN` | your Cloudflare zone; apps are `<name>.<BASE_DOMAIN>` (must match `zone_name` of `cloudflare-free`) | cluster-settings `BASE_DOMAIN` | `<your-domain>` (for example `mydomain.org`) |
| `AGE_PUBLIC_KEY` | the PUBLIC key of your SOPS age key (`age-keygen -y <keyfile>`); never the `AGE-SECRET-KEY` | `.sops.yaml` (first recipient) | `age1<your-age-public-key>` |

Filled for you by `oracle-always-free` `scripts/make-reader-key.sh` (or set them in `cluster.env`): `OCI_REGION`, `OCI_NAMESPACE`,
`OCI_TENANCY_OCID`, `OCI_VAULT_OCID`, `OCI_VAULT_READER_OCID`.

## 2. cluster-settings keys (`clusters/oke/cluster-settings.yaml`)

| Key | Meaning | Default | Required | Set by |
|---|---|---|---|---|
| `BASE_DOMAIN` | your zone | `<your-domain>` placeholder | yes | `configure.sh` |
| `OCI_REGION` | your home region (External Secrets talks to the vault there) | `<your-home-region>` placeholder | yes | `make-reader-key.sh` or `configure.sh` |
| `OCI_NAMESPACE` | Object Storage namespace of the tenancy | `<namespace>` placeholder | yes (backups, restore test) | `make-reader-key.sh` or `configure.sh` |
| `OCI_TENANCY_OCID`, `OCI_VAULT_OCID`, `OCI_VAULT_READER_OCID` | the vault and its read-only user (not secret) | placeholders | yes | `make-reader-key.sh` |
| `CLUSTER_NAME` | label in alerts | `oke-free` | no | `configure.sh` |
| `CLUSTER_DOMAIN` | cluster DNS domain | `cluster.local` | no | edit the file |
| `POD_CIDR` | pod network (Traefik trusts it for `X-Forwarded-*`); must match `oracle-always-free` `infra/network.tf` | `10.244.0.0/16` | no | `configure.sh` |
| `HOME_TAILNET_FQDN` | MagicDNS name of YOUR server that runs a private ntfy; only the optional ntfy layers use it | `chatops.<tailnet>.ts.net` placeholder | only with those layers | `configure.sh` |
| `NTFY_TOPIC` | topic for cluster results (restore test, previews) | `cluster` | no | `configure.sh` |

## 3. Optional layers (toggles)

All are **off** by default except image automation. Set them in `cluster.env` as `true` or `false`, or edit the named file.

| Variable | Layer | What it needs first | File it changes |
|---|---|---|---|
| `LAYER_MONITORING` | `infra-monitoring`: kube-prometheus-stack (slim) + OpenTelemetry to Grafana Cloud and New Relic | Vault secrets `monitoring-otel-credentials`, `monitoring-alertmanager-ntfy`, and an ntfy server (docs/RECIPES.md recipe 7) | `suspend:` in `clusters/oke/infrastructure.yaml` |
| `LAYER_SECURITY` | `infra-security`: CrowdSec on Traefik's access log, alert only (reads node logs through a read-only hostPath, root init container) | Vault secret `crowdsec-ntfy` and YOUR ntfy server at `https://ntfy.<BASE_DOMAIN>/` | `suspend:` in `clusters/oke/infrastructure.yaml` |
| `LAYER_PREVIEWS` | pull-request preview environments | Vault secrets `previews-github-auth`, `previews-preview-smoke`; `enable_preview_dns` in `cloudflare-free` (recipe 8) | `infrastructure/configs/kustomization.yaml` |
| `LAYER_RESTORE_TEST` | weekly restore test and monthly DR drill, **written for one kind of backup of the original author: adapt it first** | Vault secret `restore-test-restore-test`, a restic repository (recipe 5) | `infrastructure/configs/kustomization.yaml` |
| `LAYER_IMAGE_AUTOMATION` (default `true`) | Flux commits new image digests of `apps/hello` to `main` | a deploy key WITH write access; you cannot require pull requests on `main` (README, security notes) | `infrastructure/configs/kustomization.yaml` |
| `LAYER_HOME_NTFY_EGRESS` | tailnet egress to a private ntfy on your own server | `HOME_TAILNET_FQDN` | `infrastructure/configs/tailscale/kustomization.yaml` |
| `LAYER_CHATOPS_RBAC` | read-mostly RBAC role `chatops` for a chat bot that reaches the API through the tailnet | a tailnet grant that maps a user to the Kubernetes group `chatops` | `infrastructure/configs/tailscale/kustomization.yaml` |

A layer left out of `cluster.env` stays as the files have it. `scripts/preflight.sh` lists what is on.

## 4. Settings that are not in `cluster.env`

| What | Where | Default | Note |
|---|---|---|---|
| Kyverno enforcement | `infrastructure/configs/kyverno-policies/kustomization.yaml`, the `[Audit]` value | `[Audit]` (report only) | switch to `[Deny]` after `kubectl get policyreports -A` shows nothing would be blocked (docs/WHAT-YOU-DO.md step 14) |
| Flux profile and version | `clusters/oke/flux-instance.yaml` | `size: small`, `version: 2.x` | CPU requests are lowered for two 1-OCPU nodes: keep that patch |
| Apps | `apps/kustomization.yaml` and one folder per app | `hello` only | `hello.<BASE_DOMAIN>` must be a name in `cloudflare-free` `cluster_hostnames` |
| Helm chart versions | `infrastructure/controllers/*/helmrelease.yaml` | ranges inside a major (`42.x`, `1.x`) | pin an exact version if you prefer; Renovate proposes bumps |
| Allowed registries | `infrastructure/configs/kyverno-policies/allowed-registries.yaml` | Docker Hub, ghcr.io, quay.io, mirror.gcr.io, reg.kyverno.io, registry.k8s.io | add yours; only reports in Audit mode |

## 5. Vault secrets (OCI Vault, put with `put-secret.sh`; never in git)

| Vault secret | Keys | Layer | Required |
|---|---|---|---|
| `cloudflared-tunnel-token` | `TUNNEL_TOKEN` (output `tunnel_token` of `cloudflare-free`) | cloudflared | yes |
| `tailscale-operator-oauth` | `client_id`, `client_secret` (a Tailscale OAuth client) | Tailscale operator | yes |
| `monitoring-otel-credentials`, `monitoring-alertmanager-ntfy` | see the ExternalSecret files | monitoring | with `LAYER_MONITORING` |
| `crowdsec-ntfy` | see the ExternalSecret file | security | with `LAYER_SECURITY` |
| `previews-github-auth`, `previews-preview-smoke` | see the ExternalSecret files | previews | with `LAYER_PREVIEWS` |
| `restore-test-restore-test` | see the ExternalSecret file | restore test | with `LAYER_RESTORE_TEST` |

The only secret in git is the Vault reader's API key, encrypted with SOPS to YOUR age key (`oci-vault-reader.sops.yaml`, written by `make-reader-key.sh`).
The age PRIVATE key lives on your laptop and, as a Kubernetes Secret, in the cluster (`flux-system/sops-age`, put there by `flux-bootstrap.yml` from the Vault).

## 5b. Environment variables of `scripts/validate.sh`

| Variable | Meaning | Default |
|---|---|---|
| `OUT_DIR` | where the rendered manifests go | `.cache/rendered` (git-ignored) |
| `SKIP_KINDS` | comma list of kinds without a schema, to skip in kubeconform (keep it empty: never `-ignore-missing-schemas`) | empty |

## 6. Pinned versions in the workflows

`KUBECTL_VERSION`, `KUBECONFORM_VERSION`, `FLUX_OPERATOR_VERSION`, `TRIVY_VERSION` (`validate.yml`, downloads are checksum-verified),
`GITLEAKS_VERSION` + `GITLEAKS_SHA256` (`gitleaks.yml`: change both together). Actions are pinned to commit SHAs; Renovate proposes bumps.
