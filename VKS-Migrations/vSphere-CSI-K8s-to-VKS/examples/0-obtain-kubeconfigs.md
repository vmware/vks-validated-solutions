# Step 0: Obtain the source, Supervisor and VKS kubeconfigs

FCD adoption uses three Kubernetes APIs. The **Supervisor** creates `CnsRegisterVolume` and its PVC/PV; the destination **VKS cluster** hosts the application. Export a separate file for each API.

| Access | How to obtain it | Output path / walkthrough variable |
|---|---|---|
| Source Kubernetes/OpenShift | Authenticate with the source platform's supported CLI or administrator-provided kubeconfig; [export the source context](../../README.md#export-an-existing-source-context) | `"$HOME/ocp-kubeconfig"` / `OCP_KUBECONFIG` |
| Destination Supervisor | Follow the shared [Supervisor login and export](../../README.md#obtain-supervisor-and-vks-kubeconfigs) procedure | `"$HOME/supervisor-kubeconfig"` / `SUPERVISOR_KUBECONFIG` |
| Destination VKS | Follow the shared VKS login and export procedure, using its Supervisor endpoint, hosting namespace and cluster name | `"$HOME/vks-kubeconfig"` / `VKS_KUBECONFIG` |

Set `OUTPUT_KUBECONFIG` to the appropriate path for each export. Select the exact context from the login output. For OpenShift, authenticate with `oc login` before exporting. An upstream Kubernetes source uses its own authenticated context; `OCP_KUBECONFIG` is the variable name used by this repository's OpenShift walkthrough and script.

```bash
export OCP_KUBECONFIG="$HOME/ocp-kubeconfig"
export SUPERVISOR_KUBECONFIG="$HOME/supervisor-kubeconfig"
export VKS_KUBECONFIG="$HOME/vks-kubeconfig"
export SOURCE_NS=default                 # Source application namespace.
export TARGET_NS=migration-target        # Application namespace inside destination VKS.
export SUPERVISOR_NS=migration-target    # Hosting Supervisor namespace; verify separately.

kubectl --kubeconfig="$OCP_KUBECONFIG" get pvc -n "$SOURCE_NS"
kubectl --kubeconfig="$VKS_KUBECONFIG" get storageclass
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" get clusters.cluster.x-k8s.io -n "$SUPERVISOR_NS"
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" auth can-i get persistentvolumes
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" auth can-i create cnsregistervolumes.cns.vmware.com -n "$SUPERVISOR_NS"
kubectl --kubeconfig="$VKS_KUBECONFIG" auth can-i create persistentvolumes
kubectl --kubeconfig="$VKS_KUBECONFIG" auth can-i create persistentvolumeclaims -n "$TARGET_NS"
```

The application and Supervisor namespaces are independent even when their names match. Resolve failed access checks with the relevant administrator; exporting a kubeconfig does not add permissions. Continue with the [OpenShift-to-VKS example](../OCP-VKS-migration-example.md), which lists the remaining migration prerequisites.
