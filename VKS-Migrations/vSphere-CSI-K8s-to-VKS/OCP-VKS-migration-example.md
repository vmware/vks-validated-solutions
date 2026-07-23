# Worked example: OpenShift to VKS using FCD adoption

## Purpose

This example migrates one stateful application PVC from OpenShift to VKS without copying its filesystem data. Velero moves the application manifests; `CnsRegisterVolume` adopts the existing vSphere FCD into the destination Supervisor; a static VKS PV/PVC exposes it to the restored workload.

The commands are intentionally explicit. Review every variable and command before running them.

> [!WARNING]
> The cutover deletes the source PVC after changing the source PV reclaim policy to `Retain`. Use a test workload first, create a rollback snapshot where supported and do not proceed until the FCD UUID and source PV have been recorded.

## Prerequisites

- Access to the OpenShift source cluster, destination Supervisor and destination VKS cluster.
- `oc`, `kubectl`, `velero` and `jq` installed.
- Velero installed on both workload clusters and configured to use the same backup store.
- The source PV uses `csi.vsphere.vmware.com`.
- The destination Supervisor provides the `CnsRegisterVolume` CRD.
- A destination Supervisor namespace and compatible storage policy are available.
- The application can be stopped for cutover.

## 1. Configure cluster access

```bash
export OCP_KUBECONFIG="${HOME}/ocp-kubeconfig"
export VKS_KUBECONFIG="${HOME}/vks-kubeconfig"
export SUPERVISOR_KUBECONFIG="${HOME}/supervisor-kubeconfig"

alias ocp='oc --kubeconfig="${OCP_KUBECONFIG}"'
alias vks='kubectl --kubeconfig="${VKS_KUBECONFIG}"'
alias sup='kubectl --kubeconfig="${SUPERVISOR_KUBECONFIG}"'

ocp cluster-info
vks cluster-info
sup cluster-info
```

Aliases are convenient for an interactive walkthrough. For automation, pass `--kubeconfig` explicitly.

## 2. Define migration variables

```bash
export RUN_ID="$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)"

export SOURCE_NS="default"
export TARGET_NS="migration-target"
export SUPERVISOR_NS="migration-target"

export PVC_NAME="data-migration-test"
export REGISTER_NAME="adopt-${PVC_NAME}-${RUN_ID}"
export SUPERVISOR_PVC_NAME="${PVC_NAME}-migrated-${RUN_ID}"
export VKS_PV_NAME="${PVC_NAME}-adopted-${RUN_ID}"
export BACKUP_NAME="${SOURCE_NS}-backup-${RUN_ID}"
export RESTORE_NAME="${TARGET_NS}-restore-${RUN_ID}"
```

Create the destination VKS namespace if it does not already exist:

```bash
vks get namespace "${TARGET_NS}" >/dev/null 2>&1 || \
  vks create namespace "${TARGET_NS}"
```

## 3. Discover and record the source volume

```bash
export PV_NAME="$(
  ocp -n "${SOURCE_NS}" get pvc "${PVC_NAME}" \
    -o jsonpath='{.spec.volumeName}'
)"

export PVC_SIZE="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.capacity.storage}'
)"

export ACCESS_MODE="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.accessModes[0]}'
)"

export VOLUME_MODE="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.volumeMode}'
)"

export VOLUME_MODE="${VOLUME_MODE:-Filesystem}"

export FCD_UUID="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)"

export CSI_DRIVER="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.csi.driver}'
)"

export FS_TYPE="$(
  ocp get pv "${PV_NAME}" \
    -o jsonpath='{.spec.csi.fsType}'
)"

printf '%-24s %s\n' \
  'Source namespace:' "${SOURCE_NS}" \
  'Source PVC:' "${PVC_NAME}" \
  'Source PV:' "${PV_NAME}" \
  'FCD UUID:' "${FCD_UUID}" \
  'CSI driver:' "${CSI_DRIVER}" \
  'Capacity:' "${PVC_SIZE}" \
  'Access mode:' "${ACCESS_MODE}" \
  'Volume mode:' "${VOLUME_MODE}" \
  'Filesystem:' "${FS_TYPE:-not specified}"

[ "${CSI_DRIVER}" = "csi.vsphere.vmware.com" ] || {
  echo "ERROR: source PV does not use the vSphere CSI driver" >&2
  exit 1
}

[ -n "${FCD_UUID}" ] || {
  echo "ERROR: no CSI volumeHandle was found" >&2
  exit 1
}
```

Save the source PV and PVC definitions for audit and rollback:

```bash
mkdir -p "migration-${RUN_ID}"
ocp -n "${SOURCE_NS}" get pvc "${PVC_NAME}" -o yaml \
  > "migration-${RUN_ID}/source-pvc.yaml"
ocp get pv "${PV_NAME}" -o yaml \
  > "migration-${RUN_ID}/source-pv.yaml"
printf '%s\n' "${FCD_UUID}" \
  > "migration-${RUN_ID}/fcd-uuid.txt"
```

## 4. Create a source snapshot

Select an appropriate vSphere CSI `VolumeSnapshotClass`. Do not simply use the first class returned in a production environment.

```bash
ocp get volumesnapshotclass

export SNAPSHOT_CLASS="$(
  ocp get volumesnapshotclass \
    -o jsonpath='{range .items[?(@.driver=="csi.vsphere.vmware.com")]}{.metadata.name}{"\n"}{end}' \
    | head -n1
)"

[ -n "${SNAPSHOT_CLASS}" ] || {
  echo "ERROR: no vSphere CSI VolumeSnapshotClass found" >&2
  exit 1
}

export SNAPSHOT_NAME="${PVC_NAME}-pre-migration-${RUN_ID}"

ocp -n "${SOURCE_NS}" apply -f - <<EOF_SNAPSHOT
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF_SNAPSHOT

ocp -n "${SOURCE_NS}" wait \
  --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${SNAPSHOT_NAME}" \
  --timeout=30m

ocp -n "${SOURCE_NS}" get volumesnapshot "${SNAPSHOT_NAME}"
```

A crash-consistent snapshot may not be application-consistent. For databases, use the application's supported quiesce or backup mechanism.

## 5. Back up application manifests with Velero

The storage data is not backed up by Velero. PVCs are restored separately after the FCD has been adopted.

```bash
velero backup create "${BACKUP_NAME}" \
  --kubeconfig="${OCP_KUBECONFIG}" \
  --include-namespaces "${SOURCE_NS}" \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --exclude-resources persistentvolumes

velero backup wait "${BACKUP_NAME}" \
  --kubeconfig="${OCP_KUBECONFIG}" \
  --timeout=30m

velero backup describe "${BACKUP_NAME}" \
  --kubeconfig="${OCP_KUBECONFIG}" \
  --details
```

Confirm that the backup phase is `Completed` and review warnings before proceeding.

## 6. Restore manifests into VKS

Use destination resource modifiers where source-specific images, ingress classes, security settings or other fields must change. See [`velero-destination-configmap-modifier-examples.md`](velero-destination-configmap-modifier-examples.md).

```bash
velero restore create "${RESTORE_NAME}" \
  --kubeconfig="${VKS_KUBECONFIG}" \
  --from-backup "${BACKUP_NAME}" \
  --namespace-mappings "${SOURCE_NS}:${TARGET_NS}" \
  --exclude-resources persistentvolumeclaims,persistentvolumes

velero restore wait "${RESTORE_NAME}" \
  --kubeconfig="${VKS_KUBECONFIG}" \
  --timeout=30m

velero restore describe "${RESTORE_NAME}" \
  --kubeconfig="${VKS_KUBECONFIG}" \
  --details

vks -n "${TARGET_NS}" get deploy,statefulset,daemonset,pod,svc,ingress,pvc
```

The restored workload may be pending or unhealthy because its PVC has intentionally not yet been created. Ensure that restored controllers do not repeatedly start writers before storage cutover. Scale them down where necessary.

## 7. Quiesce the source application

Identify every resource that mounts the PVC:

```bash
ocp -n "${SOURCE_NS}" get pod -o json | jq -r \
  --arg pvc "${PVC_NAME}" '
  .items[]
  | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
  | .metadata.name'
```

Stop the application using its supported procedure. The following commands are examples only:

```bash
ocp -n "${SOURCE_NS}" scale deployment --all --replicas=0
ocp -n "${SOURCE_NS}" scale statefulset --all --replicas=0
```

Check that no remaining pod references the PVC:

```bash
REMAINING_PODS="$(
  ocp -n "${SOURCE_NS}" get pod -o json | jq -r \
    --arg pvc "${PVC_NAME}" '
    .items[]
    | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
    | .metadata.name'
)"

if [ -n "${REMAINING_PODS}" ]; then
  echo "ERROR: pods still reference ${PVC_NAME}:" >&2
  printf '%s\n' "${REMAINING_PODS}" >&2
  exit 1
fi
```

For application-consistent migration, flush and stop the application before the final cutover.

## 8. Retain and release the source FCD

Patch the source PV **before** deleting the PVC:

```bash
ocp patch pv "${PV_NAME}" \
  --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

ocp get pv "${PV_NAME}" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,HANDLE:.spec.csi.volumeHandle'
```

Delete the source PVC:

```bash
ocp -n "${SOURCE_NS}" delete pvc "${PVC_NAME}" \
  --wait=true \
  --timeout=10m
```

Wait until no source `VolumeAttachment` references the PV:

```bash
for attempt in $(seq 1 60); do
  ATTACHMENTS="$(
    ocp get volumeattachment -o json | jq -r \
      --arg pv "${PV_NAME}" '
      .items[]
      | select(.spec.source.persistentVolumeName == $pv)
      | .metadata.name'
  )"

  if [ -z "${ATTACHMENTS}" ]; then
    echo "The source FCD is detached."
    break
  fi

  echo "Waiting for VolumeAttachment removal: ${ATTACHMENTS}"
  sleep 10

done

[ -z "${ATTACHMENTS}" ] || {
  echo "ERROR: the source FCD is still attached; do not continue" >&2
  exit 1
}
```

Confirm that the source PV is now `Released` or otherwise no longer bound to the deleted claim:

```bash
ocp get pv "${PV_NAME}" -o wide
```

## 9. Register the FCD with the destination Supervisor

Confirm that the CRD exists:

```bash
sup api-resources | grep -i cnsregistervolume
```

Register the existing FCD:

```bash
sup -n "${SUPERVISOR_NS}" apply -f - <<EOF_REGISTER
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: ${REGISTER_NAME}
spec:
  volumeID: "${FCD_UUID}"
  accessMode: ${ACCESS_MODE}
  pvcName: ${SUPERVISOR_PVC_NAME}
EOF_REGISTER
```

Wait for successful registration:

```bash
if ! sup -n "${SUPERVISOR_NS}" wait \
  --for=jsonpath='{.status.registered}'=true \
  "cnsregistervolume/${REGISTER_NAME}" \
  --timeout=5m; then
  echo "CnsRegisterVolume did not report success:" >&2
  sup -n "${SUPERVISOR_NS}" get \
    "cnsregistervolume/${REGISTER_NAME}" -o yaml >&2
  exit 1
fi

REGISTER_ERROR="$(
  sup -n "${SUPERVISOR_NS}" get \
    "cnsregistervolume/${REGISTER_NAME}" \
    -o jsonpath='{.status.error}'
)"

[ -z "${REGISTER_ERROR}" ] || {
  echo "ERROR: ${REGISTER_ERROR}" >&2
  exit 1
}
```

Inspect the new Supervisor storage chain:

```bash
export SUPERVISOR_PV_NAME="$(
  sup -n "${SUPERVISOR_NS}" get pvc "${SUPERVISOR_PVC_NAME}" \
    -o jsonpath='{.spec.volumeName}'
)"

export REGISTERED_FCD_UUID="$(
  sup get pv "${SUPERVISOR_PV_NAME}" \
    -o jsonpath='{.spec.csi.volumeHandle}'
)"

sup -n "${SUPERVISOR_NS}" get pvc "${SUPERVISOR_PVC_NAME}"
sup get pv "${SUPERVISOR_PV_NAME}"

[ "${REGISTERED_FCD_UUID}" = "${FCD_UUID}" ] || {
  echo "ERROR: registered Supervisor PV refers to an unexpected FCD" >&2
  exit 1
}
```

Use the capacity reported by the Supervisor PV when creating the VKS objects:

```bash
export DESTINATION_SIZE="$(
  sup get pv "${SUPERVISOR_PV_NAME}" \
    -o jsonpath='{.spec.capacity.storage}'
)"
```

## 10. Create the static VKS PV and PVC

The VKS PV `volumeHandle` is the **Supervisor PVC name**.

```bash
FS_TYPE_BLOCK=""
if [ "${VOLUME_MODE}" = "Filesystem" ] && [ -n "${FS_TYPE}" ]; then
  FS_TYPE_BLOCK="    fsType: ${FS_TYPE}"
fi

vks apply -f - <<EOF_VKS
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${VKS_PV_NAME}
spec:
  capacity:
    storage: ${DESTINATION_SIZE}
  volumeMode: ${VOLUME_MODE}
  accessModes:
    - ${ACCESS_MODE}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${TARGET_NS}
    name: ${PVC_NAME}
  csi:
    driver: csi.vsphere.vmware.com
${FS_TYPE_BLOCK}
    volumeHandle: "${SUPERVISOR_PVC_NAME}"
    volumeAttributes:
      type: "vSphere CNS Block Volume"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${TARGET_NS}
spec:
  volumeMode: ${VOLUME_MODE}
  accessModes:
    - ${ACCESS_MODE}
  storageClassName: ""
  volumeName: ${VKS_PV_NAME}
  resources:
    requests:
      storage: ${DESTINATION_SIZE}
EOF_VKS

vks -n "${TARGET_NS}" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${PVC_NAME}" \
  --timeout=5m

vks get pv "${VKS_PV_NAME}"
vks -n "${TARGET_NS}" get pvc "${PVC_NAME}"
```

## 11. Validate the data

For a filesystem volume, mount the PVC in a temporary pod. Adjust the image and command for the platform's registry and security policy.

```bash
if [ "${VOLUME_MODE}" = "Filesystem" ]; then
  vks -n "${TARGET_NS}" apply -f - <<EOF_VALIDATE
apiVersion: v1
kind: Pod
metadata:
  name: migration-validation-${RUN_ID}
spec:
  restartPolicy: Never
  containers:
    - name: validate
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /data; find /data -maxdepth 2 -type f | head -50; sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF_VALIDATE

  vks -n "${TARGET_NS}" wait \
    --for=condition=Ready \
    "pod/migration-validation-${RUN_ID}" \
    --timeout=5m

  vks -n "${TARGET_NS}" logs "migration-validation-${RUN_ID}"
fi
```

Verify application-specific files, permissions, ownership and checksums rather than relying only on a directory listing.

Delete the validation pod before starting a `ReadWriteOnce` workload:

```bash
vks -n "${TARGET_NS}" delete pod "migration-validation-${RUN_ID}" \
  --ignore-not-found
```

## 12. Start and validate the destination workload

Restore the intended replica counts or allow the relevant operator/Helm release to reconcile:

```bash
vks -n "${TARGET_NS}" get deployment,statefulset
# Example only:
# vks -n "${TARGET_NS}" scale deployment/<name> --replicas=<count>

vks -n "${TARGET_NS}" get pod,pvc
vks -n "${TARGET_NS}" get events --sort-by=.lastTimestamp
```

Validate application health, data integrity, networking and external access.

## 13. Source cleanup

Do not clean up source rollback assets until the migration has been accepted.

After sign-off, delete the retained source PV normally:

```bash
ocp delete pv "${PV_NAME}"
```

Depending on the tested CSI and vCenter behaviour, confirm that deleting this stale Kubernetes object cannot affect the now-adopted FCD. Do **not** remove PV finalizers as a routine first step.

Retain or delete the source snapshot according to the agreed recovery and retention policy:

```bash
# Run only after migration sign-off and expiry of the rollback window.
# ocp -n "${SOURCE_NS}" delete volumesnapshot "${SNAPSHOT_NAME}"
```

## Rollback outline

Before FCD registration, recreate or restore the source claim using the retained PV or a clone from the source snapshot.

After registration, stop destination writers before attempting rollback. Avoid attaching the same `ReadWriteOnce` FCD simultaneously through both source and destination storage chains.

A snapshot clone example is shown below; `SOURCE_CLONE_SC` must support restore from the selected snapshot:

```bash
export SOURCE_CLONE_SC="thin-csi"

ocp -n "${SOURCE_NS}" apply -f - <<EOF_CLONE
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}-rollback-${RUN_ID}
spec:
  storageClassName: ${SOURCE_CLONE_SC}
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ${ACCESS_MODE}
  volumeMode: ${VOLUME_MODE}
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF_CLONE

ocp -n "${SOURCE_NS}" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${PVC_NAME}-rollback-${RUN_ID}" \
  --timeout=30m
```
