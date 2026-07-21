#!/usr/bin/env bash
set -euo pipefail

# Concise proof-of-concept for copying one PVC between clusters.
# It deliberately does not scale application workloads automatically.
# Set the environment variables below, quiesce the source application,
# then run:
#
#   ACK_FINAL_COPY=yes ./scripts/pv-migrate-poc.sh

: "${SRC_KUBECONFIG:?Set SRC_KUBECONFIG}"
: "${SRC_NAMESPACE:?Set SRC_NAMESPACE}"
: "${SRC_PVC:?Set SRC_PVC}"
: "${DST_KUBECONFIG:?Set DST_KUBECONFIG}"
: "${DST_NAMESPACE:?Set DST_NAMESPACE}"
: "${DST_PVC:?Set DST_PVC}"

SRC_CONTEXT="${SRC_CONTEXT:-}"
DST_CONTEXT="${DST_CONTEXT:-}"
MIGRATION_ID="${MIGRATION_ID:-vks-pvc-migration}"
STRATEGIES="${STRATEGIES:-loadbalancer}"
ACK_FINAL_COPY="${ACK_FINAL_COPY:-no}"

src=(kubectl --kubeconfig "$SRC_KUBECONFIG")
dst=(kubectl --kubeconfig "$DST_KUBECONFIG")
[[ -z "$SRC_CONTEXT" ]] || src+=(--context "$SRC_CONTEXT")
[[ -z "$DST_CONTEXT" ]] || dst+=(--context "$DST_CONTEXT")

command -v kubectl >/dev/null
command -v pv-migrate >/dev/null

echo "Source PVC:"
"${src[@]}" -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" -o wide

echo "Destination PVC:"
"${dst[@]}" -n "$DST_NAMESPACE" get pvc "$DST_PVC" -o wide

src_mode=$("${src[@]}" -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.spec.volumeMode}')
dst_mode=$("${dst[@]}" -n "$DST_NAMESPACE" get pvc "$DST_PVC" \
  -o jsonpath='{.spec.volumeMode}')

src_mode="${src_mode:-Filesystem}"
dst_mode="${dst_mode:-Filesystem}"

if [[ "$src_mode" != "Filesystem" || "$dst_mode" != "Filesystem" ]]; then
  echo "ERROR: this example supports Filesystem PVCs only." >&2
  exit 1
fi

if [[ "$ACK_FINAL_COPY" != "yes" ]]; then
  cat >&2 <<'EOF'
ERROR: source writers must be stopped before the final copy.
After quiescing the application, rerun with ACK_FINAL_COPY=yes.
EOF
  exit 1
fi

args=(
  --source-kubeconfig "$SRC_KUBECONFIG"
  --source-namespace "$SRC_NAMESPACE"
  --source "$SRC_PVC"
  --dest-kubeconfig "$DST_KUBECONFIG"
  --dest-namespace "$DST_NAMESPACE"
  --dest "$DST_PVC"
  --strategies "$STRATEGIES"
  --rsync-push
  --id "$MIGRATION_ID"
  --no-cleanup-on-failure
)

[[ -z "$SRC_CONTEXT" ]] || args+=(--source-context "$SRC_CONTEXT")
[[ -z "$DST_CONTEXT" ]] || args+=(--dest-context "$DST_CONTEXT")

echo "Starting final PVC copy..."
pv-migrate "${args[@]}"

echo "Copy completed. Validate data before starting the destination workload."
