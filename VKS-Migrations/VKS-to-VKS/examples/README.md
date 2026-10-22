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
