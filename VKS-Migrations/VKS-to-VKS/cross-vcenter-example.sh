#!/usr/bin/env bash
set -euo pipefail

### NOTE: Here we assume the FCD has already been migrated ## 

: "${DST_SUP_KUBECONFIG:?Set DST_SUP_KUBECONFIG}"
: "${DST_VKS_KUBECONFIG:?Set DST_VKS_KUBECONFIG}"
: "${DEST_FCD_UUID:?Set DEST_FCD_UUID after verifying it on the destination vCenter}"

DST_SUP_NS=${DST_SUP_NS:-migration-test}
DST_VKS_NS=${DST_VKS_NS:-default}
REGISTER_NAME=${REGISTER_NAME:-vc-fcd-migration}
DST_SUP_PVC=${DST_SUP_PVC:-migrated-cross-supervisor-pvc}
DST_VKS_PV=${DST_VKS_PV:-migrated-cross-vcenter-pv}
DST_VKS_PVC=${DST_VKS_PVC:-migrated-cross-vcenter-pvc}

sup_dst() { kubectl --kubeconfig="$DST_SUP_KUBECONFIG" "$@"; }
vks_dst() { kubectl --kubeconfig="$DST_VKS_KUBECONFIG" "$@"; }

sup_dst -n "$DST_SUP_NS" apply -f - <<EOF_REGISTER
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: ${REGISTER_NAME}
spec:
  volumeID: "${DEST_FCD_UUID}"
  accessMode: ReadWriteOnce
  pvcName: ${DST_SUP_PVC}
EOF_REGISTER

sup_dst -n "$DST_SUP_NS" wait --for=jsonpath='{.status.registered}'=true \
  "cnsregistervolume/${REGISTER_NAME}" --timeout=10m

DST_SUP_PV=$(sup_dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" -o jsonpath='{.spec.volumeName}')
DST_SIZE=$(sup_dst get pv "$DST_SUP_PV" -o jsonpath='{.spec.capacity.storage}')
REGISTERED_FCD_UUID=$(sup_dst get pv "$DST_SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')

[[ "$REGISTERED_FCD_UUID" == "$DEST_FCD_UUID" ]]

vks_dst apply -f - <<EOF_DEST
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DST_VKS_PV}
spec:
  capacity:
    storage: ${DST_SIZE}
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
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
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  volumeName: ${DST_VKS_PV}
  resources:
    requests:
      storage: ${DST_SIZE}
EOF_DEST

vks_dst -n "$DST_VKS_NS" wait --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_VKS_PVC}" --timeout=5m

echo "Destination volume registered and adopted. Mount ${DST_VKS_NS}/${DST_VKS_PVC} and validate the data before source cleanup."
