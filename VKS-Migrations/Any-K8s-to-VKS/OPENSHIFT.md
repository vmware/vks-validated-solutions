# OpenShift considerations

## Why OpenShift can require additional privileges

`pv-migrate` mounts the source PVC into a temporary rsync pod. On OpenShift, the default Security Context Constraints commonly allocate an arbitrary non-root UID.

This works when all source files are readable by that UID. It can fail when:

- Files are owned by `root`
- Directories do not grant traverse permission
- Ownership must be preserved
- The storage plugin exposes restrictive permissions

Typical rsync symptoms include:

```text
Permission denied
rsync error: some files/attrs were not transferred
rsync exit code 23
```

## Start with non-root mode

Test:

```bash
pv-migrate ... --non-root
```

Non-root mode intentionally does not preserve owner, group or directory timestamps. It is unsuitable when those attributes are required by the application.

## Validated root-capable approach

For root-owned source data, the temporary source rsync workload may require UID 0 and an SCC that permits it.

Create a dedicated ServiceAccount in the source namespace:

```bash
oc -n "$SRC_NAMESPACE" create serviceaccount pv-migrate
```

Grant the narrowest SCC that supports the generated pod. In a lab, the validated proof of concept used `privileged`:

```bash
oc adm policy add-scc-to-user privileged \
  -z pv-migrate \
  -n "$SRC_NAMESPACE"
```

> [!CAUTION]
> `privileged` is a broad permission. Use it only for a dedicated temporary ServiceAccount and remove it immediately after migration.

The exact `pv-migrate` Helm value names can change between releases. Before relying on an override file:

```bash
pv-migrate version
pv-migrate --help
```

Run a non-destructive test and inspect the generated or failed temporary resources:

```bash
kubectl -n "$SRC_NAMESPACE" get pod,job,serviceaccount
kubectl -n "$SRC_NAMESPACE" get pod <pod> -o yaml
```

Set the generated rsync pod to use the dedicated ServiceAccount and required security context using the Helm overrides supported by the installed `pv-migrate` release.

After the migration:

```bash
oc adm policy remove-scc-from-user privileged \
  -z pv-migrate \
  -n "$SRC_NAMESPACE"

oc -n "$SRC_NAMESPACE" delete serviceaccount pv-migrate
```

## Network direction

Using `--rsync-push` means:

- The destination VKS cluster exposes the SSH endpoint.
- The source OpenShift rsync pod initiates the connection.
- The source cluster does not need an inbound LoadBalancer for migration traffic.

Check reachability from OpenShift to the destination LoadBalancer, including firewall policy and NetworkPolicy.

## SELinux

Do not disable SELinux as a migration workaround. Use the CSI driver's supported mount behaviour and an appropriate SCC. If SELinux denials are suspected, inspect platform audit logs and confirm the volume type and mount labels with the OpenShift administrator.
