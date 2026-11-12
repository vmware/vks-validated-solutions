# Step 0: Obtain the Supervisor and VKS kubeconfigs

Start with the shared [login and kubeconfig export procedure](../../README.md#obtain-supervisor-and-vks-kubeconfigs). It covers endpoint discovery, VCF 9 and vSphere 8 login, selecting a context, and exporting a private file containing that context. Run it once for each required file below; set `OUTPUT_KUBECONFIG` to the listed path. Select contexts from the CLI output rather than guessing their names.

The VKS login needs its **hosting Supervisor namespace**. This is separate from the application namespace inside VKS, even when both are named `default`.

## Same Supervisor: Examples 1 and 2

| Exported context | `OUTPUT_KUBECONFIG` | Variable used by the walkthrough |
|---|---|---|
| Source VKS cluster | `"$HOME/source-vks-kubeconfig"` | `SRC_VKS_KUBECONFIG` |
| Destination VKS cluster | `"$HOME/destination-vks-kubeconfig"` | `DST_VKS_KUBECONFIG` |
| Shared Supervisor | `"$HOME/supervisor-kubeconfig"` | `SUPERVISOR_KUBECONFIG` |

For Example 2, the Supervisor identity must have the required permissions in **both** hosting namespaces. A context's default namespace does not grant permissions; the walkthrough passes `-n` explicitly.

After exporting, set the same paths used in the walkthrough and verify them:

```bash
export SRC_VKS_KUBECONFIG="$HOME/source-vks-kubeconfig"
export DST_VKS_KUBECONFIG="$HOME/destination-vks-kubeconfig"
export SUPERVISOR_KUBECONFIG="$HOME/supervisor-kubeconfig"
export SRC_SUP_NS=migration-source       # Replace with the source hosting namespace.
export DST_SUP_NS="$SRC_SUP_NS"          # Example 2: use the other hosting namespace.

kubectl --kubeconfig="$SRC_VKS_KUBECONFIG" get pvc -n default
kubectl --kubeconfig="$DST_VKS_KUBECONFIG" get pvc -n default
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" get clusters.cluster.x-k8s.io -n "$SRC_SUP_NS"
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" get clusters.cluster.x-k8s.io -n "$DST_SUP_NS"
kubectl --kubeconfig="$SUPERVISOR_KUBECONFIG" auth can-i get persistentvolumes
```

An empty PVC list is valid. Check that the Supervisor cluster lists contain the intended source and destination VKS clusters. These read checks do not replace the migration permissions listed in each example. Continue with [Example 1](1-same-supervisor-and-namespace.md) or [Example 2](2-same-supervisor-different-namespace.md).

## Different Supervisors: Example 3

Use the source Supervisor endpoint for the source pair and the destination Supervisor endpoint for the destination pair. Export the two VKS files above, plus:

| Exported context | `OUTPUT_KUBECONFIG` | Variable used by the walkthrough |
|---|---|---|
| Source Supervisor | `"$HOME/source-supervisor-kubeconfig"` | `SRC_SUP_KUBECONFIG` |
| Destination Supervisor | `"$HOME/destination-supervisor-kubeconfig"` | `DST_SUP_KUBECONFIG` |

```bash
export SRC_VKS_KUBECONFIG="$HOME/source-vks-kubeconfig"
export DST_VKS_KUBECONFIG="$HOME/destination-vks-kubeconfig"
export SRC_SUP_KUBECONFIG="$HOME/source-supervisor-kubeconfig"
export DST_SUP_KUBECONFIG="$HOME/destination-supervisor-kubeconfig"
export SRC_SUP_NS=migration-target      # Replace with the source hosting namespace.
export DST_SUP_NS=migration-test        # Replace with the destination hosting namespace.

kubectl --kubeconfig="$SRC_SUP_KUBECONFIG" get clusters.cluster.x-k8s.io -n "$SRC_SUP_NS"
kubectl --kubeconfig="$DST_SUP_KUBECONFIG" get clusters.cluster.x-k8s.io -n "$DST_SUP_NS"
kubectl --kubeconfig="$SRC_VKS_KUBECONFIG" get pvc -n default
kubectl --kubeconfig="$DST_VKS_KUBECONFIG" get pvc -n default
```

Continue with [Example 3](3-across-supervisors-and-vcenters.md). Preserve these four paths when configuring it; source and destination VKS files must identify different workload clusters.
