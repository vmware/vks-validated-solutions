# VKS Persistent Volume Migration

## Overview

Here we demonstrate how an existing VMware Kubernetes Service (VKS) Persistent Volume can be migrated between VKS clusters **without copying application data**.

Unlike traditional migration approaches (for example `rsync`, `pv-migrate` or Velero-based workflows), this method preserves the underlying **First Class Disk (FCD)** and reconstructs the Kubernetes storage metadata around it.

The approach can be used to migrate volumes:

- Between VKS clusters on the same Supervisor
- Between Supervisor namespaces
- Across vCenters (using cross-vCenter Storage vMotion)


---

## Architecture

The storage chain with VKS is thus:

```text
VKS PV
   │ volumeHandle = Supervisor PVC
   ▼
Supervisor PVC
   │
   ▼
Supervisor PV
   │ volumeHandle = FCD UUID
   ▼
First Class Disk (FCD)
```

The migration process effectivley reconstructs this chain while preserving the underlying FCD.

---

# Same-vCenter Migration

Two approaches are possible.

## Option A (Recommended): VolumeSnapshot

A Supervisor `VolumeSnapshot` protects the Supervisor PVC/PV while the VKS objects are deleted.

```text
VKS PV
   │
Supervisor PVC <-----> VolumeSnapshot
   │
Supervisor PV
   │
First Class Disk
```

Advantages

- Simple
- No direct access to the Supervisor control-plane VM required
- Low operational risk

Limitations

- Relies on current CSI snapshot behaviour
- Should be validated against future CSI releases

### Migration Flow

1. Discover the storage chain.
2. Create a Supervisor `VolumeSnapshot`.
3. Delete the VKS PVC and PV.
4. Recreate the VKS PV referencing the retained Supervisor PVC.
5. Create a new VKS PVC bound to the recreated PV.

---

## Option B: Supervisor PV Retain Policy

Instead of using a snapshot, patch the Supervisor PV reclaim policy to **Retain**, remove its `claimRef`, and create a replacement Supervisor PVC. This needs to be done on the Supervisor VM (i.e. via vCenter)

Advantages

- Explicit lifecycle control
- Independent of snapshot behaviour

Limitations

- Requires administrative access to the Supervisor cluster
- Requires patching Kubernetes resources
- Supportability concerns

---

# Cross-vCenter Migration

Once the VKS objects have been removed, the FCD becomes *independent* of the VKS cluster and may be migrated to another vCenter.

The workflow is:

1. Create a Supervisor VolumeSnapshot (or set Retain on the Supervisor PV)
2. Delete the VKS PVC/PV
3. Attach the FCD to a helper VM
4. Perform a cross-vCenter Storage vMotion
5. Register the migrated FCD with `CnsRegisterVolume`
6. Recreate the Supervisor PVC/PV
7. Create a new VKS PV/PVC referencing the new Supervisor PVC

```text
Source vCenter

FCD
 │
Helper VM

   >>> Storage vMotion >>>


Destination vCenter

Helper VM
 │
FCD
 │
CnsRegisterVolume
 │
Supervisor PVC
 │
VKS PV
```

---

# Validation

Worked examples are provided in [examples.md](examples.md). Runnable shell examples are also included as [same-vcenter-example.sh](same-vcenter-example.sh) and [cross-vcenter-example.sh](cross-vcenter-example.sh).

These examples demonstrate:

- Same-vCenter migration
- Cross-vCenter migration
- Supervisor snapshot workflow
- CNS registration
- VKS volume re-adoption

---

# Assumptions and Limitations

| Item | Notes |
|------|------|
| Status | Proof-of-concept |
| Data copy | None (except any storage movement performed by Storage vMotion) |
| FCD UUID | Assumed (and observed during testing) to be preserved across vCenters |
| Destination | Supervisor cluster must support `CnsRegisterVolume` |
| Storage Policy | Compatible policy must exist on the destination Supervisor |
| Snapshot approach | Depends on current CSI snapshot behaviour |
| Retain approach | Requires Supervisor administrative access |
| Rollback | Snapshot or migrated FCD provides recovery path |

---

## Summary

This technique demonstrates that VKS Persistent Volumes can be migrated by reconstructing Kubernetes metadata rather than copying application data. By preserving the underlying First Class Disk and rebuilding the Supervisor/VKS storage chain, workloads can be moved between VKS clusters—and even across vCenters—with minimal disruption.
