# VKS Persistent Volume Migration Examples

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

Choose the example that matches the relationship between the source and destination VKS clusters.

| Scenario | Storage-preservation method | Supervisor cluster-scoped access | Example |
|---|---|---:|---|
| Same Supervisor **and same Supervisor namespace** | Supervisor `VolumeSnapshot`; reuse existing Supervisor PVC | No | [1. Same Supervisor and namespace](1-same-supervisor-and-namespace.md) |
| Same Supervisor, **different Supervisor namespaces** | Powered-off helper VM + `govc volume.rm -keep` + `CnsRegisterVolume` | **No** | [2. Same Supervisor, different namespace](2-same-supervisor-different-namespace.md) |
| Different Supervisors **and vCenters** | Supervisor PV `Retain` + helper VM + cross-vCenter vMotion + `CnsRegisterVolume` | **Yes, source PV patch/cleanup** | [3. Across Supervisors and vCenters](3-across-supervisors-and-vcenters.md) |

## Storage identities

Keep these identities distinct throughout every migration:

```text
VKS PVC
  ↓ binds to
VKS PV
  ↓ csi.volumeHandle = Supervisor PVC name
Supervisor PVC
  ↓ binds to
Supervisor PV
  ↓ csi.volumeHandle = FCD UUID
FCD
```

Velero is used for application manifests and metadata. The persistent storage relationship is reconstructed separately in each example.
