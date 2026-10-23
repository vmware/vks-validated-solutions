# VKS Persistent Volume Migration Examples

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

Choose the example by the **Supervisor namespaces hosting the source and destination VKS clusters**. These are separate from application namespaces inside VKS; two applications can both use `default` while their VKS clusters belong to different Supervisor namespaces.

| Scenario | Intent | Storage-preservation method | Example |
|---|---|---|---|
| Same Supervisor **and same Supervisor namespace** | Reuse the existing Supervisor PVC/PV from another VKS cluster | Supervisor `VolumeSnapshot` | [1. Same Supervisor and namespace](1-same-supervisor-and-namespace.md) |
| Same Supervisor, **different Supervisor namespaces** | Release the source Supervisor chain and create a new one around the same disk | Powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume` | [2. Same Supervisor, different namespace](2-same-supervisor-different-namespace.md) |
| Different Supervisors **and vCenters** | Move the disk to another vCenter and create a new Supervisor chain there | Supervisor `VolumeSnapshot` + powered-off helper VM + cross-vCenter vMotion + `CnsRegisterVolume` | [3. Across Supervisors and vCenters](3-across-supervisors-and-vcenters.md) |

Examples 1 and 2 retain the FCD on its existing datastore; destination hosts must be able to access it and the disk's storage policy must be assigned to the destination Supervisor namespace. Example 3 can relocate the disk using Storage vMotion. See the [overview](../README.md#overview) for access and datastore requirements and the [architecture](../README.md#architecture) for the storage identities.

Velero is used for application manifests and metadata. The persistent storage relationship is reconstructed separately in each example.

## Running the commands

Use an interactive Bash or zsh session and run the numbered steps individually. Keep the aliases, variables and functions defined by earlier steps in that session. Stop after any error; later steps depend on the checks succeeding. Guarded code blocks use function-local `return` to stop the step without explicitly exiting your shell. They do not enable `set -e`; if your session already enables it, a failing command can still terminate the shell.

Run companion scripts in a separate Bash process, after setting the required variables and completing their prerequisites:

| Script | Scope | Invocation |
|---|---|---|
| [same-vcenter-example.sh](../scripts/same-vcenter-example.sh) | Scenario 1: snapshot protection and adoption within the same Supervisor namespace | `bash scripts/same-vcenter-example.sh` |
| [cross-vcenter-example.sh](../scripts/cross-vcenter-example.sh) | Scenario 3: destination registration and adoption after the disk has been migrated and safely detached | `bash scripts/cross-vcenter-example.sh` |

These paths assume the working directory is `VKS-to-VKS`. The scripts refuse to run when sourced, before changing shell options or issuing migration commands. Scenario 2's helper-VM handover is covered by its worked example, not by `same-vcenter-example.sh`.
