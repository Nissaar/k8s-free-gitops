<!-- Design notes of the original private repository, kept as the technical reference. The README is the entry point. -->

> Design notes. Regions, names and sizes mentioned here are the original author's examples; the values you set are listed in
> [CONFIGURATION.md](CONFIGURATION.md) and the README says what to do.

# cluster

Flux GitOps repo for **oke-free**: the 2-node Arm (arm64) OKE cluster on Oracle
Always Free (2 x `VM.Standard.A1.Flex`, 1 OCPU / 6 GB each, so roughly 9-10 GB
usable for everything). Whatever is on `main` is what runs: Flux pulls this repo
every 10 minutes and applies it. Nobody runs `kubectl apply` by hand.

Sibling repos (shared spec: `the sibling repositories`):

- `oracle-always-free` builds the cluster and runs the one-off `flux-bootstrap.yml`
  (Flux Operator + `clusters/oke/flux-instance.yaml` + the secrets
  `flux-system/flux-git-auth` and `flux-system/sops-age`).
- `cloudflare-free` owns the tunnel `oke-free`, the DNS names, Cloudflare
  Access and the `ci-smoke-tests` service token.

Manual steps, in order: [docs/WHAT-YOU-DO.md](WHAT-YOU-DO.md).
AI briefing: AGENTS.md (not published).

## Traffic

```
visitor -> Cloudflare (TLS, Access) -> tunnel oke-free -> cloudflared (2 pods)
        -> http://traefik.traefik.svc.cluster.local:80 -> Ingress -> app
you / ChatOps -> tailnet -> oke-free (Tailscale API server proxy, auth mode) -> kubectl
                 (you: system:masters; ChatOps: group chatops, see rbac-chatops.yaml)
cluster jobs -> tailnet egress -> Home ChatOps ntfy (topic "cluster")
Alertmanager -> https://ntfy.example.com/alerts (phone) + tailnet -> ChatOps ntfy "cluster" (silent)
otel-gateway -> Grafana Cloud (OTLP gateway) + New Relic (otlp.nr-data.net)
External Secrets -> OCI Vault "freetier" (API, as cluster-secrets-reader)
failover Worker (cloudflare-free) -> ntfy-standby.example.com -> tunnel -> apps/ntfy-standby
```

No LoadBalancer, no public IP: the only way in from the internet is the tunnel.

## Layout

```
clusters/oke/                 what Flux syncs first (path of the FluxInstance)
  flux-instance.yaml          Flux 2.x, 6 controllers incl. image automation
  cluster-settings.yaml       ${VARS} substituted into every layer (3 to fill)
  infrastructure.yaml         Kustomizations infra-controllers, infra-configs, infra-monitoring, infra-security
  apps.yaml                   Kustomization apps
infrastructure/controllers/   Helm charts: flux-operator, local-path-provisioner,
                              traefik, cloudflared, tailscale-operator, kyverno,
                              trivy-operator (+ their HelmRepositories in sources/),
                              secret-store/ (ClusterSecretStore oci-vault)
  external-secrets/           External Secrets Operator + the one SOPS secret
                              (own layer infra-external-secrets, applied first)
infrastructure/monitoring/    kube-prometheus-stack (slim), otel-gateway, otel-logs
infrastructure/security/      CrowdSec (LAPI + agent per node), alert only, ntfy `security`
infrastructure/configs/       things that need those CRDs: kyverno-policies,
                              tailscale (ProxyClass, ntfy egress, ChatOps RBAC),
                              image-automation, previews, restore-test
apps/                         one folder per app; apps/kustomization.yaml lists them
                              (hello, ntfy-standby)
docs/examples/                preview opt-in template
schemas/                      kubeconform schema for ResourceSet (catalog is behind)
scripts/                      seal.sh, validate.sh, helm-check.py, crd-schema.py,
                              ntfy-auth-json.py (Home ntfy .env -> Vault JSON)
```

## How Flux applies it

1. `flux-bootstrap.yml` (oracle-always-free) installs the Flux Operator and applies
   `clusters/oke/flux-instance.yaml`. The operator installs Flux and creates the
   GitRepository + Kustomization `flux-system` for `clusters/oke`.
2. `clusters/oke` holds seven more Kustomizations, applied in dependency order:

   | Kustomization            | path                                          | depends on             |
   |--------------------------|-----------------------------------------------|------------------------|
   | `infra-external-secrets` | `infrastructure/controllers/external-secrets` | -                      |
   | `infra-controllers`      | `infrastructure/controllers`                  | infra-external-secrets |
   | `infra-configs`          | `infrastructure/configs`                      | infra-controllers      |
   | `apps`                   | `apps`                                        | infra-configs          |
   | `infra-monitoring`       | `infrastructure/monitoring`                   | infra-configs          |
   | `infra-security`         | `infrastructure/security`                     | infra-configs          |

   Each one waits until everything in it is Ready before the next starts, prunes
   what you delete from git, decrypts `*.sops.yaml` with `flux-system/sops-age`,
   and substitutes `${VARS}` from `clusters/oke/cluster-settings.yaml`.
   `infra-external-secrets` is first and alone because every other layer has
   ExternalSecrets, whose CRDs must exist before Flux can apply them.
   `infra-monitoring` is apart so a broken monitoring stack (wrong Grafana
   token) never blocks apps; `infra-security` (CrowdSec) is apart for the same reason.
3. The FluxInstance itself is in `clusters/oke`, so Flux upgrades and changes
   (edit the file, merge) come from git too. Flux follows `2.x`; the operator is
   updated by its own HelmRelease (it adopts the release the bootstrap made).

Charts use version ranges (`42.x`, `1.x`, `0.x`...), so Flux takes new chart
versions inside a major by itself. A new major is a one-line PR. Images stay on
floating tags (`:latest` or the chart's own default): nothing pins an image.

## Secrets

All secrets live in **OCI Vault** `freetier` (oracle-always-free bootstrap), one
Vault secret per Kubernetes Secret, named `<namespace>-<secret>`, content a
JSON object of the Secret's keys. **External Secrets Operator** copies them
in: each folder has a `<secret>.externalsecret.yaml` (ClusterSecretStore
`oci-vault`, `dataFrom.extract`), refreshed every hour. You write them from
the laptop with `~/oracle-always-free/scripts/put-secret.sh <name>
<file.json|->` (docs/WHAT-YOU-DO.md step 5 has a command for each). Always
Free: 150 Vault secrets, 40 versions each.

| Secret (namespace/name)          | Vault secret                  | Keys | From |
|----------------------------------|-------------------------------|------|------|
| `cloudflared/tunnel-token`       | `cloudflared-tunnel-token`    | `TUNNEL_TOKEN` | cloudflare-free output `tunnel_token` |
| `tailscale/operator-oauth`       | `tailscale-operator-oauth`    | `client_id`, `client_secret` | Tailscale OAuth client |
| `previews/github-auth`           | `previews-github-auth`        | `username`, `password` | GitHub fine-grained token |
| `previews/preview-smoke`         | `previews-preview-smoke`      | `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`, `NTFY_TOKEN` | cloudflare-free outputs `ci_smoke_tests_*`, ChatOps ntfy |
| `restore-test/restore-test`      | `restore-test-restore-test`   | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `NTFY_TOKEN`, `HEALTHCHECK_URL`, `DR_HEALTHCHECK_URL` | R2, Home backup .env, ChatOps ntfy, healthchecks.io |
| `monitoring/otel-credentials`    | `monitoring-otel-credentials` | `GRAFANA_CLOUD_OTLP_ENDPOINT`, `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_TOKEN`, `NEW_RELIC_OTLP_ENDPOINT`, `NEW_RELIC_LICENSE_KEY` | Grafana Cloud OpenTelemetry tile, New Relic license key |
| `monitoring/alertmanager-ntfy`   | `monitoring-alertmanager-ntfy`| `NTFY_TOKEN`, `CHATOPS_NTFY_TOKEN` | public ntfy bot token, ChatOps `ops` token |
| `crowdsec/ntfy`                  | `crowdsec-ntfy`               | `NTFY_TOKEN` | public ntfy bot token (same as `monitoring-alertmanager-ntfy`'s) |
| `ntfy-standby/ntfy-auth`         | `ntfy-standby-ntfy-auth`      | `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, `NTFY_AUTH_TOKENS`, `NTFY_UPSTREAM_BASE_URL` | Home `ntfy/.env` (`scripts/ntfy-auth-json.py`) |

Not in Vault:

- `external-secrets/oci-vault-reader` (`privateKey`, `fingerprint`): the API
  key of the Oracle user `cluster-secrets-reader` (read-only on this vault's
  secrets). It is the ONE secret still sealed with SOPS
  (`oci-vault-reader.sops.yaml`), made and sealed by oracle-always-free's
  `scripts/make-reader-key.sh`; `scripts/seal.sh` stays for it.
- `flux-system/flux-git-auth`, `flux-system/sops-age`: made by
  oracle-always-free's `flux-bootstrap.yml` from its own Vault secrets.

The store's OCIDs (`OCI_TENANCY_OCID`, `OCI_VAULT_OCID`,
`OCI_VAULT_READER_OCID`) are cluster settings, not secrets. Later, OpenBao
can be a second ClusterSecretStore `openbao`; an app moves by changing
`secretStoreRef.name`.

## Moving an app in

One folder + one line:

1. `apps/<app>/` with a `kustomization.yaml` and the manifests (copy
   `apps/hello`: namespace, Deployment, Service, Ingress). Requests and limits
   on every container, `nodeSelector: kubernetes.io/arch: arm64`, image on a
   floating tag.
2. Add `- <app>` to `apps/kustomization.yaml`.
3. Public name: add `<app>` to `cluster_hostnames` in cloudflare-free
   (`public = true` or `false` for an Access login). Names are always
   `<app>.example.com` (Universal SSL covers one level only).
   The whole routine, including the order (app first, name second) and how
   to switch an app that already runs in Home:
   `cloudflare-free/docs/HOSTNAMES.md`.
   Who may open a private name: declare the app in `<home-server-repo>/access/apps.yaml`
   (`method: cloudflare-access`, `where: cluster`, `allow:` people with end dates;
   owner-only by default) and apply it with `access/apply-cloudflare.sh`; without an
   entry the global owner list is used.
4. Secrets: `apps/<app>/<name>.externalsecret.yaml` (copy one, e.g.
   `apps/ntfy-standby/ntfy-auth.externalsecret.yaml`), Vault secret
   `<namespace>-<name>`, filled with `put-secret.sh`.

## Image updates (the "always :latest" rule)

`apps/hello` shows the pattern:

- `image-policy.yaml`: an **ImageRepository** (scans the tag list) and an
  **ImagePolicy** that keeps only the tag `latest` (`filterTags: ^latest$`) with
  `digestReflectionPolicy: Always` and `interval: 1h`: every hour Flux looks up
  the digest `:latest` points to.
- The image line carries a marker:
  `image: traefik/whoami:latest # {"$imagepolicy": "flux-system:hello"}`
- The **ImageUpdateAutomation** (`infrastructure/configs/image-automation`)
  rewrites marked lines to `docker.io/traefik/whoami:latest@sha256:...` and
  commits that to `main` as `fluxcdbot`. Flux then rolls the Deployment.

So the app still follows `:latest`, but each change of the image is a commit you
can see, and a restart never pulls a different image behind your back. For
another app: copy `image-policy.yaml`, rename `hello`, put the marker on its
image line. ImageRepository/ImagePolicy must stay in `flux-system`.

## PR previews

Generic machinery in `infrastructure/configs/previews`; no app uses it yet.

- A **ResourceSetInputProvider** per app repo (type `GitHubPullRequest`, label
  filter `preview`) lists that repo's open PRs every 5 minutes.
- The **ResourceSet** `previews` turns each labelled PR into namespace
  `pr-<n>` with the app (`<image>:pr-<n>`), a Service and an Ingress at
  `https://pr-<n>-<app>.example.com`, then (step 2, once the app is Ready) a
  smoke-test Job per commit: it opens `/` and the health path through
  Cloudflare with the `ci-smoke-tests` Access service token headers and posts
  the result to ntfy (ChatOps topic `cluster`). Closing the PR or removing the
  label deletes it all.
- Needs `enable_preview_dns = true` in cloudflare-free (wildcard DNS + tunnel
  rule; the Access app `pr-*` lets the service token in).

**Opting an app in:** copy `docs/examples/preview-provider.yaml` to
`apps/<app>/preview.yaml`, set url/app/image/port/healthPath, list it in
`apps/<app>/kustomization.yaml`; make the app's CI push an arm64 image tagged
`pr-<number>` on every PR push; label the PR `preview`.

## Restore test (weekly)

`infrastructure/configs/restore-test`: Sunday 05:00 local time a CronJob takes
the newest snapshot of host `home` in restic repo `restic/home` on R2
that has `/nocobase/nocobase.sql.gz`, restores that file, loads it into a throwaway
Postgres in the same pod (`postgres:latest`, which is >= 18 like the
pg_dump that wrote it; emptyDir, no PVC), checks that there are tables and
that the newest row of the biggest timestamped table is under 72 h old, posts
PASS/FAIL to ntfy over the tailnet and pings healthchecks.io if
`HEALTHCHECK_URL` is set. The pod leaves nothing behind.

## DR drill (monthly)

`infrastructure/configs/restore-test/dr-drill.yaml`: the 1st of each month,
03:00 local time, the same restore as above, but the way a real recovery runs:
the dump goes into `postgres:16-alpine` (production's major version; the
`SET transaction_timeout` line from pg_dump 18 is filtered out) with
`ON_ERROR_STOP=1`, then `nocobase/nocobase:latest` starts on it (random
`APP_KEY`, 1.5 GiB limit) and must answer `GET /api/__health_check` with 200
within 10 minutes. PASS/FAIL plus the measured recovery time go to ntfy and
`DR_HEALTHCHECK_URL`. Run it by hand any time:
`kubectl -n restore-test create job --from=cronjob/dr-drill dr-drill-manual`.

## Disaster recovery

Automated:

- **Failover**: cloudflare-free's `failover` Worker (behind
  `enable_failover`) sends `ntfy.example.com` and the status page to their
  `<label>-standby` copies in the cluster when the Home origin fails,
  subscriptions included. The ntfy copy is `apps/ntfy-standby` (below); a
  status page copy does not exist yet.
- **Backups**: Home's `backup/` service (<home-server-repo>) runs nightly:
  pg_dump of NocoBase + Paperless, Paperless/Gogs data, restic to R2 and
  Oracle (`restic/home`, host `home`).
- **Proof the backups restore**: the weekly restore test and the monthly DR
  drill above (ntfy + healthchecks.io).
- **The cluster itself**: everything is in git. Lost cluster = oracle-always-free
  `tofu` apply (rebuilds OKE) + oracle-always-free `flux-bootstrap` (the same
  age key and deploy key come from OCI Vault); Flux then recreates every
  layer from this repo. Data on `local-path` volumes is not backed up
  (apps that need their data kept use the restic backup).

Still manual: rebuilding the Home VPS (new server, restore from restic,
DNS): follow `<home-server-repo>/RUNBOOK.md`.

## ntfy standby (`apps/ntfy-standby`)

A second ntfy (`binwiederhier/ntfy:latest`, followed by digest like `hello`)
for when the Home server is down. Your phone keeps its one subscription
to `ntfy.example.com`; no new topic, no second server in the app.

- Same users, ACL and tokens as Home: ntfy's declarative auth
  (`auth-users`, `auth-access`, `auth-tokens`, env `NTFY_AUTH_USERS`,
  `NTFY_AUTH_ACCESS`, `NTFY_AUTH_TOKENS`; ntfy >= 2.14.0), the same values as
  Home's `ntfy/.env`, from the Vault secret `ntfy-standby-ntfy-auth`
  (docs/WHAT-YOU-DO.md step 22). Re-applied at every start.
- `base-url https://ntfy.example.com`, `behind-proxy`, deny-all by default,
  cache (72 h) and auth database on emptyDir, no attachments, port 8080.
- Reached only through `ntfy-standby.example.com` (tunnel, public: ntfy does
  its own auth), which cloudflare-free adds with `enable_failover = true`.
  Its failover Worker on `ntfy.example.com/*` tries Home first and uses
  this copy on 5xx / timeout / network error, also for the app's
  subscription stream; a stream on the standby is ended after 5 minutes so
  the app comes back to Home once it is up. `/v1/health` is never failed
  over (monitors keep seeing Home).
- Messages published while Home is down stay here only (Home never
  sees them); if this pod restarts in that time they are gone.

## Monitoring (`infrastructure/monitoring`)

- **kube-prometheus-stack**, slim: Prometheus (scrape 60 s, retention 3 days
  / 3 GB, emptyDir), Alertmanager, node-exporter, kube-state-metrics, the
  operator. No Grafana (Grafana Cloud is the UI). Not scraped: API server,
  etcd, scheduler, controller-manager, kube-proxy, CoreDNS (Oracle manages
  them; their rules are off).
- **otel-gateway** (OTel Collector contrib, Deployment): the only exit for
  telemetry. Metrics: reads a fixed subset from Prometheus `/federate`
  (`match[]` in `otel-gateway.yaml`; it scrapes no exporter itself) plus OTLP
  from apps; logs from **otel-logs** (DaemonSet, pod log files) plus OTLP;
  traces from OTLP. Exports each signal once to **Grafana Cloud** (OTLP
  gateway, Basic auth instance id + token) and once to **New Relic**
  (`https://otlp.nr-data.net`, header `api-key`, counters as deltas).
  Prometheus has no remote_write, so nothing arrives twice. Apps send OTLP
  to `http://otel-gateway.monitoring.svc.cluster.local:4318`.
- **Alerts**: Alertmanager -> `https://ntfy.example.com/alerts`
  (`?template=alertmanager`, bot token) for the phone (topic layout of
  21 Nov 2026; the old topic `monitor` gets a copy until 28 Nov 2026, then
  that webhook is removed); through the failover
  Worker this still works when Home is down. Plus the ChatOps ntfy topic
  `cluster` over the tailnet (`ntfy-home` egress, TLS name =
  `HOME_TAILNET_FQDN`), priority 1 and tag `chatops`: a record in the
  channel without a second buzz. ChatOps also pulls `alerts` (and
  `monitor` until it retires) through its `ALERT_FEED_URL`, so it sees every alert. `Watchdog` goes nowhere.
- **Rule `NodeDiskLow`**: root filesystem of a node under 10 GB free for
  15 min (warning) or under 5 GB for 5 min (critical; hides the warning for
  that node).

## CrowdSec (`infrastructure/security`)

Decision `s-crowdsec = all` (25 Nov 2026): the Home detector also runs here.
It is the same idea as <home-server-repo> `crowdsec/`: read the web access log,
recognise probing, brute force, CVE scans and crawlers, and send **one ntfy
message per attacking address** to topic `security` (title starts with
`CrowdSec cluster`, so it is told apart from Home's).

- **Source**: Traefik's access log. `accessLog.enabled: true` (common format, no
  headers) in `infrastructure/controllers/traefik/helmrelease.yaml`; the log goes
  to stdout, so it lands in the pod's CRI log file on the node. The first field
  is the visitor address, taken from `X-Forwarded-For` (cloudflared passes it,
  Traefik trusts `POD_CIDR`). Nothing else is read (no SSH, no kubelet).
- **Install**: the official chart (`0.x`, HelmRepository `crowdsec`),
  `crowdsec-lapi` (Deployment, sqlite on two small local-path PVCs: alerts and
  agent registrations, not backed up, rebuildable) and `crowdsec-agent`
  (DaemonSet, one pod per node, tails `/var/log/containers/traefik-*` through a
  read-only hostPath). Collections: `crowdsecurity/traefik`, `http-cve`,
  `base-http-scenarios`, parser `cri-logs`.
- **Alert only**. No bouncer. Cloudflare fronts every request, so a bouncer would
  see Cloudflare addresses or a header a client can forge. You decide from the
  ntfy message and block with ChatOps `block <ip> <reason>` (Cloudflare, all
  sites). CrowdSec's own 4 h `ban` decisions only feed `cscli decisions list`.
  To enforce later, see docs/WHAT-YOU-DO.md step 25 ("enforce later").
- **Token**: Vault `crowdsec-ntfy` -> Secret `crowdsec/ntfy` -> init container
  `render-ntfy` writes the plugin file (URL + token) into a memory emptyDir
  mounted over `notifications/http.yaml`. The ConfigMap `crowdsec-ntfy-template`
  holds the message template with placeholders only.
- **Sizing** (nodes are ~80% CPU-reserved, see the troubleshooting table in the README): LAPI 10m /
  96 Mi requests, 300m / 256 Mi limits; agent (x2) 10m / 128 Mi requests, 300m /
  320 Mi limits. The community blocklist and signal sharing are off
  (`DISABLE_ONLINE_API`): no bouncer would use the list.
- **Whitelist**: loopback, private ranges and the tailnet range are never alerted
  on (a pod or node address in the log means Traefik does not see the real
  visitor: you get silence, not false accusations). Add your own addresses in
  `helmrelease.yaml` (`my-whitelist.yaml`).
- **Root**: the agent reads root-owned files under `/var/log/pods` (like
  otel-logs) and the image writes into `/etc/crowdsec`, so no non-root and no
  read-only root filesystem. `allowPrivilegeEscalation: false`, not privileged.
- The access log is also shipped by otel-logs to Grafana Cloud and New Relic
  with every other pod log (tiny volume: only public hostnames reach Traefik
  without Cloudflare Access).

## Image security

- **Trivy Operator** (`infrastructure/controllers/trivy-operator`):
  VulnerabilityReports + ConfigAuditReports, one scan job at a time; metrics
  service on for a later Prometheus.
- **No registry here.** The registry (Zot), BuildKit, Copacetic and the
  multi-arch join were removed on 16 Nov 2026: app images are built by GitHub
  Actions in each app repo and published to ghcr.io.
- **Kyverno** (`infrastructure/configs/kyverno-policies`): allowed registries,
  no privileged containers (except kube-system and tailscale), requests and
  limits required. `:latest` is allowed on purpose. All policies are in
  **Audit**; the one switch to Enforce is the patch in that folder's
  `kustomization.yaml` (`[Audit]` -> `[Deny]`).

## Resource budget (requests / limits, memory)

| What | requests | limits |
|---|---|---|
| Flux (6 controllers, size small) + operator | ~0.5 GB | ~3 GB |
| Traefik x2, cloudflared x2 | 192 Mi | 768 Mi |
| Tailscale operator + 2 proxies | ~130 Mi | ~520 Mi |
| Kyverno (3 controllers) | 256 Mi | ~900 Mi |
| Trivy Operator + 1 scan job | ~250 Mi | ~1.5 GB |
| hello, local-path | ~25 Mi | ~100 Mi |
| Weekly/monthly jobs (restore test, DR drill) | up to ~0.9 GB while running | up to ~3.3 GB (DR drill) |
| External Secrets (controller, webhook, cert controller) | 128 Mi | 416 Mi |
| Monitoring: Prometheus 400, Alertmanager 32, operator 64, kube-state-metrics 48, node-exporter 2 x 24, 2 config reloaders 2 x 16, otel-gateway 160, otel-logs 2 x 64 | 912 Mi (budget 1.3 GB) | ~2.8 GB |
| ntfy-standby | 32 Mi | 192 Mi |
| CrowdSec: lapi 96, agent 2 x 128 | 352 Mi | ~900 Mi |

Requests stay near 3 GB plus whichever job runs, so both nodes keep room;
limits overcommit, which is fine because not everything peaks at once. The
jobs run at different times (Sunday 04:00 copa, 05:00 restore test; 1st of the
month 03:00 DR drill).

## Checks

- PR CI (`.github/workflows/validate.yml`): `scripts/validate.sh`
  (kustomize build of every Kustomization path, the previews ResourceSet
  rendered with mock PRs, kubeconform with the CRD catalog) and `trivy config`
  (accepted findings with reasons in `.trivyignore.yaml`). Failures are pulled
  by ChatOps' `infra` channel; nothing pushes to ntfy.
- Locally also: `scripts/helm-check.py` renders every HelmRelease with
  `helm template` against the real chart (catches bad values).
