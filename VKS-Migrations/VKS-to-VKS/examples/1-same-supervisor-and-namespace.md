# Example 1: Same Supervisor and Supervisor Namespace

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

This example migrates a persistent volume between VKS clusters on the **same vCenter**, where both clusters use the **same Supervisor namespace**. The existing Supervisor PVC remains the VKS-facing storage identity, and a Supervisor `VolumeSnapshot` protects the backing volume while the source VKS objects are replaced.

> [!IMPORTANT]
> Use this procedure only when the source and destination VKS clusters use the same Supervisor namespace. For different Supervisor namespaces, use [Example 2](2-same-supervisor-different-namespace.md).

## Prerequisites

The workstation running these commands requires:

- `kubectl`
- `velero`
- Valid kubeconfig files for both VKS clusters and the Supervisor
- Permission to read the Supervisor PV associated with the migration and to manage namespaced PVCs and `VolumeSnapshot` objects
- A destination VKS cluster using the **same Supervisor namespace** as the source

Before starting, confirm that each context points to the expected cluster:

```bash
vks-src cluster-info
sup-src cluster-info
vks-dst cluster-info
```

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

# Both VKS clusters use this same Supervisor namespace.
export SRC_SUP_NS=migration-source
export DST_SUP_NS="$SRC_SUP_NS"

export SRC_VKS_PVC=my-test-pvc
export DST_VKS_PV=my-test-pv-migrated
export DST_VKS_PVC=my-test-pvc-migrated

export SUP_SNAPSHOT_CLASS=volumesnapshotclass-delete

export BACKUP_NAME="vks-migration-${SRC_VKS_NS}"
export RESTORE_NAME="vks-migration-${DST_VKS_NS}"
```

## 2. Create a test volume and write identifiable data

Skip this step when migrating an existing workload.

```bash
vks-src -n "$SRC_VKS_NS" apply -f - <<EOF_PVC
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


## 6. Create and verify a Supervisor snapshot

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

## 7. Delete the source VKS PVC and PV

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

Continue to the destination VKS reconstruction below.

## 8. Create the destination VKS PV and PVC

For this workflow, the VKS PV `volumeHandle` is the existing Supervisor PVC `${SUP_PVC}`.

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

## 9. Restore application manifests

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

## 10. Mount the migrated volume and verify the data

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

## 11. Cleanup after validation

Delete the test reader after validation:

```bash
vks-dst -n "$DST_VKS_NS" delete pod migration-test-reader
```

Retain the snapshot until the migrated workload has been validated and rollback is no longer required:

```bash
sup-src -n "$SRC_SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT"
```



## Validation checklist

- [ ] Source workload was quiesced before storage metadata was changed.
- [ ] VKS PV, Supervisor PVC, Supervisor PV and FCD UUID were recorded.
- [ ] Supervisor snapshot reached `readyToUse: true` before source VKS storage objects were removed.
- [ ] Existing Supervisor PVC/PV/FCD chain survived source VKS teardown.
- [ ] Destination VKS PV uses the existing Supervisor PVC name as `volumeHandle`.
- [ ] Destination VKS PVC is `Bound`.
- [ ] Migrated data and application behaviour were validated before snapshot cleanup.
