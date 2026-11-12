# Final PVC copy companion script

[`pv-migrate-poc.sh`](pv-migrate-poc.sh) performs the final filesystem copy from the [worked example](../examples/1-OCP-to-vks-using-pv-migrate.md). It requires `kubectl`, `jq`, `python3`, `helm` and a compatible `pv-migrate` CLI. The script checks the installed root-command flags; the live test uses pv-migrate **3.7.0**.

## Run

Prepare the destination PVC, take an independent backup, record source checksums, and stop writers **and their controllers on both clusters**. Both PVCs and PVs must be `Bound` filesystem volumes, with no remaining pods referencing either claim. For `WaitForFirstConsumer`, provision the destination using a temporary mounting pod, then remove that pod before running the script.

From `Any-K8s-to-VKS`:

```bash
export SRC_KUBECONFIG="$HOME/openshift-kubeconfig" # any authenticated source cluster
export DST_KUBECONFIG="$HOME/vks-kubeconfig"
export SRC_NAMESPACE=my-application
export DST_NAMESPACE=my-application
export SRC_PVC=app-data
export DST_PVC=app-data

bash scripts/pv-migrate-poc.sh --help
bash scripts/pv-migrate-poc.sh
```

Optional `SRC_CONTEXT` and `DST_CONTEXT` select explicit contexts; otherwise each file's current context is pinned. The account needs access to the `kube-system` namespace for cluster identity checks, PVCs/PVs, namespace pod lists and Helm releases, plus permissions for pv-migrate's temporary resources.

After preflight, enter the **destination PVC UID** printed by the script to authorize writing that claim. `ACK_FINAL_COPY=yes` no longer bypasses confirmation. Existing destination files can be overwritten; extraneous files are not deleted. Run in a separate Bash process—sourcing is intentionally a no-op.

## Options and safeguards

- `STRATEGIES` defaults to `loadbalancer`; `nodeport` and `local` are also accepted, including a comma-separated fallback list. The script passes `--rsync-push`; the local strategy uses its own tunnel mechanism. Verify the required network path before cutover.
- `PV_MIGRATE_VALUES_FILE` accepts one reviewed local Helm values file for platform-specific images, security contexts or networking. The file is copied into the private evidence directory before use.
- `NON_ROOT=yes` adds `--non-root` only when source files are readable and destination permissions permit writing. This mode does **not** preserve ownership; see [OpenShift considerations](../OPENSHIFT.md).
- `MIGRATION_ID` defaults to a unique short identifier. Existing matching Helm releases cause a stop. `HELM_TIMEOUT` and `LOADBALANCER_TIMEOUT` default to `5m`.
- Source/destination API identities, claim UIDs, binding, volume mode and capacity are checked before confirmation and again before/after copying. Capacity comparisons understand equivalent units such as `1Gi` and `1024Mi`.
- `OUTPUT_DIR` must name a new directory; otherwise a private temporary directory is created and retained. It contains the inspected PVC/PV definitions, tool version, command and migration log. These are evidence, not a data backup.

On failure, pv-migrate resources remain for inspection (`--no-cleanup-on-failure`). The wrapper does not delete PVCs/PVs, change reclaim policies, roll back a partial copy or restart applications. Inspect the saved log and any remaining releases before retrying. After success, validate checksums/application data independently and retain the source until sign-off.

For restricted Pod Security with pv-migrate 3.7.0, `--non-root` alone left the SSH pod's default capability and omitted seccomp settings in the live test. Use the [restricted values example](../manifests/pv-migrate-restricted-values.yaml) with non-root mode when the file permissions permit it:

```bash
export NON_ROOT=yes
export PV_MIGRATE_VALUES_FILE="$PWD/manifests/pv-migrate-restricted-values.yaml"
```

This configures the migration pods; it does not relax namespace policy. The example also uses `--no-perms` because a non-root process cannot chmod a destination root owned by another UID; it does not promise permission-mode preservation. If ownership or mode preservation is required, use an appropriate identity/security configuration instead. OpenShift SCCs and root-owned files still require the platform-specific preparation in the walkthrough.

## Validation

```bash
python3 scripts/tests/test_pv_migrate_script.py
```

These tests simulate APIs and tool responses. See [live validation](tests/live-validation-2026-11-12.md) for the disposable vanilla-Kubernetes-to-VKS test and its limits. Upstream options are documented in the [pv-migrate CLI reference](https://github.com/utkuozdemir/pv-migrate/blob/v3.7.0/docs/cli-reference.md).
