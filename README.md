# k8s-free-gitops

A **Flux GitOps repository** for a small Kubernetes cluster on Oracle Cloud's Always Free tier (two Arm nodes, 1 OCPU / 6 GB each): ingress without a
public IP, a Cloudflare Tunnel connector, the Tailscale operator for kubectl, secrets from OCI Vault through External Secrets, admission policies, image-digest
updates with Flux image automation, and optional layers for previews, monitoring, security alerts and restore tests. Whatever is on `main` is what runs; nobody runs `kubectl apply` by hand.

> **Use it from a PRIVATE repository of your own, not from a fork** (reasons in [Use it](#use-it), step 1): Flux needs a deploy key to your repository, and your layout and settings are yours.
> Community code, not affiliated with Oracle, Cloudflare or Tailscale.
> `Nissaar` below is the GitHub account that publishes this repository; `<your-...>` is always a value of yours.
> Every variable is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What you get for free

| Piece | Where | Cost |
|---|---|---|
| Flux 2.x through the Flux Operator (6 controllers, `small` profile), including image automation | `clusters/oke/flux-instance.yaml` | none |
| Traefik ingress (ClusterIP only: no load balancer), `cloudflared` x2 connecting out to your Cloudflare tunnel | `infrastructure/controllers/traefik`, `cloudflared` | none |
| Tailscale operator: kubectl over your tailnet, the API server has no public address | `infrastructure/controllers/tailscale` | free tailnet |
| External Secrets reading OCI Vault (150 free secrets); the one SOPS-sealed secret is the Vault reader's API key | `infrastructure/controllers/external-secrets`, `secret-store` | none |
| `local-path` storage class on the nodes' boot volumes | `infrastructure/controllers/local-path` | within the 200 GB |
| Kyverno policies (allowed registries, no privileged pods, requests and limits), all in **Audit** | `infrastructure/configs/kyverno-policies` | none |
| Trivy Operator (vulnerability and config reports) | `infrastructure/controllers/trivy-operator` | none |
| `hello`: a sample app that follows `:latest` by digest through image automation | `apps/hello` | none |
| **Optional, off by default:** PR previews | `infrastructure/configs/previews` | see recipe 8 |
| **Optional, off by default:** weekly restore test and monthly DR drill (specific to one kind of backup: adapt first) | `infrastructure/configs/restore-test` | see recipe 5 |
| **Optional, suspended by default:** slim Prometheus + OpenTelemetry to Grafana Cloud and New Relic | `infrastructure/monitoring` | see recipe 7 |
| **Optional, suspended by default:** CrowdSec reading Traefik's access log, alerts to an ntfy topic | `infrastructure/security` | needs an ntfy server and token |
| **Optional, off by default:** tailnet egress to a private ntfy and a ChatOps RBAC role | `infrastructure/configs/tailscale` | needs a home server |

How Flux applies the layers, the secrets table, image updates, the resource budget: [docs/DESIGN.md](docs/DESIGN.md). Every manual step in order: [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md).

## Who it is for

You run (or will run) the cluster of `oracle-always-free`, you want it managed from git, and you are comfortable reading Kubernetes manifests and Flux status. It is **not** a
general-purpose cluster template: it assumes OKE Basic with two small Arm nodes, OCI Vault for secrets, a Cloudflare tunnel in front and Tailscale for admin access.

## Accounts, prerequisites and the one thing that can still cost money

- The cluster from **`oracle-always-free`** (OKE Basic, two Arm nodes, a Vault, the `cluster-secrets-reader` user) already running or at least planned: this repository cannot work without it.
- The tunnel from **`cloudflare-free`** (its step "copy the tunnel token") and a domain on Cloudflare.
- A **Tailscale** account (free) with MagicDNS and HTTPS certificates enabled, and an OAuth client for the operator (docs step 4).
- A **GitHub** account, `gh`, and a **private** repository for this code; a fresh **age** key (`age-keygen`) for SOPS.
- On your laptop: `git`, `kubectl`, `flux` (CLI), `sops`, `age`, `jq`, and for the offline checks `kubeconform`. Optionally `helm` and `trivy`.

**The one thing that can still cost money:** a Kubernetes `Service` of type `LoadBalancer` (OKE would create a billable load balancer outside the free allowance) or a volume on the block-volume storage class
instead of `local-path`. Nothing in this repository creates either: Traefik is ClusterIP, and the only way in is the tunnel. Do not add them. The quotas of `oracle-always-free` refuse most of it anyway.

## Use it

Every command runs on your laptop in the folder of your private copy. Steps marked **verify** were not run by anyone yet.

**1. Make your own PRIVATE copy** (clone, then push to a new private repository):

```bash
git clone https://github.com/Nissaar/k8s-free-gitops.git my-cluster && cd my-cluster
git remote rename origin upstream
gh repo create <your-github-user>/<your-private-repo> --private --source . --remote origin --push
git remote -v          # origin = your private copy, upstream = this repository
```

Why private and not a fork: your cluster layout, domain and optional integrations are yours, and Flux's deploy key gives the cluster access to the repository; a fork of a public repository is always public.
Why clone and not "Use this template": the shared history lets you merge updates later ([Keep it up to date](#keep-it-up-to-date)).

**2. Harden the repository settings now** (web: **Settings**; the commands are **verify**):

```bash
SLUG=<your-github-user>/<your-private-repo>
gh api -X PUT "repos/$SLUG/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$SLUG/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
```

Also in **Settings -> Code security**: secret scanning and push protection (a private repository may need GitHub's paid secret-protection plan; the gitleaks workflow scans every push either way).
**Protecting `main` conflicts with image automation:** Flux pushes digest commits straight to `main`. Choose one: (a) **image automation off** (`LAYER_IMAGE_AUTOMATION=false` in step 4, a read-only deploy key later) and
**protect `main`** (pull request and one review; branch protection on a private repository needs GitHub Pro, Team or Enterprise); or (b) image automation on and a **single-owner repository** (or, with
Team/Enterprise, let the deploy key bypass the protection). Whoever can write to `main` controls what runs in your cluster: that is the point of GitOps and the reason to keep write access to yourself.

**3. Make your age key** (the key SOPS encrypts the one secret in git with; keep a backup, losing it means re-sealing):

```bash
mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/cluster.txt     # prints "Public key: age1..."
age-keygen -y ~/.config/sops/age/cluster.txt                                     # the public key again
```

**4. Put your settings in one file and write them** (nothing in `cluster.env` is secret):

```bash
cp cluster.env.example cluster.env && "${EDITOR:-nano}" cluster.env    # GITHUB_REPO, BASE_DOMAIN, AGE_PUBLIC_KEY (+ optional layers)
scripts/configure.sh --check                                           # shows the diff, changes nothing
scripts/configure.sh                                                   # writes the files
git diff --stat
git add .sops.yaml clusters/oke/flux-instance.yaml clusters/oke/cluster-settings.yaml clusters/oke/infrastructure.yaml infrastructure/configs/kustomization.yaml infrastructure/configs/tailscale/kustomization.yaml
git commit -m "chore: my settings" && git push
```

`configure.sh` prints `configure.sh: settings written.` and the `git add` line to use. The three OCIDs, the region and the namespace are filled later by `oracle-always-free`'s `scripts/make-reader-key.sh` (step 6).

**5. Check everything before Flux exists** (read-only; `--validate` also builds every Flux path and runs kubeconform, downloading schemas):

```bash
scripts/preflight.sh --validate
```

It lists tools, settings, optional layers, files and repository settings as `[ ok ]`, `[warn]` or `[FAIL]`. Expected at this point: no `[FAIL]`; warnings about the OCIDs and `oci-vault-reader.sops.yaml` are normal until step 6.
Offline only: `scripts/validate.sh` alone prints one `kustomize ok   <path> (<n> objects)` line per Flux path and `Summary: 59 resources found in 8 files - Valid: 59, Invalid: 0, Errors: 0, Skipped: 0` (the numbers change with the layers).

**6. Tailscale and secrets** ([docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step 4: tailnet policy, OAuth client; step 19: the cluster's key to OCI Vault). In your `oracle-always-free` copy:

```bash
cd ~/my-oracle-free                                   # your oracle-always-free copy
./scripts/make-reader-key.sh ~/my-cluster             # seals the Vault reader key to YOUR age key and fills the OCI_* settings here; commit them in this repository, by name
./scripts/put-secret.sh tailscale-operator-oauth oauth.json        # {"client_id": "...", "client_secret": "..."}; delete the file afterwards
FLUX_DEPLOY_KEY_WRITE=true ./scripts/put-flux-secrets.sh ~/.config/sops/age/cluster.txt <your-github-user>/<your-private-repo>    # false when image automation is off

cd ~/my-cloudflare-free                               # your cloudflare-free copy (R2 keys and API token exported, see its WHAT-YOU-DO step 9)
tofu -chdir=infra output -raw tunnel_token | jq -R '{TUNNEL_TOKEN: .}' | ~/my-oracle-free/scripts/put-secret.sh cloudflared-tunnel-token -
```

The exact steps, including how to create the Tailscale OAuth client, are in docs/WHAT-YOU-DO.md (steps 4, 5 and 19) and in the other two repositories' guides; the folder names above are examples (**verify** your own).

**7. Install Flux:** in your `oracle-always-free` copy, **Actions -> flux-bootstrap -> Run workflow -> type `bootstrap`** (it needs the Actions variable `CLUSTER_REPO` = `<your-github-user>/<your-private-repo>`). Then, with Tailscale up, `tailscale configure kubeconfig oke-free` and check:

```bash
scripts/preflight.sh --cluster                        # read-only: nodes, FluxInstance, Kustomizations, ExternalSecrets
kubectl get nodes -o wide                              # 2 nodes, arm64, Ready
kubectl -n flux-system get fluxinstance flux          # READY True
flux get kustomizations                               # flux-system, infra-external-secrets, infra-controllers, infra-configs, apps: True
kubectl get externalsecret -A                         # SecretSynced
kubectl get pods -A | grep -v -E 'Running|Completed'  # only the header
```

`infra-monitoring` and `infra-security` show as suspended: that is the default. To switch an optional layer on, create its secrets, set the `LAYER_...` variable in `cluster.env`, run `scripts/configure.sh`, commit and push; Flux applies it.

## How the pieces fit with the other three repositories

Order to use them: `oracle-always-free` first (cluster, vault, Flux installer), then `cloudflare-free` (domain, tunnel, logins), then **this repository**. `gcp-always-free` is independent. Hand-offs: `oracle-always-free` installs Flux and points it
at this repository (its Actions variable `CLUSTER_REPO`, a deploy key from `put-flux-secrets.sh`, the age key from the Vault); this repository's `cloudflared` reads the tunnel token that `cloudflare-free` outputs, from the Vault; the names in
`cloudflare-free`'s `cluster_hostnames` must match the Ingress hosts here (`<name>.<BASE_DOMAIN>`). Recipes: [docs/RECIPES.md](docs/RECIPES.md).

## Keep it up to date

```bash
git fetch upstream
git log --oneline HEAD..upstream/main          # what is new; read docs/CHANGELOG.md
git switch -c update-from-upstream
git merge upstream/main                        # conflicts in settings files: keep yours, or take upstream's and run scripts/configure.sh again
scripts/preflight.sh --validate
git push -u origin update-from-upstream        # open a pull request, read it, merge: Flux applies main
```

Flux applies whatever lands on `main`: read the diff of an update like a change to production. `docs/CHANGELOG.md` says when a change needs a manual step.

## Spending caps

Nothing in this repository creates a billable cloud resource by itself; the guard rails are in `oracle-always-free` (quotas) and `cloudflare-free`. Ways to spend money from inside the cluster, to avoid:

- A Service of type `LoadBalancer` (OKE would create a load balancer). There is none: Traefik is ClusterIP and the only way in is the tunnel.
- A PersistentVolumeClaim on the `oci-bv` storage class creates block volumes that count against the free 200 GB (and the quota refuses past it). `local-path` must be the only default storage class (docs step 8).
- Images are pulled from public registries; egress from Oracle is free up to a large monthly allowance. Grafana Cloud and New Relic free tiers have their own ingest caps (recipe 7).

## Tear it down

None of this was run by the authors, so treat it as **verify**: to remove an app, delete its folder and its line in `apps/kustomization.yaml` and merge: Flux prunes it (`prune: true`).
To remove everything, destroy the cluster in `oracle-always-free` (see its README), then delete the Vault secrets, the Tailscale machines `oke-free` and its proxies (Tailscale admin console), the tunnel (via `cloudflare-free`) and the repository's deploy key.

## Troubleshooting (real problems from the first sync)

| What you see | Cause and fix |
|---|---|
| `scripts/configure.sh`: `BASE_DOMAIN must be your domain...`, `AGE_PUBLIC_KEY must be an age PUBLIC key` | A required value is missing or still a placeholder. The message names it; `cluster.env.example` shows the format. |
| `preflight.sh`: `spec.sync.url is still a placeholder` | Run `scripts/configure.sh` (GITHUB_REPO) and commit `clusters/oke/flux-instance.yaml`: Flux follows the URL in git, so it must be committed before Flux can sync. |
| The `apps` layer fails with an invalid Ingress host | `BASE_DOMAIN` is still the placeholder in `cluster-settings.yaml`. Fix it with `configure.sh`, commit, push. |
| `InvalidImageName` / "short name mode is enforced" | CRI-O on OKE refuses short image names. Write `docker.io/library/...` (or the full registry) on every image. |
| Trivy Operator values rejected | An invalid `mirror` key in the chart values: drop it (it was removed in the first sync fixes). |
| Pods stay `Pending` right after Flux installs (CPU) | Each 1-OCPU node has only about 840m allocatable CPU and Flux's six controllers requested 600m by default. `flux-instance.yaml` patches their requests to 20m; keep that patch, and keep your own requests small. |
| `no matches for kind ExternalSecret` | The ExternalSecret CRDs must exist before any layer that uses them. That is why `infra-external-secrets` is its own first layer; do not move it into `infra-controllers`. |
| `flux get kustomizations` shows a layer not Ready | `flux logs --kind=Kustomization --name=<name> -n flux-system`, or `kubectl -n <ns> describe helmrelease <name>`. Retry after a fix: `flux reconcile kustomization <name> --with-source`. |
| `SecretSyncedError` on an ExternalSecret | `kubectl -n <ns> describe externalsecret <name>`. "secret not found": that Vault secret is not there yet. `401`/`NotAuthenticated`: the reader key or the three OCIDs are wrong (run `make-reader-key.sh` again). `404 NotAuthorizedOrNotFound` on all: the reader's policy in oracle-always-free is not applied. Force a refresh: `kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite`. |
| `seal.sh` says "still has the placeholder recipient" | Put your age public key in `.sops.yaml` first (`AGE_PUBLIC_KEY` + `scripts/configure.sh`). |
| Two default storage classes | `kubectl annotate storageclass oci-bv storageclass.kubernetes.io/is-default-class=false --overwrite` (OKE owns that object, so it is not in git). |
| Flux cannot push digest commits | Image automation needs a deploy key with write access and a `main` that does not require pull requests. Or turn image automation off (`LAYER_IMAGE_AUTOMATION=false`). |
| `kubectl` times out | The API endpoint is private. Use Tailscale (`tailscale configure kubeconfig oke-free`); before the operator exists, use the Bastion session that `flux-bootstrap.yml` opens for 30 minutes. |
| Alert `KubeCPUOvercommit` (warning) fires | Two small nodes are about 80 % reserved by requests, not by real use. Accept it, or trim requests to measured use. Do not add nodes: the free Arm allowance is used up. |
| Alert `CPUThrottlingHigh` for `oke-*` pods in `kube-system` | Oracle's own managed pods have tiny limits and are reset by OKE. Ignore, or exclude them from the rule. |
| A Helm chart updates itself | Charts use version ranges (`42.x`, `1.x`): Flux takes new versions inside a major. A new major is a one-line pull request. Images stay on floating tags by default. |

## Security notes

- **Secret:** the age PRIVATE key (laptop and `flux-system/sops-age`), the Vault reader API key (sealed in `oci-vault-reader.sops.yaml`, readable only with your age key), Flux's deploy key, everything in OCI Vault.
  **Not secret:** `cluster-settings.yaml`, OCIDs, the domain, repository settings. The only secret in git is the SOPS-encrypted reader key; plaintext `*.plain.yaml`, `*.secret.yaml`, `*.dec.yaml` and key files are git-ignored.
- **Who can change the cluster:** whoever can write to `main` (Flux applies it) and whoever has Flux's deploy key. The key is **read-only** when image automation is off, **write** when it is on (image automation commits digests to `main`).
  Keep write access to yourself; on GitHub Pro/Team/Enterprise protect `main` (and let the deploy key bypass if image automation is on).
- **External Secrets is cluster-wide:** the `ClusterSecretStore` `oci-vault` can be used by an ExternalSecret in ANY namespace, so anyone who can create one can read every secret in the vault (the reader user is limited to that one vault).
  Treat "can create ExternalSecrets" as "can read the vault". To narrow it, add `spec.conditions` (namespace allow-list) to `infrastructure/controllers/secret-store/cluster-secret-store.yaml` (**verify**, not done by default).
- **Admission policies are in Audit:** Kyverno reports but does not block, so that nothing you run is refused by surprise. Move to `Deny` when the reports are clean (docs step 14).
- **No cluster-admin to anything surprising:** the only RBAC this repository adds is the optional `chatops` role (read everything except Secrets, restart Deployments, suspend/resume Flux objects), bound to a Kubernetes group that only a tailnet grant can give.
  Operators installed by Helm charts bring their own RBAC; read the charts before you trust them.
- **Network:** Traefik is ClusterIP, `cloudflared` connects out, the API server is private. NetworkPolicy is declared in the Flux profile but the OKE CNI (flannel) does not enforce it.
- **Floating versions:** images use `:latest` tags and Helm charts use ranges inside a major (so Renovate and Flux can follow upstream); `apps/hello` follows `:latest` by digest. Pin exact versions in the manifests if you prefer reproducibility over freshness.
- **Optional layers that widen access:** CrowdSec reads the nodes' pod logs through a read-only hostPath and runs a root init container; the OpenTelemetry log collector runs as root to read the same logs. Both are off by default.

Report a vulnerability: [SECURITY.md](SECURITY.md).

## CI safety: pull requests from forks

- The workflows never use `pull_request_target` or `workflow_run`, and `validate.yml` and `gitleaks.yml` have no secrets: they build and check manifests offline. Pull requests from forks run exactly the same checks.
- Nothing here logs in to a cloud. The only credentials are in the cluster (Vault reader key sealed with SOPS to **your** age key, Flux's deploy key) and in Vault.
- The sealed file `oci-vault-reader.sops.yaml` is not in this repository; your own `make-reader-key.sh` run creates it.
- In the repository settings require approval for outside collaborators' workflows (see SECURITY.md).

## Checks (the same run in CI)

```bash
scripts/validate.sh
shellcheck scripts/*.sh
trivy config --ignorefile .trivyignore.yaml --skip-dirs .cache .
python3 scripts/helm-check.py          # renders every HelmRelease: needs helm
gitleaks detect --redact --no-banner
```

## Layout

```
cluster.env.example           YOUR settings in one file: copy to cluster.env, then scripts/configure.sh
clusters/oke/                 what Flux syncs first: FluxInstance, cluster-settings (${VARS}), the Kustomizations of each layer
infrastructure/controllers/   Helm charts and their sources: flux-operator, traefik, cloudflared, tailscale, kyverno, trivy, local-path, external-secrets
infrastructure/configs/       what needs those CRDs: kyverno policies, tailscale ProxyClass, image automation, [previews], [restore-test]
infrastructure/monitoring/    [suspended] kube-prometheus-stack (slim), OpenTelemetry gateway and log collector
infrastructure/security/      [suspended] CrowdSec
apps/                         one folder per app; apps/kustomization.yaml lists them (hello)
docs/                         CONFIGURATION.md (every variable), WHAT-YOU-DO.md, DESIGN.md, RECIPES.md, CHANGELOG.md, examples/ (preview opt-in template)
scripts/                      configure.sh, preflight.sh, validate.sh, seal.sh, helm-check.py, crd-schema.py
```

Some files mention a home server, a "ChatOps" assistant and specific backups: optional integrations of the original author's own setup (recipes 3, 5 and 8); skip or delete them.

## License and contributing

MIT, see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md).
