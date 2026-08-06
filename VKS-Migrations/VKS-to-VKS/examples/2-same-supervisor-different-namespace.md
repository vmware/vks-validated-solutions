# Example 2: Same Supervisor, Different Supervisor Namespace

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

This example migrates a persistent volume between VKS clusters on the **same vCenter and Supervisor**, but across **different Supervisor namespaces**. It uses a powered-off helper VM as a deletion interlock, removes only the CNS registration with `govc volume.rm -keep`, and then re-registers the retained FCD in the destination namespace.

This is a zero-copy storage handover: the FCD backing data is not copied, the cluster-scoped Supervisor PV is not patched, and elevated Supervisor access is not required.

> [!IMPORTANT]
> Do not use a Supervisor `VolumeSnapshot` for this path. vSphere CSI prevents deletion of the source Supervisor PVC while snapshots of the volume exist.

## Prerequisites

The workstation running these commands requires:

- `kubectl`
- `velero`
- `govc` 0.49.0 or later
- `jq`
- Valid kubeconfig files for both VKS clusters and the shared Supervisor
- Permission to read Supervisor PVs and to manage namespaced PVCs in the source and destination Supervisor namespaces
- Permission to create `CnsRegisterVolume` objects in the destination Supervisor namespace
- A vCenter account with sufficient privileges to create/manage the powered-off helper VM and run `govc volume.rm -keep`
- The required destination storage policy assigned to the destination Supervisor namespace

**Cluster-scoped Supervisor PV modification is not required for this workflow.**

Before starting, confirm that each context points to the expected cluster:

```bash
vks-src cluster-info
sup-src cluster-info
vks-dst cluster-info
sup-dst cluster-info
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

# Source and destination VKS clusters use different namespaces on the same Supervisor.
export SRC_SUP_NS=migration-source
export DST_SUP_NS=migration-target

export SRC_VKS_PVC=my-test-pvc
export DST_VKS_PV=my-test-pv-migrated
export DST_VKS_PVC=my-test-pvc-migrated

export DST_SUP_PVC=my-test-pvc-migrated-supervisor
export REGISTER_NAME=same-vcenter-fcd-migration

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




A Supervisor PVC is namespace-scoped and a Supervisor PV is cluster-scoped. A second PVC in another namespace cannot bind to the existing PV while that PV still contains the source PVC `claimRef`. The `CnsRegisterVolume` controller also refuses to create another Supervisor PV for an FCD whose volume ID is already represented by an existing Supervisor PV.

In validated testing, attempting to register the FCD in the destination namespace before removing the old Supervisor PV returned:

```text
PV: "<source-supervisor-pv>" with the volume ID: "<fcd-uuid>" is already present.
Can not create multiple PV with same volume Id.
```

Rather than modifying the cluster-scoped Supervisor PV, this path temporarily removes the FCD's **CNS registration while preserving the backing disk**:

```text
Source Supervisor namespace                         Destination Supervisor namespace
===========================                         =================================

Supervisor PVC (old)
        │
Supervisor PV (old)
        │
        ▼
   CNS volume  ────── govc volume.rm -keep ──────►  retained FCD
        │                                                   │
        └──── source CSI DeleteVolume blocked               │
              by powered-off helper VM                      │
                                                            ▼
                                                   CnsRegisterVolume
                                                            │
                                                            ▼
                                                   Supervisor PVC (new)
                                                            │
                                                   Supervisor PV (new)
```

> [!IMPORTANT]
> Do **not** create a Supervisor `VolumeSnapshot` for this path. A snapshot prevents deletion of the source Supervisor PVC.
>
> Do **not** run `govc volume.rm` without `-keep`. The `-keep` flag is what removes the CNS container-volume registration while retaining the backing disk.

> [!NOTE]
> This workflow was validated with the FCD attached to a **powered-off helper VM**. The attachment acts as a deletion interlock: when source CSI tries to delete the volume because the Supervisor PV has reclaim policy `Delete`, vCenter returns `ResourceInUse` and the backing disk remains intact while the CNS registration is deliberately removed.

> [!CAUTION]
> The generic `CnsDeleteVolume` API documentation lists `ResourceInUse` as a possible result for an attached volume. In the validated environment, `govc volume.rm -keep` succeeded while the FCD remained attached even though destructive CSI `DeleteVolume` retries were failing with `ResourceInUse`. Treat that behaviour as version-dependent. If `volume.rm -keep` itself returns `ResourceInUse`, do **not** simply detach the helper VM while CSI is still retrying a destructive delete.

## 6. Confirm `govc` support and configure vCenter access

`govc volume.rm -keep` requires govc 0.49.0 or later:

```bash
govc version
govc volume.rm -h | grep -F -- '-keep'
```

Configure the normal `GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD`, `GOVC_DATASTORE` and inventory defaults for the vCenter hosting the source FCD.

Record the CNS volume and its backing object before changing anything:

```bash
export FCD_BACKING_ID=$(govc volume.ls -L "$FCD_UUID")

printf '%-20s %s\n' \
  'CNS volume ID:' "$FCD_UUID" \
  'FCD backing ID:' "$FCD_BACKING_ID"

govc volume.ls -l "$FCD_UUID"
govc disk.ls -l "$FCD_BACKING_ID"
```

Do not continue unless both objects resolve as expected.

## 7. Create a powered-off helper VM and attach the FCD

The helper VM is a safety interlock only. It must remain powered off and no guest operating system must mount or modify the disk.

Discover the backing path:

```bash
export FCD_PATH=$(
  govc disk.ls -json "$FCD_BACKING_ID" |
    jq -er '.objects[0].config.backing.filePath'
)

export HELPER_VM="${FCD_UUID}-migration-guard"

printf 'FCD backing path: %s\n' "$FCD_PATH"
```

Create the helper VM in inventory accessible to the datastore containing the FCD and attach the existing disk without creating a linked delta:

```bash
govc vm.create \
  -on=false \
  -net=none \
  "$HELPER_VM"

govc vm.disk.attach \
  -vm "$HELPER_VM" \
  -disk "$FCD_PATH" \
  -link=false

govc device.info -vm "$HELPER_VM" disk-*
```

Verify that the helper VM is powered off:

```bash
test "$(govc vm.info -json "$HELPER_VM" | jq -r '.VirtualMachines[0].Runtime.PowerState')" = "poweredOff"
```

## 8. Delete the source VKS PVC and PV

The source workload must already be quiesced and the Velero backup completed.

Delete the source VKS PVC and PV:

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
  --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi
```

The Supervisor PVC may disappear automatically. If it remains, remove it using the normal namespaced Supervisor context:

```bash
if sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" >/dev/null 2>&1; then
  sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" --wait=true
fi
```

Because the Supervisor PV still has reclaim policy `Delete`, the vSphere CSI provisioner will try to delete the CNS volume. The helper-VM attachment must prevent the backing FCD from being destroyed.

Verify that the Supervisor PV remains in `Released` state and still references the expected volume ID:

```bash
sup-src get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,HANDLE:.spec.csi.volumeHandle

test "$(sup-src get pv "$SUP_PV" -o jsonpath='{.status.phase}')" = "Released"
test "$(sup-src get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')" = "$FCD_UUID"
```

Inspect the PV events:

```bash
sup-src describe pv "$SUP_PV"
```

The validated workflow showed repeated `VolumeFailedDelete` events containing:

```text
ResourceInUse
The resource 'volume' is in use.
```

Do not continue if the backing disk has disappeared or if the source PV is not in the expected guarded state.

## 9. Remove the CNS registration but keep the FCD

This is the handover operation:

```bash
govc volume.rm -keep "$FCD_UUID"
```

**`-keep` is essential. It instructs CNS to remove the container-volume registration without deleting the backing disk**.

Verify that the CNS volume registration is gone:

```bash
if govc volume.ls "$FCD_UUID" >/dev/null 2>&1; then
  echo "ERROR: CNS volume is still registered" >&2
  exit 1
fi
```

Then verify independently that the backing FCD still exists:

```bash
govc disk.ls -l "$FCD_BACKING_ID"
govc device.info -vm "$HELPER_VM" disk-*
```

At this point the desired state is:

```text
old CNS registration: gone
backing FCD:           present
helper VM:             powered off, FCD still attached
```

## 10. Wait for the old Supervisor PV to disappear

Once CNS no longer contains the old container-volume registration, the source CSI deletion can finish reconciling the stale Supervisor PV without destroying the retained FCD.

Wait for the old Supervisor PV to be removed:

```bash
sup-src wait \
  --for=delete \
  "pv/${SUP_PV}" \
  --timeout=5m
```

Confirm that the old PV no longer blocks registration of the same volume ID:

```bash
if sup-src get pv "$SUP_PV" >/dev/null 2>&1; then
  echo "ERROR: old Supervisor PV still exists" >&2
  exit 1
fi
```

This is the critical difference from the old `Retain` workflow: there is no retained Supervisor PV and therefore no cluster-scoped `claimRef` to edit.

## 11. Detach the retained FCD from the helper VM

Only detach the helper disk **after** the old CNS registration and old Supervisor PV are gone.

Identify the helper VM disk device and remove it while keeping the backing files:

```bash
govc device.info -vm "$HELPER_VM" disk-*

export HELPER_DISK_DEVICE=$(
  govc device.ls -vm "$HELPER_VM" | awk '/^disk-/ {print $1; exit}'
)

test -n "$HELPER_DISK_DEVICE" || {
  echo "ERROR: helper VM disk device not found" >&2
  exit 1
}

govc device.remove \
  -vm "$HELPER_VM" \
  -keep \
  "$HELPER_DISK_DEVICE"
```

Verify that the retained FCD still exists:

```bash
govc disk.ls -l "$FCD_BACKING_ID"
```

The helper VM can be removed after the migration has been validated.

## 12. Register the retained FCD in the destination Supervisor namespace

Create a namespaced `CnsRegisterVolume` object:

```bash
sup-dst -n "$DST_SUP_NS" apply -f - <<EOF_REGISTER
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: ${REGISTER_NAME}
spec:
  volumeID: "${FCD_UUID}"
  accessMode: ${SUP_ACCESS_MODE}
  pvcName: ${DST_SUP_PVC}
EOF_REGISTER
```

Wait for registration:

```bash
sup-dst -n "$DST_SUP_NS" wait \
  --for=jsonpath='{.status.registered}'=true \
  "cnsregistervolume/${REGISTER_NAME}" \
  --timeout=10m
```

Inspect the result and fail if the controller reports an error:

```bash
sup-dst -n "$DST_SUP_NS" get \
  "cnsregistervolume/${REGISTER_NAME}" \
  -o yaml

REGISTER_ERROR=$(
  sup-dst -n "$DST_SUP_NS" get \
    "cnsregistervolume/${REGISTER_NAME}" \
    -o jsonpath='{.status.error}'
)

test -z "$REGISTER_ERROR" || {
  echo "ERROR: CnsRegisterVolume failed: $REGISTER_ERROR" >&2
  exit 1
}
```

Discover the newly created Supervisor PV:

```bash
export DST_SUP_PV=$(
  sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" \
  -o custom-columns=NAME:.metadata.name,PV:.spec.volumeName,PHASE:.status.phase

sup-dst get pv "$DST_SUP_PV" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,HANDLE:.spec.csi.volumeHandle
```

Confirm that the destination Supervisor PVC is `Bound` and that the new Supervisor PV represents the retained FCD:

```bash
test "$(
  sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" \
    -o jsonpath='{.status.phase}'
)" = "Bound"

test "$(
  sup-dst get pv "$DST_SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)" = "$FCD_UUID"
```

The VKS volume handle is now the new Supervisor PVC name:

```bash
export DEST_VOLUME_HANDLE="$DST_SUP_PVC"
```

## 13. Create the destination VKS PV and PVC

For this workflow, the VKS PV `volumeHandle` is the newly registered destination Supervisor PVC `${DST_SUP_PVC}` in `${DST_SUP_NS}`.

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

## 14. Restore application manifests

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

## 15. Mount the migrated volume and verify the data

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

## 16. Cleanup after validation

Delete the test reader after validation:

```bash
vks-dst -n "$DST_VKS_NS" delete pod migration-test-reader
```

There is no migration snapshot or retained source Supervisor PV to remove. After the migrated workload has been validated, remove the powered-off helper VM if it is no longer required:

```bash
govc vm.destroy "$HELPER_VM"
```

Only destroy the helper VM after its migration-guard disk has been detached with `device.remove -keep` and the destination workload has been validated.


## Validation checklist

- [ ] Source workload was quiesced and manifest-only Velero backup completed.
- [ ] VKS PV, Supervisor PVC, Supervisor PV, CNS volume ID and FCD backing object were recorded.
- [ ] Powered-off helper VM held the FCD before source storage teardown.
- [ ] Source Supervisor PV entered `Released` and CSI deletion failed safely with `ResourceInUse`.
- [ ] `govc volume.rm -keep` removed the old CNS registration while the FCD remained present.
- [ ] Old Supervisor PV disappeared before the helper VM released the disk.
- [ ] `CnsRegisterVolume` created a new Supervisor PVC/PV in the destination namespace.
- [ ] New Supervisor PV references the original FCD UUID.
- [ ] Destination VKS PV uses the new Supervisor PVC name as `volumeHandle`.
- [ ] Destination workload mounted and validated the original data.
