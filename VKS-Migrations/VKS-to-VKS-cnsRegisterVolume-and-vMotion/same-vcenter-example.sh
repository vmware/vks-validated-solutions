#!/usr/bin/env bash
set -euo pipefail

: "${SRC_VKS_KUBECONFIG:?Set SRC_VKS_KUBECONFIG}"
: "${DST_VKS_KUBECONFIG:?Set DST_VKS_KUBECONFIG}"
: "${SUPERVISOR_KUBECONFIG:?Set SUPERVISOR_KUBECONFIG}"

SRC_VKS_NS=${SRC_VKS_NS:-default}
DST_VKS_NS=${DST_VKS_NS:-default}
SUP_NS=${SUP_NS:-migration-target}
SRC_VKS_PVC=${SRC_VKS_PVC:-my-test-pvc}
DST_VKS_PV=${DST_VKS_PV:-my-test-pv-migrated}
DST_VKS_PVC=${DST_VKS_PVC:-my-test-pvc-migrated}
SUP_SNAPSHOT_CLASS=${SUP_SNAPSHOT_CLASS:-volumesnapshotclass-delete}

vks_src() { kubectl --kubeconfig="$SRC_VKS_KUBECONFIG" "$@"; }
vks_dst() { kubectl --kubeconfig="$DST_VKS_KUBECONFIG" "$@"; }
sup() { kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" "$@"; }

VKS_PV=$(vks_src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" -o jsonpath='{.spec.volumeName}')
VKS_PVC_SIZE=$(vks_src get pv "$VKS_PV" -o jsonpath='{.spec.capacity.storage}')
SUP_PVC=$(vks_src get pv "$VKS_PV" -o jsonpath='{.spec.csi.volumeHandle}')
SUP_PV=$(sup -n "$SUP_NS" get pvc "$SUP_PVC" -o jsonpath='{.spec.volumeName}')
FCD_UUID=$(sup get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')
SUP_SNAPSHOT="${SUP_PVC}-migration-snapshot"

printf 'VKS PV=%s\nSupervisor PVC=%s/%s\nSupervisor PV=%s\nFCD UUID=%s\n' \
  "$VKS_PV" "$SUP_NS" "$SUP_PVC" "$SUP_PV" "$FCD_UUID"

cat <<'MESSAGE'
Quiesce the source workload and verify that the volume is no longer mounted.
Press Enter to continue after completing that step, or Ctrl-C to abort.
MESSAGE
read -r

sup -n "$SUP_NS" apply -f - <<EOF_SNAPSHOT
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SUP_SNAPSHOT}
spec:
  volumeSnapshotClassName: ${SUP_SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${SUP_PVC}
EOF_SNAPSHOT

sup -n "$SUP_NS" wait --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${SUP_SNAPSHOT}" --timeout=10m

vks_src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true
if vks_src get pv "$VKS_PV" >/dev/null 2>&1; then
  vks_src delete pv "$VKS_PV" --wait=true
fi

sup -n "$SUP_NS" get pvc "$SUP_PVC" >/dev/null
[[ $(sup get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}') == "$FCD_UUID" ]]

vks_dst apply -f - <<EOF_DEST
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DST_VKS_PV}
spec:
  capacity:
    storage: ${VKS_PVC_SIZE}
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
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  volumeName: ${DST_VKS_PV}
  resources:
    requests:
      storage: ${VKS_PVC_SIZE}
EOF_DEST

vks_dst -n "$DST_VKS_NS" wait --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_VKS_PVC}" --timeout=5m

echo "Migration metadata rebuilt. Mount ${DST_VKS_NS}/${DST_VKS_PVC} and validate the data before deleting ${SUP_NS}/${SUP_SNAPSHOT}."
