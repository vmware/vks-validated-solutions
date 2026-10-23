#!/usr/bin/env bash

# Run in a separate Bash process. Sourcing must not change the caller's shell
# options or run migration commands; return success to preserve caller errexit.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Run this script in a separate process: bash scripts/same-vcenter-example.sh' >&2
  return 0 2>/dev/null || exit 1
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' 'Sourcing skipped. Run: bash scripts/same-vcenter-example.sh' >&2
  return 0
fi

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
: "${VKS_PV:?Source VKS PVC must be bound to a PV}"
VKS_PVC_SIZE=$(vks_src get pv "$VKS_PV" -o jsonpath='{.spec.capacity.storage}')
: "${VKS_PVC_SIZE:?Source VKS PV has no capacity}"
SUP_PVC=$(vks_src get pv "$VKS_PV" -o jsonpath='{.spec.csi.volumeHandle}')
: "${SUP_PVC:?Source VKS PV has no Supervisor PVC handle}"
SUP_PV=$(sup -n "$SUP_NS" get pvc "$SUP_PVC" -o jsonpath='{.spec.volumeName}')
: "${SUP_PV:?Source Supervisor PVC must be bound to a PV}"
FCD_UUID=$(sup get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')
: "${FCD_UUID:?Source Supervisor PV has no FCD handle}"
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

vks_src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true --timeout=5m
vks_src delete pv "$VKS_PV" --ignore-not-found --wait=true --timeout=5m

sup -n "$SUP_NS" get pvc "$SUP_PVC" >/dev/null
RETAINED_FCD_UUID=$(sup get pv "$SUP_PV" -o jsonpath='{.spec.csi.volumeHandle}')
if [[ "$RETAINED_FCD_UUID" != "$FCD_UUID" ]]; then
  printf '%s\n' 'Source Supervisor PV no longer references the recorded FCD; stopping before destination adoption.' >&2
  exit 1
fi

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
