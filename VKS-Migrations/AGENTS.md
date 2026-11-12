# Repository guidance

This repository contains migration patterns, worked examples and companion scripts for stateful Kubernetes workloads moving to or between VKS clusters. Read the affected method's README, example and script usage before changing its workflow.

## Keep the migration methods distinct

| Directory | Persistent-data mechanism |
|---|---|
| `Any-K8s-to-VKS/` | Copy filesystem contents into a pre-provisioned destination PVC with `pv-migrate`/`rsync`. |
| `vSphere-CSI-K8s-to-VKS/` | Retain an existing non-VKS vSphere CSI FCD and adopt it through the destination Supervisor. |
| `VKS-to-VKS/` | Preserve or move the FCD and reconstruct the VKS/Supervisor storage relationships. |

- Application metadata migration and persistent-data migration are separate operations. Do not blindly restore source PV/PVC definitions.
- A VKS PV's CSI volume handle identifies a Supervisor PVC; the bound Supervisor PV identifies the FCD. Supervisor hosting namespaces and VKS application namespaces are also distinct.
- Filesystem copy does not cover raw block volumes. Cross-vCenter storage relocation can transfer blocks even when the Kubernetes workflow avoids a filesystem copy.

## Documentation

- Keep the main README's purpose and method selection clear in a five-second skim. Keep kubeconfig setup near the end, without a collapsible wrapper.
- Put numbered walkthroughs in each method's `examples/`, starting with `0-obtain-kubeconfigs.md`. Link to the shared kubeconfig guide instead of duplicating it. Keep vSphere 8 and VCF 9 login flows distinct.
- Keep examples, script help, script usage and README links consistent when changing commands or layout. Preserve exact filename casing for Linux/GitHub links.
- Verify version-dependent CLI options against installed help and authoritative documentation. Separate documented behavior, live-tested results and untested proposals; a successful lab run does not establish vendor support.

## Migration script safeguards

- Preserve explicit kubeconfigs and pinned contexts, cluster/resource identity checks, bounded requests and polling, and failure on ambiguous or existing destination objects.
- Preserve typed PVC UID/FCD UUID confirmation before cutover. Sourcing scripts must remain a no-op; execute them in a separate Bash process.
- Require quiesced workloads and detachment checks at the scenario's specified stages. Preserve UID/resourceVersion preconditions and follow each scenario's retention/snapshot rules.
- [VKS scenario 2](VKS-to-VKS/examples/2-same-supervisor-different-namespace.md) uses a powered-off helper VM and `-keep` operations, excludes Supervisor snapshots, and requires old-chain teardown before disk detachment. Do not substitute the other scenarios' `Retain` workflow or destroy a helper VM with its retained disk attached.
- Keep private evidence and useful failed-run resources for diagnosis. Do not add automatic finalizer removal, destructive rollback, or source/backup cleanup on failure. Retain rollback assets until destination validation and sign-off.
- For `pv-migrate`, preserve source read-only mounts and explicit metadata-preservation limits. Non-root mode, restricted Pod Security and OpenShift SCCs require separate checks; do not relax cluster policy to make a test pass.

## Validation

For shell changes, run `bash -n` on the changed scripts and the affected offline suite from the repository root (requires Python 3, Bash and jq):

```bash
python3 Any-K8s-to-VKS/scripts/tests/test_pv_migrate_script.py
python3 vSphere-CSI-K8s-to-VKS/scripts/tests/test_zero_copy_script.py
python3 VKS-to-VKS/scripts/tests/test_migration_scripts.py
```

Run only the suites relevant to the change; check for skipped tests. These simulate APIs and do not establish live compatibility. For documentation-only edits, check local links, anchors and `git diff --check`; a live migration is unnecessary.

When live validation is part of the task:

- Discover current endpoints, versions and permissions; previous validation reports are historical evidence. Use explicit contexts and isolated, uniquely named test resources. For a disposable source VM, prefer `govc` on the available vSphere environment, with VMware Fusion as a fallback.
- Test the actual companion script and verify data independently, including source integrity for copy workflows. Record versions, topology, results, limitations and cleanup in the method's `scripts/tests/` validation record.
- Scope cleanup to recorded resource UIDs/VM identities. Verify removal of test workloads, storage and VMs while preserving existing workloads. Failed resources may remain for inspection, but report what remains.
- Keep kubeconfigs, passwords, tokens, SSH keys and raw sensitive evidence outside the repository. Commit only sanitized validation records; keep temporary credentials and evidence private.
