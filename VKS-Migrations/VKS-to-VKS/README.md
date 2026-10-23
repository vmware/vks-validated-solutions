# VKS Persistent Volume Migration

## Overview

This solution demonstrates how an existing VMware Kubernetes Service (VKS) persistent volume can be migrated between VKS clusters while preserving the underlying **First Class Disk (FCD)**.

Unlike filesystem-copy approaches such as `rsync` or `pv-migrate`, these workflows reconstruct the Kubernetes and CNS metadata around the existing disk. Velero can be used separately to move application manifests and metadata.

Choose the scenario by the **Supervisor namespace hosting each VKS cluster**, not by the application namespace inside VKS. For example, two applications can both use `default` in their respective VKS clusters while those clusters belong to Supervisor namespaces `a` and `b`; that is Scenario 2.

| Scenario | Intent: what changes? | FCD preservation / handover method |
|---|---|---|
| [1. Same Supervisor and same Supervisor namespace](examples/1-same-supervisor-and-namespace.md) | Move the volume to another VKS cluster while **reusing the existing Supervisor PVC/PV**. | Supervisor `VolumeSnapshot`; destination VKS PV references the existing Supervisor PVC |
| [2. Same Supervisor, different Supervisor namespaces](examples/2-same-supervisor-different-namespace.md) | Hand over the existing disk from namespace `a` to namespace `b`; **replace the Supervisor PVC/PV chain**. | Powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume` |
| [3. Different Supervisors and vCenters](examples/3-across-supervisors-and-vcenters.md) | Move the disk to a destination vCenter and **build a new Supervisor PVC/PV chain** there. | Supervisor `VolumeSnapshot` + helper VM + cross-vCenter Storage vMotion + `CnsRegisterVolume` |

**Access requirements:** The examples require permission to read the relevant cluster-scoped Supervisor PVs and manage the namespaced PVCs, snapshots or `CnsRegisterVolume` objects used by the selected procedure. Scenario 2 does not require patching or directly deleting a Supervisor PV; its deletion checks poll with `get` and do not require PV `watch` permission. The helper-VM paths also require sufficient vCenter privileges to manage the VM and disk; Scenario 2 additionally requires the CNS unregister operation. See each example's prerequisites; namespaced access alone does not cover every command.

**Datastore requirements:** Scenarios 1 and 2 keep the FCD on its **existing datastore**. The destination VKS hosts must be able to access that datastore within the supported Supervisor storage topology, and the disk's storage policy must be available to the destination Supervisor namespace and compatible with the datastore. A matching datastore or storage-policy name is not enough. `CnsRegisterVolume` registers the existing disk; it does not relocate or copy it. Scenario 3 can move the disk to a different destination datastore using Storage vMotion and must satisfy the destination storage-policy and accessibility requirements.

The cross-vCenter example does not cover moving between two Supervisors within one vCenter; do not assume that changing Supervisor also creates a separate CNS inventory.

> [!CAUTION]
> These procedures are proofs of concept. Rehearse them with disposable workloads, quiesce the application, and retain an independent application-consistent backup before modifying storage objects.


## Architecture

Keep the storage identities distinct throughout the migration:

```text
VKS PVC
   │ binds to
   ▼
VKS PV
   │ csi.volumeHandle = Supervisor PVC name
   ▼
Supervisor PVC
   │ binds to
   ▼
Supervisor PV
   │ csi.volumeHandle = FCD UUID
   ▼
First Class Disk (FCD)
```

PVCs are namespace-scoped; PVs are cluster-scoped in their respective VKS or Supervisor cluster. A Supervisor PV belongs to the Supervisor cluster and references a namespaced claim through `claimRef`.

The two `volumeHandle` values are different: the **VKS PV uses the Supervisor PVC name**, while the **Supervisor PV uses the FCD UUID**. `CnsRegisterVolume.spec.volumeID` takes the FCD UUID and creates the Supervisor PV/PVC; it does not create the VKS PV/PVC. The migration method depends on which part of this chain must change.


## Scenario 1: Same Supervisor and Same Supervisor Namespace

When both VKS clusters use the **same Supervisor namespace**, the existing Supervisor PVC can remain in place.

A Supervisor `VolumeSnapshot` protects the Supervisor PVC/PV/FCD relationship while the source VKS storage objects are removed. The destination VKS PV then references the same Supervisor PVC name.

```text
Source VKS Cluster                        Destination VKS Cluster
==================                        =======================

VKS PVC/PV    <--- delete | create --->    new VKS PVC/PV
     │                                      │
     └──────────────┐   ┌───────────────────┘
                    ▼   ▼
                Supervisor PVC  <--- VolumeSnapshot
                      │
                 Supervisor PV
                      │
                     FCD                                   
```

High-level flow:

1. Discover and record the complete storage chain.
2. Quiesce the source workload and create a manifest-only Velero backup if required.
3. Create a Supervisor `VolumeSnapshot`.
4. Delete the source VKS PVC/PV.
5. Create the destination VKS PV with `csi.volumeHandle` set to the existing Supervisor PVC name.
6. Bind the destination VKS PVC and validate the data.
7. Remove the snapshot only after the rollback window has ended.

See [Example 1: Same Supervisor and namespace](examples/1-same-supervisor-and-namespace.md).

## Scenario 2: Same Supervisor, Different Supervisor Namespaces

A Supervisor PVC is namespace-scoped, whereas its PV is cluster-scoped. A destination PVC in another Supervisor namespace cannot take over the existing PV while the PV still references the source claim. `CnsRegisterVolume` also refuses to create another Supervisor PV when the same FCD UUID is already represented by an existing PV.

For a move from Supervisor namespace `a` to `b`, **release the source storage chain before registering the disk in the destination namespace**. Changing a PV's reclaim policy to `Retain` preserves it after claim deletion; it does not remove its old `claimRef` or make the disk available for a second Supervisor PV. Reusing the source Supervisor PVC is the intent of Scenario 1 only.

The validated zero-copy handover keeps the disk on the same datastore and avoids manually modifying the cluster-scoped Supervisor PV. A powered-off helper VM prevents destructive deletion while the source storage objects are removed. Then `govc volume.rm -keep` removes the FCD's **CNS registration while preserving the backing disk**, and CSI finishes removing the old Supervisor PV.

```text
Before handover:
  Source VKS PVC → VKS PV → Supervisor PVC in a → Supervisor PV → FCD

Attach the FCD to a powered-off helper VM:
  Source VKS PVC → VKS PV → Supervisor PVC in a → Supervisor PV → FCD::[VM]

Remove the source VKS storage objects and Supervisor PVC:
  Supervisor PV → FCD::[VM]

Run govc volume.rm -keep; wait for CSI to remove the old Supervisor PV:
  FCD::[VM]

Detach the disk with govc device.remove -keep:
  FCD

Register the FCD with CnsRegisterVolume in namespace b:
  new Supervisor PVC in b → new Supervisor PV → FCD
    └─── created by CnsRegisterVolume ────┘

Create the destination VKS PV/PVC using the new Supervisor PVC name:
  new VKS PVC → new VKS PV → new Supervisor PVC in b → new Supervisor PV → FCD
```

High-level flow (the worked example assumes the source Supervisor PV has reclaim policy `Delete`):

1. Discover the source VKS → Supervisor → FCD storage chain.
2. Quiesce the workload and create a manifest-only Velero backup if required.
3. Attach the FCD to a **powered-off helper VM** as a deletion interlock.
4. Delete the source VKS PVC/PV and source Supervisor PVC.
5. The source Supervisor PV becomes `Released`; destructive CSI `DeleteVolume` retries fail with `ResourceInUse` while the FCD remains attached to the helper VM.
6. Run:

   ```bash
   govc volume.rm -keep <FCD-UUID>
   ```

   This removes the CNS container-volume registration while preserving the FCD backing object. It does not directly delete the Kubernetes Supervisor PV.
7. Wait for CSI to remove the old Supervisor PV; confirm that the backing FCD still exists. A `Released` PV alone is not sufficient.
8. Detach the FCD from the helper VM **without deleting the disk**, using `govc device.remove -keep`. Only destroy the helper VM after the disk has been detached.
9. Create `CnsRegisterVolume` in the destination Supervisor namespace using the retained FCD UUID. Wait for `status.registered: true` and a `Bound` destination Supervisor PVC.
10. Use the resulting destination Supervisor PVC name as the `volumeHandle` of the destination VKS PV.
11. Bind the destination VKS PVC, restore application metadata, and validate the data.

> [!IMPORTANT]
> Do **not** create a Supervisor `VolumeSnapshot` for this path. vSphere CSI prevents deletion of the source Supervisor PVC while snapshots of the volume exist.

> [!WARNING]
> Never run `govc volume.rm` without `-keep` in this workflow. The `-keep` flag is what preserves the backing disk.

> [!NOTE]
> This workflow was validated with the FCD still attached to a powered-off helper VM. Source CSI repeatedly attempted destructive deletion, but vCenter returned `ResourceInUse`; `govc volume.rm -keep` successfully removed the CNS registration while preserving the FCD. Treat this exact interaction as version-dependent. If `volume.rm -keep` itself returns `ResourceInUse`, do not detach the helper VM while destructive CSI deletion is still retrying.

A command check on 23 October 2026 used vCenter 9.0.2 (build 25148086), Supervisor Kubernetes 1.32.9, VKS Kubernetes 1.35.5 and govc 0.56.0. A disposable volume survived teardown, unregister, detach, registration and VKS adoption with matching SHA-256 checksums. That check was a round trip through one VKS cluster and one Supervisor namespace; it did not independently validate cross-namespace migration or Velero backup/restore.

If an attempted handover still shows the source namespace in the Supervisor PV's `claimRef`, check these points before proceeding:

| Symptom or attempted shortcut | Meaning and next check |
|---|---|
| The source Supervisor PV was changed to `Retain`, then its PVC was deleted | The old PV and claim reference remain. `Retain` protects the disk but does not complete the handover. This is a different starting state from Example 2's `Delete` workflow; resolve it before continuing. |
| `CnsRegisterVolume` reports `Can not create multiple PV with same volume Id` | A Supervisor PV still represents the FCD. Read the registration object's `status.error` and confirm the old Supervisor PV has disappeared before retrying destination registration. |
| The registration object was created, but the new Supervisor PVC is not ready | Object creation alone does not confirm registration. Check `status.registered`, `status.error` and the destination PVC's binding state before creating the VKS PV/PVC. |
| The destination VKS PV uses the FCD UUID as `volumeHandle` | Use the **new destination Supervisor PVC name** instead. The FCD UUID belongs in `CnsRegisterVolume.spec.volumeID` and the Supervisor PV's handle. |

Do not delete unprotected source storage objects just to clear a registration error. With reclaim policy `Delete`, normal reconciliation can delete the backing FCD. Follow the helper-VM protection and teardown order in the worked example; keep the helper disk attached until both the old CNS registration and Supervisor PV are gone.

This path requires read access to the Supervisor PVs, the namespaced permissions described above, and sufficient vCenter privileges. It does not require manually patching a Supervisor PV's reclaim policy or `claimRef`.

See [Example 2: Same Supervisor, different namespace](examples/2-same-supervisor-different-namespace.md).

## Scenario 3: Across Supervisors and vCenters

For a cross-vCenter migration, a Supervisor `VolumeSnapshot` is used to preserve the source Supervisor PVC/PV/FCD relationship while the source VKS objects are removed. The FCD is then attached to a helper VM and moved to the destination vCenter using cross-vCenter Storage vMotion.

Unlike the same-Supervisor, different-namespace case, the source Supervisor PVC does **not** need to be rebound into another namespace on the same Supervisor. The destination vCenter has its own CNS inventory, so the migrated FCD can be registered with the destination Supervisor using `CnsRegisterVolume`.

```text
Source vCenter                                            Destination vCenter
==============                                            ===================

VKS PVC/PV
    │
    ▼
Supervisor PVC ◄── VolumeSnapshot
    │
Supervisor PV
    │
   FCD
    │
helper VM ───────── X-vCenter Storage vMotion ───────────────► helper VM
                                                                   │
                                                                  FCD
                                                                   │
                                                            CnsRegisterVolume
                                                                   │
                                                            Supervisor PVC/PV
                                                                   │
                                                             Destination VKS
```

High-level flow:

1. Discover the complete source VKS → Supervisor → FCD storage chain.
2. Quiesce the source workload and create a manifest-only Velero backup if required.
3. Create and verify a Supervisor `VolumeSnapshot` for the source volume.
4. Delete the source VKS PVC/PV while the snapshot preserves the Supervisor storage relationship.
5. Attach the FCD to a powered-off helper VM.
6. Perform cross-vCenter Storage vMotion of the helper VM and attached disk.
7. Re-discover and verify the migrated FCD identity on the destination vCenter.
8. Detach the migrated FCD from the helper VM **without deleting the disk**, using `govc device.remove -keep`.
9. Create `CnsRegisterVolume` in the destination Supervisor namespace using the migrated FCD UUID.
10. Use the resulting destination Supervisor PVC name as the `volumeHandle` of the destination VKS PV.
11. Bind the destination VKS PVC, restore application metadata, and validate the workload and data.
12. Retain the source snapshot until destination validation and the agreed rollback window are complete, then perform source cleanup.

Cross-vCenter Storage vMotion may transfer storage blocks. The workflow avoids a Kubernetes-level or filesystem-level data copy, but it does not imply that no storage data moves between vCenters.

See [Example 3: Across Supervisors and vCenters](examples/3-across-supervisors-and-vcenters.md).

## Worked Examples

The detailed procedures are split by migration scenario:

1. [Same Supervisor and Supervisor namespace](examples/1-same-supervisor-and-namespace.md)
2. [Same Supervisor, different Supervisor namespace](examples/2-same-supervisor-different-namespace.md)
3. [Across Supervisors and vCenters](examples/3-across-supervisors-and-vcenters.md)

See the [examples index](examples/README.md) for the scenario comparison and command execution guidance. Run the interactive examples one step at a time; execute the companion scripts with `bash`, rather than sourcing them into your shell.

## Assumptions and Limitations

| Item | Notes |
|---|---|
| Status | Proof-of-concept / validated solution pattern; rehearse before production use |
| Application consistency | Quiesce writes and retain an independent application-consistent backup |
| Velero | Used for application manifests/metadata; PV/PVC storage relationships are reconstructed separately |
| Same namespace | Supervisor `VolumeSnapshot` retains the existing Supervisor PVC/PV/FCD relationship |
| Different namespace, same Supervisor | Validated with powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume`; no cluster-scoped PV modification required |
| Same-Supervisor datastore | Scenarios 1 and 2 reuse the existing FCD on its current datastore; destination hosts and storage policy must support access to it |
| `govc` | The cross-namespace workflow requires a version supporting `volume.rm -keep` |
| Cross-vCenter | Uses a source Supervisor `VolumeSnapshot`, helper VM, cross-vCenter Storage vMotion, and destination `CnsRegisterVolume` |
| Cross-vCenter data movement | Storage vMotion may copy or move storage blocks even though Kubernetes/filesystem data is not copied |
| FCD identity across vCenters | Re-discover and verify the migrated FCD on the destination before registration |
| Destination | Destination Supervisor must support `CnsRegisterVolume` and have the required storage policy assigned to the destination namespace |
| Rollback | Define the rollback point explicitly for each scenario and do not remove protection until destination validation is complete |

## Summary

VKS persistent volumes can be migrated by preserving the underlying FCD and rebuilding the Kubernetes/CNS metadata around it rather than copying the filesystem data.

The preservation mechanism is scenario-specific:

- **Same Supervisor namespace:** keep the Supervisor storage chain alive with a `VolumeSnapshot` and reuse the existing Supervisor PVC.
- **Different namespace on the same Supervisor:** protect the FCD with a helper VM, remove the old CNS registration with `govc volume.rm -keep`, then register it into the destination namespace.
- **Across vCenters:** protect the source storage chain with a `VolumeSnapshot`, move the FCD with a helper VM using cross-vCenter Storage vMotion, then register the migrated disk with the destination Supervisor.
