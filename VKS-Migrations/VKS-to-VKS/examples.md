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

This example preserves the source Supervisor PVC with a VolumeSnapshot, removes the source VKS objects, and creates a static PV/PVC pair in the destination VKS cluster that references the same Supervisor PVC.

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
export SUP_NS=migration-target

export SRC_VKS_PVC=my-test-pvc
export DST_VKS_PV=my-test-pv-migrated
export DST_VKS_PVC=my-test-pvc-migrated

# Use a VolumeSnapshotClass present on the Supervisor.
export SUP_SNAPSHOT_CLASS=volumesnapshotclass-delete
```

Confirm that the snapshot class exists:

```bash
sup-src get volumesnapshotclass "$SUP_SNAPSHOT_CLASS"
```

## 2. Create a test volume and write identifiable data

Skip this step when migrating an existing workload.

```bash
vks-src -n "$SRC_VKS_NS" apply -f - <<'EOF_PVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-test-pvc
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
  namespace: $SRC_VKS_NS
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      command: ["sh", "-c"]
      args:
        - |
          echo "VKS migration test \$(date -u +%FT%TZ)" > /data/migration-test.txt
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

The Supervisor PVC is in the Supervisor namespace associated with the source VKS cluster.

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
  sup-src -n "$SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
)

export FCD_UUID=$(
  sup-src get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)

printf '%-18s %s\n' \
  'VKS PVC:' "$SRC_VKS_NS/$SRC_VKS_PVC" \
  'VKS PV:' "$SRC_VKS_PV" \
  'PVC size:' "$VKS_PVC_SIZE" \
  'Supervisor PVC:' "$SUP_NS/$SUP_PVC" \
  'Supervisor PV:' "$SUP_PV" \
  'FCD UUID:' "$FCD_UUID"
```

Save these values before continuing. They are required for validation and recovery.

Verify the chain explicitly:

```bash
vks-src get pv "$SRC_VKS_PV" \
  -o custom-columns=NAME:.metadata.name,HANDLE:.spec.csi.volumeHandle,RECLAIM:.spec.persistentVolumeReclaimPolicy

sup-src -n "$SUP_NS" get pvc "$SUP_PVC" \
  -o custom-columns=NAME:.metadata.name,PV:.spec.volumeName,PHASE:.status.phase

sup-src get pv "$SUP_PV" \
  -o custom-columns=NAME:.metadata.name,HANDLE:.spec.csi.volumeHandle,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

## 4. Quiesce the source workload

Stop all workloads that write to the PVC. <br>

**For an application deployment or StatefulSet, scale it to zero and verify that the PVC is no longer mounted.** <br><br>

In this example, the pod is deleted:
```bash
vks-src -n "$SRC_VKS_NS" delete pod migration-test-writer \
  --wait=true
```



```bash
vks-src get volumeattachments \
  -o custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName \
  | grep -F "$SRC_VKS_PV" || true
```

Do not continue while the source volume remains attached to a running workload.

## 5. Create and verify the Supervisor snapshot

```bash
export SUP_SNAPSHOT="${SUP_PVC}-migration-snapshot"

sup-src -n "$SUP_NS" apply -f - <<EOF_SNAPSHOT
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SUP_SNAPSHOT}
spec:
  volumeSnapshotClassName: ${SUP_SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${SUP_PVC}
EOF_SNAPSHOT

sup-src -n "$SUP_NS" wait \
  --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${SUP_SNAPSHOT}" \
  --timeout=10m

sup-src -n "$SUP_NS" get volumesnapshot "$SUP_SNAPSHOT" -o wide
```

Record the Supervisor PV reclaim policy and confirm that the snapshot is ready before deleting anything:

```bash
sup-src get pv "$SUP_PV" \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

## 6. Delete the source VKS PVC and PV

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
  --wait=true

# The CSI controller may delete the VKS PV automatically. Delete it only if it remains.
if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi
```

Verify that the Supervisor PVC, Supervisor PV and FCD relationship remains:

```bash
sup-src -n "$SUP_NS" get pvc "$SUP_PVC"
sup-src get pv "$SUP_PV"
sup-src get pv "$SUP_PV" \
  -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
```

The final command must still return the original FCD UUID.

## 7. Create the destination VKS PV and PVC

On the **destination VKS cluster** create a PV and PVC that references the existing Supervisor PVC for the `volumeHandle`<br>
Use a static PV with `storageClassName: ""` to prevent dynamic provisioning. The PV handle points to the existing Supervisor PVC.

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
    volumeHandle: "${SUP_PVC}"
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

## 8. Mount the migrated volume and verify the data

```bash
vks-dst -n "$DST_VKS_NS" apply -f - <<EOF_READER
apiVersion: v1
kind: Pod
metadata:
  name: migration-test-reader
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
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

## 9. Cleanup after validation

Do not remove the Supervisor snapshot until the migrated workload has been validated and rollback is no longer required.

```bash
vks-dst -n "$DST_VKS_NS" delete pod migration-test-reader

# Optional: remove the snapshot only after migration acceptance.
sup-src -n "$SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT"
```

---

# Alternative Same-vCenter Preservation Method: Retain the Supervisor PV

Use this method only when you have sufficient Supervisor administrative access. It does not rely on a VolumeSnapshot.

## 1. Patch the Supervisor PV before deleting the source VKS PVC

Run against the Supervisor control plane with credentials that can modify cluster-scoped PVs:

```bash
kubectl patch pv "$SUP_PV" \
  --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

kubectl get pv "$SUP_PV" \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

## 2. Quiesce the workload and delete the VKS objects

Follow steps 4 and 6 from Example 1.

## 3. Remove the old Supervisor PV claim reference

Confirm that the old Supervisor PVC has been deleted before removing `claimRef`:

```bash
kubectl patch pv "$SUP_PV" \
  --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

## 4. Create a replacement Supervisor PVC

Set the destination storage policy name before applying the PVC:

```bash
export DST_STORAGE_CLASS=vsan-esa-default-policy-raid5
export DST_SUP_PVC="$SUP_PVC"

sup-dst -n "$SUP_NS" apply -f - <<EOF_SUP_PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DST_SUP_PVC}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${DST_STORAGE_CLASS}
  volumeName: ${SUP_PV}
  resources:
    requests:
      storage: ${VKS_PVC_SIZE}
EOF_SUP_PVC

sup-dst -n "$SUP_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_SUP_PVC}" \
  --timeout=5m
```

Then create the destination VKS PV/PVC as shown in step 7, using `${DST_SUP_PVC}` as the VKS PV `volumeHandle`.

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
```

## 2. Discover the source storage chain

Run the discovery commands from Example 1, changing `SUP_NS` to `SRC_SUP_NS`:

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

## 4. Create and verify the source Supervisor snapshot

```bash
export SUP_SNAPSHOT="${SUP_PVC}-migration-snapshot"

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
```

## 5. Delete the source VKS PVC and PV

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi

sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC"
sup-src get pv "$SUP_PV"
```

Do not proceed unless the Supervisor objects still exist and the Supervisor PV still references `${SRC_FCD_UUID}`.

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

## 12. Mount the volume and validate the migrated data

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

## 13. Detach and remove the helper VM

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

## 14. Source cleanup

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
- [ ] The Supervisor snapshot reached `readyToUse: true`, or the Supervisor PV was explicitly retained.
- [ ] The destination Supervisor PV references the expected FCD UUID.
- [ ] The destination VKS PVC is `Bound`.
- [ ] The volume mounts successfully in the destination VKS cluster.
- [ ] File-level or application-level data validation succeeds.
- [ ] The destination workload operates correctly before source cleanup.
- [ ] Source cleanup is deferred until rollback is no longer required.
