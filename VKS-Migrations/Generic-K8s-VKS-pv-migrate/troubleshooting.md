# Troubleshooting

## Destination PVC remains Pending

Check:

```bash
kubectl --kubeconfig "$DST_KUBECONFIG" \
  -n "$DST_NAMESPACE" describe pvc "$DST_PVC"

kubectl --kubeconfig "$DST_KUBECONFIG" get storageclass
kubectl --kubeconfig "$DST_KUBECONFIG" get events \
  -n "$DST_NAMESPACE" --sort-by=.lastTimestamp
```

Common causes:

- Invalid VKS StorageClass
- Insufficient ResourceQuota
- Topology or policy incompatibility
- `WaitForFirstConsumer` binding behaviour
- Requested size unavailable

## LoadBalancer strategy times out

Inspect the temporary Service:

```bash
kubectl --kubeconfig "$DST_KUBECONFIG" \
  -n "$DST_NAMESPACE" get service -w
```

Check:

- Load balancer implementation is installed
- An address has been allocated
- The address is routable from the source
- Firewall and NetworkPolicy permit the generated port
- DNS or host override is not resolving to an unreachable address

Increase the wait if allocation is slow:

```bash
pv-migrate ... --loadbalancer-timeout 10m
```

## rsync exits with code 23

This normally means that some files or attributes could not be transferred.

Inspect the source rsync pod logs and file permissions. On OpenShift, root-owned files may require a dedicated SCC and root-capable migration pod. See [`OPENSHIFT.md`](OPENSHIFT.md).

Do not treat code 23 as success without reviewing exactly what was omitted.

## Source or destination PVC is mounted

`pv-migrate` fails safely when it detects mounted PVCs.

Quiesce the application and remove the mounting pod. Avoid `--ignore-mounted` during the final migration unless the application-specific consistency implications have been accepted.

## Destination contains unexpected files

A dynamically provisioned filesystem may contain provider-created directories such as `lost+found`.

Decide whether these are expected. Do not use `--dest-delete-extraneous-files` until source and destination paths are verified.

## Ownership differs after migration

Possible causes:

- `--non-root`
- `--no-chown`
- Destination filesystem limitations
- SCC or Pod Security restrictions
- NFS root-squash
- Different application UID/GID model on VKS

Compare:

```bash
kubectl exec <reader-pod> -- find /data -maxdepth 2 -printf '%u:%g %m %p\n'
```

## The application starts before data is ready

Keep destination workloads scaled to zero during restore, or use a Velero restore resource modifier. Confirm the destination PVC contains validated data before scaling up.

## Migration resources remain after a failure

Use:

```bash
pv-migrate ... --no-cleanup-on-failure
```

to preserve resources for inspection, then:

```bash
kubectl get all,secret,serviceaccount -A \
  -l app.kubernetes.io/part-of=pv-migrate
```

Clean up only after collecting logs:

```bash
pv-migrate cleanup <operation-id> \
  --kubeconfig "$DST_KUBECONFIG"
```

## Transfer is slow

Check:

- Source and destination storage latency
- Number of small files
- Cross-site bandwidth and packet loss
- CPU limits on rsync/sshd pods
- Compression overhead

For already-compressed or high-speed LAN data, test `--no-compress`. For controlled testing, `--rsync-extra-args` can pass rsync options, but validate them carefully.

## Backup restores storage objects unexpectedly

Confirm the backup and restore both exclude:

```text
persistentvolumes
persistentvolumeclaims
volumesnapshots.snapshot.storage.k8s.io
volumesnapshotcontents.snapshot.storage.k8s.io
```

Inspect:

```bash
velero backup describe "$BACKUP_NAME" --details
velero restore describe "$RESTORE_NAME" --details
```
