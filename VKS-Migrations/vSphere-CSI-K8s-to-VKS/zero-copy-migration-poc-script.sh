#!/usr/bin/env bash
set -euo pipefail

# This is a PROOF-OF-CONCEPT script to show how to 
# move one RWO Filesystem PVC from a Kubernetes
# cluster using vSphere CSI directly into VKS. 

# IMPORTANT: THIS IS NOT SUITABLE FOR PRODUCTION USE AS-IS


# Edit or export these values.
SRC_KUBECONFIG="${SRC_KUBECONFIG:-$HOME/ocp-kubeconfig}"
SUP_KUBECONFIG="${SUP_KUBECONFIG:-$HOME/supervisor-kubeconfig}"
VKS_KUBECONFIG="${VKS_KUBECONFIG:-$HOME/vks-kubeconfig}"
SRC_NS="${SRC_NS:-payments}"
DST_NS="${DST_NS:-payments}"
SUP_NS="${SUP_NS:-migration-target}"
PVC_NAME="${PVC_NAME:-payments-db}"
WORKLOAD="${WORKLOAD:-deployment/payments-api}"
SNAPSHOT_CLASS="${SNAPSHOT_CLASS:-volumesnapshotclass-delete}"

src() { kubectl --kubeconfig="$SRC_KUBECONFIG" "$@"; }
sup() { kubectl --kubeconfig="$SUP_KUBECONFIG" "$@"; }
vks() { kubectl --kubeconfig="$VKS_KUBECONFIG" "$@"; }

STAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_NAME="${PVC_NAME}-cutover"
BACKUP_NAME="${SRC_NS}-manifest-${STAMP}"
RESTORE_NAME="${BACKUP_NAME}-restore"
SUP_PVC_NAME="${PVC_NAME}-adopted"
REGISTER_NAME="register-${PVC_NAME}"
VKS_PV_NAME="${PVC_NAME}-zero-copy"

# 1. Resolve the source PVC -> PV -> FCD identity chain.
SRC_PV="$(src -n "$SRC_NS" get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}')"
FCD_UUID="$(src get pv "$SRC_PV" -o jsonpath='{.spec.csi.volumeHandle}')"
CAPACITY="$(src get pv "$SRC_PV" -o jsonpath='{.spec.capacity.storage}')"
FS_TYPE="$(src get pv "$SRC_PV" -o jsonpath='{.spec.csi.fsType}')"
FS_TYPE="${FS_TYPE:-ext4}"
SOURCE_REPLICAS="$(src -n "$SRC_NS" get "$WORKLOAD" -o jsonpath='{.spec.replicas}')"
SOURCE_REPLICAS="${SOURCE_REPLICAS:-1}"

printf 'Source PV: %s\nFCD UUID: %s\n' "$SRC_PV" "$FCD_UUID"

# 2. Quiesce the application, retain the FCD and take a rollback snapshot.
src -n "$SRC_NS" scale "$WORKLOAD" --replicas=0
src -n "$SRC_NS" rollout status "$WORKLOAD" --timeout=300s
src patch pv "$SRC_PV" --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

cat <<EOF | src apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${SRC_NS}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF
src -n "$SRC_NS" wait "volumesnapshot/$SNAPSHOT_NAME" \
  --for=jsonpath='{.status.readyToUse}'=true --timeout=300s

# Back up manifests only; storage is reconstructed separately.
velero backup create "$BACKUP_NAME" \
  --kubeconfig="$SRC_KUBECONFIG" \
  --include-namespaces="$SRC_NS" \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --default-volumes-to-fs-backup=false \
  --exclude-resources=persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

# Releasing the claim detaches the volume while Retain preserves the FCD.
src -n "$SRC_NS" delete pvc "$PVC_NAME"

# 3. Register the existing FCD in the destination Supervisor namespace.
cat <<EOF | sup apply -f -
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: ${REGISTER_NAME}
  namespace: ${SUP_NS}
spec:
  pvcName: ${SUP_PVC_NAME}
  volumeID: ${FCD_UUID}
  accessMode: ReadWriteOnce
EOF
sup -n "$SUP_NS" wait "cnsregistervolume/$REGISTER_NAME" \
  --for=jsonpath='{.status.registered}'=true --timeout=300s
sup -n "$SUP_NS" wait "pvc/$SUP_PVC_NAME" \
  --for=jsonpath='{.status.phase}'=Bound --timeout=300s

# Confirm that the Supervisor PV still points to the original FCD.
SUP_PV="$(sup -n "$SUP_NS" get pvc "$SUP_PVC_NAME" -o jsonpath='{.spec.volumeName}')"
REGISTERED_FCD="$(sup get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')"
test "$REGISTERED_FCD" = "$FCD_UUID"

# 4. In VKS, the static PV handle is the Supervisor PVC name
vks create namespace "$DST_NS" --dry-run=client -o yaml | vks apply -f -
cat <<EOF | vks apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${VKS_PV_NAME}
spec:
  capacity: {storage: ${CAPACITY}}
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: {namespace: ${DST_NS}, name: ${PVC_NAME}}
  csi:
    driver: csi.vsphere.vmware.com
    volumeHandle: ${SUP_PVC_NAME}
    fsType: ${FS_TYPE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${DST_NS}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: ""
  volumeName: ${VKS_PV_NAME}
  resources:
    requests: {storage: ${CAPACITY}}
EOF
vks -n "$DST_NS" wait "pvc/$PVC_NAME" \
  --for=jsonpath='{.status.phase}'=Bound --timeout=300s
# Reapply application-owned PVC labels/annotations here where required.

# 5. Restore manifests and reactivate the workload.
# Apply Velero resource-modifier ConfigMaps before this restore where required.
velero restore create "$RESTORE_NAME" \
  --kubeconfig="$VKS_KUBECONFIG" \
  --from-backup="$BACKUP_NAME" \
  --namespace-mappings="$SRC_NS:$DST_NS" \
  --include-cluster-resources=false \
  --exclude-resources=persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait

vks -n "$DST_NS" scale "$WORKLOAD" --replicas="$SOURCE_REPLICAS"
vks -n "$DST_NS" rollout status "$WORKLOAD" --timeout=300s

printf '\nCompleted: FCD %s is mounted through VKS PVC %s/%s\n' \
  "$FCD_UUID" "$DST_NS" "$PVC_NAME"
