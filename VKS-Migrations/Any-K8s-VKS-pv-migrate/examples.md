# Worked Example: OpenShift to VKS using pv-migrate

This example copies data from an OpenShift PVC to a VKS PVC and uses Velero for application metadata.

The commands are intentionally explicit. Replace every value in the configuration section before running them.

## 1. Prerequisites

Install locally:

- `kubectl`
- `oc`
- `velero`
- `pv-migrate`
- `helm`

Confirm access to both clusters:

```bash
oc --kubeconfig "$SRC_KUBECONFIG" whoami
kubectl --kubeconfig "$DST_KUBECONFIG" auth can-i create pods -n "$DST_NAMESPACE"
pv-migrate version
```

The destination VKS cluster must provide a LoadBalancer implementation reachable from the source cluster when using the `loadbalancer` strategy.

## 2. Configure the migration

```bash
export SRC_KUBECONFIG="$HOME/openshift-kubeconfig"
export SRC_CONTEXT=""
export SRC_NAMESPACE="my-application"
export SRC_PVC="app-data"

export DST_KUBECONFIG="$HOME/vks-kubeconfig"
export DST_CONTEXT=""
export DST_NAMESPACE="my-application"
export DST_PVC="app-data"
export DST_STORAGE_CLASS="vsan-esa-default-policy-raid5"
export DST_PVC_SIZE="100Gi"

export BACKUP_NAME="my-application-pre-migration"
export RESTORE_NAME="my-application-to-vks"
export MIGRATION_ID="my-application-data"
```

Convenience wrappers:

```bash
src() {
  kubectl --kubeconfig "$SRC_KUBECONFIG" \
    ${SRC_CONTEXT:+--context "$SRC_CONTEXT"} "$@"
}

dst() {
  kubectl --kubeconfig "$DST_KUBECONFIG" \
    ${DST_CONTEXT:+--context "$DST_CONTEXT"} "$@"
}
```

## 3. Discover the source volume

```bash
src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" -o wide
```

Capture important fields:

```bash
SRC_PV=$(src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.spec.volumeName}')

SRC_SIZE=$(src get pv "$SRC_PV" \
  -o jsonpath='{.spec.capacity.storage}')

SRC_ACCESS_MODE=$(src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.spec.accessModes[0]}')

SRC_VOLUME_MODE=$(src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.spec.volumeMode}')

SRC_STORAGE_CLASS=$(src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.spec.storageClassName}')

printf 'PV: %s\nSize: %s\nAccess mode: %s\nVolume mode: %s\nStorageClass: %s\n' \
  "$SRC_PV" "$SRC_SIZE" "$SRC_ACCESS_MODE" \
  "${SRC_VOLUME_MODE:-Filesystem}" "$SRC_STORAGE_CLASS"
```

Save the complete PVC definition for reference:

```bash
src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" -o yaml \
  > "${SRC_NAMESPACE}-${SRC_PVC}-source.yaml"
```

Record portable metadata:

```bash
src -n "$SRC_NAMESPACE" get pvc "$SRC_PVC" \
  -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
```

Do not copy binding annotations such as:

- `pv.kubernetes.io/bind-completed`
- `pv.kubernetes.io/bound-by-controller`
- `volume.kubernetes.io/storage-provisioner`
- `volume.beta.kubernetes.io/storage-provisioner`

## 4. Identify workloads mounting the PVC

```bash
src -n "$SRC_NAMESPACE" get pods -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}
{range .spec.volumes[*]}
{.persistentVolumeClaim.claimName}{" "}
{end}{"\n"}
{end}' | grep -w "$SRC_PVC" || true
```

Record the owning workload:

```bash
src -n "$SRC_NAMESPACE" get deploy,statefulset -o wide
```

For Helm-managed applications:

```bash
helm --kubeconfig "$SRC_KUBECONFIG" \
  ${SRC_CONTEXT:+--kube-context "$SRC_CONTEXT"} \
  -n "$SRC_NAMESPACE" list

helm --kubeconfig "$SRC_KUBECONFIG" \
  ${SRC_CONTEXT:+--kube-context "$SRC_CONTEXT"} \
  -n "$SRC_NAMESPACE" get values <release-name> -a \
  > <release-name>-values.yaml
```

## 5. Create the destination namespace and PVC

```bash
dst create namespace "$DST_NAMESPACE" \
  --dry-run=client -o yaml | dst apply -f -
```

Create the PVC:

```bash
cat <<EOF | dst apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DST_PVC}
  namespace: ${DST_NAMESPACE}
spec:
  accessModes:
    - ${SRC_ACCESS_MODE}
  volumeMode: ${SRC_VOLUME_MODE:-Filesystem}
  storageClassName: ${DST_STORAGE_CLASS}
  resources:
    requests:
      storage: ${DST_PVC_SIZE}
EOF
```

Wait for it to bind:

```bash
dst -n "$DST_NAMESPACE" wait \
  --for=jsonpath='{.status.phase}'=Bound \
  "pvc/${DST_PVC}" \
  --timeout=5m
```

Check the destination:

```bash
dst -n "$DST_NAMESPACE" get pvc "$DST_PVC" -o wide
```

## 6. Capture application metadata with Velero

The following command runs against whichever cluster is currently selected by the Velero client. Set the source context first or use your organisation's standard Velero workflow.

```bash
kubectl config use-context "<source-context>"
```

Create a manifests-only backup:

```bash
velero backup create "$BACKUP_NAME" \
  --include-namespaces "$SRC_NAMESPACE" \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait
```

Inspect it:

```bash
velero backup describe "$BACKUP_NAME" --details
velero backup logs "$BACKUP_NAME"
```

Do not proceed until the backup is `Completed` and any warnings have been reviewed.

## 7. Optional initial copy

An initial copy reduces final cutover time. The application may remain online only when a live filesystem copy is acceptable.

```bash
pv-migrate \
  --source-kubeconfig "$SRC_KUBECONFIG" \
  ${SRC_CONTEXT:+--source-context "$SRC_CONTEXT"} \
  --source-namespace "$SRC_NAMESPACE" \
  --source "$SRC_PVC" \
  --dest-kubeconfig "$DST_KUBECONFIG" \
  ${DST_CONTEXT:+--dest-context "$DST_CONTEXT"} \
  --dest-namespace "$DST_NAMESPACE" \
  --dest "$DST_PVC" \
  --strategies loadbalancer \
  --rsync-push \
  --id "${MIGRATION_ID}-initial" \
  --no-cleanup-on-failure
```

For a first test, omit `--dest-delete-extraneous-files`. This prevents an unexpected source path or partial source mount from deleting valid destination content.

## 8. Quiesce the source application

Use the application's supported shutdown procedure.

For a Deployment:

```bash
src -n "$SRC_NAMESPACE" scale deployment/<deployment-name> --replicas=0
src -n "$SRC_NAMESPACE" rollout status deployment/<deployment-name> \
  --timeout=5m || true
```

For a StatefulSet:

```bash
src -n "$SRC_NAMESPACE" scale statefulset/<statefulset-name> --replicas=0
```

Confirm no remaining pod mounts the PVC:

```bash
src -n "$SRC_NAMESPACE" get pods -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}
{range .spec.volumes[*]}
{.persistentVolumeClaim.claimName}{" "}
{end}{"\n"}
{end}' | grep -w "$SRC_PVC" || true
```

The final command should return no application pod.

## 9. Run the final copy

```bash
pv-migrate \
  --source-kubeconfig "$SRC_KUBECONFIG" \
  ${SRC_CONTEXT:+--source-context "$SRC_CONTEXT"} \
  --source-namespace "$SRC_NAMESPACE" \
  --source "$SRC_PVC" \
  --dest-kubeconfig "$DST_KUBECONFIG" \
  ${DST_CONTEXT:+--dest-context "$DST_CONTEXT"} \
  --dest-namespace "$DST_NAMESPACE" \
  --dest "$DST_PVC" \
  --strategies loadbalancer \
  --rsync-push \
  --id "${MIGRATION_ID}-final" \
  --no-cleanup-on-failure
```

Use `--dest-delete-extraneous-files` for the final copy only when the destination must be an exact mirror and the source and destination paths have been verified.

## 10. Validate the copied data

Create temporary reader pods.

Source:

```bash
cat <<EOF | src apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: migration-source-reader
  namespace: ${SRC_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${SRC_PVC}
EOF
```

Destination:

```bash
cat <<EOF | dst apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: migration-destination-reader
  namespace: ${DST_NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${DST_PVC}
EOF
```

Wait for both:

```bash
src -n "$SRC_NAMESPACE" wait --for=condition=Ready \
  pod/migration-source-reader --timeout=5m

dst -n "$DST_NAMESPACE" wait --for=condition=Ready \
  pod/migration-destination-reader --timeout=5m
```

Compare representative checks:

```bash
src -n "$SRC_NAMESPACE" exec migration-source-reader -- \
  sh -c 'find /data -xdev -type f | wc -l'

dst -n "$DST_NAMESPACE" exec migration-destination-reader -- \
  sh -c 'find /data -xdev -type f | wc -l'
```

For a manageable dataset, create sorted checksums:

```bash
src -n "$SRC_NAMESPACE" exec migration-source-reader -- \
  sh -c 'cd /data && find . -xdev -type f -exec sha256sum {} + | sort' \
  > source.sha256

dst -n "$DST_NAMESPACE" exec migration-destination-reader -- \
  sh -c 'cd /data && find . -xdev -type f -exec sha256sum {} + | sort' \
  > destination.sha256

diff -u source.sha256 destination.sha256
```

For large datasets, use application-native integrity checks or a representative checksum strategy rather than hashing every file during a constrained outage.

Remove the readers:

```bash
src -n "$SRC_NAMESPACE" delete pod migration-source-reader
dst -n "$DST_NAMESPACE" delete pod migration-destination-reader
```

## 11. Restore or reconstruct the destination application

Restore metadata without storage resources:

```bash
kubectl config use-context "<destination-context>"

velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --namespace-mappings "${SRC_NAMESPACE}:${DST_NAMESPACE}" \
  --exclude-resources \
persistentvolumes,persistentvolumeclaims,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
  --wait
```

Inspect:

```bash
velero restore describe "$RESTORE_NAME" --details
velero restore logs "$RESTORE_NAME"
```

Alternatively, reinstall the Helm release using the recorded chart version and values. Ensure the chart references the pre-created destination PVC.

## 12. Start and validate the destination application

```bash
dst -n "$DST_NAMESPACE" get deploy,statefulset,pods,pvc
```

Scale the destination workload:

```bash
dst -n "$DST_NAMESPACE" scale deployment/<deployment-name> --replicas=<replicas>
```

Validate:

- Pod readiness
- Application logs
- Database or application integrity
- Service endpoints
- Ingress or Route translation
- Authentication and secrets
- Read/write behaviour
- Scheduled jobs and external integrations

## 13. Rollback

Before traffic is redirected, rollback is simply to leave the source application stopped or restart it.

After traffic has reached the destination, establish whether destination writes need to be copied back before rollback. This example does not implement reverse synchronisation automatically.

Restart the source only after preventing split-brain or simultaneous writers.

## 14. Cleanup

Clean failed detached operations if used:

```bash
pv-migrate cleanup "${MIGRATION_ID}-initial" \
  --kubeconfig "$DST_KUBECONFIG" || true

pv-migrate cleanup "${MIGRATION_ID}-final" \
  --kubeconfig "$DST_KUBECONFIG" || true
```

Remove temporary SCC grants and migration-only network rules. Retain the source PVC according to the rollback and retention plan.
