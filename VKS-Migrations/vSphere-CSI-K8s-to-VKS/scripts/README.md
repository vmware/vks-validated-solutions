# FCD adoption companion script

[`zero-copy-migration-poc-script.sh`](zero-copy-migration-poc-script.sh) performs the storage cutover from the [OpenShift-to-VKS walkthrough](../examples/1-OCP-VKS-migration-example.md). It uses `kubectl` for all three APIs; the `OCP_*` variable names remain compatible with the walkthrough. A VKS source must use the separate [VKS-to-VKS method](../../VKS-to-VKS/README.md).

## Run

Use Bash, `kubectl` and `jq`. Complete kubeconfig setup, backups, source quiescing and destination datastore/policy checks first. Both destination namespaces must already exist. This script supports **ReadWriteOnce filesystem volumes**; it does not back up data, stop controllers, restore manifests or restart applications.

From `vSphere-CSI-K8s-to-VKS`, set the variables from the walkthrough:

```bash
export OCP_KUBECONFIG="$HOME/ocp-kubeconfig"
export VKS_KUBECONFIG="$HOME/vks-kubeconfig"
export SUPERVISOR_KUBECONFIG="$HOME/supervisor-kubeconfig"
export SOURCE_NS=default
export TARGET_NS=migration-target
export SUPERVISOR_NS=migration-target  # hosting Supervisor namespace; verify separately
export PVC_NAME=data-migration-test

bash scripts/zero-copy-migration-poc-script.sh --help
bash scripts/zero-copy-migration-poc-script.sh
```

Set `FSTYPE` to the verified filesystem if the source PV omits `spec.csi.fsType`. Optional `OCP_CONTEXT`, `VKS_CONTEXT` and `SUPERVISOR_CONTEXT` select explicit contexts; otherwise each kubeconfig's current context is pinned at startup. Access must include reading the `kube-system` namespace on all three APIs for distinct-cluster checks, plus the storage operations in the walkthrough.

Run the script in a separate process; sourcing it is intentionally a no-op. After preflight and server dry-runs, enter the **exact displayed FCD UUID** to authorize cutover. The old `CONFIRM_DESTRUCTIVE_CUTOVER=YES` setting no longer approves deletion.

## Safeguards and recovery

- Rejects mismatched source PVC/PV identities, non-FCD handles, active source pods and existing destination objects.
- Sets the source PV to `Retain` with UID/resourceVersion checks, then deletes only the observed source PVC using API deletion preconditions.
- Waits for PVC deletion, attachment removal and source PV release before registration. Polling and API requests have time limits.
- Creates destination objects without overwriting them; checks registration errors and verifies the Supervisor/VKS disk, claim UIDs, capacity and filesystem.
- Saves source definitions, destination manifests and created-object identities in a private evidence directory. Set `OUTPUT_DIR` to a **new** directory to choose its location; otherwise the printed temporary directory is retained. These records are not a data backup.

If a step fails, inspect that directory and the current storage state before retrying. A partial run deliberately stops on existing targets. There is no automatic rollback, source-PV deletion, snapshot cleanup or finalizer removal. After success, validate recorded data/checksums through a read-only reader before starting writers; retain rollback assets until sign-off.

## Checks

```bash
python3 scripts/tests/test_zero_copy_script.py
```

The tests use a simulated Kubernetes API and cannot establish live platform compatibility. See [live validation](tests/live-validation-2026-11-12.md) for the checks performed and their limits.
