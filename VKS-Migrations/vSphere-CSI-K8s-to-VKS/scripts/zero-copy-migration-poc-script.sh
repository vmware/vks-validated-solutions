#!/usr/bin/env bash

# Execute in a separate Bash process; sourcing must not change shell options.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Run with bash: bash scripts/zero-copy-migration-poc-script.sh' >&2
  return 0 2>/dev/null || exit 1
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' 'Sourcing skipped. Run: bash scripts/zero-copy-migration-poc-script.sh' >&2
  return 0
fi
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/zero-copy-migration-poc-script.sh [--help]

Companion to examples/1-OCP-VKS-migration-example.md. Adopts one detached,
existing vSphere CSI FCD into VKS. Supports ReadWriteOnce filesystem volumes.
Uses kubectl for all APIs; OCP_* names are retained for compatibility with the
OpenShift walkthrough. VKS sources require the separate VKS-to-VKS method.

Required environment:
  OCP_KUBECONFIG, VKS_KUBECONFIG, SUPERVISOR_KUBECONFIG
  SOURCE_NS          Source application namespace
  TARGET_NS          Existing destination VKS application namespace
  SUPERVISOR_NS      Existing namespace hosting the destination VKS cluster
  PVC_NAME           Source and destination application claim name

Optional environment:
  OCP_CONTEXT, VKS_CONTEXT, SUPERVISOR_CONTEXT
                     Default to each file's current context; pinned at startup
  FSTYPE             Must match source CSI fsType; required if source omits it
  RUN_ID             Default: UTC timestamp and process ID
  REGISTER_NAME, SUPERVISOR_PVC_NAME, VKS_PV_NAME
                     Default to unique names derived from PVC_NAME and RUN_ID
  OUTPUT_DIR         New directory for rollback JSON and manifests; by default
                     a private temporary directory is created and retained

Before confirming: stop writers and their controllers, take an independent data
backup and a compatible source snapshot where supported, complete the manifest-
only Velero backup, record a known checksum, and verify destination datastore
access, storage policy and hosting namespace. The script does not do these tasks.

Preflight and server dry-runs precede an exact FCD-ID confirmation. The legacy
CONFIRM_DESTRUCTIVE_CUTOVER=YES alone cannot approve deletion. The script then
sets the source PV to Retain and deletes the UID-checked source PVC. Existing
targets cause a stop. No source PVs, snapshots or finalizers are removed; no
rollback or cleanup is automatic. Inspect partial runs before retrying. Restore
metadata, validate data through a read-only reader, and restart workloads manually.
HELP
}
[[ $# -le 1 ]] || { usage >&2; exit 1; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 1 ;;
esac
STEP=preflight
OUTPUT_DIR=${OUTPUT_DIR:-}
die() { printf 'ERROR during %s: %s\n' "$STEP" "$*" >&2; exit 1; }
trap 'printf "Stopped during %s. Inspect storage state before retrying; no automatic cleanup was performed. Evidence directory: %s\n" "$STEP" "${OUTPUT_DIR:-not created}" >&2' ERR
for tool in kubectl jq; do command -v "$tool" >/dev/null || die "Required command not found: $tool"; done
: "${OCP_KUBECONFIG:?Set OCP_KUBECONFIG}"
: "${VKS_KUBECONFIG:?Set VKS_KUBECONFIG}"
: "${SUPERVISOR_KUBECONFIG:?Set SUPERVISOR_KUBECONFIG}"
: "${SOURCE_NS:?Set SOURCE_NS}"
: "${TARGET_NS:?Set TARGET_NS}"
: "${SUPERVISOR_NS:?Set SUPERVISOR_NS}"
: "${PVC_NAME:?Set PVC_NAME}"
for config in "$OCP_KUBECONFIG" "$VKS_KUBECONFIG" "$SUPERVISOR_KUBECONFIG"; do
  [[ -r "$config" ]] || die "Unreadable kubeconfig: $config"
done
OCP_CONTEXT=${OCP_CONTEXT:-$(kubectl --kubeconfig="$OCP_KUBECONFIG" config current-context)}
VKS_CONTEXT=${VKS_CONTEXT:-$(kubectl --kubeconfig="$VKS_KUBECONFIG" config current-context)}
SUPERVISOR_CONTEXT=${SUPERVISOR_CONTEXT:-$(kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" config current-context)}
[[ -n "$OCP_CONTEXT" && -n "$VKS_CONTEXT" && -n "$SUPERVISOR_CONTEXT" ]] || die 'Every kubeconfig needs a selected context.'
ocp() { kubectl --kubeconfig="$OCP_KUBECONFIG" --context="$OCP_CONTEXT" --request-timeout=30s "$@"; }
vks() { kubectl --kubeconfig="$VKS_KUBECONFIG" --context="$VKS_CONTEXT" --request-timeout=30s "$@"; }
sup() { kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" --context="$SUPERVISOR_CONTEXT" --request-timeout=30s "$@"; }
as_object() { jq -se 'if length == 1 and (.[0] | type == "object") then .[0] else error("Expected one JSON object") end'; }
get_json() { local client=$1; shift; "$client" get "$@" -o json | as_object; }
field() { jq -er "$1 | select(type == \"string\" and length > 0)"; }
require_namespace() {
  local object
  object=$(get_json "$1" namespace "$2")
  jq -e '.metadata.deletionTimestamp == null and .status.phase == "Active"' <<<"$object" >/dev/null || die "Namespace $2 is not active."
}
require_absent() {
  local client=$1 object
  shift
  object=$("$client" get "$@" --ignore-not-found -o json)
  [[ -z "$object" ]] || die "Destination object already exists ($*). Inspect it before retrying."
}
require_no_pods() {
  local pods
  pods=$(get_json ocp -n "$SOURCE_NS" pods)
  jq -e '.items | type == "array"' <<<"$pods" >/dev/null || die 'Invalid source pod list.'
  pods=$(jq -r --arg pvc "$PVC_NAME" '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc)) | .metadata.name' <<<"$pods")
  [[ -z "$pods" ]] || die "Source pods still reference the PVC: $pods. Stop writers and their controllers first."
}
require_no_attachments() {
  local attachments
  attachments=$(get_json ocp volumeattachments) || die 'Unable to list source VolumeAttachments.'
  jq -e '.items | type == "array"' <<<"$attachments" >/dev/null || die 'Invalid VolumeAttachment list.'
  jq -e --arg pv "$PV_NAME" '[.items[] | select(.spec.source.persistentVolumeName == $pv)] | length == 0' <<<"$attachments" >/dev/null
}
require_targets_absent() {
  require_absent sup -n "$SUPERVISOR_NS" cnsregistervolume "$REGISTER_NAME"
  require_absent sup -n "$SUPERVISOR_NS" pvc "$SUPERVISOR_PVC_NAME"
  require_absent vks pv "$VKS_PV_NAME"
  require_absent vks -n "$TARGET_NS" pvc "$PVC_NAME"
}

printf 'Source context: %s\nVKS context: %s\nSupervisor context: %s\n' "$OCP_CONTEXT" "$VKS_CONTEXT" "$SUPERVISOR_CONTEXT"
require_namespace ocp "$SOURCE_NS"
require_namespace vks "$TARGET_NS"
require_namespace sup "$SUPERVISOR_NS"
SRC_CLUSTER_UID=$(get_json ocp namespace kube-system | field '.metadata.uid')
DST_CLUSTER_UID=$(get_json vks namespace kube-system | field '.metadata.uid')
SUP_CLUSTER_UID=$(get_json sup namespace kube-system | field '.metadata.uid')
[[ "$SRC_CLUSTER_UID" != "$DST_CLUSTER_UID" && "$SRC_CLUSTER_UID" != "$SUP_CLUSTER_UID" && "$DST_CLUSTER_UID" != "$SUP_CLUSTER_UID" ]] ||
  die 'Source, destination VKS and Supervisor must identify three distinct Kubernetes APIs.'
SRC_PVC_JSON=$(get_json ocp -n "$SOURCE_NS" pvc "$PVC_NAME")
SRC_PVC_UID=$(field '.metadata.uid' <<<"$SRC_PVC_JSON")
PV_NAME=$(field '.spec.volumeName' <<<"$SRC_PVC_JSON")
SRC_PV_JSON=$(get_json ocp pv "$PV_NAME")
SRC_PV_UID=$(field '.metadata.uid' <<<"$SRC_PV_JSON")
FCD_UUID=$(field '.spec.csi.volumeHandle' <<<"$SRC_PV_JSON")
[[ "$FCD_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  die 'Source volumeHandle must be an FCD UUID. VKS Supervisor-PVC handles require VKS-to-VKS migration.'
SOURCE_SIZE=$(field '.spec.capacity.storage' <<<"$SRC_PV_JSON")
SOURCE_FS=$(jq -r '.spec.csi.fsType // ""' <<<"$SRC_PV_JSON")
FSTYPE=${FSTYPE:-$SOURCE_FS}
[[ -n "$FSTYPE" ]] || die 'Source PV omits fsType. Verify the actual filesystem and set FSTYPE.'
[[ -z "$SOURCE_FS" || "$SOURCE_FS" == "$FSTYPE" ]] || die 'FSTYPE differs from the recorded source CSI filesystem.'
[[ "$FSTYPE" =~ ^[a-zA-Z0-9._+-]+$ ]] || die 'Invalid FSTYPE.'
verify_source() {
  jq -e --arg uid "$SRC_PVC_UID" --arg pv "$PV_NAME" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .status.phase == "Bound" and
    .spec.volumeName == $pv and (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]
  ' <<<"$SRC_PVC_JSON" >/dev/null || die 'Source PVC identity, binding or volume mode changed or is unsupported.'
  jq -e --arg uid "$SRC_PV_UID" --arg cuid "$SRC_PVC_UID" --arg ns "$SOURCE_NS" --arg pvc "$PVC_NAME" \
    --arg id "$FCD_UUID" --arg size "$SOURCE_SIZE" --arg fs "$SOURCE_FS" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .status.phase == "Bound" and
    .spec.claimRef.uid == $cuid and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc and
    .spec.csi.driver == "csi.vsphere.vmware.com" and .spec.csi.volumeHandle == $id and
    .spec.capacity.storage == $size and (.spec.csi.fsType // "") == $fs and
    (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]
  ' <<<"$SRC_PV_JSON" >/dev/null || die 'Source PV identity, claim binding, capacity or storage type is unexpected.'
}
verify_source
require_no_pods
# Check read permission and API health before any mutation; detachment is polled later.
ATTACHMENTS_JSON=$(get_json ocp volumeattachments)
jq -e '.items | type == "array"' <<<"$ATTACHMENTS_JSON" >/dev/null || die 'Invalid VolumeAttachment list.'
RUN_ID=${RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}
REGISTER_NAME=${REGISTER_NAME:-adopt-${PVC_NAME}-${RUN_ID}}
SUPERVISOR_PVC_NAME=${SUPERVISOR_PVC_NAME:-${PVC_NAME}-migrated-${RUN_ID}}
VKS_PV_NAME=${VKS_PV_NAME:-${PVC_NAME}-adopted-${RUN_ID}}
require_targets_absent
REGISTRATION_MANIFEST=$(jq -n --arg name "$REGISTER_NAME" --arg ns "$SUPERVISOR_NS" --arg id "$FCD_UUID" --arg pvc "$SUPERVISOR_PVC_NAME" '{
  apiVersion:"cns.vmware.com/v1alpha1", kind:"CnsRegisterVolume", metadata:{name:$name, namespace:$ns},
  spec:{volumeID:$id, accessMode:"ReadWriteOnce", pvcName:$pvc}}')
DESTINATION_MANIFEST=$(jq -n --arg pv "$VKS_PV_NAME" --arg pvc "$PVC_NAME" --arg ns "$TARGET_NS" --arg size "$SOURCE_SIZE" \
  --arg fs "$FSTYPE" --arg handle "$SUPERVISOR_PVC_NAME" '{apiVersion:"v1", kind:"List", items:[
  {apiVersion:"v1", kind:"PersistentVolume", metadata:{name:$pv}, spec:{capacity:{storage:$size},
    volumeMode:"Filesystem", accessModes:["ReadWriteOnce"], persistentVolumeReclaimPolicy:"Retain", storageClassName:"",
    claimRef:{namespace:$ns,name:$pvc}, csi:{driver:"csi.vsphere.vmware.com", fsType:$fs, volumeHandle:$handle,
      volumeAttributes:{type:"vSphere CNS Block Volume"}}}},
  {apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$pvc,namespace:$ns},spec:{volumeMode:"Filesystem",
    accessModes:["ReadWriteOnce"],storageClassName:"",volumeName:$pv,resources:{requests:{storage:$size}}}}]}')
sup create --dry-run=server -f - <<<"$REGISTRATION_MANIFEST" >/dev/null
vks create --dry-run=server -f - <<<"$DESTINATION_MANIFEST" >/dev/null
umask 077
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -m 700 "$OUTPUT_DIR" || die 'OUTPUT_DIR must be a new directory; do not overwrite a previous run.'
else
  OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vks-fcd-adoption.XXXXXX")
fi
printf '%s\n' "$SRC_PVC_JSON" > "$OUTPUT_DIR/source-pvc.json"
printf '%s\n' "$SRC_PV_JSON" > "$OUTPUT_DIR/source-pv.json"
printf '%s\n' "$REGISTRATION_MANIFEST" > "$OUTPUT_DIR/registration.json"
printf '%s\n' "$DESTINATION_MANIFEST" > "$OUTPUT_DIR/destination.json"
printf '%s\n' "$FCD_UUID" > "$OUTPUT_DIR/fcd-uuid.txt"
printf '\nSource: %s/%s (PV %s)\nFCD: %s\nCapacity: %s\nFilesystem: %s\nSupervisor PVC: %s/%s\nDestination: %s/%s\nEvidence: %s\n' \
  "$SOURCE_NS" "$PVC_NAME" "$PV_NAME" "$FCD_UUID" "$SOURCE_SIZE" "$FSTYPE" "$SUPERVISOR_NS" "$SUPERVISOR_PVC_NAME" "$TARGET_NS" "$PVC_NAME" "$OUTPUT_DIR"
printf '%s\n' 'Confirm backups, stopped controllers/writers, destination datastore/policy and namespace checks are complete.'
printf 'Type the FCD UUID above to retain the source PV, delete its PVC and adopt the disk: '
IFS= read -r confirmation || die 'Confirmation was not received; no cluster objects changed.'
[[ "$confirmation" == "$FCD_UUID" ]] || die 'Confirmation did not match; no cluster objects changed.'

STEP='source protection and PVC deletion'
# Recheck after the operator pause; JSON Patch and DELETE then enforce identity atomically.
SRC_PVC_JSON=$(get_json ocp -n "$SOURCE_NS" pvc "$PVC_NAME")
SRC_PV_JSON=$(get_json ocp pv "$PV_NAME")
verify_source
require_no_pods
require_targets_absent
# Refresh rollback evidence after the confirmation pause, before any mutation.
printf '%s\n' "$SRC_PVC_JSON" > "$OUTPUT_DIR/source-pvc.json"
printf '%s\n' "$SRC_PV_JSON" > "$OUTPUT_DIR/source-pv.json"
PV_RV=$(field '.metadata.resourceVersion' <<<"$SRC_PV_JSON")
RETAIN_PATCH=$(jq -n --arg uid "$SRC_PV_UID" --arg rv "$PV_RV" '[
  {op:"test",path:"/metadata/uid",value:$uid},{op:"test",path:"/metadata/resourceVersion",value:$rv},
  {op:"replace",path:"/spec/persistentVolumeReclaimPolicy",value:"Retain"}]')
SRC_PV_JSON=$(ocp patch pv "$PV_NAME" --type=json -p "$RETAIN_PATCH" -o json | as_object)
verify_source
jq -e '.spec.persistentVolumeReclaimPolicy == "Retain"' <<<"$SRC_PV_JSON" >/dev/null || die 'Source Retain policy was not established.'
printf '%s\n' "$SRC_PV_JSON" > "$OUTPUT_DIR/source-pv-retained.json"
SRC_PVC_JSON=$(get_json ocp -n "$SOURCE_NS" pvc "$PVC_NAME")
verify_source
require_no_pods
PVC_RV=$(field '.metadata.resourceVersion' <<<"$SRC_PVC_JSON")
DELETE_OPTIONS=$(jq -n --arg uid "$SRC_PVC_UID" --arg rv "$PVC_RV" '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:$uid,resourceVersion:$rv}}')
# --raw with -f sends DeleteOptions in the DELETE body using kubeconfig transport.
ocp delete --raw="/api/v1/namespaces/$SOURCE_NS/persistentvolumeclaims/$PVC_NAME" -f - <<<"$DELETE_OPTIONS" > "$OUTPUT_DIR/source-pvc-delete-response.json"
deadline=$((SECONDS + 600))
while :; do
  remaining=$(ocp -n "$SOURCE_NS" get pvc "$PVC_NAME" --ignore-not-found -o json)
  [[ -n "$remaining" ]] || break
  remaining=$(as_object <<<"$remaining")
  jq -e --arg uid "$SRC_PVC_UID" '.metadata.uid == $uid' <<<"$remaining" >/dev/null || die 'Source PVC was recreated; stop its controller before proceeding.'
  (( SECONDS < deadline )) || die 'Source PVC deletion timed out. Keep Retain and inspect finalizers; do not remove them.'
  sleep 5
done
STEP='source disk detachment'
deadline=$((SECONDS + 600))
while ! require_no_attachments; do
  (( SECONDS < deadline )) || die 'Source VolumeAttachment remains after 10 minutes; registration was not attempted.'
  sleep 5
done
# A retained PV remains as rollback evidence. Wait for the binder's Released update.
deadline=$((SECONDS + 300))
while :; do
  SRC_PV_JSON=$(get_json ocp pv "$PV_NAME")
  jq -e --arg uid "$SRC_PV_UID" --arg id "$FCD_UUID" --arg cuid "$SRC_PVC_UID" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .spec.csi.volumeHandle == $id and
    .spec.persistentVolumeReclaimPolicy == "Retain" and .spec.claimRef.uid == $cuid
  ' <<<"$SRC_PV_JSON" >/dev/null || die 'Source PV identity or Retain policy changed before registration.'
  if jq -e '.status.phase == "Released"' <<<"$SRC_PV_JSON" >/dev/null; then break; fi
  (( SECONDS < deadline )) || die 'Source PV did not become Released within 5 minutes.'
  sleep 5
done

STEP='destination FCD registration'
remaining=$(ocp -n "$SOURCE_NS" get pvc "$PVC_NAME" --ignore-not-found -o json)
[[ -z "$remaining" ]] || die 'Source PVC was recreated; stop its controller before proceeding.'
require_targets_absent
REGISTRATION_JSON=$(sup create -f - -o json <<<"$REGISTRATION_MANIFEST" | as_object)
REGISTER_UID=$(field '.metadata.uid' <<<"$REGISTRATION_JSON")
printf '%s\n' "$REGISTRATION_JSON" > "$OUTPUT_DIR/created-registration.json"
deadline=$((SECONDS + 600))
while :; do
  REGISTRATION_JSON=$(get_json sup -n "$SUPERVISOR_NS" cnsregistervolume "$REGISTER_NAME")
  jq -e --arg uid "$REGISTER_UID" --arg id "$FCD_UUID" --arg pvc "$SUPERVISOR_PVC_NAME" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .spec.volumeID == $id and
    .spec.pvcName == $pvc and .spec.accessMode == "ReadWriteOnce"
  ' <<<"$REGISTRATION_JSON" >/dev/null || die 'Registration identity or specification changed.'
  error=$(jq -r '.status.error // ""' <<<"$REGISTRATION_JSON")
  [[ -z "$error" ]] || die "CnsRegisterVolume reported: $error. Inspect the registration before retrying."
  if jq -e '.status.registered == true' <<<"$REGISTRATION_JSON" >/dev/null; then break; fi
  (( SECONDS < deadline )) || die 'Registration did not complete within 10 minutes.'
  sleep 5
done
STEP='Supervisor binding verification'
deadline=$((SECONDS + 300))
while :; do
  SUP_PVC_JSON=$(sup -n "$SUPERVISOR_NS" get pvc "$SUPERVISOR_PVC_NAME" --ignore-not-found -o json)
  if [[ -n "$SUP_PVC_JSON" ]]; then
    SUP_PVC_JSON=$(as_object <<<"$SUP_PVC_JSON")
    jq -e '.metadata.deletionTimestamp == null' <<<"$SUP_PVC_JSON" >/dev/null || die 'Supervisor PVC is terminating.'
    if jq -e '.status.phase == "Bound"' <<<"$SUP_PVC_JSON" >/dev/null; then break; fi
  fi
  (( SECONDS < deadline )) || die 'Supervisor PVC did not bind within 5 minutes.'
  sleep 5
done
SUP_PVC_UID=$(field '.metadata.uid' <<<"$SUP_PVC_JSON")
SUPERVISOR_PV_NAME=$(field '.spec.volumeName' <<<"$SUP_PVC_JSON")
SUP_PV_JSON=$(get_json sup pv "$SUPERVISOR_PV_NAME")
jq -e '(.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]' <<<"$SUP_PVC_JSON" >/dev/null || die 'Supervisor PVC has an incompatible volume mode.'
jq -e --arg id "$FCD_UUID" --arg ns "$SUPERVISOR_NS" --arg pvc "$SUPERVISOR_PVC_NAME" --arg uid "$SUP_PVC_UID" --arg size "$SOURCE_SIZE" --arg fs "$FSTYPE" '
  .metadata.deletionTimestamp == null and .status.phase == "Bound" and .spec.csi.driver == "csi.vsphere.vmware.com" and
  .spec.csi.volumeHandle == $id and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc and .spec.claimRef.uid == $uid and
  .spec.capacity.storage == $size and (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"] and
  ((.spec.csi.fsType // "") == "" or .spec.csi.fsType == $fs)
' <<<"$SUP_PV_JSON" >/dev/null || die 'Supervisor PV disk, binding, canonical capacity or filesystem does not match the source.'
printf '%s\n' "$SUP_PVC_JSON" > "$OUTPUT_DIR/supervisor-pvc.json"
printf '%s\n' "$SUP_PV_JSON" > "$OUTPUT_DIR/supervisor-pv.json"

STEP='VKS adoption'
CREATED_PV=$(vks create -f - -o json <<<"$(jq '.items[0]' <<<"$DESTINATION_MANIFEST")" | as_object)
VKS_PV_UID=$(field '.metadata.uid' <<<"$CREATED_PV")
printf '%s\n' "$CREATED_PV" > "$OUTPUT_DIR/created-vks-pv.json"
CREATED_PVC=$(vks create -f - -o json <<<"$(jq '.items[1]' <<<"$DESTINATION_MANIFEST")" | as_object)
VKS_PVC_UID=$(field '.metadata.uid' <<<"$CREATED_PVC")
printf '%s\n' "$CREATED_PVC" > "$OUTPUT_DIR/created-vks-pvc.json"
deadline=$((SECONDS + 300))
while :; do
  VKS_PVC_JSON=$(get_json vks -n "$TARGET_NS" pvc "$PVC_NAME")
  jq -e --arg uid "$VKS_PVC_UID" --arg pv "$VKS_PV_NAME" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .spec.volumeName == $pv and
    (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"] and .spec.storageClassName == ""
  ' <<<"$VKS_PVC_JSON" >/dev/null || die 'Destination VKS PVC identity or binding changed.'
  if jq -e '.status.phase == "Bound"' <<<"$VKS_PVC_JSON" >/dev/null; then break; fi
  (( SECONDS < deadline )) || die 'VKS PVC did not bind within 5 minutes.'
  sleep 5
done
VKS_PV_JSON=$(get_json vks pv "$VKS_PV_NAME")
jq -e --arg uid "$VKS_PV_UID" --arg cuid "$VKS_PVC_UID" --arg ns "$TARGET_NS" --arg pvc "$PVC_NAME" \
  --arg handle "$SUPERVISOR_PVC_NAME" --arg size "$SOURCE_SIZE" --arg fs "$FSTYPE" '
  .metadata.uid == $uid and .metadata.deletionTimestamp == null and .status.phase == "Bound" and
  .spec.csi.driver == "csi.vsphere.vmware.com" and .spec.csi.volumeHandle == $handle and .spec.csi.fsType == $fs and
  .spec.claimRef.uid == $cuid and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc and
  .spec.persistentVolumeReclaimPolicy == "Retain" and .spec.capacity.storage == $size and
  (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]
' <<<"$VKS_PV_JSON" >/dev/null || die 'Destination VKS PV identity or storage binding is unexpected.'
printf '%s\n' "$VKS_PV_JSON" > "$OUTPUT_DIR/destination-pv-bound.json"
printf '%s\n' "$VKS_PVC_JSON" > "$OUTPUT_DIR/destination-pvc-bound.json"
printf '\nAdopted %s/%s; data has NOT yet been validated. Evidence: %s\n' "$TARGET_NS" "$PVC_NAME" "$OUTPUT_DIR"
printf '%s\n' 'Keep source PV/snapshots and backups. Restore metadata without PVs/PVCs, validate the known checksum with a read-only reader, then restart writers. Do not strip finalizers or blindly rerun.'
