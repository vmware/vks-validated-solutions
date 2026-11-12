# Step 0: Obtain the source and destination kubeconfigs

This method needs a source Kubernetes kubeconfig and a destination **VKS** kubeconfig. The `pv-migrate` copy does not use a Supervisor kubeconfig. Supervisor login may still be needed to obtain VKS access.

1. Authenticate to the source using its platform's supported login procedure (for OpenShift, use `oc login`) or obtain a kubeconfig from its administrator. Follow [export an existing source context](../../README.md#export-an-existing-source-context), selecting the source cluster and writing `"$HOME/openshift-kubeconfig"`.
2. Follow [obtain Supervisor and VKS kubeconfigs](../../README.md#obtain-supervisor-and-vks-kubeconfigs) for the destination. Log in using the destination Supervisor endpoint, the **hosting Supervisor namespace**, and the VKS cluster name. Export the **VKS context** with `OUTPUT_KUBECONFIG="$HOME/vks-kubeconfig"`.

These filenames match the OpenShift [worked example](../examples.md); other source platforms can use a different source filename consistently.

```bash
export SRC_KUBECONFIG="$HOME/openshift-kubeconfig"
export DST_KUBECONFIG="$HOME/vks-kubeconfig"
export SRC_CONTEXT=""    # Each exported file has one selected context.
export DST_CONTEXT=""
export SRC_NAMESPACE=my-application    # Replace with the source application namespace.
export DST_NAMESPACE=my-application    # Destination application namespace inside VKS.

kubectl --kubeconfig="$SRC_KUBECONFIG" config get-contexts
kubectl --kubeconfig="$DST_KUBECONFIG" config get-contexts
kubectl --kubeconfig="$SRC_KUBECONFIG" get pvc -n "$SRC_NAMESPACE"
kubectl --kubeconfig="$DST_KUBECONFIG" get storageclass
kubectl --kubeconfig="$DST_KUBECONFIG" auth can-i create pods -n "$DST_NAMESPACE"
kubectl --kubeconfig="$DST_KUBECONFIG" auth can-i create persistentvolumeclaims -n "$DST_NAMESPACE"
```

Verify the intended source PVC and destination StorageClass. Resolve any access failures before continuing with the [worked example](../examples.md). The authorization checks are representative; the workflow also needs permissions for its temporary migration resources and Velero operations. Create the destination application namespace in the preparation step if it does not yet exist.
