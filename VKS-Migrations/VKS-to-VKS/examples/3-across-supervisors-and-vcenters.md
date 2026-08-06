# Example 3: Across Supervisors and vCenters

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

This example preserves the source disk, attaches it to a helper VM, migrates the VM and disk to a destination vCenter, registers the FCD with the destination Supervisor, and adopts the resulting Supervisor PVC into a destination VKS cluster.

> [!IMPORTANT]
> Cross-vCenter vMotion may transfer the disk's storage blocks. The procedure avoids a Kubernetes-level or filesystem-level data copy, but it does not imply that no storage data is transferred by vMotion.

> [!NOTE]
> The `govc volume.rm -keep` handover in [Example 2](2-same-supervisor-different-namespace.md) has been validated for moving an FCD between Supervisor namespaces on the **same vCenter**. It has not yet been validated as the source-preservation mechanism for the cross-vCenter workflow below, so this example continues to use the tested Supervisor PV `Retain` procedure.

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
export REGISTER_NAME=vc-fcd-migration
export DST_SUP_PVC=migrated-cross-supervisor-pvc
export DST_VKS_PV=migrated-cross-vcenter-pv
export DST_VKS_PVC=migrated-cross-vcenter-pvc

export BACKUP_NAME="vks-cross-vcenter-${SRC_VKS_NS}"
export RESTORE_NAME="vks-cross-vcenter-${DST_VKS_NS}"
```

## 2. Discover the source storage chain

Discover and record the complete source storage chain:

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

## 5. Create and verify the source Supervisor snapshot

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

## 6. Delete the source VKS PVC and PV

```bash
vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true

if vks-src get pv "$SRC_VKS_PV" >/dev/null 2>&1; then
  vks-src delete pv "$SRC_VKS_PV" --wait=true
fi

sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC"
sup-src get pv "$SUP_PV"
```

## 7. Create a powered-off helper VM and attach the FCD

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

## 8. Perform the cross-vCenter migration

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

## 9. Verify destination storage-policy compatibility

Before registering the disk, verify in vCenter that:

- The FCD is visible in the destination inventory.
- Its datastore is accessible to the destination Supervisor.
- Its VM Storage Policy is assigned to the destination Supervisor namespace.
- The policy is compatible with the datastore hosting the FCD.

Registration may fail or produce an unusable PVC if these mappings are incorrect.

## 10. Register the FCD with the destination Supervisor

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

## 11. Discover the destination Supervisor PV and volume size

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

## 12. Adopt the destination Supervisor PVC in VKS

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

## 13. Restore application manifests

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

## 14. Mount the volume and validate the migrated data

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

## 15. Detach and remove the helper VM

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

## 16. Source cleanup

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


## Validation checklist

- [ ] Source workload was quiesced and manifest-only Velero backup completed.
- [ ] Source VKS PV, Supervisor PVC, Supervisor PV and FCD UUID were recorded.
- [ ] FCD was attached to a powered-off helper VM before cross-vCenter migration.
- [ ] Destination FCD UUID was rediscovered and verified after vMotion.
- [ ] Destination storage policy/datastore compatibility was verified.
- [ ] `CnsRegisterVolume` created the destination Supervisor PVC/PV.
- [ ] Destination Supervisor PV references the expected destination FCD UUID.
- [ ] Destination VKS PV uses the destination Supervisor PVC name as `volumeHandle`.
- [ ] Destination workload mounted and validated the data before source cleanup.
