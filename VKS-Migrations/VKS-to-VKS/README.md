# VKS Persistent Volume Migration

## Overview

This solution demonstrates how an existing VMware Kubernetes Service (VKS) persistent volume can be migrated between VKS clusters while preserving the underlying **First Class Disk (FCD)**.

Unlike filesystem-copy approaches such as `rsync` or `pv-migrate`, these workflows reconstruct the Kubernetes and CNS metadata around the existing disk. Velero can be used separately to move application manifests and metadata.

Three migration scenarios are covered:

| Scenario | FCD preservation / handover method | Cluster-scoped Supervisor access |
|---|---|---:|
| Same Supervisor **and same Supervisor namespace** | Supervisor `VolumeSnapshot`; reuse the existing Supervisor PVC | No |
| Same Supervisor, **different Supervisor namespaces** | Powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume` | **No** |
| Different Supervisors **and vCenters** | Supervisor `VolumeSnapshot` + helper VM + cross-vCenter Storage vMotion + `CnsRegisterVolume` | **No** |

> [!CAUTION]
> These procedures are proofs of concept. Rehearse them with disposable workloads, quiesce the application, and retain an independent application-consistent backup before modifying storage objects.

<br>
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

The migration method depends on which part of this chain must change.

<br>
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

<br>
## Scenario 2: Same Supervisor, Different Supervisor Namespaces

A Supervisor PVC is namespace-scoped, whereas its PV is cluster-scoped. A destination PVC in another Supervisor namespace cannot take over the existing PV while the PV still references the source claim. `CnsRegisterVolume` also refuses to create another Supervisor PV when the same FCD UUID is already represented by an existing PV.

The validated zero-copy handover avoids modifying the cluster-scoped Supervisor PV. Instead, it temporarily removes the FCD's **CNS registration while preserving the backing disk**.

```text
Source Supervisor Namespace                    Destination Supervisor Namespace
===========================                    ================================

Supervisor PVC
     │
Supervisor PV
     │
     ▼
 CNS volume ───── govc volume.rm -keep ─────► retained FCD
     │                                                │
     └── CSI DeleteVolume blocked by                  │
         powered-off helper VM                        ▼
                                             CnsRegisterVolume
                                                    │
                                             Supervisor PVC
                                                    │
                                             Supervisor PV
                                                    │
                                             destination VKS
```

High-level flow:

1. Discover the source VKS → Supervisor → FCD storage chain.
2. Quiesce the workload and create a manifest-only Velero backup if required.
3. Attach the FCD to a **powered-off helper VM** as a deletion interlock.
4. Delete the source VKS PVC/PV and source Supervisor PVC.
5. The source Supervisor PV becomes `Released`; destructive CSI `DeleteVolume` retries fail with `ResourceInUse` while the FCD remains attached to the helper VM.
6. Run:

   ```bash
   govc volume.rm -keep <FCD-UUID>
   ```

   This removes the CNS container-volume registration while preserving the FCD backing object.
7. Wait for the old Supervisor PV representation to disappear.
8. Detach the FCD from the helper VM **without deleting the disk**.
9. Create `CnsRegisterVolume` in the destination Supervisor namespace using the retained FCD UUID.
10. Use the resulting destination Supervisor PVC name as the `volumeHandle` of the destination VKS PV.
11. Bind the destination VKS PVC, restore application metadata, and validate the data.

> [!IMPORTANT]
> Do **not** create a Supervisor `VolumeSnapshot` for this path. vSphere CSI prevents deletion of the source Supervisor PVC while snapshots of the volume exist.

> [!WARNING]
> Never run `govc volume.rm` without `-keep` in this workflow. The `-keep` flag is what preserves the backing disk.

> [!NOTE]
> This workflow was validated with the FCD still attached to a powered-off helper VM. Source CSI repeatedly attempted destructive deletion, but vCenter returned `ResourceInUse`; `govc volume.rm -keep` successfully removed the CNS registration while preserving the FCD. Treat this exact interaction as version-dependent. If `volume.rm -keep` itself returns `ResourceInUse`, do not detach the helper VM while destructive CSI deletion is still retrying.

This path requires normal namespaced Supervisor access plus sufficient vCenter privileges for the helper VM and CNS operation. **It does not require an elevated Supervisor login or cluster-scoped PV patching.**

See [Example 2: Same Supervisor, different namespace](examples/2-same-supervisor-different-namespace.md).

<br>
## Scenario 3: Across Supervisors and vCenters

For a cross-vCenter migration, a Supervisor `VolumeSnapshot` is used to preserve the source Supervisor PVC/PV/FCD relationship while the source VKS objects are removed. The FCD is then attached to a helper VM and moved to the destination vCenter using cross-vCenter Storage vMotion.

Unlike the same-Supervisor, different-namespace case, the source Supervisor PVC does **not** need to be rebound into another namespace on the same Supervisor. The destination vCenter has its own CNS inventory, so the migrated FCD can be registered with the destination Supervisor using `CnsRegisterVolume`.

```text
Source vCenter                                      Destination vCenter
==============                                      ===================

VKS PVC/PV
    │
    ▼
Supervisor PVC ◄── VolumeSnapshot
    │
Supervisor PV
    │
   FCD
    │
helper VM ───────── cross-vCenter Storage vMotion ─────► helper VM
                                                          │
                                                         FCD
                                                          │
                                                  CnsRegisterVolume
                                                          │
                                                  Supervisor PVC/PV
                                                          │
                                                   destination VKS
```

High-level flow:

1. Discover the complete source VKS → Supervisor → FCD storage chain.
2. Quiesce the source workload and create a manifest-only Velero backup if required.
3. Create and verify a Supervisor `VolumeSnapshot` for the source volume.
4. Delete the source VKS PVC/PV while the snapshot preserves the Supervisor storage relationship.
5. Attach the FCD to a powered-off helper VM.
6. Perform cross-vCenter Storage vMotion of the helper VM and attached disk.
7. Re-discover and verify the migrated FCD identity on the destination vCenter.
8. Detach the migrated FCD from the helper VM **without deleting the disk**.
9. Create `CnsRegisterVolume` in the destination Supervisor namespace using the migrated FCD UUID.
10. Use the resulting destination Supervisor PVC name as the `volumeHandle` of the destination VKS PV.
11. Bind the destination VKS PVC, restore application metadata, and validate the workload and data.
12. Retain the source snapshot until destination validation and the agreed rollback window are complete, then perform source cleanup.

Cross-vCenter Storage vMotion may transfer storage blocks. The workflow avoids a Kubernetes-level or filesystem-level data copy, but it does not imply that no storage data moves between vCenters.

See [Example 3: Across Supervisors and vCenters](examples/3-across-supervisors-and-vcenters.md).

<br>
## Worked Examples

The detailed procedures are split by migration scenario:

1. [Same Supervisor and Supervisor namespace](examples/1-same-supervisor-and-namespace.md)
2. [Same Supervisor, different Supervisor namespace](examples/2-same-supervisor-different-namespace.md)
3. [Across Supervisors and vCenters](examples/3-across-supervisors-and-vcenters.md)

See the [examples index](examples/README.md) for the scenario comparison and storage-identity model.

<br>
## Assumptions and Limitations

| Item | Notes |
|---|---|
| Status | Proof-of-concept / validated solution pattern; rehearse before production use |
| Application consistency | Quiesce writes and retain an independent application-consistent backup |
| Velero | Used for application manifests/metadata; PV/PVC storage relationships are reconstructed separately |
| Same namespace | Supervisor `VolumeSnapshot` retains the existing Supervisor PVC/PV/FCD relationship |
| Different namespace, same Supervisor | Validated with powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume`; no cluster-scoped PV modification required |
| `govc` | The cross-namespace workflow requires a version supporting `volume.rm -keep` |
| Cross-vCenter | Uses a source Supervisor `VolumeSnapshot`, helper VM, cross-vCenter Storage vMotion, and destination `CnsRegisterVolume` |
| Cross-vCenter data movement | Storage vMotion may copy or move storage blocks even though Kubernetes/filesystem data is not copied |
| FCD identity across vCenters | Re-discover and verify the migrated FCD on the destination before registration |
| Destination | Destination Supervisor must support `CnsRegisterVolume` and have the required storage policy assigned to the destination namespace |
| Rollback | Define the rollback point explicitly for each scenario and do not remove protection until destination validation is complete |

<br>
## Summary

VKS persistent volumes can be migrated by preserving the underlying FCD and rebuilding the Kubernetes/CNS metadata around it rather than copying the filesystem data.

The preservation mechanism is scenario-specific:

- **Same Supervisor namespace:** keep the Supervisor storage chain alive with a `VolumeSnapshot` and reuse the existing Supervisor PVC.
- **Different namespace on the same Supervisor:** protect the FCD with a helper VM, remove the old CNS registration with `govc volume.rm -keep`, then register it into the destination namespace.
- **Across vCenters:** protect the source storage chain with a `VolumeSnapshot`, move the FCD with a helper VM using cross-vCenter Storage vMotion, then register the migrated disk with the destination Supervisor.
