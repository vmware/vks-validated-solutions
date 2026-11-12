# pv-migrate companion validation — 12 November 2026

Script: [`pv-migrate-poc.sh`](../pv-migrate-poc.sh)  
SHA-256: `8e0dd21444384c8edf40d402c414bd7cb6f576adf86249567b3267f454d43d85`

## Environment and scope

- **Source:** disposable Ubuntu 24.04 VM cloned with `govc` on vSphere (2 CPUs, 4 GiB RAM), running kind 0.33.0 and upstream Kubernetes 1.35.8. A 1 GiB filesystem PVC used kind's local-path provisioner.
- **Destination:** disposable namespace and 1 GiB vSphere CSI PVC in VKS; nodes reported Kubernetes 1.35.5+vmware.1, vCenter 9.0.2 build 25148086.
- **Tools:** pv-migrate 3.7.0, Helm 4.0.1 and kubectl 1.35.0. Downloaded kind and pv-migrate binaries were checked against published release checksums.
- **Copy:** the complete companion script, using `loadbalancer`, `--rsync-push`, `NON_ROOT=yes` and the [restricted values example](../../manifests/pv-migrate-restricted-values.yaml). The source API was reached through a temporary SSH tunnel; rsync traffic went directly from the source pod to the VKS LoadBalancer.

The values file SHA-256 was `0c80a25c9872b7eb36b3560c05a9adef272568e0cb9f844d22cda25e2502284e`. The VKS restricted Pod Security policy was not relaxed.

## Results

| Check | Result |
|---|---|
| Source claim still referenced by a completed writer pod | Rejected before copying |
| Missing destination-UID confirmation | Rejected before copying |
| Successful final-copy run | Exit 0; source mounted read-only; LoadBalancer push strategy completed |
| Script's post-copy identity verification | Both PVC/PV bindings and identities unchanged |
| Independent read-only verification | Source remained unchanged and destination matched recorded SHA-256 checksums |
| Test data | 1 MiB random payload, text marker, nested path containing spaces, empty file and symlink |
| Existing destination-only file | Preserved with its original checksum |
| Successful pv-migrate cleanup | Both temporary Helm releases removed |

The final source marker and binary were refreshed before the successful run, so that run had to transfer changed contents rather than merely accept files left by an earlier partial attempt.

Final payload SHA-256: `c4ef13127362b591858284d1ee64d0da18bacd46a6bd3b468816d316255c5f52`.

## Issues found and corrected

1. The current CLI requires `pv-migrate --version`; the old `version` subcommand failed. Helm 4 also requires different release-list options from the old `--all` usage. The wrapper now checks the CLI and uses Helm 3/4-compatible release filters.
2. With pv-migrate 3.7.0, `--non-root` alone still rendered `SYS_CHROOT` and omitted required seccomp/drop settings. Pod admission failed. The values example explicitly drops all capabilities, clears the added capability list and sets `RuntimeDefault` seccomp.
3. The next attempt transferred data but returned rsync code 23 when it could not chmod the destination volume root. The wrapper correctly reported failure and retained the temporary resources. The optional values example uses `--no-perms`; ownership/mode preservation is therefore outside this tested configuration. Only the failed test releases were manually removed before retrying.

The [offline suite](test_pv_migrate_script.py) passed **22 distinct test methods**: an initial 19-test run, then focused tests and a successful-flow rerun after final refinements. Coverage includes context/identity changes, pod and release collisions, API failures, capacity units, resize states, confirmation, failed copies, private evidence and safe sourcing. Shell syntax and documentation-link checks also passed.

Cleanup completed: both test namespaces, the destination VKS/Supervisor storage chain and its FCD, and the disposable source VM were verified absent. Kubernetes cleanup used recorded UIDs and normal CSI reclamation; VM cleanup checked its recorded UUID and instance identity. Temporary kubeconfigs and SSH credentials were removed. Existing workloads were not modified.

Limits: this validates a small filesystem copy, not OpenShift SCCs, root-owned source data, ownership/mode preservation, application consistency, Velero restore, large-volume performance, raw block volumes or the `local`/`nodeport` strategies. Failed-run resources require inspection; the wrapper never treats partial transfer as success.
