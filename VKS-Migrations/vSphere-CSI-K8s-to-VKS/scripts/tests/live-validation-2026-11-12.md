# FCD adoption script validation — 12 November 2026

Script: [`zero-copy-migration-poc-script.sh`](../zero-copy-migration-poc-script.sh)  
SHA-256: `19b114a592438f73e11abe4d8f9b0baeffbf72ef0f269e7aaf12c066beff1818`

Live checks used vCenter **9.0.2 build 25148086**, `kubectl` **1.35.0**, and VKS nodes reporting **1.35.5+vmware.1**. Only disposable test resources were changed. A usable non-VKS source connection was not available, so **a complete live source-to-VKS migration was not exercised**.

| Check | Result |
|---|---|
| Script with identical source/destination APIs | Rejected before mutation |
| Raw PVC DELETE with UID/resourceVersion preconditions | Wrong UID and stale resourceVersion rejected; current pair accepted; absence verified |
| PV Retain JSON Patch preconditions | Wrong UID and stale resourceVersion rejected; current pair accepted |
| Destination server dry-runs, registration and binding | Passed using the script's unchanged helper, manifest and destination sections with a fresh disposable 1 GiB FCD |
| Supervisor identity checks | Correct FCD, PVC/PV claim UID, capacity, filesystem compatibility and Bound state |
| VKS identity checks | Correct Supervisor PVC handle, new object UIDs, claim binding, capacity, filesystem and Retain policy |
| Destination mount/read | Writer and separate read-only reader completed with matching marker SHA-256 |

Marker checksum: `74fa9c4d3ee2854a814f667d85dfe23189505ee36222220916c3cc05bccd5dce`.

The guard fixtures used an unbound PVC with provisioning disabled and an unmounted hostPath PV already set to `Retain`. They validate API precondition enforcement, not a real FCD's transition from `Delete` to `Retain`. The destination fixture began as a blank disk: its mount/read result validates adoption and access, not preservation of migrated source data.

The [offline regression suite](test_zero_copy_script.py) passed **20 tests** (including failure-case subtests). It exercises the full scripted sequence with a simulated API, including source identity changes, conflicting destinations, API failures, confirmation, deletion ordering, registration errors and binding mismatches. Bash/zsh sourcing checks ensure the script does not change the caller's options or run migration commands. Shell syntax, local documentation links and `git diff --check` also passed.

Cleanup completed: all task-created Kubernetes objects and the test FCD were verified absent. The disposable destination PV's policy was changed to `Delete` with UID/resourceVersion checks solely for normal CSI cleanup; the migration script itself leaves it at `Retain`. No finalizers were stripped. Temporary kubeconfigs were removed, and existing workloads were not modified.

Not exercised live: non-VKS source detachment and retained-PV release, source snapshot/Velero workflows, application restart, cross-vCenter transport, or other product-version combinations.
