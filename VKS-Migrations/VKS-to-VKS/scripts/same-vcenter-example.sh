#!/usr/bin/env bash

# Execute in a separate Bash process; never change a sourcing shell's options.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Run with bash: bash scripts/same-vcenter-example.sh' >&2
  return 0 2>/dev/null || exit 1
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' 'Sourcing skipped. Run: bash scripts/same-vcenter-example.sh' >&2
  return 0
fi

set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/same-vcenter-example.sh [--help]

Companion to examples/1-same-supervisor-and-namespace.md, steps 3 and 6-8.
Only for two VKS clusters in the SAME Supervisor and Supervisor namespace.
Requires bash, kubectl, jq, and an already quiesced RWO filesystem volume.

Required environment:
  SRC_VKS_KUBECONFIG, DST_VKS_KUBECONFIG, SUPERVISOR_KUBECONFIG
  SRC_SUP_NS                 Shared Supervisor namespace (legacy SUP_NS accepted)
Optional environment:
  DST_SUP_NS                 Defaults to SRC_SUP_NS; must equal it
  SRC_VKS_CONTEXT, DST_VKS_CONTEXT, SUPERVISOR_CONTEXT
                             Default to each kubeconfig's current context; pinned
  SRC_VKS_NS, DST_VKS_NS     Application namespaces (default: default)
  SRC_VKS_PVC               Source claim (default: my-test-pvc)
  DST_VKS_PVC               Destination claim (default: SRC_VKS_PVC)
  DST_VKS_PV                Destination PV (default: my-test-pv-migrated)
  SUP_SNAPSHOT_CLASS        Default: volumesnapshotclass-delete
  SUP_SNAPSHOT              Default: <Supervisor-PVC>-migration-snapshot
  FSTYPE                    Must match source CSI fsType; if source omits it,
                             defaults to ext4 (verify the actual filesystem)

Before confirming: take an independent data backup, complete and review the
manifest-only backup in Example 1, stop source writers/controllers, record a
known file/checksum, and verify both VKS clusters use the shared namespace and
the destination hosts can access the datastore and assigned storage policy.
This proof of concept needs rehearsal on the target versions. It does not
perform backup/restore, start workloads, validate data, or remove snapshots.
Existing destination objects or snapshots cause a stop; inspect partial runs
and use the walkthrough to recover instead of blindly rerunning this script.
HELP
}

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
  usage >&2
  exit 1
fi
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
STAGE=preflight
trap 'printf "Stopped during %s. Inspect the reported error and current storage state. Keep snapshot protection; do not strip finalizers or blindly rerun.\n" "$STAGE" >&2' ERR
for tool in kubectl jq; do command -v "$tool" >/dev/null || fail "Missing dependency: $tool"; done

: "${SRC_VKS_KUBECONFIG:?Set SRC_VKS_KUBECONFIG}"
: "${DST_VKS_KUBECONFIG:?Set DST_VKS_KUBECONFIG}"
: "${SUPERVISOR_KUBECONFIG:?Set SUPERVISOR_KUBECONFIG}"
SRC_SUP_NS=${SRC_SUP_NS:-${SUP_NS:-}}
: "${SRC_SUP_NS:?Set SRC_SUP_NS to the shared Supervisor namespace (or legacy SUP_NS)}"
DST_SUP_NS=${DST_SUP_NS:-$SRC_SUP_NS}
[[ "$SRC_SUP_NS" == "$DST_SUP_NS" ]] || fail 'Different Supervisor namespaces require Example 2; this script only implements Example 1.'
[[ -z "${SUP_NS:-}" || "$SUP_NS" == "$SRC_SUP_NS" ]] || fail 'SUP_NS conflicts with SRC_SUP_NS.'
SRC_VKS_NS=${SRC_VKS_NS:-default}
DST_VKS_NS=${DST_VKS_NS:-default}
SRC_VKS_PVC=${SRC_VKS_PVC:-my-test-pvc}
DST_VKS_PV=${DST_VKS_PV:-my-test-pv-migrated}
DST_VKS_PVC=${DST_VKS_PVC:-$SRC_VKS_PVC}
SUP_SNAPSHOT_CLASS=${SUP_SNAPSHOT_CLASS:-volumesnapshotclass-delete}

for config in "$SRC_VKS_KUBECONFIG" "$DST_VKS_KUBECONFIG" "$SUPERVISOR_KUBECONFIG"; do
  [[ -r "$config" ]] || fail "Unreadable kubeconfig: $config"
done
SRC_VKS_CONTEXT=${SRC_VKS_CONTEXT:-$(kubectl --kubeconfig="$SRC_VKS_KUBECONFIG" config current-context)}
DST_VKS_CONTEXT=${DST_VKS_CONTEXT:-$(kubectl --kubeconfig="$DST_VKS_KUBECONFIG" config current-context)}
SUPERVISOR_CONTEXT=${SUPERVISOR_CONTEXT:-$(kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" config current-context)}
[[ -n "$SRC_VKS_CONTEXT" && -n "$DST_VKS_CONTEXT" && -n "$SUPERVISOR_CONTEXT" ]] || fail 'Every kubeconfig must select a context.'
vks_src() { kubectl --kubeconfig="$SRC_VKS_KUBECONFIG" --context="$SRC_VKS_CONTEXT" "$@"; }
vks_dst() { kubectl --kubeconfig="$DST_VKS_KUBECONFIG" --context="$DST_VKS_CONTEXT" "$@"; }
sup() { kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" --context="$SUPERVISOR_CONTEXT" "$@"; }

# A successful command with empty/unexpected output is not proof of safe state.
get_json() {
  local client=$1 result
  shift
  result=$("$client" "$@" -o json) || return 1
  jq -se 'if length == 1 and (.[0] | type == "object") then .[0]
          else error("Expected exactly one Kubernetes JSON object") end' <<<"$result"
}

printf 'Source VKS context: %s\nDestination VKS context: %s\nSupervisor context: %s\nShared Supervisor namespace: %s\n' \
  "$SRC_VKS_CONTEXT" "$DST_VKS_CONTEXT" "$SUPERVISOR_CONTEXT" "$SRC_SUP_NS"
vks_src cluster-info
vks_dst cluster-info
sup cluster-info
get_json vks_dst get namespace "$DST_VKS_NS" | jq -e '.metadata.deletionTimestamp == null and .status.phase == "Active"' >/dev/null
get_json sup get namespace "$SRC_SUP_NS" | jq -e '.metadata.deletionTimestamp == null and .status.phase == "Active"' >/dev/null
# Namespace UIDs detect the same VKS cluster even through different contexts/URLs.
SRC_CLUSTER_UID=$(vks_src get namespace kube-system -o jsonpath='{.metadata.uid}')
DST_CLUSTER_UID=$(vks_dst get namespace kube-system -o jsonpath='{.metadata.uid}')
[[ -n "$SRC_CLUSTER_UID" && -n "$DST_CLUSTER_UID" && "$SRC_CLUSTER_UID" != "$DST_CLUSTER_UID" ]] || fail 'Source and destination must be distinct VKS clusters.'

require_absent() {
  local client=$1 existing
  shift
  existing=$("$client" get "$@" --ignore-not-found -o name) || fail 'Could not check object absence.'
  [[ -z "$existing" ]] || fail "Object already exists: $existing. Inspect it before proceeding."
}
require_absent vks_dst pv "$DST_VKS_PV"
require_absent vks_dst pvc "$DST_VKS_PVC" -n "$DST_VKS_NS"

SRC_PVC_JSON=$(get_json vks_src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC")
jq -e '.status.phase == "Bound" and .metadata.deletionTimestamp == null' <<<"$SRC_PVC_JSON" >/dev/null
SRC_PVC_UID=$(jq -er '.metadata.uid | select(length > 0)' <<<"$SRC_PVC_JSON")
SRC_VKS_PV=$(jq -er '.spec.volumeName | select(length > 0)' <<<"$SRC_PVC_JSON")
SRC_PV_JSON=$(get_json vks_src get pv "$SRC_VKS_PV")
jq -e --arg uid "$SRC_PVC_UID" --arg ns "$SRC_VKS_NS" --arg name "$SRC_VKS_PVC" '
  .metadata.deletionTimestamp == null and .status.phase == "Bound" and
  .spec.claimRef.uid == $uid and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $name and
  .spec.csi.driver == "csi.vsphere.vmware.com" and
  (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]
' <<<"$SRC_PV_JSON" >/dev/null || fail 'Source must be a bound vSphere CSI ReadWriteOnce filesystem volume with the expected claim.'
SRC_PV_UID=$(jq -er '.metadata.uid | select(length > 0)' <<<"$SRC_PV_JSON")
VKS_PVC_SIZE=$(jq -er '.spec.capacity.storage | select(length > 0)' <<<"$SRC_PV_JSON")
SUP_PVC=$(jq -er '.spec.csi.volumeHandle | select(length > 0)' <<<"$SRC_PV_JSON")
SOURCE_FSTYPE=$(jq -r '.spec.csi.fsType // ""' <<<"$SRC_PV_JSON")
FSTYPE=${FSTYPE:-${SOURCE_FSTYPE:-ext4}}
[[ -z "$SOURCE_FSTYPE" || "$FSTYPE" == "$SOURCE_FSTYPE" ]] || fail 'FSTYPE differs from the source PV fsType.'
[[ "$FSTYPE" =~ ^[a-zA-Z0-9._-]+$ ]] || fail 'Invalid FSTYPE.'
SUP_PVC_JSON=$(get_json sup -n "$SRC_SUP_NS" get pvc "$SUP_PVC")
SUP_PVC_UID=$(jq -er '.metadata.uid | select(length > 0)' <<<"$SUP_PVC_JSON")
SUP_PV=$(jq -er '.spec.volumeName | select(length > 0)' <<<"$SUP_PVC_JSON")
SUP_PV_JSON=$(get_json sup get pv "$SUP_PV")
SUP_PV_UID=$(jq -er '.metadata.uid | select(length > 0)' <<<"$SUP_PV_JSON")
FCD_UUID=$(jq -er '.spec.csi.volumeHandle | select(length > 0)' <<<"$SUP_PV_JSON")
SUP_STORAGE_CLASS=$(jq -r '.spec.storageClassName // ""' <<<"$SUP_PVC_JSON")
SUP_SNAPSHOT=${SUP_SNAPSHOT:-${SUP_PVC}-migration-snapshot}

verify_supervisor_chain() {
  local pvc_json pv_json
  pvc_json=$(get_json sup -n "$SRC_SUP_NS" get pvc "$SUP_PVC")
  pv_json=$(get_json sup get pv "$SUP_PV")
  jq -e --arg pv "$SUP_PV" --arg uid "$SUP_PVC_UID" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and
    .status.phase == "Bound" and .spec.volumeName == $pv
  ' <<<"$pvc_json" >/dev/null || fail 'Supervisor PVC changed, is not Bound to the recorded PV, or is terminating.'
  jq -e --arg id "$FCD_UUID" --arg uid "$SUP_PV_UID" --arg claim "$SUP_PVC_UID" \
    --arg ns "$SRC_SUP_NS" --arg name "$SUP_PVC" '
    .metadata.uid == $uid and .metadata.deletionTimestamp == null and .status.phase == "Bound" and
    .spec.claimRef.uid == $claim and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $name and
    .spec.csi.driver == "csi.vsphere.vmware.com" and .spec.csi.volumeHandle == $id and
    (.spec.volumeMode // "Filesystem") == "Filesystem" and .spec.accessModes == ["ReadWriteOnce"]
  ' <<<"$pv_json" >/dev/null || fail 'Supervisor PV identity/binding changed, is terminating, or is not an RWO filesystem volume.'
}
verify_detached() {
  local attachments pods
  attachments=$(get_json vks_src get volumeattachments)
  jq -e --arg pv "$SRC_VKS_PV" '[.items[] | select(.spec.source.persistentVolumeName == $pv)] | length == 0' \
    <<<"$attachments" >/dev/null || fail 'Source VolumeAttachments remain; wait for detachment and rerun.'
  pods=$(get_json vks_src -n "$SRC_VKS_NS" get pods)
  jq -e --arg pvc "$SRC_VKS_PVC" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))] | length == 0' \
    <<<"$pods" >/dev/null || fail 'Source pods still reference this claim; stop their controllers and remove the pods first.'
}
verify_supervisor_chain
verify_detached
require_absent sup volumesnapshot "$SUP_SNAPSHOT" -n "$SRC_SUP_NS"
get_json sup get volumesnapshotclass "$SUP_SNAPSHOT_CLASS" | jq -e '.driver == "csi.vsphere.vmware.com"' >/dev/null

# Build JSON with jq so configuration values are never interpolated as YAML.
DEST_MANIFEST=$(jq -n --arg pv "$DST_VKS_PV" --arg pvc "$DST_VKS_PVC" --arg ns "$DST_VKS_NS" \
  --arg size "$VKS_PVC_SIZE" --arg handle "$SUP_PVC" --arg fs "$FSTYPE" '
  {apiVersion:"v1",kind:"List",items:[
    {apiVersion:"v1",kind:"PersistentVolume",metadata:{name:$pv},spec:{
      capacity:{storage:$size},volumeMode:"Filesystem",accessModes:["ReadWriteOnce"],
      persistentVolumeReclaimPolicy:"Retain",storageClassName:"",claimRef:{namespace:$ns,name:$pvc},
      csi:{driver:"csi.vsphere.vmware.com",fsType:$fs,volumeHandle:$handle,
        volumeAttributes:{type:"vSphere CNS Block Volume"}}}},
    {apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$pvc,namespace:$ns},spec:{
      volumeMode:"Filesystem",accessModes:["ReadWriteOnce"],storageClassName:"",volumeName:$pv,
      resources:{requests:{storage:$size}}}}]}
')
# Validate destination names, schema and create permissions before source teardown.
printf '%s\n' "$DEST_MANIFEST" | vks_dst create --dry-run=server -f - >/dev/null
printf '\nRecord these values before continuing:\nVKS PVC=%s/%s\nVKS PV=%s\nCapacity=%s\nFilesystem=%s\nSupervisor PVC=%s/%s\nSupervisor PV=%s\nStorage policy=%s\nFCD UUID=%s\nSnapshot=%s\nDestination PVC=%s/%s\n' \
  "$SRC_VKS_NS" "$SRC_VKS_PVC" "$SRC_VKS_PV" "$VKS_PVC_SIZE" "$FSTYPE" "$SRC_SUP_NS" "$SUP_PVC" \
  "$SUP_PV" "$SUP_STORAGE_CLASS" "$FCD_UUID" "$SUP_SNAPSHOT" "$DST_VKS_NS" "$DST_VKS_PVC"
cat <<'MESSAGE'
Confirm both VKS clusters belong to this SAME Supervisor namespace, source
controllers are stopped, an independent data backup and the manifest-only backup
are complete/reviewed, and a known file/checksum is recorded. This creates a
Supervisor snapshot then DELETES the source VKS PVC/PV. Snapshot-only protection
must have been rehearsed on these versions. No finalizers will be removed.
MESSAGE
printf 'Type the source claim name (%s) to proceed: ' "$SRC_VKS_PVC"
IFS= read -r confirmation || fail 'Confirmation not received.'
[[ "$confirmation" == "$SRC_VKS_PVC" ]] || fail 'Confirmation did not match; no storage objects changed.'

STAGE='snapshot creation'
verify_supervisor_chain
verify_detached
jq -n --arg name "$SUP_SNAPSHOT" --arg ns "$SRC_SUP_NS" --arg class "$SUP_SNAPSHOT_CLASS" --arg pvc "$SUP_PVC" '
  {apiVersion:"snapshot.storage.k8s.io/v1",kind:"VolumeSnapshot",metadata:{name:$name,namespace:$ns},
   spec:{volumeSnapshotClassName:$class,source:{persistentVolumeClaimName:$pvc}}}
' | sup create -f -
sup -n "$SRC_SUP_NS" wait --for=jsonpath='{.status.readyToUse}'=true "volumesnapshot/$SUP_SNAPSHOT" --timeout=10m
get_json sup -n "$SRC_SUP_NS" get volumesnapshot "$SUP_SNAPSHOT" | jq -e --arg pvc "$SUP_PVC" '
  .metadata.deletionTimestamp == null and .status.readyToUse == true and .status.error == null and
  .spec.source.persistentVolumeClaimName == $pvc and ((.status.boundVolumeSnapshotContentName // "") | length > 0)
' >/dev/null

STAGE='source VKS deletion'
verify_detached
verify_supervisor_chain
get_json vks_src -n "$SRC_VKS_NS" get pvc "$SRC_VKS_PVC" | jq -e --arg uid "$SRC_PVC_UID" --arg pv "$SRC_VKS_PV" '
  .metadata.uid == $uid and .spec.volumeName == $pv and .status.phase == "Bound" and .metadata.deletionTimestamp == null
' >/dev/null
get_json vks_src get pv "$SRC_VKS_PV" | jq -e --arg uid "$SRC_PV_UID" --arg handle "$SUP_PVC" '
  .metadata.uid == $uid and .spec.csi.volumeHandle == $handle and .metadata.deletionTimestamp == null
' >/dev/null
vks_src -n "$SRC_VKS_NS" delete pvc "$SRC_VKS_PVC" --wait=true --timeout=5m
vks_src delete pv "$SRC_VKS_PV" --ignore-not-found --wait=true --timeout=5m
require_absent vks_src pvc "$SRC_VKS_PVC" -n "$SRC_VKS_NS"
require_absent vks_src pv "$SRC_VKS_PV"

STAGE='destination adoption'
verify_supervisor_chain
printf '%s\n' "$DEST_MANIFEST" | vks_dst create -f -
vks_dst -n "$DST_VKS_NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$DST_VKS_PVC" --timeout=5m
DST_PVC_JSON=$(get_json vks_dst -n "$DST_VKS_NS" get pvc "$DST_VKS_PVC")
jq -e --arg pv "$DST_VKS_PV" '.status.phase == "Bound" and .spec.volumeName == $pv and .metadata.deletionTimestamp == null' \
  <<<"$DST_PVC_JSON" >/dev/null
DST_PVC_UID=$(jq -er '.metadata.uid | select(length > 0)' <<<"$DST_PVC_JSON")
get_json vks_dst get pv "$DST_VKS_PV" | jq -e --arg handle "$SUP_PVC" --arg uid "$DST_PVC_UID" '
  .status.phase == "Bound" and .metadata.deletionTimestamp == null and .spec.csi.volumeHandle == $handle and .spec.claimRef.uid == $uid
' >/dev/null
verify_supervisor_chain
printf '\nDestination claim %s/%s is Bound to the preserved Supervisor volume.\n' "$DST_VKS_NS" "$DST_VKS_PVC"
cat <<MESSAGE
Continue with Example 1 steps 9-11: restore application metadata only (exclude
PVs/PVCs/snapshots), keep workloads stopped, and validate the recorded file with
a read-only reader before restoring replicas. If you renamed the destination
claim, update workload references. Binding alone does not validate the data.
Keep ${SRC_SUP_NS}/${SUP_SNAPSHOT} through the rollback window. Before snapshot
cleanup, confirm source PV deletion completed AND no source CSI deletion retries
remain. A successful destination mount alone does not prove retries have stopped.
MESSAGE
