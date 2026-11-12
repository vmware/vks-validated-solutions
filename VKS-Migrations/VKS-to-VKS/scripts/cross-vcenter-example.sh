#!/usr/bin/env bash

# Sourcing must not change the caller's options or run migration commands.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Run this script in a separate process: bash scripts/cross-vcenter-example.sh' >&2
  return 0 2>/dev/null || exit 1
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' 'Sourcing skipped. Run: bash scripts/cross-vcenter-example.sh' >&2
  return 0
fi
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/cross-vcenter-example.sh [--help]

Companion to ../examples/3-across-supervisors-and-vcenters.md, steps 11-13.
Registers an already migrated, detached FCD and adopts its Supervisor PVC in VKS.
This proof of concept supports ReadWriteOnce filesystem volumes only.

Required environment:
  DST_SUP_KUBECONFIG   Destination Supervisor kubeconfig file
  DST_VKS_KUBECONFIG   Destination VKS kubeconfig file
  DEST_FCD_UUID       Verified destination disk ID (do not assume source ID)
  VKS_PVC_SIZE        Recorded source PV .spec.capacity.storage, e.g. 1Gi

Optional environment (defaults):
  DST_SUP_CONTEXT     Current context in DST_SUP_KUBECONFIG, pinned at startup
  DST_VKS_CONTEXT     Current context in DST_VKS_KUBECONFIG, pinned at startup
  DST_SUP_NS          migration-test (namespace hosting the destination VKS)
  DST_VKS_NS          default (application namespace; must already exist)
  SRC_VKS_PVC         my-test-pvc (recorded source application claim name)
  DST_VKS_PVC         SRC_VKS_PVC (preserves restored workload references)
  DST_SUP_PVC         migrated-cross-supervisor-pvc
  DST_VKS_PV          migrated-cross-vcenter-pv
  REGISTER_NAME       vc-fcd-migration
  FSTYPE              ext4 (set to the source filesystem, e.g. xfs)

Requires kubectl and jq. Complete Example 3 steps 1-10 first: quiesce writers,
record the storage chain and source capacity, complete the manifest-only Velero
backup and independent data backup, protect the source with its Supervisor
snapshot, migrate the powered-off helper VM and disk, verify the destination
identity/policy/datastore, and detach with device.remove -keep. Verify the
helper has no disks and the migrated FCD still resolves before running this.

The script asks you to type DEST_FCD_UUID before registration. Existing target
objects cause it to stop; inspect a partial run before retrying. No snapshots,
helper VMs or source objects are cleaned up. Velero restore, read-only data
validation and application restart remain manual.
HELP
}
[[ $# -le 1 ]] || { usage >&2; exit 1; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 1 ;;
esac

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
STEP=preflight
trap 'printf "Stopped during %s. Inspect existing objects before retrying; no automatic cleanup was performed.\n" "$STEP" >&2' ERR
for dependency in kubectl jq; do
  command -v "$dependency" >/dev/null || die "Required command not found: $dependency"
done
: "${DST_SUP_KUBECONFIG:?Set DST_SUP_KUBECONFIG}"
: "${DST_VKS_KUBECONFIG:?Set DST_VKS_KUBECONFIG}"
: "${DEST_FCD_UUID:?Set DEST_FCD_UUID after verifying it on the destination vCenter}"
: "${VKS_PVC_SIZE:?Set VKS_PVC_SIZE to the recorded source PV capacity}"
[[ -r "$DST_SUP_KUBECONFIG" ]] || die 'Destination Supervisor kubeconfig is not readable.'
[[ -r "$DST_VKS_KUBECONFIG" ]] || die 'Destination VKS kubeconfig is not readable.'
if [[ -z "${DST_SUP_CONTEXT:-}" ]]; then
  DST_SUP_CONTEXT=$(kubectl --kubeconfig="$DST_SUP_KUBECONFIG" config current-context)
fi
if [[ -z "${DST_VKS_CONTEXT:-}" ]]; then
  DST_VKS_CONTEXT=$(kubectl --kubeconfig="$DST_VKS_KUBECONFIG" config current-context)
fi
[[ -n "$DST_SUP_CONTEXT" && -n "$DST_VKS_CONTEXT" ]] || die 'Both kubeconfigs need a selected context.'
DST_SUP_NS=${DST_SUP_NS:-migration-test}
DST_VKS_NS=${DST_VKS_NS:-default}
SRC_VKS_PVC=${SRC_VKS_PVC:-my-test-pvc}
DST_VKS_PVC=${DST_VKS_PVC:-$SRC_VKS_PVC}
REGISTER_NAME=${REGISTER_NAME:-vc-fcd-migration}
DST_SUP_PVC=${DST_SUP_PVC:-migrated-cross-supervisor-pvc}
DST_VKS_PV=${DST_VKS_PV:-migrated-cross-vcenter-pv}
FSTYPE=${FSTYPE:-ext4}
[[ "$FSTYPE" =~ ^[a-zA-Z0-9._+-]+$ ]] || die 'FSTYPE must be a filesystem type such as ext4 or xfs.'

sup_dst() { kubectl --kubeconfig="$DST_SUP_KUBECONFIG" --context="$DST_SUP_CONTEXT" --request-timeout=30s "$@"; }
vks_dst() { kubectl --kubeconfig="$DST_VKS_KUBECONFIG" --context="$DST_VKS_CONTEXT" --request-timeout=30s "$@"; }

# Require a single object even if a proxy or test double returns success with no JSON.
as_object() {
  jq -se 'if length == 1 and (.[0] | type == "object") then .[0] else error("Expected one JSON object") end'
}
get_json() {
  local client=$1
  shift
  "$client" get "$@" -o json | as_object
}

# GET failures must never be mistaken for an absent target or usable namespace.
require_namespace() {
  local client=$1 namespace=$2 object
  object=$(get_json "$client" namespace "$namespace")
  jq -e '.metadata.deletionTimestamp == null and .status.phase == "Active"' <<<"$object" >/dev/null ||
    die "Namespace $namespace is not active or is terminating."
}
require_absent() {
  local client=$1 object
  shift
  object=$("$client" get "$@" --ignore-not-found -o json)
  [[ -z "$object" ]] || die "Destination object already exists ($*). Inspect it before retrying."
}

printf 'Destination Supervisor context: %s\nDestination VKS context: %s\n' "$DST_SUP_CONTEXT" "$DST_VKS_CONTEXT"
sup_dst cluster-info
vks_dst cluster-info
require_namespace sup_dst "$DST_SUP_NS"
require_namespace vks_dst "$DST_VKS_NS"
require_absent sup_dst -n "$DST_SUP_NS" cnsregistervolume "$REGISTER_NAME"
require_absent sup_dst -n "$DST_SUP_NS" pvc "$DST_SUP_PVC"
require_absent vks_dst pv "$DST_VKS_PV"
require_absent vks_dst -n "$DST_VKS_NS" pvc "$DST_VKS_PVC"

# Validate both manifests before registration changes the Supervisor.
REGISTRATION_MANIFEST=$(jq -n --arg name "$REGISTER_NAME" --arg namespace "$DST_SUP_NS" \
  --arg id "$DEST_FCD_UUID" --arg pvc "$DST_SUP_PVC" '{
    apiVersion: "cns.vmware.com/v1alpha1", kind: "CnsRegisterVolume",
    metadata: {name: $name, namespace: $namespace},
    spec: {volumeID: $id, accessMode: "ReadWriteOnce", pvcName: $pvc}
  }')
DESTINATION_MANIFEST=$(jq -n --arg pv "$DST_VKS_PV" --arg pvc "$DST_VKS_PVC" --arg namespace "$DST_VKS_NS" \
  --arg size "$VKS_PVC_SIZE" --arg handle "$DST_SUP_PVC" --arg fs "$FSTYPE" '{
  apiVersion: "v1", kind: "List", items: [
    {apiVersion: "v1", kind: "PersistentVolume", metadata: {name: $pv}, spec: {
      capacity: {storage: $size}, volumeMode: "Filesystem", accessModes: ["ReadWriteOnce"],
      persistentVolumeReclaimPolicy: "Retain", storageClassName: "",
      claimRef: {namespace: $namespace, name: $pvc},
      csi: {driver: "csi.vsphere.vmware.com", fsType: $fs, volumeHandle: $handle,
        volumeAttributes: {type: "vSphere CNS Block Volume"}}
    }},
    {apiVersion: "v1", kind: "PersistentVolumeClaim", metadata: {name: $pvc, namespace: $namespace}, spec: {
      volumeMode: "Filesystem", accessModes: ["ReadWriteOnce"], storageClassName: "",
      volumeName: $pv, resources: {requests: {storage: $size}}
    }}
  ]
}')
sup_dst create --dry-run=server -f - <<<"$REGISTRATION_MANIFEST" >/dev/null
vks_dst create --dry-run=server -f - <<<"$DESTINATION_MANIFEST" >/dev/null

printf '\nDestination FCD: %s\nRecorded source capacity: %s\nFilesystem: %s\nSupervisor PVC: %s/%s\nVKS PV: %s\nVKS PVC: %s/%s\n' \
  "$DEST_FCD_UUID" "$VKS_PVC_SIZE" "$FSTYPE" "$DST_SUP_NS" "$DST_SUP_PVC" "$DST_VKS_PV" "$DST_VKS_NS" "$DST_VKS_PVC"
if [[ "$DST_VKS_PVC" != "$SRC_VKS_PVC" ]]; then
  printf 'Update workload claim references from %s to %s before starting writers.\n' "$SRC_VKS_PVC" "$DST_VKS_PVC"
fi
cat <<'MESSAGE'
Confirm Example 3 steps 1-10 are complete: writers remain stopped; the source
snapshot and backups are retained; the destination disk, capacity, filesystem,
storage policy and namespace have been verified; and device.remove -keep has
left the powered-off helper empty while preserving the FCD.
MESSAGE
printf 'Type the destination FCD ID above to register and adopt it: '
IFS= read -r confirmation || die 'Confirmation was not received; no objects were created.'
[[ "$confirmation" == "$DEST_FCD_UUID" ]] || die 'Confirmation did not match; no objects were created.'

# Create, rather than apply, so another run cannot overwrite an existing CR.
STEP='destination FCD registration'
REGISTRATION_JSON=$(sup_dst create -f - -o json <<<"$REGISTRATION_MANIFEST" | as_object)
REGISTER_UID=$(jq -er '.metadata.uid | select(type == "string" and length > 0)' <<<"$REGISTRATION_JSON")
verify_registration_identity() {
  jq -e --arg uid "$REGISTER_UID" --arg id "$DEST_FCD_UUID" --arg pvc "$DST_SUP_PVC" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and
    .spec.volumeID == $id and .spec.pvcName == $pvc and .spec.accessMode == "ReadWriteOnce"
  ' <<<"$REGISTRATION_JSON" >/dev/null || die 'Registration identity changed or the object is terminating.'
}

# Bounded GETs report controller errors before registered=true and need no watch.
deadline=$((SECONDS + 600))
while :; do
  REGISTRATION_JSON=$(get_json sup_dst -n "$DST_SUP_NS" cnsregistervolume "$REGISTER_NAME")
  verify_registration_identity
  REGISTER_ERROR=$(jq -r '.status.error // ""' <<<"$REGISTRATION_JSON")
  [[ -z "$REGISTER_ERROR" ]] || die "CnsRegisterVolume reported: $REGISTER_ERROR. Inspect registration and PVC before retrying."
  if jq -e '.status.registered == true' <<<"$REGISTRATION_JSON" >/dev/null; then
    break
  fi
  if (( SECONDS >= deadline )); then
    jq '{metadata: {name: .metadata.name}, status: .status}' <<<"$REGISTRATION_JSON" >&2
    die 'Registration did not complete within 10 minutes. Inspect the registration before retrying.'
  fi
  sleep 5
done

STEP='destination Supervisor binding verification'
deadline=$((SECONDS + 300))
while :; do
  SUP_PVC_JSON=$(sup_dst -n "$DST_SUP_NS" get pvc "$DST_SUP_PVC" --ignore-not-found -o json)
  if [[ -n "$SUP_PVC_JSON" ]]; then
    SUP_PVC_JSON=$(as_object <<<"$SUP_PVC_JSON")
    jq -e '.metadata.deletionTimestamp == null' <<<"$SUP_PVC_JSON" >/dev/null || die 'Destination Supervisor PVC is terminating.'
    if jq -e '.status.phase == "Bound"' <<<"$SUP_PVC_JSON" >/dev/null; then
      break
    fi
  fi
  (( SECONDS < deadline )) || die 'Destination Supervisor PVC did not bind within 5 minutes.'
  sleep 5
done
DST_SUP_PV=$(jq -er '.spec.volumeName | select(type == "string" and length > 0)' <<<"$SUP_PVC_JSON")
SUP_PVC_UID=$(jq -er '.metadata.uid | select(type == "string" and length > 0)' <<<"$SUP_PVC_JSON")
SUP_PV_JSON=$(get_json sup_dst pv "$DST_SUP_PV")
jq -e '(.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]' \
  <<<"$SUP_PVC_JSON" >/dev/null || die 'Destination Supervisor PVC is not a ReadWriteOnce filesystem claim.'
jq -e --arg id "$DEST_FCD_UUID" --arg namespace "$DST_SUP_NS" \
  --arg pvc "$DST_SUP_PVC" --arg uid "$SUP_PVC_UID" --arg fs "$FSTYPE" '
  .metadata.deletionTimestamp == null and .status.phase == "Bound" and
  .spec.csi.driver == "csi.vsphere.vmware.com" and .spec.csi.volumeHandle == $id and
  .spec.claimRef.namespace == $namespace and .spec.claimRef.name == $pvc and .spec.claimRef.uid == $uid and
  (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"] and
  ((.spec.csi.fsType // "") == "" or .spec.csi.fsType == $fs)
' <<<"$SUP_PV_JSON" >/dev/null || die 'Destination Supervisor PV identity, binding, filesystem or lifecycle state is unexpected.'
DST_SIZE=$(jq -er '.spec.capacity.storage | select(type == "string" and length > 0)' <<<"$SUP_PV_JSON")
[[ "$DST_SIZE" == "$VKS_PVC_SIZE" ]] || die "Destination capacity $DST_SIZE differs from recorded source capacity $VKS_PVC_SIZE. Verify canonical PV quantities before adoption."
printf 'Verified Supervisor PV: %s\nDestination capacity: %s\nVKS volume handle: %s\n' "$DST_SUP_PV" "$DST_SIZE" "$DST_SUP_PVC"

STEP='destination VKS adoption'
vks_dst create -f - <<<"$DESTINATION_MANIFEST"
vks_dst -n "$DST_VKS_NS" wait --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_VKS_PVC}" --timeout=5m --request-timeout=5m
DST_PVC_JSON=$(get_json vks_dst -n "$DST_VKS_NS" pvc "$DST_VKS_PVC")
DST_PVC_UID=$(jq -er '.metadata.uid | select(type == "string" and length > 0)' <<<"$DST_PVC_JSON")
jq -e --arg pv "$DST_VKS_PV" '
  .metadata.deletionTimestamp == null and .status.phase == "Bound" and .spec.volumeName == $pv
' <<<"$DST_PVC_JSON" >/dev/null || die 'Destination VKS PVC did not retain the expected binding.'
DST_PV_JSON=$(get_json vks_dst pv "$DST_VKS_PV")
jq -e --arg handle "$DST_SUP_PVC" --arg namespace "$DST_VKS_NS" --arg pvc "$DST_VKS_PVC" --arg uid "$DST_PVC_UID" '
  .metadata.deletionTimestamp == null and .status.phase == "Bound" and
  .spec.csi.driver == "csi.vsphere.vmware.com" and .spec.csi.volumeHandle == $handle and
  .spec.persistentVolumeReclaimPolicy == "Retain" and
  .spec.claimRef.namespace == $namespace and .spec.claimRef.name == $pvc and .spec.claimRef.uid == $uid
' <<<"$DST_PV_JSON" >/dev/null || die 'Destination VKS PV does not match the expected Supervisor handle and claim.'
printf '\nRegistered and adopted %s/%s; data has not yet been validated.\n' "$DST_VKS_NS" "$DST_VKS_PVC"
cat <<'MESSAGE'
Continue with Example 3 steps 14-16: restore manifests without PVs/PVCs/snapshots,
keep writers stopped, and validate the recorded file or checksum through a
read-only reader. Remove the reader before restoring application replica counts.
Retain the source snapshot and empty helper until validation and rollback
decisions are complete. Before snapshot cleanup, confirm source VKS PV deletion
completed and no source deletion retries remain. Never strip storage finalizers.
MESSAGE
