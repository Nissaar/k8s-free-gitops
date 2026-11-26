# What you do, in order

Everything here is manual and done once, unless a step says otherwise. Order
matters: oracle-always-free and cloudflare-free steps are referenced by their own
`docs/WHAT-YOU-DO.md` step numbers. Commands run from the root of YOUR private copy of this repo
(called `~/k8s-free-gitops` below) unless a step says otherwise. `<your-...>` always means a value of yours.
**Shortcut for steps 2 to 3:** put your settings (repository, domain, age public key, optional layers) into `cluster.env` and run
`scripts/configure.sh` (it writes the files these steps describe); `scripts/preflight.sh` then checks them. docs/CONFIGURATION.md
lists every variable. Steps about ChatOps, ntfy standby, restore test and Home belong to the original author's own setup:
skip them unless you have the same.

## 0. Tools on the laptop (once)

`kubectl`, `flux`, `sops`, `age`, `helm`, `trivy`, `jq` are installed already.
The `oci` CLI comes from oracle-always-free step 0 (needed for the secrets, step 5).
Also:

```bash
# kubeconform (only for scripts/validate.sh; CI installs its own)
v=v0.8.0; cd /tmp && curl -fsSLO https://github.com/yannh/kubeconform/releases/download/$v/kubeconform-linux-amd64.tar.gz \
  && curl -fsSLO https://github.com/yannh/kubeconform/releases/download/$v/CHECKSUMS \
  && grep ' kubeconform-linux-amd64.tar.gz$' CHECKSUMS | sha256sum -c - \
  && tar xzf kubeconform-linux-amd64.tar.gz kubeconform && sudo mv kubeconform /usr/local/bin/
```

## 1. Create the GitHub repo and push

The repo must exist before oracle-always-free step 7 (it adds Flux's deploy key to it).

```bash
cd ~/k8s-free-gitops
gh repo create <your-github-user>/k8s-free-gitops --private --source . --remote origin
git push -u origin main
```

GitHub -> <your-github-user>/k8s-free-gitops -> Settings -> Branches -> add a rule for `main` only
if you want PRs; leave "allow force pushes" off. Do NOT require PR reviews on
main: Flux image automation pushes digest commits straight to main.

## 2. age key and `.sops.yaml`

oracle-always-free step 7 makes the cluster's age key (skip this if done):

```bash
age-keygen -o ~/.config/sops/age/cluster.txt
age-keygen -y ~/.config/sops/age/cluster.txt      # prints age1... (public)
```

1. Put the printed `age1...` into `.sops.yaml` in place of
   `age1REPLACE_WITH_YOUR_PUBLIC_KEY`. Optional: add your laptop key
   (`age1<your-laptop-public-key>`, from `your age/sops notes`) as a second line so either key
   decrypts.
2. Back up `~/.config/sops/age/cluster.txt` like your other keys:
   `your own age-key backup routine` (sops-guide README section 4.3).
   Losing it means re-sealing every secret.
3. So that `sops` on the laptop can open sealed files:
   `export SOPS_AGE_KEY_FILE=~/.config/sops/age/cluster.txt` (add to `~/.bashrc`).

## 3. Fill `clusters/oke/cluster-settings.yaml`

(`scripts/configure.sh` does this and step 2's `.sops.yaml` line from `cluster.env`; the text below is what it does.)
Two values here (not secret); three more (`OCI_TENANCY_OCID`,
`OCI_VAULT_OCID`, `OCI_VAULT_READER_OCID`) are filled by
oracle-always-free's `scripts/make-reader-key.sh` (step 19):

- `OCI_NAMESPACE`: in oracle-always-free, `tofu -chdir=bootstrap output -raw s3_endpoint`
  prints `https://<namespace>.compat.objectstorage...`; the `<namespace>` part.
  (Or OCI console -> profile menu -> Tenancy -> "Object storage namespace".)
- `HOME_TAILNET_FQDN`: Tailscale admin console -> Machines -> `chatops` ->
  the full name `chatops.<tailnet>.ts.net` (shown under the machine name).

## 4. Tailscale: tailnet policy, HTTPS, OAuth client

1. Admin console -> **DNS**: MagicDNS **on**; **HTTPS Certificates** -> Enable
   (needed for `oke-free` kubectl).
2. Tag the ChatOps device (so it does NOT inherit your own admin rights):
   Machines -> `chatops` -> `...` -> **Edit ACL tags** -> `tag:chatops` -> Save.
3. Admin console -> **Access controls** -> JSON editor. Merge this into your
   policy (keep what you have; add to the existing sections):

   ```json
   "tagOwners": {
     "tag:k8s-operator": ["autogroup:admin"],
     "tag:k8s":          ["tag:k8s-operator"],
     "tag:chatops":      ["autogroup:admin"]
   },
   "grants": [
     // you: full cluster-admin through the API server proxy (oke-free)
     { "src": ["autogroup:admin"], "dst": ["tag:k8s-operator"], "ip": ["tcp:443"],
       "app": { "tailscale.com/cap/kubernetes": [{ "impersonate": { "groups": ["system:masters"] } }] } },
     // ChatOps: Kubernetes group "chatops" (RBAC: infrastructure/configs/tailscale/rbac-chatops.yaml)
     { "src": ["tag:chatops"], "dst": ["tag:k8s-operator"], "ip": ["tcp:443"],
       "app": { "tailscale.com/cap/kubernetes": [{ "impersonate": { "groups": ["chatops"] } }] } },
     // cluster proxies (restore test, previews) -> Home's private ntfy
     { "src": ["tag:k8s"], "dst": ["tag:chatops"], "ip": ["tcp:443"] },
   ]
   ```
   If `chatops` stays untagged instead (<home-server-repo>/ops/README uses a
   `hosts` entry), it belongs to you and also gets `system:masters` from the
   first grant: tag it. If your policy still has the default allow-all `acls`
   rule, the `ip` parts are already allowed; the `app` parts are still needed.
   Save. Check your phone still reaches the ChatOps ntfy after tagging.
4. Admin console -> **Settings** -> **Trust credentials** -> **+ Credential**
   -> OAuth:
   - Description: `oke-free operator`
   - Scopes: **General > Services**: Read + Write; **Devices > Core**: Read +
     Write; **Keys > Auth Keys**: Read + Write
   - Tags (for each write scope that asks): `tag:k8s-operator`
   - **Generate credential**, copy Client ID and Client secret (shown once) for
     step 5b.

## 5. Secrets: now in OCI Vault

The secrets that used to be sealed here (`*.example.yaml` + `seal.sh`) are now
in OCI Vault, one Vault secret per Kubernetes Secret, named
`<namespace>-<secret>`, content a JSON object of its keys. External Secrets
in the cluster copies them in (`*.externalsecret.yaml` files). You put them
there from the laptop with `~/oracle-always-free/scripts/put-secret.sh`; it
prints only the name and the key names. Nothing to commit for these.

Before the first one:

- Oracle login (oracle-always-free step 2), fresh within the hour:
  `oci session refresh --profile oracle-always-free-admin`
- The cluster's key to the vault: oracle-always-free step 15 (this repo's
  step 19 explains it). That is the only file still sealed with SOPS here.

Each command below pipes the values straight in; `read -rs` asks for a
value without showing it. Run them from `~/k8s-free-gitops`.

```bash
put=~/oracle-always-free/scripts/put-secret.sh
```
Commands that read cloudflare-free outputs (a, d, e) need its state: run
them in a shell where you did the `export`s and `tofu init` of
cloudflare-free step 9. Those `AWS_*` variables are the R2 state keys:
don't overwrite them (5d reads its own R2 keys as `R2_ID` / `R2_SECRET`).

a. **`cloudflared/tunnel-token`**, key `TUNNEL_TOKEN` (cloudflare-free must
   be applied first; its step 9 has the same command):
   ```bash
   tofu -chdir=$HOME/cloudflare-free/infra output -raw tunnel_token \
     | jq -R '{TUNNEL_TOKEN: .}' | $put cloudflared-tunnel-token -
   ```

b. **`tailscale/operator-oauth`**, keys `client_id`, `client_secret` (step 4.4):
   ```bash
   read -r  TS_ID;     export TS_ID       # paste the Client ID, Enter
   read -rs TS_SECRET; export TS_SECRET   # paste the Client secret, Enter
   jq -n '{client_id: env.TS_ID, client_secret: env.TS_SECRET}' | $put tailscale-operator-oauth -
   unset TS_ID TS_SECRET
   ```

c. (removed: the `zot/zot-s3` secret went with Zot, 16 Nov 2026)

d. **`restore-test/restore-test`**, keys `RESTIC_REPOSITORY`,
   `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `NTFY_TOKEN`, `HEALTHCHECK_URL`, `DR_HEALTHCHECK_URL`. Where they come from:
   - `RESTIC_REPOSITORY`: `s3:` + cloudflare-free output `r2_s3_endpoint` +
     `/backups/restic/home`.
   - `RESTIC_PASSWORD`: the one in `<home-server-repo>/backup/.env` on Home.
   - R2 keys: Cloudflare dashboard -> **R2** -> **Manage R2 API Tokens** ->
     **Create API token** -> name `oke-restore-test`, permission **Object Read
     only**, bucket `backups` only -> Create -> copy Access Key ID + Secret.
   - `NTFY_TOKEN`: on Home,
     `cd <home-server-dir>/ops && docker compose exec ntfy ntfy token add --label oke-free ops`
     (user `ops` may write every topic of the ChatOps ntfy). Keep it for
     step 21 too.
   - `HEALTHCHECK_URL`: healthchecks.io -> **Add Check** -> name
     `oke restore test`, period 7 days, grace 1 day -> copy the ping URL.
     `DR_HEALTHCHECK_URL`: a second check `oke DR drill`, period 31 days,
     grace 2 days. Either may stay empty (press Enter).
   ```bash
   export RESTIC_REPOSITORY="s3:$(tofu -chdir=$HOME/cloudflare-free/infra output -raw r2_s3_endpoint)/backups/restic/home"
   read -rs RESTIC_PASSWORD; export RESTIC_PASSWORD
   read -r  R2_ID; export R2_ID              # oke-restore-test Access Key ID
   read -rs R2_SECRET; export R2_SECRET      # oke-restore-test Secret Access Key
   read -rs NTFY_TOKEN; export NTFY_TOKEN
   read -r  HEALTHCHECK_URL; export HEALTHCHECK_URL
   read -r  DR_HEALTHCHECK_URL; export DR_HEALTHCHECK_URL
   jq -n '{RESTIC_REPOSITORY: env.RESTIC_REPOSITORY, RESTIC_PASSWORD: env.RESTIC_PASSWORD,
           AWS_ACCESS_KEY_ID: env.R2_ID, AWS_SECRET_ACCESS_KEY: env.R2_SECRET,
           NTFY_TOKEN: env.NTFY_TOKEN, HEALTHCHECK_URL: env.HEALTHCHECK_URL,
           DR_HEALTHCHECK_URL: env.DR_HEALTHCHECK_URL}' | $put restore-test-restore-test -
   unset RESTIC_REPOSITORY RESTIC_PASSWORD R2_ID R2_SECRET NTFY_TOKEN HEALTHCHECK_URL DR_HEALTHCHECK_URL
   ```

e. **`previews/preview-smoke`**, keys `CF_ACCESS_CLIENT_ID`,
   `CF_ACCESS_CLIENT_SECRET`, `NTFY_TOKEN`: the `ci-smoke-tests` service
   token (cloudflare-free outputs; the secret is only readable right after
   the apply that created the token; otherwise Zero Trust -> Access ->
   Service credentials -> `ci-smoke-tests` -> Refresh) and the ntfy token of d.
   ```bash
   cf=$HOME/cloudflare-free/infra
   export CF_ID=$(tofu -chdir=$cf output -raw ci_smoke_tests_client_id)
   export CF_SECRET=$(tofu -chdir=$cf output -raw ci_smoke_tests_client_secret)
   read -rs NTFY_TOKEN; export NTFY_TOKEN
   jq -n '{CF_ACCESS_CLIENT_ID: env.CF_ID, CF_ACCESS_CLIENT_SECRET: env.CF_SECRET, NTFY_TOKEN: env.NTFY_TOKEN}' \
     | $put previews-preview-smoke -
   unset CF_ID CF_SECRET NTFY_TOKEN
   ```

f. **`previews/github-auth`**, keys `username` (any word) and `password`:
   github.com -> Settings -> Developer settings -> Fine-grained tokens ->
   Generate: owner `<your-github-user>`, repositories = the app repos that will use
   previews (pick any one for now), permissions **Metadata: Read**,
   **Pull requests: Read**, expiry 1 year (note the date).
   ```bash
   read -rs GH_TOKEN; export GH_TOKEN
   jq -n '{username: "flux", password: env.GH_TOKEN}' | $put previews-github-auth -
   unset GH_TOKEN
   ```

g. The monitoring and ntfy standby secrets: steps 20, 21 and 22.

Then check and push the settings (no secret files any more):

```bash
scripts/validate.sh                     # kustomize + kubeconform
git status --short                      # cluster-settings.yaml (+ .sops.yaml, the reader key from step 19)
git add clusters/oke/cluster-settings.yaml
git commit -m "Fill cluster settings" && git push
```

Never `git add -A`.

## 6. Bootstrap Flux

oracle-always-free step 8: GitHub -> <your-github-user>/oracle-always-free -> Actions ->
**flux-bootstrap** -> Run workflow -> type `bootstrap`. It applies
`clusters/oke/flux-instance.yaml` and waits for it.

## 7. kubectl over the tailnet and the Flux check

```bash
tailscale configure kubeconfig oke-free
kubectl get nodes -o wide                            # 2 nodes, arm64, Ready
kubectl -n flux-system get fluxinstance flux         # READY True
flux get kustomizations                              # flux-system, infra-external-secrets, infra-controllers, infra-configs,
                                                     # apps, infra-monitoring: all True
kubectl get externalsecret -A                        # all SecretSynced (step 19.3 if not)
flux get helmreleases -A                             # all True
flux get images all -A                               # hello repository/policy, latest digest shown
kubectl get pods -A | grep -v -E 'Running|Completed' # should print only the header
```

If one is not Ready: `flux get kustomizations` shows the message; then
`flux logs --kind=Kustomization --name=<name> -n flux-system` or
`kubectl -n <ns> describe helmrelease <name>`. Force a retry after a fix:
`flux reconcile kustomization <name> --with-source`.

First minutes: `infra-external-secrets` installs External Secrets; then
`infra-controllers` waits for every chart (up to 15 min; cloudflared and the
Tailscale operator wait for their secrets from Vault); `infra-configs`,
`apps` and `infra-monitoring` follow. `oke-free` appears in the
Tailscale admin console as a machine tagged `tag:k8s-operator`.

## 8. Storage class

```bash
kubectl get storageclass
```
Only `local-path` may say `(default)`. If `oci-bv` also says it:
`kubectl annotate storageclass oci-bv storageclass.kubernetes.io/is-default-class=false --overwrite`
(one-off; OKE owns that object, so it is not in git).

## 9. hello.example.com end to end

1. Browser: `https://hello.example.com` -> Cloudflare Access asks for your
   email -> one-time PIN -> the whoami page. `X-Forwarded-For` shows your own
   IP (Traefik trusts cloudflared's headers), `Host: hello.example.com`.
2. With the service token (as the smoke tests do):
   ```bash
   curl -s -H "CF-Access-Client-Id: <id>" -H "CF-Access-Client-Secret: <secret>" https://hello.example.com/health -w '%{http_code}\n'
   ```
   -> `200`.
3. Image automation: within the hour after bootstrap there is a commit by
   `fluxcdbot` on main ("chore(images): follow :latest digests") that changes
   `apps/hello/deployment.yaml` to `docker.io/traefik/whoami:latest@sha256:...`.
   `git pull` before your next change.

## 10. Uptime Kuma monitor for hello.example.com

Access blocks Kuma like any visitor, so the monitor sends the service token.
It holds a secret, so add it in the Kuma UI (not as an AutoKuma JSON file in
<home-server-repo>, which is committed):

Kuma -> **Add New Monitor**:
- Monitor Type: **HTTP(s)**
- Friendly Name: `hello (oke cluster)`
- URL: `https://hello.example.com/health`
- Heartbeat Interval: `60`, Retries: `2`
- Advanced -> **Headers**:
  `{"CF-Access-Client-Id": "<id>", "CF-Access-Client-Secret": "<secret>"}`
- Accepted Status Codes: `200-299` (a `302` means Access refused the token)
- Notifications: your ntfy notification -> **Save**

## 11. Restore test and DR drill: first runs

```bash
kubectl -n restore-test create job --from=cronjob/restore-test restore-test-first
kubectl -n restore-test logs -f job/restore-test-first -c report      # PASS/FAIL line
kubectl -n restore-test create job --from=cronjob/dr-drill dr-drill-first
kubectl -n restore-test logs -f job/dr-drill-first -c report          # PASS + recovery time
```
Subscribe to the topic `cluster` on the ChatOps ntfy server first; both post
there. A failed step's details: `-c restore`, `-c check`, `-c load`,
`-c nocobase`. After that they run by themselves (Sunday 05:00 / the 1st at
03:00, local time).

## 12. ChatOps `cluster` channel

The grant is step 4.3 and the RBAC (`group chatops`) is in this repo. On
Home follow `<home-server-repo>/ops/README.md` -> "cluster" setup steps 1, 4
and 5 (rebuild the stack, kubeconfig for `oke-free`, check with `nodes`).

## 13. (removed) Zot and BuildKit

Removed on 16 Nov 2026: the registry (Zot), BuildKit, Copacetic and the multi-arch join are gone. Images for the Home apps are built by GitHub Actions and published to ghcr.io; nothing runs on the cluster for building or storing images.

## 14. Kyverno: from Audit to Enforce (later)

After a week, read what would be blocked:
```bash
kubectl get policyreports -A
kubectl get policyreports -A -o json | jq -r '.items[].results[]? | select(.result=="fail") | "\(.policy): \(.resources[0].namespace)/\(.resources[0].name)"' | sort -u
```
Fix those (or accept them), then in
`infrastructure/configs/kyverno-policies/kustomization.yaml` change `[Audit]`
to `[Deny]`, PR, merge. That is the only switch. Back to `[Audit]` the same way.

## 15. Trivy Operator

```bash
kubectl get vulnerabilityreports -A          # one per workload image, after the first scans (one at a time)
kubectl get configauditreports -A
```

## 16. PR previews (when an app wants them)

1. cloudflare-free: set `enable_preview_dns = true` (wildcard DNS + tunnel
   rule) and apply.
2. Make sure the token from 5f covers the app's repo (edit the token ->
   Repository access -> add it).
3. In this repo: `cp docs/examples/preview-provider.yaml apps/<app>/preview.yaml`,
   edit url/app/image/port/healthPath, add `- preview.yaml` to
   `apps/<app>/kustomization.yaml`, PR, merge.
4. In the app repo: CI builds arm64 and pushes `<image>:pr-<number>` on every
   PR push. Create the label `preview` (Issues -> Labels -> New label).
5. Label a PR `preview`. Within 5 min: `kubectl get ns | grep pr-`; the smoke
   result arrives on ntfy `cluster`. `https://pr-<n>-<app>.example.com` asks for
   the Access login.

## 17. (removed) Copacetic

Removed on 16 Nov 2026: the registry (Zot), BuildKit, Copacetic and the multi-arch join are gone. Images for the Home apps are built by GitHub Actions and published to ghcr.io; nothing runs on the cluster for building or storing images.

## 18. (removed) Build farm

Removed on 16 Nov 2026: the registry (Zot), BuildKit, Copacetic and the multi-arch join are gone. Images for the Home apps are built by GitHub Actions and published to ghcr.io; nothing runs on the cluster for building or storing images.

## 19. The cluster's key to OCI Vault (once, before step 6)

External Secrets reads OCI Vault as the Oracle user
`cluster-secrets-reader` (read-only on the secrets of vault `freetier`).
Its API key is the one secret still sealed with SOPS in this repo
(`infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml`).
You never write it by hand:

1. Steps 2 (age key in `.sops.yaml`) must be done.
2. Follow oracle-always-free `docs/WHAT-YOU-DO.md` step 15 (sub-steps 1-6): it
   creates the user, runs `scripts/make-reader-key.sh` (key made on the
   laptop, public half uploaded, private half sealed here, the three OCIDs
   written into `clusters/oke/cluster-settings.yaml`) and commits these
   three files here.
3. After Flux runs (step 7), check:
   ```bash
   kubectl get clustersecretstore oci-vault        # STATUS Valid, READY True
   kubectl get externalsecret -A                   # every line SecretSynced, READY True
   ```
   A line with `SecretSyncedError`: `kubectl -n <ns> describe externalsecret <name>`.
   "secret not found" = that Vault secret is not there yet (step 5 / 20-22);
   "401"/"NotAuthenticated" = key or OCIDs wrong (run oracle-always-free step 15.4
   again); "404 NotAuthorizedOrNotFound" on every secret = the policy of
   oracle-always-free `bootstrap/secrets-reader.tf` is not applied.

## 20. Grafana Cloud and New Relic credentials (monitoring)

The OTel collector `otel-gateway` sends metrics, logs and traces to both.
One Vault secret, `monitoring-otel-credentials`.

1. **Grafana Cloud**: grafana.com -> sign in -> **My Account** -> your
   stack -> on the **OpenTelemetry** tile click **Configure**.
   - Copy **OTLP endpoint** (looks like
     `https://otlp-gateway-prod-<zone>.grafana.net/otlp`) and **Instance ID**
     (a number).
   - Under **Password / API Token** click **Generate now**, name
     `oke-free-otel` -> **Create token**. The token has the scopes
     metrics:write, logs:write, traces:write. Copy it (shown once).
2. **New Relic**: one.newrelic.com -> your name (bottom left) -> **API
   Keys** -> the key of type **INGEST - LICENSE** -> `...` -> **Copy key**.
   If the address bar says `one.eu.newrelic.com`, your account is in the EU.
3. Put them in (from `~/k8s-free-gitops`):
   ```bash
   export GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-<zone>.grafana.net/otlp   # from 1
   export GRAFANA_CLOUD_INSTANCE_ID=<instance id>                                        # from 1
   read -rs GRAFANA_CLOUD_TOKEN; export GRAFANA_CLOUD_TOKEN                              # paste, Enter
   export NEW_RELIC_OTLP_ENDPOINT=https://otlp.nr-data.net   # EU account: https://otlp.eu01.nr-data.net
   read -rs NEW_RELIC_LICENSE_KEY; export NEW_RELIC_LICENSE_KEY                          # paste, Enter
   jq -n '{GRAFANA_CLOUD_OTLP_ENDPOINT: env.GRAFANA_CLOUD_OTLP_ENDPOINT,
           GRAFANA_CLOUD_INSTANCE_ID: env.GRAFANA_CLOUD_INSTANCE_ID,
           GRAFANA_CLOUD_TOKEN: env.GRAFANA_CLOUD_TOKEN,
           NEW_RELIC_OTLP_ENDPOINT: env.NEW_RELIC_OTLP_ENDPOINT,
           NEW_RELIC_LICENSE_KEY: env.NEW_RELIC_LICENSE_KEY}' \
     | ~/oracle-always-free/scripts/put-secret.sh monitoring-otel-credentials -
   unset GRAFANA_CLOUD_TOKEN NEW_RELIC_LICENSE_KEY
   ```
4. If the cluster already runs: the collector reads them at start, so
   `kubectl -n monitoring annotate externalsecret otel-credentials force-sync=$(date +%s) --overwrite`
   then `kubectl -n monitoring rollout restart deployment/otel-gateway`.

## 21. Alertmanager's ntfy tokens

Alertmanager posts every alert to `https://ntfy.example.com/alerts` (your
phone; until 28 Nov 2026 also to the old topic `monitor`, see the
<home-server-repo> SETUP-GUIDE "Notification topics (21 Nov)") and, silently,
to the ChatOps channel `cluster` over the tailnet.
One Vault secret, `monitoring-alertmanager-ntfy`:

- `NTFY_TOKEN`: the **bot** (publisher) token of the public ntfy, the one
  `<home-server-repo>/ntfy/setup.sh` printed (Proton Pass). It may publish to
  every topic, so `alerts` needs no server change. Subscribe to `alerts`
  on `ntfy.example.com` in the phone app if you have not already (Grafana
  Cloud and Uptime Kuma use it too).
- `CHATOPS_NTFY_TOKEN`: the ChatOps ntfy token of user `ops` from step 5d.

```bash
read -rs NTFY_TOKEN; export NTFY_TOKEN                   # bot token
read -rs CHATOPS_NTFY_TOKEN; export CHATOPS_NTFY_TOKEN   # ops token
jq -n '{NTFY_TOKEN: env.NTFY_TOKEN, CHATOPS_NTFY_TOKEN: env.CHATOPS_NTFY_TOKEN}' \
  | ~/oracle-always-free/scripts/put-secret.sh monitoring-alertmanager-ntfy -
unset NTFY_TOKEN CHATOPS_NTFY_TOKEN
```
Alertmanager reads the token files on every send: no restart needed.

## 22. ntfy standby: copy Home's users, ACL and tokens into Vault

`apps/ntfy-standby` must know exactly the users, ACL and tokens of the
Home ntfy, so your phone (user `admin`) and every publisher (`bot`, ...)
work there unchanged. They are the three `NTFY_AUTH_*` lines of
`<home-server-dir>/ntfy/.env` on Home. One command copies them
into the Vault secret `ntfy-standby-ntfy-auth` without printing or saving
anything (replace `<home>` with what you type after `ssh` to reach the
Home server; add `sudo` before `cat` if the file is not readable by that
user):

```bash
cd ~/k8s-free-gitops
ssh <home> 'cat <home-server-dir>/ntfy/.env' \
  | python3 scripts/ntfy-auth-json.py \
  | ~/oracle-always-free/scripts/put-secret.sh ntfy-standby-ntfy-auth -
```
-> `created ntfy-standby-ntfy-auth (keys: NTFY_AUTH_ACCESS, NTFY_AUTH_TOKENS,
NTFY_AUTH_USERS, NTFY_UPSTREAM_BASE_URL)`.

Run the same command again **every time you change users or tokens in
Home** (`add-alert-reader.sh`, `add-github-notifier.sh`, `migrate-topics.sh`, a new password),
then `kubectl -n ntfy-standby annotate externalsecret ntfy-auth force-sync=$(date +%s) --overwrite`
and `kubectl -n ntfy-standby rollout restart deployment/ntfy`. If you
forget, the standby still knows the old ones (it says `unchanged` when
nothing changed).

## 23. Monitoring: check it works (after step 7)

1. Pods and memory:
   ```bash
   flux get kustomizations infra-monitoring        # Ready True
   kubectl -n monitoring get pods                  # prometheus, alertmanager, operator, kube-state-metrics,
                                                   # node-exporter x2, otel-gateway, otel-logs x2: Running
   kubectl -n monitoring get externalsecret        # otel-credentials, alertmanager-ntfy: SecretSynced
   ```
2. Prometheus targets (from the laptop over the tailnet):
   `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`
   -> open http://localhost:9090/targets: node-exporter, kube-state-metrics,
   kubelet all UP. http://localhost:9090/alerts lists `NodeDiskLow`.
3. **Grafana Cloud**: your stack -> **Explore** -> data source
   `grafanacloud-<stack>-prom` -> query `up{cluster="oke-free"}` -> about
   10 series with value 1 within 5 minutes. Logs: data source
   `grafanacloud-<stack>-logs` -> `{k8s_namespace_name="flux-system"}`.
4. **New Relic**: one.newrelic.com -> **Query your data** ->
   `FROM Metric SELECT count(*) WHERE k8s.cluster.name = 'oke-free' SINCE 30 minutes ago`
   (not 0) and `FROM Log SELECT count(*) WHERE k8s.cluster.name = 'oke-free' SINCE 30 minutes ago`.
   If nothing arrives: `kubectl -n monitoring logs deploy/otel-gateway | grep -i -E 'error|401|403'`.
5. **Test alert** (phone + ChatOps):
   ```bash
   kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
     amtool alert add TestAlert severity=warning instance=test --annotation=summary="test from oke-free" \
     --alertmanager.url=http://localhost:9093
   ```
   Within a minute: a push on topic `alerts` (ntfy.example.com; until 28 Nov
   2026 a second one on `monitor`) and a silent
   line in the ChatOps channel `cluster`. It resolves by itself after 5
   minutes (a "resolved" push follows). If the ChatOps line never comes:
   `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager | grep -i webhook`
   (a TLS or 401 error there; the tailnet grant is step 4.3).
6. Free tiers: Grafana Cloud -> **Administration** -> **Cost management** ->
   **Usage**: active series should stay well under 10 000 (the collector
   only forwards the series listed in `infrastructure/monitoring/otel-gateway.yaml`,
   `match[]`). New Relic -> **Administration** -> **Data management**: GB
   ingested this month, 100 GB free.

## 24. ntfy standby: check it, then turn on failover

1. After step 22 and a Flux sync:
   ```bash
   kubectl -n ntfy-standby get externalsecret,pods     # ntfy-auth SecretSynced; ntfy Running 1/1
   kubectl -n ntfy-standby logs deploy/ntfy | head     # no "error" lines about auth-users
   ```
2. Same users as Home (over a port-forward, nothing public yet):
   ```bash
   kubectl -n ntfy-standby port-forward svc/ntfy 8080:80 &
   curl -s localhost:8080/v1/health                                      # {"healthy":true}
   curl -s -u admin:<admin password> localhost:8080/v1/account | jq .username   # "admin"
   curl -s -H "Authorization: Bearer <bot token>" -d "standby direct test" localhost:8080/alerts | jq .id
   kill %1
   ```
   A 401 means the Vault secret is not Home's (run step 22 again).
3. Turn on failover in cloudflare-free: its `docs/WHAT-YOU-DO.md` step 13
   (sub-steps 1-4), which adds `ntfy-standby.example.com` to the tunnel.
   Then `curl -s https://ntfy-standby.example.com/v1/health` ->
   `{"healthy":true}`.
4. Test the switch, in both directions: cloudflare-free step 13, sub-steps
   5-7 (stop ntfy in Home, publish, the phone gets it with
   `x-failover: standby`; start it again, back within 5 minutes). The phone
   keeps its one subscription to `ntfy.example.com`; nothing to change in
   the app. Keep the app's connection protocol on the default **JSON
   stream** (ntfy app -> Settings -> Advanced -> Connection protocol): with
   WebSockets it stays on the standby until it reconnects on its own.
5. Uptime Kuma monitor for the standby (Home Kuma UI, it holds no
   secret but is not in the AutoKuma files): **Add New Monitor** ->
   Monitor Type **HTTP(s) - Keyword** -> Friendly Name `ntfy standby (oke)`
   -> URL `https://ntfy-standby.example.com/v1/health` -> Keyword `true` ->
   Heartbeat Interval `120`, Retries `2` -> Notifications: your ntfy
   notification -> **Save**. The existing `ntfy` monitor
   (`https://ntfy.example.com/v1/health`) keeps showing Home's real state:
   the Worker never fails `/v1/health` over.

## 25. CrowdSec (alert only): Vault secret, check, rollback

CrowdSec reads Traefik's access log and sends one ntfy message per attacking
address to topic `security` (title `CrowdSec cluster HIGH|MEDIUM|LOW: ...`).
It blocks nothing; you block with ChatOps `block <ip> <reason>`.

1. **Vault secret** `crowdsec-ntfy`: the **bot** (publisher) token of the
   public ntfy, the same value as `NTFY_TOKEN` in step 21. Before the PR is
   merged (otherwise the LAPI pod waits for its Secret):
   ```bash
   read -rs NTFY_TOKEN; export NTFY_TOKEN                   # bot token
   jq -n '{NTFY_TOKEN: env.NTFY_TOKEN}' \
     | ~/oracle-always-free/scripts/put-secret.sh crowdsec-ntfy -
   unset NTFY_TOKEN
   ```
   You already subscribe to `security` on `ntfy.example.com` for Home; no
   app change.
2. Merge the PR. Flux applies it within the hour (or
   `flux reconcile kustomization infra-controllers infra-security --with-source`).
   Traefik restarts once (access log on).
3. **Check** (laptop, Tailscale up, `KUBECONFIG=~/.kube/oke-free.yaml`):
   ```bash
   kubectl -n crowdsec get externalsecret,pods,pvc
   # externalsecret ntfy SecretSynced; crowdsec-lapi 1/1; crowdsec-agent-xxxxx 1/1 on each node; 2 PVCs Bound
   kubectl -n traefik logs deploy/traefik --tail=3
   # a line starting with a PUBLIC visitor address, then "- -" and the request. If it starts with
   # 10.x (a pod/node address) do NOT go on: Traefik does not see the visitor (see below).
   kubectl -n crowdsec exec ds/crowdsec-agent -- cscli collections list
   # crowdsecurity/traefik, http-cve, base-http-scenarios: enabled
   kubectl -n crowdsec exec ds/crowdsec-agent -- cscli metrics
   # "Acquisition Metrics": file /var/log/containers/traefik-*... lines read > 0, parsed > 0 once traffic came
   kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli machines list
   # two machines (one per agent pod), validated
   kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli notifications test http_ntfy
   # a sample alert arrives on topic security, title "CrowdSec cluster ..."
   ```
4. **Your own addresses**: add your home/office address as `- <address>/32` in
   `infrastructure/security/helmrelease.yaml` (`my-whitelist.yaml`, one line per
   address), merge, then
   `kubectl -n crowdsec rollout restart daemonset/crowdsec-agent`.
5. Real alerts: probe a public hostname from a network that is not whitelisted,
   e.g. 6 times `curl -s -o /dev/null https://<public-host>/.env`; within a minute:
   `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list` and a ntfy
   message on `security`. Resources: `kubectl -n crowdsec top pods`
   (agent under ~150 Mi, LAPI under ~120 Mi expected).
6. If the Traefik log starts with a 10.x address: cloudflared must send
   `X-Forwarded-For` (it does by default) and `ports.web.forwardedHeaders.trustedIPs`
   in the Traefik release must contain the cloudflared pods' range (`${POD_CIDR}`).
   Until the first field is a public address CrowdSec stays silent by design.
7. **Rollback**: remove the `infra-security` Kustomization from
   `clusters/oke/infrastructure.yaml` (git revert of the PR); Flux prunes the
   namespace, the chart and its PVCs. To stop logging the access log too, set
   `accessLog.enabled: false` in the Traefik release. Nothing else depends on it.
   Vault secret `crowdsec-ntfy` can stay.
8. **Enforce later** (not enabled): a bouncer needs the real visitor address
   (step 6 proven) and a Cloudflare-side enforcement (the CrowdSec Cloudflare
   bouncer with its API token), because a cluster-side bouncer cannot block what
   arrives through the tunnel. Decide that separately; this PR installs none.

## Later: rotating a secret

All secrets except the Vault reader key are in OCI Vault: run the command of
its step again with the new value (5a-f, 18.3, 20, 21, 22, 25);
`put-secret.sh` adds a new version. The cluster picks it up within an hour;
at once: `kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite`.
Pods read secrets at start: `kubectl -n <ns> rollout restart deployment/<name>`
(Alertmanager does not need it; CrowdSec: `deployment/crowdsec-lapi`). The Vault reader key itself: oracle-always-free
step 15.7.
