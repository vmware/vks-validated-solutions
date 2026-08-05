# VKS Persistent Volume Migration: Worked Examples

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

This document provides two worked examples:

1. [Migrate a volume between VKS clusters on the same vCenter](#example-1-migrate-between-vks-clusters-on-the-same-vcenter)
2. [Migrate a volume between VKS clusters across vCenters](#example-2-migrate-between-vks-clusters-across-vcenters)

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

## Prerequisites

The workstation running these commands requires:

- `kubectl`
- `velero`
- Valid kubeconfig files for the source and destination VKS clusters
- Valid kubeconfig files for the source and destination Supervisors
- Permission to read and create PVs, PVCs and VolumeSnapshots
- Permission to create `CnsRegisterVolume` objects for cross-vCenter migration
- `govc` and `jq` for the helper-VM workflow
- A destination Supervisor namespace with an appropriate storage policy assigned

Before starting, confirm that each context points to the expected cluster:

```bash
vks-src cluster-info
sup-src cluster-info
vks-dst cluster-info
sup-dst cluster-info
```

---

# Example 1: Migrate Between VKS Clusters on the Same vCenter

This example re-adopts an existing FCD in another VKS cluster without copying the filesystem data.

There are two distinct same-vCenter cases, and they require different preservation methods:

| Destination | Preservation method | Privileged Supervisor access |
|---|---|---|
| VKS cluster using the **same Supervisor namespace** | Create a Supervisor `VolumeSnapshot` and reuse the existing Supervisor PVC | No additional cluster-scoped PV modification |
| VKS cluster using a **different Supervisor namespace** | Set the Supervisor PV reclaim policy to `Retain`, allow/remove the old Supervisor PVC, clear the retained PV `claimRef`, and bind a new Supervisor PVC in the destination namespace | **Required** |

> [!IMPORTANT]
> Do not use the snapshot-preservation path when moving the volume to a different Supervisor namespace. vSphere CSI prevents deletion of a Supervisor PVC while snapshots of that volume exist:
>
> ```text
> Deleting volume with snapshots is not allowed
> ```
>
> A cross-namespace migration therefore requires the Supervisor PV `Retain` and rebind workflow.

## 1. Configure kubeconfigs and variables

```bash
export SRC_VKS_KUBECONFIG="$HOME/source-vks-kubeconfig"
export DST_VKS_KUBECONFIG="$HOME/destination-vks-kubeconfig"
export SUPERVISOR_KUBECONFIG="$HOME/supervisor-kubeconfig"

alias vks-src='kubectl --kubeconfig=${SRC_VKS_KUBECONFIG}'
alias vks-dst='kubectl --kubeconfig=${DST_VKS_KUBECONFIG}'
alias sup-src='kubectl --kubeconfig=${SUPERVISOR_KUBECONFIG}'
alias sup-dst='kubectl --kubeconfig=${SUPERVISOR_KUBECONFIG}'

export SRC_VKS_NS=default
export DST_VKS_NS=default

# Supervisor namespaces associated with the source and destination VKS clusters.
export SRC_SUP_NS=migration-source
export DST_SUP_NS=migration-target

export SRC_VKS_PVC=my-test-pvc
export DST_VKS_PV=my-test-pv-migrated
export DST_VKS_PVC=my-test-pvc-migrated

# Used only for a different-Supervisor-namespace migration.
export DST_SUP_PVC=my-test-pvc-migrated-supervisor

# Used only for the same-Supervisor-namespace snapshot path.
export SUP_SNAPSHOT_CLASS=volumesnapshotclass-delete

export BACKUP_NAME="vks-migration-${SRC_VKS_NS}"
export RESTORE_NAME="vks-migration-${DST_VKS_NS}"
```

## 2. Create a test volume and write identifiable data

Skip this step when migrating an existing workload.

```bash
vks-src -n "$SRC_VKS_NS" apply -f - <<'EOF_PVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SRC_VKS_PVC}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF_PVC

vks-src -n "$SRC_VKS_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${SRC_VKS_PVC}" \
  --timeout=5m

vks-src -n "$SRC_VKS_NS" apply -f - <<EOF_POD
apiVersion: v1
kind: Pod
metadata:
  name: migration-test-writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          echo "VKS migration test $(date -u +%FT%TZ)" > /data/migration-test.txt
          sync
          cat /data/migration-test.txt
          sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${SRC_VKS_PVC}
EOF_POD

vks-src -n "$SRC_VKS_NS" wait \
  --for=condition=Ready \
  pod/migration-test-writer \
  --timeout=5m

vks-src -n "$SRC_VKS_NS" exec migration-test-writer -- \
  cat /data/migration-test.txt
```

## 3. Discover and record the storage chain

```bash
export SRC_VKS_PV=$(
  vks-src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export VKS_PVC_SIZE=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.capacity.storage}'
)

export SUP_PVC=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

export SUP_PV=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export FCD_UUID=$(
  sup-src get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

export SUP_STORAGE_CLASS=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.storageClassName}'
)

export SUP_ACCESS_MODE=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.accessModes[0]}'
)

printf '%-22s %s\n' \
  'VKS PVC:' "$SRC_VKS_NS/$SRC_VKS_PVC" \
  'VKS PV:' "$SRC_VKS_PV" \
  'PVC size:' "$VKS_PVC_SIZE" \
  'Supervisor PVC:' "$SRC_SUP_NS/$SUP_PVC" \
  'Supervisor PV:' "$SUP_PV" \
  'Supervisor policy:' "$SUP_STORAGE_CLASS" \
  'FCD UUID:' "$FCD_UUID"
```

Save these values before continuing.

Verify the chain explicitly:

```bash
vks-src get pv "$SRC_VKS_PV" \
  -o custom-columns=NAME:.metadata.name,HANDLE:.spec.csi.volumeHandle,RECLAIM:.spec.persistentVolumeReclaimPolicy

sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
  -o custom-columns=NAME:.metadata.name,PV:.spec.volumeName,PHASE:.status.phase

sup-src get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,HANDLE:.spec.csi.volumeHandle,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

## 4. Quiesce the source workload

Stop all pods that write to the PVC. The example pod is deleted here:

```bash
vks-src -n "$SRC_VKS_NS" delete pod migration-test-writer \
  --wait=true
```

For a Deployment or StatefulSet, scale it to zero instead.

Check for remaining VKS `VolumeAttachment` objects:

```bash
vks-src get volumeattachments \
  -o custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName \
  | grep -F "$SRC_VKS_PV" || true
```

Do not continue while the source volume remains attached to a running workload.

## 5. Create a manifest-only Velero backup

Velero handles the Kubernetes object path independently from the storage migration. PVs, PVCs and snapshot objects are deliberately excluded because the destination storage relationship is reconstructed separately.

```bash
velero backup create "$BACKUP_NAME" \
  --kubeconfig "$SRC_VKS_KUBECONFIG" \
  --include-namespaces "$SRC_VKS_NS" \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

velero backup describe "$BACKUP_NAME" \
  --kubeconfig "$SRC_VKS_KUBECONFIG" \
  --details
```

Do not continue until the backup reports `Completed` and any warnings have been reviewed.

> [!IMPORTANT]
> This Velero backup protects application manifests and metadata only. Persistent data is preserved by the storage workflow below.

## 6. Select the preservation path

```bash
if [ "$SRC_SUP_NS" = "$DST_SUP_NS" ]; then
  echo "Same Supervisor namespace: use the snapshot-preservation path."
else
  echo "Different Supervisor namespaces: use the Retain-and-rebind path."
fi
```

---

## Path A: Same Supervisor namespace

Use this path only when both VKS clusters are associated with the **same Supervisor namespace**.

### A1. Create and verify a Supervisor snapshot

```bash
export SUP_SNAPSHOT="${SUP_PVC}-migration-snapshot"

sup-src get volumesnapshotclass "$SUP_SNAPSHOT_CLASS"

sup-src -n "$SRC_SUP_NS" apply -f - <<EOF_SNAPSHOT
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SUP_SNAPSHOT}
spec:
  volumeSnapshotClassName: ${SUP_SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${SUP_PVC}
EOF_SNAPSHOT

sup-src -n "$SRC_SUP_NS" wait \
  --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${SUP_SNAPSHOT}" \
  --timeout=10m

sup-src -n "$SRC_SUP_NS" get volumesnapshot "$SUP_SNAPSHOT" -o wide
```

### A2. Delete the source VKS PVC and PV

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
  --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi
```

The Supervisor PVC/PV/FCD chain must remain because the snapshot still references the volume.

Verify it:

```bash
sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC"
sup-src get pv "$SUP_PV"

CURRENT_FCD_UUID=$(
  sup-src get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

test "$CURRENT_FCD_UUID" = "$FCD_UUID" || {
  echo "ERROR: FCD identity changed" >&2
  exit 1
}

export DEST_VOLUME_HANDLE="$SUP_PVC"
```

Continue to [Create the destination VKS PV and PVC](#7-create-the-destination-vks-pv-and-pvc).

---

## Path B: Different Supervisor namespaces

Use this path when the destination VKS cluster is associated with a **different namespace on the same Supervisor**.

A Supervisor PVC is namespace-scoped. The destination VKS cluster cannot use the source namespace's Supervisor PVC directly.

The migration therefore rebinds the existing Supervisor PV/FCD to a new PVC:

```text
Source Supervisor namespace                        Destination Supervisor namespace
===========================                        =================================

Supervisor PVC (old)    <--- delete / create--->    Supervisor PVC (new)
        x                                                  │
        x                                                  │
        x ----------------->  Supervisor PV <==============│
                            [remove claimRef]
                                    │
                                    ▼
                                   FCD
```

> [!IMPORTANT]
> Do **not** create a Supervisor VolumeSnapshot for this path. A snapshot prevents deletion of the Supervisor PVC, which is required before the retained PV can be rebound into the destination namespace.

### B1. Obtain privileged Supervisor access

The next operations modify a cluster-scoped Supervisor PV. The normal namespaced Supervisor context may not have permission to perform them.

Obtain an administrative Kubernetes context for the Supervisor using the supported vCenter/Supervisor administrative access method for the environment.

The examples below use:

```bash
alias sup-admin='kubectl --kubeconfig=${SUPERVISOR_ADMIN_KUBECONFIG}'
```

Confirm that it can read and patch the Supervisor PV:

```bash
sup-admin get pv "$SUP_PV"
sup-admin auth can-i patch pv "$SUP_PV"
```

Do not continue unless the answer to the second command is `yes`.

### B2. Set the Supervisor PV reclaim policy to `Retain`

This must be done **before** deleting the source VKS storage objects.

```bash
sup-admin patch pv "$SUP_PV" \
  --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
)" = "Retain" || {
  echo "ERROR: Supervisor PV is not Retain" >&2
  exit 1
}
```

Also verify the FCD identity before proceeding:

```bash
test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$FCD_UUID" || {
  echo "ERROR: unexpected FCD UUID" >&2
  exit 1
}
```

### B3. Delete the source VKS PVC and PV

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
  --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi
```

The Supervisor PVC may be removed automatically as part of the VKS volume deletion. Check its state:

```bash
sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" || true
```

If it still exists, delete it explicitly:

```bash
if sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" >/dev/null 2>&1; then
  sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" --wait=true
fi
```

Because the Supervisor PV was changed to `Retain`, it must remain after the claim is removed:

```bash
sup-admin get pv "$SUP_PV"

test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$FCD_UUID" || {
  echo "ERROR: retained Supervisor PV does not reference expected FCD" >&2
  exit 1
}
```

### B4. Inspect and clear the old Supervisor PV `claimRef`

After the source Supervisor PVC has gone, the retained PV can remain in `Released` state with the old claim identity:

```bash
sup-admin get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle
```

If the old `claimRef` remains, a PVC in the destination namespace cannot bind to the PV.

Remove it:

```bash
sup-admin patch pv "$SUP_PV" \
  --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

Verify that the PV is unclaimed and still points to the same FCD:

```bash
sup-admin get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle

test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$FCD_UUID"
```

### B5. Create a replacement Supervisor PVC in the destination namespace

The destination Supervisor namespace must be entitled to the selected storage policy.

By default, this example reuses the source PVC's StorageClass. Override it if the destination namespace uses a different compatible policy:

```bash
export DST_SUP_STORAGE_CLASS="$SUP_STORAGE_CLASS"
```

Create a new Supervisor PVC and bind it explicitly to the retained Supervisor PV:

```bash
sup-dst -n "$DST_SUP_NS" apply -f - <<EOF_DEST_SUP_PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DST_SUP_PVC}
spec:
  accessModes:
    - ${SUP_ACCESS_MODE}
  volumeMode: Filesystem
  storageClassName: ${DST_SUP_STORAGE_CLASS}
  volumeName: ${SUP_PV}
  resources:
    requests:
      storage: ${VKS_PVC_SIZE}
EOF_DEST_SUP_PVC
```

Wait for binding:

```bash
sup-dst -n "$DST_SUP_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_SUP_PVC}" \
  --timeout=5m
```

Validate both sides of the binding:

```bash
sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" \
  -o custom-columns=NAME:.metadata.name,PV:.spec.volumeName,PHASE:.status.phase

sup-admin get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle
```

Confirm:

- the destination Supervisor PVC is `Bound`;
- the Supervisor PV `claimRef` points to `${DST_SUP_NS}/${DST_SUP_PVC}`;
- the Supervisor PV CSI `volumeHandle` is still `${FCD_UUID}`.

Then:

```bash
export DEST_VOLUME_HANDLE="$DST_SUP_PVC"
```

---

## 7. Create the destination VKS PV and PVC

For either path, the VKS PV `volumeHandle` must be the Supervisor PVC visible to the destination VKS cluster:

- Path A: the existing `${SUP_PVC}`;
- Path B: the new `${DST_SUP_PVC}` in `${DST_SUP_NS}`.

```bash
vks-dst apply -f - <<EOF_DEST_VOLUME
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DST_VKS_PV}
spec:
  capacity:
    storage: ${VKS_PVC_SIZE}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${DST_VKS_NS}
    name: ${DST_VKS_PVC}
  csi:
    driver: csi.vsphere.vmware.com
    fsType: ext4
    volumeHandle: "${DEST_VOLUME_HANDLE}"
    volumeAttributes:
      type: "vSphere CNS Block Volume"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DST_VKS_PVC}
  namespace: ${DST_VKS_NS}
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: ${DST_VKS_PV}
  resources:
    requests:
      storage: ${VKS_PVC_SIZE}
EOF_DEST_VOLUME

vks-dst -n "$DST_VKS_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_VKS_PVC}" \
  --timeout=5m
```

## 8. Restore application manifests

Restore application metadata only after the destination VKS PV/PVC has been created.

```bash
velero restore create "$RESTORE_NAME" \
  --kubeconfig "$DST_VKS_KUBECONFIG" \
  --from-backup "$BACKUP_NAME" \
  --namespace-mappings "${SRC_VKS_NS}:${DST_VKS_NS}" \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

velero restore describe "$RESTORE_NAME" \
  --kubeconfig "$DST_VKS_KUBECONFIG" \
  --details
```

If the application is managed by Helm, GitOps or another package manager, reconstructing the application from that source of truth may be preferable. In either case, verify that restored workloads reference `${DST_VKS_PVC}` where the destination claim name differs.

## 9. Mount the migrated volume and verify the data

```bash
vks-dst -n "$DST_VKS_NS" apply -f - <<EOF_READER
apiVersion: v1
kind: Pod
metadata:
  name: migration-test-reader
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c"]
      args: ["cat /data/migration-test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${DST_VKS_PVC}
EOF_READER

vks-dst -n "$DST_VKS_NS" wait \
  --for=condition=Ready \
  pod/migration-test-reader \
  --timeout=5m

vks-dst -n "$DST_VKS_NS" exec migration-test-reader -- \
  cat /data/migration-test.txt
```

The output should match the content written on the source cluster.

## 10. Cleanup after validation

Delete the test reader after validation:

```bash
vks-dst -n "$DST_VKS_NS" delete pod migration-test-reader
```

If Path A was used, retain the snapshot until the migrated workload has been validated and rollback is no longer required:

```bash
sup-src -n "$SRC_SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT"
```

For Path B, there is no migration snapshot to remove.

---

# Example 2: Migrate Between VKS Clusters Across vCenters

This example preserves the source disk, attaches it to a helper VM, migrates the VM and disk to a destination vCenter, registers the FCD with the destination Supervisor, and adopts the resulting Supervisor PVC into a destination VKS cluster.

> [!IMPORTANT]
> Cross-vCenter vMotion may transfer the disk's storage blocks. The procedure avoids a Kubernetes-level or filesystem-level data copy, but it does not imply that no storage data is transferred by vMotion.

## 1. Configure source and destination contexts

```bash
export SRC_VKS_KUBECONFIG="$HOME/source-vks-kubeconfig"
export SRC_SUP_KUBECONFIG="$HOME/source-supervisor-kubeconfig"
export DST_VKS_KUBECONFIG="$HOME/destination-vks-kubeconfig"
export DST_SUP_KUBECONFIG="$HOME/destination-supervisor-kubeconfig"

alias vks-src='kubectl --kubeconfig=${SRC_VKS_KUBECONFIG}'
alias sup-src='kubectl --kubeconfig=${SRC_SUP_KUBECONFIG}'
alias vks-dst='kubectl --kubeconfig=${DST_VKS_KUBECONFIG}'
alias sup-dst='kubectl --kubeconfig=${DST_SUP_KUBECONFIG}'

export SRC_VKS_NS=default
export SRC_SUP_NS=migration-target
export DST_VKS_NS=default
export DST_SUP_NS=migration-test

export SRC_VKS_PVC=my-test-pvc
export SUP_SNAPSHOT_CLASS=volumesnapshotclass-delete

export REGISTER_NAME=vc-fcd-migration
export DST_SUP_PVC=migrated-cross-supervisor-pvc
export DST_VKS_PV=migrated-cross-vcenter-pv
export DST_VKS_PVC=migrated-cross-vcenter-pvc

export BACKUP_NAME="vks-cross-vcenter-${SRC_VKS_NS}"
export RESTORE_NAME="vks-cross-vcenter-${DST_VKS_NS}"
```

## 2. Discover the source storage chain

Discover the source storage chain as in Example 1:

```bash
export SRC_VKS_PV=$(
  vks-src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export VKS_PVC_SIZE=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.capacity.storage}'
)

export SUP_PVC=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

export SUP_PV=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export SRC_FCD_UUID=$(
  sup-src get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

printf '%-18s %s\n' \
  'VKS PV:' "$SRC_VKS_PV" \
  'Supervisor PVC:' "$SRC_SUP_NS/$SUP_PVC" \
  'Supervisor PV:' "$SUP_PV" \
  'Source FCD UUID:' "$SRC_FCD_UUID"
```

## 3. Quiesce the source workload

Scale the application to zero or otherwise stop all writes. Confirm that no pod is using the PVC before continuing.

Check for remaining VKS `VolumeAttachment` objects:

```bash
vks-src get volumeattachments \
  -o custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName \
  | grep -F "$SRC_VKS_PV" || true
```

Do not continue while the volume remains attached to a source workload.

## 4. Create a manifest-only Velero backup

```bash
velero backup create "$BACKUP_NAME" \
  --kubeconfig "$SRC_VKS_KUBECONFIG" \
  --include-namespaces "$SRC_VKS_NS" \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

velero backup describe "$BACKUP_NAME" \
  --kubeconfig "$SRC_VKS_KUBECONFIG" \
  --details
```

The Velero backup handles application metadata only. The FCD is preserved independently by the storage workflow.

## 5. Retain the source Supervisor PV

For a cross-vCenter migration, do **not** use a Supervisor `VolumeSnapshot` as the retention mechanism. The source Supervisor PVC must be removed before moving the FCD, and vSphere CSI blocks PVC deletion while snapshots exist.

Obtain a privileged source Supervisor context capable of patching cluster-scoped PVs:

```bash
export SRC_SUP_ADMIN_KUBECONFIG="$HOME/source-supervisor-admin-kubeconfig"
alias sup-admin='kubectl --kubeconfig=${SRC_SUP_ADMIN_KUBECONFIG}'

sup-admin auth can-i patch pv "$SUP_PV"
```

Set the Supervisor PV to `Retain`:

```bash
sup-admin patch pv "$SUP_PV" \
  --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
)" = "Retain" || {
  echo "ERROR: Supervisor PV is not Retain" >&2
  exit 1
}
```

Verify the FCD identity:

```bash
test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$SRC_FCD_UUID" || {
  echo "ERROR: unexpected source FCD UUID" >&2
  exit 1
}
```

Delete the source VKS PVC and PV:

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi
```

If the source Supervisor PVC remains, delete it explicitly:

```bash
if sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" >/dev/null 2>&1; then
  sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" --wait=true
fi
```

The retained Supervisor PV and FCD must remain:

```bash
sup-admin get pv "$SUP_PV"

test "$(
  sup-admin get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$SRC_FCD_UUID"
```

The retained Supervisor PV may remain `Released` with the old `claimRef`. That does not need to be cleared for the cross-vCenter path because the source PV is not rebound locally.

## 6. Create a powered-off helper VM and attach the FCD

Configure `govc` for the source vCenter before running these commands. The helper VM must be created in inventory accessible to the source FCD.

```bash
export GOVC_DATASTORE='source-datastore'
export GOVC_RESOURCE_POOL='source-cluster/Resources'
export HELPER_VM="${SRC_FCD_UUID}-migrator"

export FCD_PATH=$(
  govc disk.ls -json "$SRC_FCD_UUID" |
    jq -er '.objects[0].config.backing.filePath'
)

printf 'FCD backing path: %s\n' "$FCD_PATH"

govc vm.create \
  -on=false \
  -net=none \
  "$HELPER_VM"

govc vm.disk.attach \
  -vm "$HELPER_VM" \
  -disk "$FCD_PATH" \
  -link=false

govc device.info -vm "$HELPER_VM"
```

The helper VM must remain powered off. Do not allow a guest OS to mount or modify the disk.

## 7. Perform the cross-vCenter migration

Using the source vCenter UI, perform a cross-vCenter migration of the helper VM and its attached disk.

During migration:

- Select destination compute and storage compatible with the destination Supervisor.
- Ensure the required destination storage policy is assigned to the VM and FCD.
- Do not power on the helper VM.

After migration, configure `govc` for the destination vCenter and rediscover the FCD:

```bash
# Re-export GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD and related settings
# so govc points to the destination vCenter.

govc vm.info "$HELPER_VM"
govc device.info -vm "$HELPER_VM"
```

Set the destination FCD UUID. In validated testing this was the same as the source UUID, but always verify it rather than assuming:

```bash
export DEST_FCD_UUID="$SRC_FCD_UUID"

govc disk.ls -json "$DEST_FCD_UUID" | jq -e . >/dev/null
printf 'Destination FCD UUID: %s\n' "$DEST_FCD_UUID"
```

If the UUID differs, use the UUID discovered on the destination vCenter in all subsequent commands.

## 8. Verify destination storage-policy compatibility

Before registering the disk, verify in vCenter that:

- The FCD is visible in the destination inventory.
- Its datastore is accessible to the destination Supervisor.
- Its VM Storage Policy is assigned to the destination Supervisor namespace.
- The policy is compatible with the datastore hosting the FCD.

Registration may fail or produce an unusable PVC if these mappings are incorrect.

## 9. Register the FCD with the destination Supervisor

```bash
sup-dst -n "$DST_SUP_NS" apply -f - <<EOF_REGISTER
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: ${REGISTER_NAME}
spec:
  volumeID: "${DEST_FCD_UUID}"
  accessMode: ReadWriteOnce
  pvcName: ${DST_SUP_PVC}
EOF_REGISTER

sup-dst -n "$DST_SUP_NS" wait \
  --for=jsonpath='{.status.registered}'=true \
  "cnsregistervolume/${REGISTER_NAME}" \
  --timeout=10m
```

Inspect registration status and any reported error:

```bash
sup-dst -n "$DST_SUP_NS" get \
  "cnsregistervolume/${REGISTER_NAME}" \
  -o yaml

sup-dst -n "$DST_SUP_NS" get \
  "cnsregistervolume/${REGISTER_NAME}" \
  -o jsonpath='{.status.error}{"\n"}'
```

## 10. Discover the destination Supervisor PV and volume size

```bash
export DST_SUP_PV=$(
  sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export DST_SIZE=$(
  sup-dst get pv "$DST_SUP_PV" \
    -o jsonpath='{.spec.capacity.storage}'
)

export REGISTERED_FCD_UUID=$(
  sup-dst get pv "$DST_SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

printf '%-24s %s\n' \
  'Destination Supervisor PVC:' "$DST_SUP_NS/$DST_SUP_PVC" \
  'Destination Supervisor PV:' "$DST_SUP_PV" \
  'Registered FCD UUID:' "$REGISTERED_FCD_UUID" \
  'Registered size:' "$DST_SIZE"

test "$REGISTERED_FCD_UUID" = "$DEST_FCD_UUID"
```

The final command must exit successfully.

## 11. Adopt the destination Supervisor PVC in VKS

```bash
vks-dst apply -f - <<EOF_DEST_VOLUME
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DST_VKS_PV}
spec:
  capacity:
    storage: ${DST_SIZE}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${DST_VKS_NS}
    name: ${DST_VKS_PVC}
  csi:
    driver: csi.vsphere.vmware.com
    fsType: ext4
    volumeHandle: "${DST_SUP_PVC}"
    volumeAttributes:
      type: "vSphere CNS Block Volume"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DST_VKS_PVC}
  namespace: ${DST_VKS_NS}
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: ${DST_VKS_PV}
  resources:
    requests:
      storage: ${DST_SIZE}
EOF_DEST_VOLUME

vks-dst -n "$DST_VKS_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_VKS_PVC}" \
  --timeout=5m
```

## 12. Restore application manifests

Restore application metadata only after the destination VKS PV/PVC has been reconstructed:

```bash
velero restore create "$RESTORE_NAME" \
  --kubeconfig "$DST_VKS_KUBECONFIG" \
  --from-backup "$BACKUP_NAME" \
  --namespace-mappings "${SRC_VKS_NS}:${DST_VKS_NS}" \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

velero restore describe "$RESTORE_NAME" \
  --kubeconfig "$DST_VKS_KUBECONFIG" \
  --details
```

For Helm- or GitOps-managed applications, reconstructing the application from its original source of truth may be preferable. Verify that restored workloads reference `${DST_VKS_PVC}` where required.

## 13. Mount the volume and validate the migrated data

```bash
vks-dst -n "$DST_VKS_NS" apply -f - <<EOF_READER
apiVersion: v1
kind: Pod
metadata:
  name: cross-vcenter-migration-reader
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c"]
      args: ["cat /data/migration-test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${DST_VKS_PVC}
EOF_READER

vks-dst -n "$DST_VKS_NS" wait \
  --for=condition=Ready \
  pod/cross-vcenter-migration-reader \
  --timeout=10m

vks-dst -n "$DST_VKS_NS" exec cross-vcenter-migration-reader -- \
  cat /data/migration-test.txt
```

Validate application-level consistency before accepting the migration.

## 14. Detach and remove the helper VM

After the FCD has been registered and the destination workload validated, remove the disk from the helper VM without deleting the backing disk, then delete the helper VM.

```bash
# Identify the attached disk device first.
govc device.info -vm "$HELPER_VM"

# Use the appropriate device name returned above. Do not pass -destroy.
# Example only:
# govc device.remove -vm "$HELPER_VM" disk-1000-1

govc vm.destroy "$HELPER_VM"
```

Confirm that the FCD and destination PVC remain present before deleting the VM.

## 15. Source cleanup

Complete source cleanup only after destination validation and migration acceptance.

The source Supervisor may retain stale Kubernetes objects after the FCD has moved. First try normal deletion:

```bash
sup-src -n "$SRC_SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT" \
  --wait=true

sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" \
  --wait=true
```

If the VolumeSnapshot cannot be deleted because the underlying FCD is no longer present in the source vCenter, inspect its finalizers:

```bash
sup-src -n "$SRC_SUP_NS" get volumesnapshot "$SUP_SNAPSHOT" \
  -o jsonpath='{.metadata.finalizers}{"\n"}'
```

As a last-resort cleanup step, remove the finalizers and delete the object:

```bash
sup-src -n "$SRC_SUP_NS" patch volumesnapshot "$SUP_SNAPSHOT" \
  --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'

sup-src -n "$SRC_SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT"
sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC"
```

> [!WARNING]
> Removing finalizers bypasses controller cleanup. Use it only after confirming that the FCD has been migrated successfully and that the remaining source objects are stale metadata.

---

# Validation Checklist

Before declaring the migration complete, confirm all of the following:

- [ ] The source workload was quiesced before storage metadata was changed.
- [ ] The original VKS PV, Supervisor PVC, Supervisor PV and FCD UUID were recorded.
- [ ] The correct preservation method was used: snapshot for same-Supervisor-namespace migration, or Supervisor PV `Retain` for cross-namespace/cross-vCenter migration.
- [ ] The destination Supervisor PV references the expected FCD UUID.
- [ ] The destination VKS PVC is `Bound`.
- [ ] The volume mounts successfully in the destination VKS cluster.
- [ ] File-level or application-level data validation succeeds.
- [ ] The destination workload operates correctly before source cleanup.
- [ ] Source cleanup is deferred until rollback is no longer required.
