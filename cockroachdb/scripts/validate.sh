#!/usr/bin/env bash
# validate.sh — post-deployment validation for CockroachDB on VKS
#
# Run with kubectl context set to the WORKLOAD cluster (cluster-vks).
# Checks node readiness, rack topology labels, storage class configuration,
# and (if deployed) CockroachDB pod health and rack distribution.
#
# Usage: ./validate.sh

set -uo pipefail

PASS=0
FAIL=0
STORAGE_CLASS="vsan-esa-default-policy-raid5"
RACKS=(rack1 rack2 rack3)

ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$1"; }

echo "== CockroachDB on VKS — deployment validation =="
echo "Context: $(kubectl config current-context 2>/dev/null || echo 'none')"
echo

# ------------------------------------------------------------------
echo "-- 1. Node readiness"
# ------------------------------------------------------------------
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERROR: cannot reach the cluster. Check your kubectl context." >&2
    exit 2
fi

NOT_READY=$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l | tr -d ' ')
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
if [ "$NOT_READY" -eq 0 ]; then
    ok "All ${TOTAL_NODES} nodes Ready"
else
    bad "${NOT_READY} of ${TOTAL_NODES} node(s) not Ready"
fi

# ------------------------------------------------------------------
echo "-- 2. Rack topology labels (fault domains)"
# ------------------------------------------------------------------
for rack in "${RACKS[@]}"; do
    COUNT=$(kubectl get nodes -l "topology.kubernetes.io/region=${rack}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$COUNT" -ge 1 ]; then
        ok "${rack}: ${COUNT} node(s) labeled"
    else
        bad "${rack}: no nodes carry topology.kubernetes.io/region=${rack}"
    fi
done

UNLABELED=$(kubectl get nodes --no-headers \
    -o custom-columns='NAME:.metadata.name,REGION:.metadata.labels.topology\.kubernetes\.io/region' \
    | awk '$2 == "<none>"' | grep -vc 'control-plane' || true)
WORKER_UNLABELED=$(kubectl get nodes --no-headers \
    -l '!node-role.kubernetes.io/control-plane' \
    -o custom-columns='NAME:.metadata.name,REGION:.metadata.labels.topology\.kubernetes\.io/region' \
    | awk '$2 == "<none>"' | wc -l | tr -d ' ')
if [ "$WORKER_UNLABELED" -eq 0 ]; then
    ok "All worker nodes carry a region label"
else
    bad "${WORKER_UNLABELED} worker node(s) missing a region label"
fi

# ------------------------------------------------------------------
echo "-- 3. Storage class"
# ------------------------------------------------------------------
if kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
    ok "StorageClass ${STORAGE_CLASS} exists"
    IS_DEFAULT=$(kubectl get storageclass "$STORAGE_CLASS" \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)
    if [ "$IS_DEFAULT" = "true" ]; then
        ok "${STORAGE_CLASS} is the default StorageClass"
    else
        bad "${STORAGE_CLASS} is not marked default (check vsphereOptions.persistentVolumes.defaultStorageClass)"
    fi
else
    bad "StorageClass ${STORAGE_CLASS} not found"
fi

# ------------------------------------------------------------------
echo "-- 4. CockroachDB workload (optional)"
# ------------------------------------------------------------------
CRDB_PODS=$(kubectl get pods -A \
    -l 'app.kubernetes.io/name in (cockroachdb, cockroach)' \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$CRDB_PODS" -eq 0 ]; then
    skip "No CockroachDB pods found — deploy CockroachDB, then re-run for workload checks"
else
    NOT_RUNNING=$(kubectl get pods -A \
        -l 'app.kubernetes.io/name in (cockroachdb, cockroach)' \
        --no-headers | awk '$4 != "Running"' | wc -l | tr -d ' ')
    if [ "$NOT_RUNNING" -eq 0 ]; then
        ok "All ${CRDB_PODS} CockroachDB pod(s) Running"
    else
        bad "${NOT_RUNNING} of ${CRDB_PODS} CockroachDB pod(s) not Running"
    fi

    # Verify pods are spread across all three racks
    for rack in "${RACKS[@]}"; do
        RACK_NODES=$(kubectl get nodes -l "topology.kubernetes.io/region=${rack}" \
            --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)
        RACK_PODS=0
        for node in $RACK_NODES; do
            N=$(kubectl get pods -A \
                -l 'app.kubernetes.io/name in (cockroachdb, cockroach)' \
                --field-selector "spec.nodeName=${node}" \
                --no-headers 2>/dev/null | wc -l | tr -d ' ')
            RACK_PODS=$((RACK_PODS + N))
        done
        if [ "$RACK_PODS" -ge 1 ]; then
            ok "${rack}: ${RACK_PODS} CockroachDB pod(s)"
        else
            bad "${rack}: no CockroachDB pods scheduled (replica placement not rack-balanced)"
        fi
    done
fi

# ------------------------------------------------------------------
echo
echo "== Result: ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ] || exit 1
