#!/usr/bin/env bash

# Sourcing must not change the caller's options or run migration commands.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Run with bash: bash scripts/pv-migrate-poc.sh' >&2
  return 0 2>/dev/null || exit 1
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' 'Sourcing skipped. Run: bash scripts/pv-migrate-poc.sh' >&2
  return 0
fi
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/pv-migrate-poc.sh [--help]

Final filesystem copy between two distinct Kubernetes clusters, into an already
provisioned destination PVC. Companion to examples/1-OCP-to-vks-using-pv-migrate.md.
Requires kubectl, jq, python3, helm and the pv-migrate root-command flag interface
(as in pv-migrate 3.7). The source is mounted read-only by pv-migrate.

Required environment:
  SRC_KUBECONFIG, SRC_NAMESPACE, SRC_PVC
  DST_KUBECONFIG, DST_NAMESPACE, DST_PVC

Optional environment:
  SRC_CONTEXT, DST_CONTEXT   Each file's current context; pinned at startup
  STRATEGIES                 loadbalancer (or nodeport/local, comma-separated)
  MIGRATION_ID               Unique UTC timestamp/random suffix; max 24 characters
  PV_MIGRATE_VALUES_FILE     Local reviewed Helm values file for images, SCC,
                             security contexts, networking or other chart settings
  NON_ROOT                   no; set yes only if source files are readable and
                             ownership preservation is not required
  HELM_TIMEOUT               5m (pv-migrate Helm operations)
  LOADBALANCER_TIMEOUT        5m (pv-migrate LoadBalancer address wait)
  OUTPUT_DIR                 New private evidence directory; default mktemp path

Both PVCs/PVs must be Bound filesystem volumes with no active resize; destination
PV and PVC-reported capacities must be at least as large as the source PV. For WaitForFirstConsumer, prepare the destination
with a temporary mounting pod, then delete it before running this script. Stop
writers AND their controllers on both sides. No referencing pods may remain.
Take an independent backup, retain the source, and record data/checksums first.

After preflight, type the exact destination PVC UID to authorize writing it.
ACK_FINAL_COPY=yes no longer bypasses confirmation. Existing files may be
replaced by the copy; extraneous destination files are not deleted. There is no
automatic application shutdown, metadata migration, data validation or rollback.
pv-migrate normally removes its temporary resources after success; failed-run
resources are retained for inspection. Inspect partial copies before retrying.
HELP
}
[[ $# -le 1 ]] || { usage >&2; exit 1; }
case "${1:-}" in -h|--help) usage; exit 0 ;; '') ;; *) usage >&2; exit 1 ;; esac
STEP=preflight
OUTPUT_DIR=${OUTPUT_DIR:-}
die() { printf 'ERROR during %s: %s\n' "$STEP" "$*" >&2; exit 1; }
trap 'printf "Stopped during %s. Inspect the copy and temporary resources before retrying; no wrapper cleanup performed. Evidence: %s\n" "$STEP" "${OUTPUT_DIR:-not created}" >&2' ERR
for tool in kubectl jq python3 helm pv-migrate; do command -v "$tool" >/dev/null || die "Missing dependency: $tool"; done
: "${SRC_KUBECONFIG:?Set SRC_KUBECONFIG}"
: "${DST_KUBECONFIG:?Set DST_KUBECONFIG}"
: "${SRC_NAMESPACE:?Set SRC_NAMESPACE}"
: "${DST_NAMESPACE:?Set DST_NAMESPACE}"
: "${SRC_PVC:?Set SRC_PVC}"
: "${DST_PVC:?Set DST_PVC}"
for config in "$SRC_KUBECONFIG" "$DST_KUBECONFIG"; do [[ -r "$config" ]] || die "Unreadable kubeconfig: $config"; done
SRC_CONTEXT=${SRC_CONTEXT:-$(kubectl --kubeconfig="$SRC_KUBECONFIG" config current-context)}
DST_CONTEXT=${DST_CONTEXT:-$(kubectl --kubeconfig="$DST_KUBECONFIG" config current-context)}
[[ -n "$SRC_CONTEXT" && -n "$DST_CONTEXT" ]] || die 'Both kubeconfigs must select a context.'
STRATEGIES=${STRATEGIES:-loadbalancer}
[[ "$STRATEGIES" =~ ^(loadbalancer|nodeport|local)(,(loadbalancer|nodeport|local))*$ ]] || die 'Use cross-cluster strategies: loadbalancer, nodeport and/or local.'
MIGRATION_ID=${MIGRATION_ID:-copy-$(date -u +%y%m%d%H%M%S)-$RANDOM}
[[ ${#MIGRATION_ID} -le 24 && "$MIGRATION_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'MIGRATION_ID must be a lowercase DNS label of at most 24 characters.'
NON_ROOT=${NON_ROOT:-no}
[[ "$NON_ROOT" == yes || "$NON_ROOT" == no ]] || die 'NON_ROOT must be yes or no.'
HELM_TIMEOUT=${HELM_TIMEOUT:-5m}
LOADBALANCER_TIMEOUT=${LOADBALANCER_TIMEOUT:-5m}
for duration in "$HELM_TIMEOUT" "$LOADBALANCER_TIMEOUT"; do
  [[ "$duration" =~ ^[1-9][0-9]*(s|m|h)$ ]] || die 'Timeouts must be positive whole seconds, minutes or hours (e.g. 5m).'
done
if [[ -n "${PV_MIGRATE_VALUES_FILE:-}" ]]; then
  [[ -f "$PV_MIGRATE_VALUES_FILE" && -r "$PV_MIGRATE_VALUES_FILE" ]] || die 'PV_MIGRATE_VALUES_FILE must be a readable local file.'
fi
PV_MIGRATE_VERSION=$(pv-migrate --version)
PV_MIGRATE_HELP=$(pv-migrate --help)
for flag in --source --dest --source-context --dest-context --source-kubeconfig --dest-kubeconfig --source-namespace --dest-namespace --strategies --rsync-push --id --no-cleanup-on-failure --helm-values --helm-timeout --loadbalancer-timeout; do
  [[ "$PV_MIGRATE_HELP" == *"$flag "* ]] || die "Installed pv-migrate lacks $flag in root help. Review its CLI/version before proceeding."
done
[[ "$NON_ROOT" != yes || "$PV_MIGRATE_HELP" == *'--non-root '* ]] || die 'Installed pv-migrate lacks --non-root.'
src() { kubectl --kubeconfig="$SRC_KUBECONFIG" --context="$SRC_CONTEXT" --request-timeout=30s "$@"; }
dst() { kubectl --kubeconfig="$DST_KUBECONFIG" --context="$DST_CONTEXT" --request-timeout=30s "$@"; }
as_object() { jq -se 'if length == 1 and (.[0] | type == "object") then .[0] else error("Expected one JSON object") end'; }
get_json() { local client=$1; shift; "$client" get "$@" -o json | as_object; }
field() { jq -er "$1 | select(type == \"string\" and length > 0)"; }
namespace_uid() {
  local object
  object=$(get_json "$1" namespace "$2") || die "Unable to read namespace $2 from $1."
  jq -e '.metadata.deletionTimestamp == null and .status.phase == "Active"' <<<"$object" >/dev/null || die "Namespace $2 is not active."
  field '.metadata.uid' <<<"$object"
}
require_no_pods() {
  local client=$1 ns=$2 pvc=$3 pods
  pods=$(get_json "$client" -n "$ns" pods)
  jq -e '.items | type == "array"' <<<"$pods" >/dev/null || die "Invalid pod list from $client."
  pods=$(jq -r --arg pvc "$pvc" '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc)) | .metadata.name' <<<"$pods")
  [[ -z "$pods" ]] || die "$client pods still reference $ns/$pvc: $pods. Stop controllers and delete their stopped pods."
}
require_no_releases() {
  local config=$1 context=$2 ns=$3 releases
  # Explicit state flags work with Helm 3 and 4; filter before pagination.
  releases=$(python3 - "$config" "$context" "$ns" "$MIGRATION_ID" <<'PY_HELM'
import subprocess,sys
config,context,namespace,migration_id=sys.argv[1:]
try:
    subprocess.run(['helm','--kubeconfig',config,'--kube-context',context,'-n',namespace,
        'list','--deployed','--failed','--pending','--uninstalled','--superseded','--uninstalling',
        '--filter','^pv-migrate-'+migration_id+'-','--max','1','--output','json'],check=True,timeout=30)
except subprocess.TimeoutExpired:
    sys.exit('Helm release check exceeded 30 seconds')
except subprocess.CalledProcessError as exc:
    sys.exit(exc.returncode)
PY_HELM
  )
  jq -e --arg prefix "pv-migrate-$MIGRATION_ID-" '
    type == "array" and all(.[]; (.name | type == "string") and (.name | startswith($prefix) | not))
  ' <<<"$releases" >/dev/null || die "Existing or unreadable Helm releases for migration $MIGRATION_ID in $ns. Inspect before retrying."
}
load_claims() {
  SRC_PVC_JSON=$(get_json src -n "$SRC_NAMESPACE" pvc "$SRC_PVC")
  DST_PVC_JSON=$(get_json dst -n "$DST_NAMESPACE" pvc "$DST_PVC")
  SRC_PV_NAME=$(field '.spec.volumeName' <<<"$SRC_PVC_JSON")
  DST_PV_NAME=$(field '.spec.volumeName' <<<"$DST_PVC_JSON")
  SRC_PV_JSON=$(get_json src pv "$SRC_PV_NAME")
  DST_PV_JSON=$(get_json dst pv "$DST_PV_NAME")
}
validate_claim() {
  local pvc=$1 pv=$2 ns=$3 name=$4
  jq -e --argjson pvc "$pvc" --arg ns "$ns" --arg name "$name" '
    .spec.accessModes as $pvModes |
    $pvc.metadata.name == $name and $pvc.metadata.namespace == $ns and
    ($pvc.metadata.uid | type == "string" and length > 0) and $pvc.metadata.deletionTimestamp == null and
    $pvc.status.phase == "Bound" and ($pvc.spec.volumeMode // "Filesystem") == "Filesystem" and
    ($pvc.spec.accessModes | type == "array" and length > 0) and
    .metadata.name == $pvc.spec.volumeName and (.metadata.uid | type == "string" and length > 0) and
    .metadata.deletionTimestamp == null and .status.phase == "Bound" and
    (.spec.volumeMode // "Filesystem") == "Filesystem" and
    all($pvc.spec.accessModes[]; . as $mode | $pvModes | index($mode) != null) and
    (($pvc.status.conditions // []) | all(.[];
      (.type != "Resizing" and .type != "FileSystemResizePending") or .status != "True")) and
    .spec.claimRef.namespace == $ns and .spec.claimRef.name == $name and .spec.claimRef.uid == $pvc.metadata.uid
  ' <<<"$pv" >/dev/null || die "Invalid or changed Bound filesystem PVC/PV relationship for $ns/$name."
}
# Exact Decimal arithmetic supports Kubernetes binary/decimal SI and exponent quantities.
check_capacity() {
  python3 - "$1" "$2" <<'PY'
import decimal,re,sys
decimal.getcontext().prec=100
D=decimal.Decimal
def quantity(value):
    match=re.fullmatch(r'([+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))((?:[eE][+-]?[0-9]+)|(?:[KMGTPE]i)|[numkKMGTPE]?)',value)
    if not match: raise ValueError('unsupported Kubernetes storage quantity: '+value)
    number,suffix=match.groups()
    if suffix.endswith('i'): scale=D(1024)**('KMGTPE'.index(suffix[0])+1)
    elif suffix.startswith(('e','E')) and len(suffix)>1: scale=D(10)**int(suffix[1:])
    else: scale=D(10)**{'n':-9,'u':-6,'m':-3,'':0,'k':3,'K':3,'M':6,'G':9,'T':12,'P':15,'E':18}[suffix]
    result=D(number)*scale
    if not result.is_finite() or result<=0: raise ValueError('capacity must be positive')
    return result
try:
    source,destination=map(quantity,sys.argv[1:])
    if destination<source: raise ValueError('destination PV capacity is smaller than source PV capacity')
except (ValueError,decimal.DecimalException) as exc:
    print(str(exc),file=sys.stderr);sys.exit(1)
PY
}
claim_signature() {
  jq -Sc --argjson pvc "$1" '{pvcUID:$pvc.metadata.uid, pvUID:.metadata.uid, pv:.metadata.name,
    capacity:.spec.capacity.storage, claim:$pvc.spec.volumeName, modes:.spec.accessModes,
    pvcSpec:$pvc.spec, reportedCapacity:$pvc.status.capacity.storage,
    storage:(.spec | del(.claimRef,.persistentVolumeReclaimPolicy))}' <<<"$2"
}
validate_storage() {
  validate_claim "$SRC_PVC_JSON" "$SRC_PV_JSON" "$SRC_NAMESPACE" "$SRC_PVC"
  validate_claim "$DST_PVC_JSON" "$DST_PV_JSON" "$DST_NAMESPACE" "$DST_PVC"
  jq -e 'any(.spec.accessModes[]; . == "ReadWriteOnce" or . == "ReadWriteMany" or . == "ReadWriteOncePod")' <<<"$DST_PVC_JSON" >/dev/null || die 'Destination claim has no writable access mode.'
  SRC_SIZE=$(field '.spec.capacity.storage' <<<"$SRC_PV_JSON")
  DST_SIZE=$(field '.spec.capacity.storage' <<<"$DST_PV_JSON")
  check_capacity "$SRC_SIZE" "$DST_SIZE" || die 'Destination capacity check failed.'
  DST_FILESYSTEM_SIZE=$(field '.status.capacity.storage' <<<"$DST_PVC_JSON")
  check_capacity "$SRC_SIZE" "$DST_FILESYSTEM_SIZE" || die 'Destination PVC reported filesystem capacity is too small; complete expansion first.'
  jq -e --argjson dst "$DST_PV_JSON" '
    ((.spec.csi // null) == null or ($dst.spec.csi // null) == null or
      .spec.csi.driver != $dst.spec.csi.driver or .spec.csi.volumeHandle != $dst.spec.csi.volumeHandle) and
    ((.spec.nfs // null) == null or ($dst.spec.nfs // null) == null or
      .spec.nfs.server != $dst.spec.nfs.server or .spec.nfs.path != $dst.spec.nfs.path)
  ' <<<"$SRC_PV_JSON" >/dev/null || die 'Source and destination identify the same CSI/NFS backing volume.'
}
check_quiescence_and_releases() {
  require_no_pods src "$SRC_NAMESPACE" "$SRC_PVC"
  require_no_pods dst "$DST_NAMESPACE" "$DST_PVC"
  require_no_releases "$SRC_KUBECONFIG" "$SRC_CONTEXT" "$SRC_NAMESPACE"
  require_no_releases "$DST_KUBECONFIG" "$DST_CONTEXT" "$DST_NAMESPACE"
}
SRC_CLUSTER_UID=$(namespace_uid src kube-system)
DST_CLUSTER_UID=$(namespace_uid dst kube-system)
[[ "$SRC_CLUSTER_UID" != "$DST_CLUSTER_UID" ]] || die 'This cross-cluster example requires distinct source and destination Kubernetes APIs.'
SRC_NS_UID=$(namespace_uid src "$SRC_NAMESPACE")
DST_NS_UID=$(namespace_uid dst "$DST_NAMESPACE")
load_claims
validate_storage
SRC_SIGNATURE=$(claim_signature "$SRC_PVC_JSON" "$SRC_PV_JSON")
DST_SIGNATURE=$(claim_signature "$DST_PVC_JSON" "$DST_PV_JSON")
check_quiescence_and_releases
umask 077
if [[ -n "$OUTPUT_DIR" ]]; then mkdir -m 700 "$OUTPUT_DIR" || die 'OUTPUT_DIR must be a new directory.'
else OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pv-migrate-check.XXXXXX"); fi
save_claims() {
  printf '%s\n' "$SRC_PVC_JSON" > "$OUTPUT_DIR/source-pvc$1.json"
  printf '%s\n' "$SRC_PV_JSON" > "$OUTPUT_DIR/source-pv$1.json"
  printf '%s\n' "$DST_PVC_JSON" > "$OUTPUT_DIR/destination-pvc$1.json"
  printf '%s\n' "$DST_PV_JSON" > "$OUTPUT_DIR/destination-pv$1.json"
}
save_claims ''
printf '%s\n' "$PV_MIGRATE_VERSION" > "$OUTPUT_DIR/pv-migrate-version.txt"
printf '%s\n' "$MIGRATION_ID" > "$OUTPUT_DIR/migration-id.txt"
if [[ -n "${PV_MIGRATE_VALUES_FILE:-}" ]]; then
  cp "$PV_MIGRATE_VALUES_FILE" "$OUTPUT_DIR/helm-values.yaml"
  PV_MIGRATE_VALUES_FILE="$OUTPUT_DIR/helm-values.yaml"
fi
DST_PVC_UID=$(field '.metadata.uid' <<<"$DST_PVC_JSON")
printf '\nSource: %s / %s/%s (%s)\nDestination: %s / %s/%s (%s)\nDestination PVC UID: %s\nMigration ID: %s\nStrategies: %s\nEvidence: %s\n' \
  "$SRC_CONTEXT" "$SRC_NAMESPACE" "$SRC_PVC" "$SRC_SIZE" "$DST_CONTEXT" "$DST_NAMESPACE" "$DST_PVC" "$DST_SIZE" "$DST_PVC_UID" "$MIGRATION_ID" "$STRATEGIES" "$OUTPUT_DIR"
printf '%s\n' 'Confirm backups, stopped writers/controllers on both sides, network access and reviewed Helm values.'
printf 'Type the destination PVC UID above to authorize the final copy: '
IFS= read -r confirmation || die 'Confirmation was not received; no copy started.'
[[ "$confirmation" == "$DST_PVC_UID" ]] || die 'Confirmation did not match; no copy started.'
revalidate() {
  [[ "$(namespace_uid src kube-system)" == "$SRC_CLUSTER_UID" && "$(namespace_uid dst kube-system)" == "$DST_CLUSTER_UID" &&
     "$(namespace_uid src "$SRC_NAMESPACE")" == "$SRC_NS_UID" && "$(namespace_uid dst "$DST_NAMESPACE")" == "$DST_NS_UID" ]] || die 'Cluster or namespace identity changed.'
  load_claims
  validate_storage
  [[ "$(claim_signature "$SRC_PVC_JSON" "$SRC_PV_JSON")" == "$SRC_SIGNATURE" && "$(claim_signature "$DST_PVC_JSON" "$DST_PV_JSON")" == "$DST_SIGNATURE" ]] || die 'PVC/PV identity or storage configuration changed.'
}
STEP='pre-copy revalidation'
revalidate
check_quiescence_and_releases
save_claims ''
args=(--source-kubeconfig "$SRC_KUBECONFIG" --source-context "$SRC_CONTEXT" --source-namespace "$SRC_NAMESPACE" --source "$SRC_PVC"
  --dest-kubeconfig "$DST_KUBECONFIG" --dest-context "$DST_CONTEXT" --dest-namespace "$DST_NAMESPACE" --dest "$DST_PVC"
  --strategies "$STRATEGIES" --rsync-push --id "$MIGRATION_ID" --no-cleanup-on-failure
  --helm-timeout "$HELM_TIMEOUT" --loadbalancer-timeout "$LOADBALANCER_TIMEOUT")
[[ "$NON_ROOT" != yes ]] || args+=(--non-root)
[[ -z "${PV_MIGRATE_VALUES_FILE:-}" ]] || args+=(--helm-values "$PV_MIGRATE_VALUES_FILE")
printf '%q ' pv-migrate "${args[@]}" > "$OUTPUT_DIR/command.txt"
printf '\n' >> "$OUTPUT_DIR/command.txt"
STEP='final PVC copy'
# pipefail preserves a migration failure even when tee succeeds.
pv-migrate "${args[@]}" 2>&1 | tee "$OUTPUT_DIR/pv-migrate.log"
STEP='post-copy identity verification'
revalidate
save_claims '-after'
printf '\nCopy finished and PVC/PV identities remain unchanged. Evidence: %s\n' "$OUTPUT_DIR"
printf '%s\n' 'Data has NOT been validated. Compare checksums/application data before starting writers; retain the source and backups. Extraneous destination files were not deleted.'
