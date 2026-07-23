#!/usr/bin/env bash
# Proof-of-concept: adopt one existing vSphere CSI FCD from OpenShift into VKS.
# Review the detailed worked example before running this script.
set -Eeuo pipefail

: "${OCP_KUBECONFIG:?Set OCP_KUBECONFIG}"
: "${VKS_KUBECONFIG:?Set VKS_KUBECONFIG}"
: "${SUPERVISOR_KUBECONFIG:?Set SUPERVISOR_KUBECONFIG}"
: "${SOURCE_NS:?Set SOURCE_NS}"
: "${TARGET_NS:?Set TARGET_NS}"
: "${SUPERVISOR_NS:?Set SUPERVISOR_NS}"
: "${PVC_NAME:?Set PVC_NAME}"

ocp() { oc --kubeconfig="${OCP_KUBECONFIG}" "$@"; }
vks() { kubectl --kubeconfig="${VKS_KUBECONFIG}" "$@"; }
sup() { kubectl --kubeconfig="${SUPERVISOR_KUBECONFIG}" "$@"; }

RUN_ID="${RUN_ID:-$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)}"
REGISTER_NAME="${REGISTER_NAME:-adopt-${PVC_NAME}-${RUN_ID}}"
SUPERVISOR_PVC_NAME="${SUPERVISOR_PVC_NAME:-${PVC_NAME}-migrated-${RUN_ID}}"
VKS_PV_NAME="${VKS_PV_NAME:-${PVC_NAME}-adopted-${RUN_ID}}"

PV_NAME="$(ocp -n "${SOURCE_NS}" get pvc "${PVC_NAME}" -o jsonpath='{.spec.volumeName}')"
FCD_UUID="$(ocp get pv "${PV_NAME}" -o jsonpath='{.spec.csi.volumeHandle}')"
CSI_DRIVER="$(ocp get pv "${PV_NAME}" -o jsonpath='{.spec.csi.driver}')"
ACCESS_MODE="$(ocp get pv "${PV_NAME}" -o jsonpath='{.spec.accessModes[0]}')"
VOLUME_MODE="$(ocp get pv "${PV_NAME}" -o jsonpath='{.spec.volumeMode}')"
VOLUME_MODE="${VOLUME_MODE:-Filesystem}"
FS_TYPE="$(ocp get pv "${PV_NAME}" -o jsonpath='{.spec.csi.fsType}')"

[[ "${CSI_DRIVER}" == "csi.vsphere.vmware.com" ]] || {
  echo "ERROR: ${PV_NAME} is not a vSphere CSI PV" >&2
  exit 1
}

cat <<SUMMARY
Source PVC:          ${SOURCE_NS}/${PVC_NAME}
Source PV:           ${PV_NAME}
FCD UUID:            ${FCD_UUID}
Destination:         ${TARGET_NS}/${PVC_NAME}
Supervisor PVC:      ${SUPERVISOR_NS}/${SUPERVISOR_PVC_NAME}
SUMMARY

if [[ "${CONFIRM_DESTRUCTIVE_CUTOVER:-}" != "YES" ]]; then
  echo "Set CONFIRM_DESTRUCTIVE_CUTOVER=YES after quiescing the source and creating a rollback snapshot." >&2
  exit 2
fi

# Refuse to continue while any pod still references the source PVC.
remaining_pods="$(
  ocp -n "${SOURCE_NS}" get pod -o json | jq -r \
    --arg pvc "${PVC_NAME}" '
    .items[]
    | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
    | .metadata.name'
)"

if [[ -n "${remaining_pods}" ]]; then
  echo "ERROR: source pods still reference ${PVC_NAME}:" >&2
  printf '%s\n' "${remaining_pods}" >&2
  exit 1
fi

ocp patch pv "${PV_NAME}" --type=merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
ocp -n "${SOURCE_NS}" delete pvc "${PVC_NAME}" --wait=true --timeout=10m

for _ in $(seq 1 60); do
  attachments="$(
    ocp get volumeattachment -o json | jq -r \
      --arg pv "${PV_NAME}" '
      .items[]
      | select(.spec.source.persistentVolumeName == $pv)
      | .metadata.name'
  )"
  [[ -z "${attachments}" ]] && break
  echo "Waiting for source attachment removal: ${attachments}"
  sleep 10
done

[[ -z "${attachments:-}" ]] || {
  echo "ERROR: source FCD remains attached" >&2
  exit 1
}

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

if ! sup -n "${SUPERVISOR_NS}" wait \
  --for=jsonpath='{.status.registered}'=true \
  "cnsregistervolume/${REGISTER_NAME}" --timeout=5m; then
  sup -n "${SUPERVISOR_NS}" get "cnsregistervolume/${REGISTER_NAME}" -o yaml >&2
  exit 1
fi

SUPERVISOR_PV_NAME="$(
  sup -n "${SUPERVISOR_NS}" get pvc "${SUPERVISOR_PVC_NAME}" \
    -o jsonpath='{.spec.volumeName}'
)"
DESTINATION_SIZE="$(
  sup get pv "${SUPERVISOR_PV_NAME}" -o jsonpath='{.spec.capacity.storage}'
)"
REGISTERED_FCD_UUID="$(
  sup get pv "${SUPERVISOR_PV_NAME}" -o jsonpath='{.spec.csi.volumeHandle}'
)"

[[ "${REGISTERED_FCD_UUID}" == "${FCD_UUID}" ]] || {
  echo "ERROR: destination Supervisor PV points to a different FCD" >&2
  exit 1
}

vks get namespace "${TARGET_NS}" >/dev/null 2>&1 || vks create namespace "${TARGET_NS}"

fs_type_line=""
if [[ "${VOLUME_MODE}" == "Filesystem" && -n "${FS_TYPE}" ]]; then
  fs_type_line="    fsType: ${FS_TYPE}"
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
${fs_type_line}
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
  "pvc/${PVC_NAME}" --timeout=5m

printf '\nAdoption complete. Validate data before deleting source rollback assets.\n'
vks get pv "${VKS_PV_NAME}"
vks -n "${TARGET_NS}" get pvc "${PVC_NAME}"
