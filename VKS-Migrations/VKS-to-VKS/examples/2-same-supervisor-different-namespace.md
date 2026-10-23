# Example 2: Same Supervisor, Different Supervisor Namespace

> [!CAUTION]
> These procedures are proofs of concept. Test them with disposable workloads before using them with production data. Quiesce the application and take an independent backup before modifying storage objects.

The examples assume a filesystem volume with `ReadWriteOnce` access. Adjust `volumeMode`, access modes and `fsType` for the source workload where required.

This example migrates a persistent volume between VKS clusters on the **same vCenter and Supervisor**, but across **different Supervisor namespaces**. It uses a powered-off helper VM as a deletion interlock, removes only the CNS registration with `govc volume.rm -keep`, and then re-registers the retained FCD in the destination namespace.

This is a zero-copy storage handover: the FCD stays on its existing datastore while the source Supervisor PVC/PV chain is replaced. The workflow reads the cluster-scoped Supervisor PV but does not patch it or directly delete it.

Here, source and destination namespaces mean **Supervisor namespaces hosting the VKS clusters**. Application namespaces inside the VKS clusters may have the same name, such as `default`.

Before destination registration, the old CNS registration and old Supervisor PV must both be gone while the FCD remains intact. `govc volume.rm -keep` removes the CNS registration; CSI subsequently removes the old Supervisor PV. Merely setting that PV to `Retain`, deleting its claim, or observing it in `Released` state does not complete this handover.

> [!IMPORTANT]
> Do not use a Supervisor `VolumeSnapshot` for this path. vSphere CSI prevents deletion of the source Supervisor PVC while snapshots of the volume exist.

## Prerequisites

The workstation running these commands requires:

- `kubectl`
- `velero`
- [`govc`](https://github.com/vmware/govmomi/releases) 0.49.0 or later 
- `jq`
- Valid kubeconfig files for both VKS clusters and the shared Supervisor
- Permission to read Supervisor PVs and to manage namespaced PVCs in the source and destination Supervisor namespaces
- Permission to create `CnsRegisterVolume` objects in the destination Supervisor namespace
- A vCenter account with sufficient privileges to create/manage the powered-off helper VM and run `govc volume.rm -keep`
- The FCD's existing datastore accessible to the helper VM and destination VKS hosts within the supported Supervisor storage topology
- The FCD's storage policy assigned to the destination Supervisor namespace and compatible with its existing datastore
- A source Supervisor PV with reclaim policy `Delete`, as required by the CSI cleanup sequence in this example

**Cluster-scoped Supervisor PV modification is not required for this workflow.**

If an earlier attempt changed the source Supervisor PV to `Retain`, inspect the current storage chain before proceeding. This example relies on normal CSI deletion to remove the old PV; a retained PV requires a separate recovery plan. Do not switch it back to `Delete` or delete source storage objects while the FCD is unprotected.

Run the numbered steps individually, in order, in an interactive Bash or zsh session. Stop on any failed command and resolve it before continuing. Guarded steps use functions with `return` to stop that step without an `exit` command closing your shell. Keep the functions and recorded variables available for subsequent steps; do not paste the entire procedure as one script. See the [execution guidance](README.md#running-the-commands), including the caveat for shells that already enable `set -e`.

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

Define a bounded deletion check. It requires `get`, rather than `watch`, permission and treats only a successful empty response as absence:

```bash
wait_for_absence() {
  local kubeconfig="$1" observed deadline=$((SECONDS + 300))
  shift
  while (( SECONDS < deadline )); do
    observed=$(kubectl --kubeconfig="$kubeconfig" get "$@" \
      --ignore-not-found -o json --request-timeout=15s) || return 1
    if [ -z "$observed" ]; then
      return 0
    fi
    sleep 5
  done
  printf 'ERROR: timed out waiting for deletion: %s\n' "$*" >&2
  return 1
}
```

Confirm that each context points to the expected cluster before continuing:

```bash
vks-src cluster-info
sup-src cluster-info
vks-dst cluster-info
sup-dst cluster-info
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
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: writer
      image: busybox:1.36
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
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
discover_storage_chain() {
  local value
  SRC_VKS_PV=$(
  vks-src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" \
    -o jsonpath='{.spec.volumeName}'
  ) || return 1
  test -n "$SRC_VKS_PV" || { echo 'ERROR: source PVC is not bound' >&2; return 1; }

  VKS_PVC_SIZE=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.capacity.storage}'
  ) || return 1

  SUP_PVC=$(
  vks-src get pv "$SRC_VKS_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
  ) || return 1
  test -n "$SUP_PVC" || { echo 'ERROR: source PV has no CSI handle' >&2; return 1; }

  SUP_PV=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.volumeName}'
  ) || return 1
  test -n "$SUP_PV" || { echo 'ERROR: source Supervisor PVC is not bound' >&2; return 1; }

  FCD_UUID=$(
  sup-src get pv "$SUP_PV" \
    -o jsonpath='{.spec.csi.volumeHandle}'
  ) || return 1

  SUP_STORAGE_CLASS=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.storageClassName}'
  ) || return 1

  SUP_ACCESS_MODE=$(
  sup-src -n "$SRC_SUP_NS" get pvc "$SUP_PVC" \
    -o jsonpath='{.spec.accessModes[0]}'
  ) || return 1

  for value in "$VKS_PVC_SIZE" "$FCD_UUID" "$SUP_STORAGE_CLASS" "$SUP_ACCESS_MODE"; do
    test -n "$value" || { echo 'ERROR: incomplete source storage chain' >&2; return 1; }
  done
  printf '%-22s %s\n' \
  'VKS PVC:' "$SRC_VKS_NS/$SRC_VKS_PVC" \
  'VKS PV:' "$SRC_VKS_PV" \
  'PVC size:' "$VKS_PVC_SIZE" \
  'Supervisor PVC:' "$SRC_SUP_NS/$SUP_PVC" \
  'Supervisor PV:' "$SUP_PV" \
  'Supervisor policy:' "$SUP_STORAGE_CLASS" \
  'FCD UUID:' "$FCD_UUID"
}
discover_storage_chain
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
  --wait=true --timeout=5m
```

For a Deployment or StatefulSet, scale it to zero instead.

Wait for the VKS attachment to disappear before attaching the disk to the helper VM:

```bash
wait_for_source_detach() {
  local attachments remaining deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    attachments=$(vks-src get volumeattachments -o json --request-timeout=15s) || return 1
    remaining=$(printf '%s\n' "$attachments" | jq -er --arg pv "$SRC_VKS_PV" \
      '[.items[] | select(.spec.source.persistentVolumeName == $pv)] | length') || return 1
    if [ "$remaining" = 0 ]; then
      return 0
    fi
    sleep 5
  done
  echo 'ERROR: source volume is still attached; do not attach the helper disk' >&2
  return 1
}
wait_for_source_detach
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

Supervisor PVC (removed)
        x
Supervisor PV (removed)
        x
        x
       FCD  ────── govc volume.rm -keep ──────►       retained FCD (old supervisor PV/PVC removed)
        │
       [VM]                                                 │
        └──── DeleteVolume blocked                          │
              by powered-off 'helper' VM                    │
                                                            ▼
                                                     CnsRegisterVolume
                                                            │
                                                            │ creates
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
# Download the latest govc release, if needed:
curl -sL https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz | sudo tar -xz -C /usr/local/bin govc

govc version
govc volume.rm -h | grep -F -- '-keep'
```

Configure the normal `GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD`, `GOVC_DATASTORE` and inventory defaults for the vCenter hosting the source FCD.

Record the CNS volume and its backing object before changing anything:

```bash
record_backing_disk() {
  FCD_BACKING_ID=$(govc volume.ls -L "$FCD_UUID") || return 1
  test -n "$FCD_BACKING_ID" || { echo 'ERROR: CNS backing ID is empty' >&2; return 1; }
  printf '%-20s %s\n' \
    'CNS volume ID:' "$FCD_UUID" \
    'FCD backing ID:' "$FCD_BACKING_ID"
  govc volume.ls -l "$FCD_UUID" || return 1
  govc disk.ls -l "$FCD_BACKING_ID" || return 1
}
record_backing_disk
```

Do not continue unless both objects resolve as expected.

## 7. Create a powered-off helper VM and attach the FCD

The helper VM is a safety interlock only. It must remain powered off and no guest operating system must mount or modify the disk.

Discover the backing path:

```bash
record_backing_path() {
  local disk_json
  disk_json=$(govc disk.ls -json "$FCD_BACKING_ID") || return 1
  FCD_PATH=$(printf '%s\n' "$disk_json" | jq -er \
    '.objects | select(length == 1) | .[0].config.backing.filePath | select(length > 0)') || return 1
  HELPER_VM="${FCD_UUID}-migration-guard"
  printf 'FCD backing path: %s\n' "$FCD_PATH"
}
record_backing_path
```

Create the helper VM in inventory accessible to the datastore containing the FCD and attach the existing disk without creating a linked delta:

```bash
create_helper() {
  test -n "$FCD_PATH" && test -n "$HELPER_VM" || return 1
  govc vm.create -on=false -net=none "$HELPER_VM" || return 1
  govc vm.disk.attach -vm "$HELPER_VM" -disk "$FCD_PATH" -link=false || return 1
  govc device.info -vm "$HELPER_VM" 'disk-*' || return 1
}
create_helper
```

If creation or attachment fails, inspect the helper before retrying; do not delete source storage. Verify that exactly one helper VM is selected, it is powered off, and its only disk is the recorded FCD. This function is reused before teardown and detachment:

```bash
verify_helper_guard() {
  local vm_json devices_json
  vm_json=$(govc vm.info -json "$HELPER_VM") || return 1
  printf '%s\n' "$vm_json" | jq -e --arg name "$HELPER_VM" '
    .virtualMachines | length == 1 and
    (.[0].name == $name and .[0].runtime.powerState == "poweredOff")
  ' >/dev/null || { echo 'ERROR: helper VM is not uniquely identified and powered off' >&2; return 1; }
  devices_json=$(govc device.info -json -vm "$HELPER_VM" 'disk-*') || return 1
  printf '%s\n' "$devices_json" | jq -e --arg path "$FCD_PATH" --arg id "$FCD_BACKING_ID" '
    .devices | length == 1 and
    (.[0].backing.fileName == $path and .[0].vDiskId.id == $id)
  ' >/dev/null || { echo 'ERROR: helper does not hold exactly the recorded FCD' >&2; return 1; }
}
verify_helper_guard
```

These JSON selectors match govc 0.56.0. Inspect your version's JSON if a field differs; do not bypass a failed guard. Quote `'disk-*'` to prevent zsh from expanding it as a local filename pattern.

## 8. Delete the source VKS PVC and PV

The source workload must already be quiesced and the Velero backup completed.

Recheck the helper and source Supervisor PV before deleting the source storage objects. PV deletion is requested asynchronously because its finalizer may remain until the unregister step:

```bash
teardown_source_storage() {
  local pv_json
  verify_helper_guard || return 1
  pv_json=$(sup-src get pv "$SUP_PV" -o json) || return 1
  printf '%s\n' "$pv_json" | jq -e --arg id "$FCD_UUID" '
    .spec.persistentVolumeReclaimPolicy == "Delete" and .spec.csi.volumeHandle == $id
  ' >/dev/null || { echo 'ERROR: unexpected source Supervisor PV identity or reclaim policy' >&2; return 1; }
  vks-src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" \
    --ignore-not-found --wait=true --timeout=5m || return 1
  vks-src delete pv "$SRC_VKS_PV" --ignore-not-found --wait=false || return 1
  # Normal reconciliation may already have removed the Supervisor PVC.
  sup-src -n "$SRC_SUP_NS" delete pvc "$SUP_PVC" --ignore-not-found --wait=false || return 1
  wait_for_absence "$SUPERVISOR_KUBECONFIG" pvc "$SUP_PVC" -n "$SRC_SUP_NS" || return 1
}
teardown_source_storage
```

Because the Supervisor PV still has reclaim policy `Delete`, the vSphere CSI provisioner will try to delete the CNS volume. The helper-VM attachment must prevent the backing FCD from being destroyed.

Verify that the Supervisor PV remains in `Released` state and still references the expected volume ID:

```bash
verify_source_released() {
  local pv_json
  pv_json=$(sup-src get pv "$SUP_PV" -o json) || return 1
  printf '%s\n' "$pv_json" | jq -e --arg id "$FCD_UUID" '
    .status.phase == "Released" and .spec.persistentVolumeReclaimPolicy == "Delete"
    and .spec.csi.volumeHandle == $id
  ' >/dev/null || { echo 'ERROR: source Supervisor PV has not reached the expected guarded state' >&2; return 1; }
  govc disk.ls -l "$FCD_BACKING_ID" || return 1
}
verify_source_released
```

Allow reconciliation to settle and repeat this check if the PV has not yet become `Released`.

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

This is the handover operation. Check the query contents to verify removal: `govc volume.ls` can succeed with empty output when the registration is absent; the tested JSON response was `{"volume":null}`. A failed query is an error, not proof of absence.

```bash
verify_cns_absent() {
  local cns_json
  cns_json=$(govc volume.ls -json "$FCD_UUID") || return 1
  printf '%s\n' "$cns_json" | jq -e 'has("volume") and ((.volume // []) | length == 0)' >/dev/null || {
    echo 'ERROR: CNS volume is still registered or the response schema is unexpected' >&2
    return 1
  }
}

unregister_keep_disk() {
  verify_helper_guard || return 1
  verify_source_released || return 1
  govc volume.rm -keep "$FCD_UUID" || return 1
  verify_cns_absent || return 1
  govc disk.ls -l "$FCD_BACKING_ID" || return 1
  verify_helper_guard || return 1
}
unregister_keep_disk
```

**`-keep` is essential. It instructs CNS to remove the container-volume registration without deleting the backing disk**.

The function independently confirms that the backing FCD still exists and remains attached. If any check fails, keep the helper disk attached and investigate before proceeding.

At this point the desired state is:

```text
old CNS registration: gone
backing FCD:           present
helper VM:             powered off, FCD still attached
```

## 10. Wait for the old Supervisor PV to disappear

Once CNS no longer contains the old container-volume registration, the source CSI deletion can finish reconciling the stale Supervisor PV without destroying the retained FCD.

Wait for the old Supervisor PV and source VKS PV to be removed. Bounded GET polling avoids requiring Supervisor PV `watch` permission, which is not always granted alongside `get`:

```bash
wait_for_old_pvs() {
  wait_for_absence "$SUPERVISOR_KUBECONFIG" pv "$SUP_PV" || return 1
  wait_for_absence "$SRC_VKS_KUBECONFIG" pv "$SRC_VKS_PV" || return 1
}
wait_for_old_pvs
```

This is the critical difference from the old `Retain` workflow: there is no retained Supervisor PV and therefore no cluster-scoped `claimRef` to edit.

## 11. Detach the retained FCD from the helper VM

Only detach the helper disk **after** the old CNS registration and old Supervisor PV are gone.

Identify the disk by its recorded backing path and FCD backing ID, rather than selecting the first VM disk. Recheck the handover conditions before removing the device while keeping its backing files:

```bash
detach_helper_disk() {
  local devices_json
  verify_cns_absent || return 1
  wait_for_old_pvs || return 1
  verify_helper_guard || return 1
  devices_json=$(govc device.info -json -vm "$HELPER_VM" 'disk-*') || return 1
  HELPER_DISK_DEVICE=$(printf '%s\n' "$devices_json" | jq -er \
    --arg path "$FCD_PATH" --arg id "$FCD_BACKING_ID" '
      [.devices[] | select(.backing.fileName == $path and .vDiskId.id == $id)]
      | select(length == 1) | .[0].name | select(length > 0)
    ') || return 1
  govc device.remove -vm "$HELPER_VM" -keep "$HELPER_DISK_DEVICE" || return 1
  devices_json=$(govc device.info -json -vm "$HELPER_VM" 'disk-*') || return 1
  printf '%s\n' "$devices_json" | jq -e 'has("devices") and ((.devices // []) | length == 0)' >/dev/null || {
    echo 'ERROR: helper still has a disk after detachment' >&2
    return 1
  }
  govc disk.ls -l "$FCD_BACKING_ID" || return 1
}
detach_helper_disk
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

Inspect the result. Object creation alone does not confirm successful registration:

```bash
sup-dst -n "$DST_SUP_NS" get \
  "cnsregistervolume/${REGISTER_NAME}" \
  -o yaml
```

Verify registration, discover the new Supervisor PV, and confirm that the destination PVC is `Bound` to the retained FCD. Set the destination handle only after these checks pass:

```bash
verify_destination_registration() {
  local registration_json pvc_json pv_json
  DEST_VOLUME_HANDLE=
  registration_json=$(sup-dst -n "$DST_SUP_NS" get \
    "cnsregistervolume/${REGISTER_NAME}" -o json) || return 1
  printf '%s\n' "$registration_json" | jq -e '
    .status.registered == true and ((.status.error // "") == "")
  ' >/dev/null || {
    printf 'ERROR: registration incomplete: %s\n' "$registration_json" >&2
    return 1
  }
  pvc_json=$(sup-dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" -o json) || return 1
  DST_SUP_PV=$(printf '%s\n' "$pvc_json" | jq -er '
    select(.status.phase == "Bound") | .spec.volumeName | select(length > 0)
  ') || return 1
  pv_json=$(sup-dst get pv "$DST_SUP_PV" -o json) || return 1
  printf '%s\n' "$pv_json" | jq -e --arg id "$FCD_UUID" '
    .spec.csi.volumeHandle == $id
  ' >/dev/null || { echo 'ERROR: destination Supervisor PV references a different FCD' >&2; return 1; }
  DEST_VOLUME_HANDLE="$DST_SUP_PVC"
  printf 'Destination Supervisor PV: %s\nVKS volume handle: %s\n' "$DST_SUP_PV" "$DEST_VOLUME_HANDLE"
}
verify_destination_registration
```

The VKS volume handle is now the new Supervisor PVC name, not the FCD UUID.

## 13. Create the destination VKS PV and PVC

For this workflow, the VKS PV `volumeHandle` is the newly registered destination Supervisor PVC **name** `${DST_SUP_PVC}` in `${DST_SUP_NS}`. Do not put the FCD UUID here: that UUID is used by `CnsRegisterVolume` and the Supervisor PV. Continue only after Step 12 confirms successful registration and a `Bound` destination Supervisor PVC.

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

The test pods run as UID/GID 1000 with restricted Pod Security settings. The reader mounts read-only and does not set `fsGroup`; for an existing workload, use an identity that already has permission to read its data.

```bash
vks-dst -n "$DST_VKS_NS" apply -f - <<EOF_READER
apiVersion: v1
kind: Pod
metadata:
  name: migration-test-reader
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
  pod/migration-test-reader \
  --timeout=5m

vks-dst -n "$DST_VKS_NS" exec migration-test-reader -- \
  cat /data/migration-test.txt
```

The output should match the content written on the source cluster.

## 16. Cleanup after validation

Delete the test reader after validation:

```bash
vks-dst -n "$DST_VKS_NS" delete pod migration-test-reader --timeout=5m
```

There is no migration snapshot or retained source Supervisor PV to remove. After the migrated workload has been validated, remove the powered-off helper VM if it is no longer required:

```bash
destroy_empty_helper() {
  local vm_json devices_json
  vm_json=$(govc vm.info -json "$HELPER_VM") || return 1
  printf '%s\n' "$vm_json" | jq -e --arg name "$HELPER_VM" '
    .virtualMachines | length == 1 and
    (.[0].name == $name and .[0].runtime.powerState == "poweredOff")
  ' >/dev/null || return 1
  devices_json=$(govc device.info -json -vm "$HELPER_VM" 'disk-*') || return 1
  printf '%s\n' "$devices_json" | jq -e 'has("devices") and ((.devices // []) | length == 0)' >/dev/null || {
    echo 'ERROR: helper still has a disk; do not destroy it' >&2
    return 1
  }
  govc vm.destroy "$HELPER_VM" || return 1
}
destroy_empty_helper
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
