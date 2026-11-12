# Example 3: Across Supervisors and vCenters

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

Run one numbered step at a time in an interactive Bash or zsh shell. Guarded steps use named functions so a failed check stops that function without explicitly exiting your shell. Do not continue to later steps after an error. See the [execution guidance](README.md#running-the-commands), including the caveat for shells that already enable `set -e`.

This example preserves the source disk, attaches it to a helper VM, migrates the VM and disk to a destination vCenter, detaches the disk without deleting it, registers the FCD with the destination Supervisor, and adopts the resulting Supervisor PVC into a destination VKS cluster.

> [!IMPORTANT]
> Cross-vCenter vMotion may transfer the disk's storage blocks. The procedure avoids a Kubernetes-level or filesystem-level data copy, but it does not imply that no storage data is transferred by vMotion.


## Prerequisites

- `kubectl`, `velero`, `govc` and `jq`
- Valid kubeconfigs for both VKS clusters and both Supervisors: complete [Step 0](0-obtain-kubeconfigs.md) first
- Permission to read Supervisor PVs, manage namespaced PVCs and snapshots, and create destination `CnsRegisterVolume` objects
- vCenter privileges to manage the helper VM and perform cross-vCenter migration
- Source and destination compute, storage, networking and storage policies compatible with the intended migration

The helper cleanup guard uses the govc 0.56.0 JSON fields from Example 2; inspect your version's response if they differ.

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
export DST_VKS_PVC="$SRC_VKS_PVC"
export SUP_SNAPSHOT_CLASS=volumesnapshotclass-delete

export BACKUP_NAME="vks-cross-vcenter-${SRC_VKS_NS}"
export RESTORE_NAME="vks-cross-vcenter-${DST_VKS_NS}"
```

Confirm all four contexts before continuing:

```bash
vks-src cluster-info
sup-src cluster-info
vks-dst cluster-info
sup-dst cluster-info
```

## 2. Discover the source storage chain

Discover and record the complete source storage chain:

```bash
discover_source_volume() {
  SRC_VKS_PV=$(
    vks-src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" \
      -o jsonpath='{.spec.volumeName}'
  ) || return 1
  test -n "$SRC_VKS_PV" || { echo "ERROR: source PVC has no bound PV" >&2; return 1; }

  VKS_PVC_SIZE=$(
    vks-src get pv "$SRC_VKS_PV" \
      -o jsonpath='{.spec.capacity.storage}'
  ) || return 1

  SUP_PVC=$(
    vks-src get pv "$SRC_VKS_PV" \
      -o jsonpath='{.spec.csi.volumeHandle}'
  ) || return 1
  test -n "$SUP_PVC" || { echo "ERROR: source PV has no Supervisor PVC handle" >&2; return 1; }

  SUP_PV=$(
    sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
      -o jsonpath='{.spec.volumeName}'
  ) || return 1
  test -n "$SUP_PV" || { echo "ERROR: Supervisor PVC has no bound PV" >&2; return 1; }

  SRC_FCD_UUID=$(
    sup-src get pv "$SUP_PV" \
      -o jsonpath='{.spec.csi.volumeHandle}'
  ) || return 1
  test -n "$SRC_FCD_UUID" && test -n "$VKS_PVC_SIZE" || {
    echo "ERROR: source FCD UUID or volume size is empty" >&2
    return 1
  }

  export SRC_VKS_PV VKS_PVC_SIZE SUP_PVC SUP_PV SRC_FCD_UUID

  printf '%-18s %s\n' \
    'VKS PV:' "$SRC_VKS_PV" \
    'Supervisor PVC:' "$SRC_SUP_NS/$SUP_PVC" \
    'Supervisor PV:' "$SUP_PV" \
    'Source FCD UUID:' "$SRC_FCD_UUID"
}
discover_source_volume
```

## 3. Quiesce the source workload

Record the application replica count. Quiesce writes and record a known readable file with its contents or checksum before unmounting. Then scale the application to zero or otherwise stop all pods using the PVC, and keep them stopped through destination reader validation.

Check the source VKS attachments:

```bash
vks-src get volumeattachments \
  -o custom-columns=NAME:.metadata.name,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName
```

Continue only when the command succeeds and no row has a PV equal to `${SRC_VKS_PV}`. If a row remains, wait and rerun the command; a query error is not evidence of detachment.

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

Do not continue until the backup reports `Completed` and any warnings have been reviewed.

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

This example keeps the snapshot-only preservation path; it does not require changing the source VKS PV to `Retain`. The Supervisor [snapshot admission check](https://github.com/kubernetes-sigs/vsphere-csi-driver/blob/v3.5.0/pkg/syncer/admissionhandler/validatepvc.go) can reject deletion of an RWO PVC whose Supervisor PV has reclaim policy `Delete` while a snapshot references that PVC.

Rehearse the complete procedure with disposable data on the target versions. The source VKS `csi-provisioner` version, feature settings and PV finalizers determine whether explicit PV deletion can finish while Supervisor PVC deletion is blocked. If the command below times out, stop and inspect the source PV and CSI errors; do not remove the snapshot or strip finalizers to make it finish.

```bash
remove_source_vks_volume() {
  vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
    --wait=true --timeout=5m || return 1

  vks-src delete pv "$SRC_VKS_PV" \
    --ignore-not-found --wait=true --timeout=5m || return 1

  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" || return 1
  sup-src get pv "$SUP_PV" || return 1
}
remove_source_vks_volume
```

## 7. Create a powered-off helper VM and attach the FCD

Configure `govc` for the source vCenter before running these commands. The helper VM must be created in inventory accessible to the source FCD.

```bash
export GOVC_DATASTORE='source-datastore'
export GOVC_RESOURCE_POOL='source-cluster/Resources'
export HELPER_VM="${SRC_FCD_UUID}-migrator"

create_helper_vm() {
  local fcd_info
  FCD_BACKING_ID=$(govc volume.ls -L "$SRC_FCD_UUID") || return 1
  test -n "$FCD_BACKING_ID" || return 1
  fcd_info=$(govc disk.ls -json "$FCD_BACKING_ID") || return 1
  FCD_PATH=$(printf '%s\n' "$fcd_info" |
    jq -er '.objects | select(length == 1) | .[0].config.backing.filePath | select(type == "string" and length > 0)') || return 1
  export FCD_PATH

  printf 'FCD backing path: %s\n' "$FCD_PATH"

  govc vm.create \
    -on=false \
    -net=none \
    "$HELPER_VM" || return 1

  govc vm.disk.attach \
    -vm "$HELPER_VM" \
    -disk "$FCD_PATH" \
    -link=false || return 1

  govc device.info -vm "$HELPER_VM" || return 1
}
create_helper_vm
```

Check `govc vm.info "$HELPER_VM"` and the device output above: the helper must be powered off and its only disk must have the recorded `${FCD_PATH}`. Do not let a guest OS mount the disk. If creation or attachment fails, inspect the helper before retrying.

## 8. Perform the cross-vCenter migration

Using the source vCenter UI, perform a cross-vCenter migration of the helper VM and its attached disk.

During migration:

- Select destination compute and storage compatible with the destination Supervisor.
- Ensure the required destination storage policy is assigned to the VM and FCD.
- Do not power on the helper VM.

After migration, configure `govc` for the destination vCenter **and destination datastore**. Update or unset source datacenter/resource-pool defaults before inspecting the migrated helper:

```bash
# Re-export GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD and related settings
# so govc points to the destination vCenter.

govc vm.info "$HELPER_VM"
govc device.info -vm "$HELPER_VM"
```

Inspect the migrated disk's ID and backing path:

```bash
govc device.info -json -vm "$HELPER_VM" 'disk-*' \
  | jq '.devices[] | {name, id: .vDiskId.id, path: .backing.fileName}'
```

There must be exactly one disk. Record its nonempty `id` below after comparing the VM and backing path with the completed migration task. Do not assume the source UUID remained unchanged.

```bash
export DEST_FCD_UUID='<destination-disk-id>'
govc disk.ls -l "$DEST_FCD_UUID"
```

Stop if the query fails or the disk does not match the migrated helper.

## 9. Verify destination storage-policy compatibility

Before registering the disk, verify in vCenter that:

- The FCD is visible in the destination inventory.
- Its datastore is accessible to the destination Supervisor.
- Its VM Storage Policy is assigned to the destination Supervisor namespace.
- The policy is compatible with the datastore hosting the FCD.

Registration may fail or produce an unusable PVC if these mappings are incorrect.

## 10. Detach the migrated FCD without deleting it

Detach the FCD from the powered-off helper VM before registering it or starting the destination workload. Keep `govc` configured for the destination vCenter and the datastore containing the migrated FCD.

Inspect the helper and the FCD backing path:

```bash
govc vm.info "$HELPER_VM"
govc disk.ls -L "$DEST_FCD_UUID"
govc device.info -vm "$HELPER_VM" 'disk-*'
```

Continue only if the helper is powered off and its only disk matches the recorded destination ID and backing path. Set its device name from the output; do not assume the first disk is correct.

```bash
export HELPER_DISK_DEVICE='<confirmed-device-name>'
govc device.remove -vm "$HELPER_VM" -keep "$HELPER_DISK_DEVICE"
govc device.info -vm "$HELPER_VM" 'disk-*'
govc disk.ls -l "$DEST_FCD_UUID"
```

Stop on any failed command. Continue only when the helper has no disks and the FCD still resolves. Keep the empty helper until destination validation is complete.

## 11. Register the FCD with the destination Supervisor

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
```

## 12. Discover the destination Supervisor PV and volume size

The registration YAML above must show `registered: true` with no error. Then wait for the claim and inspect the resulting PV:

```bash
sup-dst -n "$DST_SUP_NS" wait \
  --for=jsonpath='{.status.phase}'=Bound "pvc/${DST_SUP_PVC}" --timeout=5m
DST_SUP_PV=$(sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" -o jsonpath='{.spec.volumeName}')
sup-dst get pv "$DST_SUP_PV" \
  -o custom-columns=NAME:.metadata.name,HANDLE:.spec.csi.volumeHandle,SIZE:.spec.capacity.storage
DST_SIZE=$(sup-dst get pv "$DST_SUP_PV" -o jsonpath='{.spec.capacity.storage}')
```

Continue only if every command succeeds, the handle equals `${DEST_FCD_UUID}`, and the size is nonempty and matches the source capacity. Object creation alone is not proof of successful registration.

## 13. Adopt the destination Supervisor PVC in VKS

Continue only after Step 12 confirms registration and a `Bound` Supervisor PVC referencing the migrated FCD. The VKS `volumeHandle` is that Supervisor PVC name, not the FCD UUID.

The destination application namespace `${DST_VKS_NS}` must already exist (the default `default` namespace does). Create it first if using a new namespace.

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

## 14. Restore application manifests

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

Keep restored workloads scaled to zero through reader validation. The destination PVC name defaults to the source name; update workload claim references only if deliberately renaming it. For Helm or GitOps workloads, restore from that source of truth if preferred.

## 15. Mount the volume and validate the migrated data

Replace `/data/migration-test.txt` in both reader commands below with the known file recorded in Step 3; this example does not create a test file.

The sample reader runs as UID/GID 1000; adjust these values if the existing data requires a different identity. It mounts the volume read-only and omits `fsGroup` to avoid requesting ownership changes to migrated data.

```bash
vks-dst -n "$DST_VKS_NS" apply -f - <<EOF_READER
apiVersion: v1
kind: Pod
metadata:
  name: cross-vcenter-migration-reader
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: reader
      image: busybox:1.36
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      command: ["sh", "-c"]
      args: ["cat /data/migration-test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${DST_VKS_PVC}
        readOnly: true
EOF_READER

vks-dst -n "$DST_VKS_NS" wait \
  --for=condition=Ready \
  pod/cross-vcenter-migration-reader \
  --timeout=10m

vks-dst -n "$DST_VKS_NS" exec cross-vcenter-migration-reader -- \
  cat /data/migration-test.txt
```

Compare the file with the recorded source contents or checksum, then remove the reader before restarting application writers:

```bash
vks-dst -n "$DST_VKS_NS" delete pod cross-vcenter-migration-reader --timeout=5m
```

Restore the recorded application replica count and validate application-level consistency before accepting the migration.

## 16. Remove the helper VM

After the destination workload has been validated, confirm that the migrated FCD and destination PVC remain present and inspect the helper VM's remaining devices:

```bash
govc disk.ls -l "$DEST_FCD_UUID"
sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC"
govc device.info -vm "$HELPER_VM"
```

The migrated FCD must already be detached. The cleanup guard requires a uniquely identified, powered-off helper with no disks; `govc vm.destroy` deletes disks that remain attached.

```bash
destroy_empty_helper() {
  local vm_json devices_json
  vm_json=$(govc vm.info -json "$HELPER_VM") || return 1
  printf '%s\n' "$vm_json" | jq -e --arg name "$HELPER_VM" '
    .virtualMachines | length == 1 and
    (.[0].name == $name and .[0].runtime.powerState == "poweredOff")
  ' >/dev/null || return 1
  devices_json=$(govc device.info -json -vm "$HELPER_VM" 'disk-*') || return 1
  printf '%s\n' "$devices_json" | jq -se 'length == 1 and (.[0] | has("devices") and (.devices == null or .devices == []))' >/dev/null || {
    echo 'ERROR: helper still has a disk; do not destroy it' >&2
    return 1
  }
  govc vm.destroy "$HELPER_VM" || return 1
}
destroy_empty_helper
```

## 17. Source cleanup

Complete source cleanup only after destination validation and migration acceptance. Confirm that source VKS PV deletion completed; do not use snapshot cleanup to unblock a still-pending source volume deletion.

The source Supervisor may retain stale Kubernetes objects after the FCD has moved. First try normal deletion:

```bash
cleanup_source_objects() {
  sup-src -n "$SRC_SUP_NS" delete volumesnapshot "$SUP_SNAPSHOT" \
    --ignore-not-found --wait=true --timeout=5m || return 1

  sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" \
    --ignore-not-found --wait=true --timeout=5m || return 1
}
cleanup_source_objects
```

If the VolumeSnapshot cannot be deleted because the underlying FCD is no longer present in the source vCenter, inspect its finalizers:

```bash
sup-src -n "$SRC_SUP_NS" get volumesnapshot "$SUP_SNAPSHOT" \
  -o jsonpath='{.metadata.finalizers}{"\n"}'
```

If normal cleanup fails, inspect the snapshot's associated `VolumeSnapshotContent` and controller errors with the Supervisor administrator. Do not remove all finalizers as a routine step: that bypasses controller cleanup and can leave snapshot content or storage metadata behind.

## Validation checklist

- [ ] Source workload was quiesced and manifest-only Velero backup completed.
- [ ] Source VKS PV, Supervisor PVC, Supervisor PV and FCD UUID were recorded.
- [ ] Source VKS PV was removed while the snapshot preserved the Supervisor storage chain.
- [ ] FCD was attached to a powered-off helper VM before cross-vCenter migration.
- [ ] Destination FCD UUID was rediscovered and verified after vMotion.
- [ ] Destination storage policy/datastore compatibility was verified.
- [ ] Migrated FCD was detached with `device.remove -keep` and remained present before destination registration.
- [ ] `CnsRegisterVolume` created the destination Supervisor PVC/PV.
- [ ] Destination Supervisor PV references the expected destination FCD UUID.
- [ ] Destination VKS PV uses the destination Supervisor PVC name as `volumeHandle`.
- [ ] Destination workload mounted and validated the data before source cleanup.
- [ ] Helper VM was removed only after validation and after detaching every disk intended for preservation.
