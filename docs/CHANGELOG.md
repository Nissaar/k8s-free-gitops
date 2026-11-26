# Changelog

Notable changes of this public copy, newest first. Changes that need a manual step from you are marked **ACTION**.

## 2026-11-25: audit for strangers, variables, preflight

### Security
- **No repository, domain or region of the original author in the defaults.** `clusters/oke/cluster-settings.yaml` now carries `<your-domain>` and `<your-home-region>`
  placeholders (a forgotten value makes the `apps` layer fail visibly instead of serving a placeholder host); `flux-instance.yaml` and `.sops.yaml` still need YOUR values:
  `scripts/configure.sh` writes all of them from `cluster.env`, `scripts/preflight.sh` fails while one is left. **ACTION** when you update an older copy: nothing changes in files you already set.
- **Image automation is a switch** (`LAYER_IMAGE_AUTOMATION`): with it off, Flux's deploy key can be read-only (`FLUX_DEPLOY_KEY_WRITE=false` in `oracle-always-free`'s `put-flux-secrets.sh`) and `main` can require pull requests.
- The README states the cluster-wide reach of the `ClusterSecretStore` and the floating-version policy instead of leaving them implicit.
- `validate.yml`: `persist-credentials: false`, timeouts, and `shellcheck scripts/*.sh` (two scripts had shellcheck errors, fixed).

### Added
- `docs/CONFIGURATION.md`: every variable (cluster.env, cluster-settings, layer toggles, Vault secrets), where it is set, default, example.
- `cluster.env.example` + `scripts/configure.sh` (`--check` shows the diff, changes nothing) for the required settings and the optional layers.
- `scripts/preflight.sh`: read-only check of tools, settings, layers, files, repository settings and deploy-key rights; `--validate` runs `scripts/validate.sh`; `--cluster` asks the cluster (get/list only).
- README: how a stranger uses the repository, step by step.

### Changed
- `OCI_REGION` and `OCI_NAMESPACE` are filled by `oracle-always-free`'s `make-reader-key.sh` together with the three OCIDs.
- `infrastructure/configs/tailscale/rbac-chatops.yaml` (optional, off by default) keeps the read-only rule for Kyverno policies but not the original author's `restore-test` Job-creation role (it belongs to a ChatOps command and to the restore-test layer).
