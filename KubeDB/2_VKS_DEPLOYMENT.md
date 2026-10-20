# VKS Deployment
## Versions
* vSphere Kubernetes Service 3.7 / VKr v1.36.2+vmware.2-vkr.3

## References
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)

## Requirements
### CLI Tools
See [client-vm-configuration.md](client-vm-configuration.md).
* kubectl v1.35 or later (within the supported version skew of the v1.36 cluster)
* vcf cli v9.0

### Required vSphere Steps
Complete [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md):
1. Supervisor namespace `kubedb-prod`
2. Storage policy `vsan-esa-default-policy-raid5`
3. VM classes `guaranteed-large` and `best-effort-2xlarge`

**Note**: If you use different names, storage policies, or VM classes, update [manifests/vks.yaml](manifests/vks.yaml).

## Deployment Procedure

### 1. Set environment variables
```bash
# Update with correct values
export SUPERVISOR_IP="<supervisor_ip>"
export SUPERVISOR_USERNAME="<username>"
export SUPERVISOR_NAMESPACE_NAME="kubedb-prod"
export SUPERVISOR_CONTEXT="kubedb-sv"
export CLUSTER_NAME="kubedb-vks-01"
```
<br>
<br>

### 2. Create and use the Supervisor context
```bash
vcf context create "$SUPERVISOR_CONTEXT" \
  --endpoint "$SUPERVISOR_IP" \
  --username "$SUPERVISOR_USERNAME"

vcf context use "$SUPERVISOR_CONTEXT":"$SUPERVISOR_NAMESPACE_NAME"
```
<br>
<br>

### 3. Create the VKS cluster
[manifests/vks.yaml](manifests/vks.yaml) defines three control plane nodes (guaranteed-large) and three workers (best-effort-2xlarge, 800Gi containerd volume) on vSAN ESA RAID-5, with the baseline Pod Security Standard.
```bash
sed -e "s/kubedb-vks-01/$CLUSTER_NAME/" -e "s/kubedb-prod/$SUPERVISOR_NAMESPACE_NAME/" manifests/vks.yaml \
  | kubectl apply -f -
```
<details>
<summary>Expected output</summary>

```shell
cluster.cluster.x-k8s.io/kubedb-vks-01 created
```
</details>
<br>
<br>

### 4. Wait for the VKS cluster
Wait until `AVAILABLE` is `True`.
```bash
kubectl get cluster "$CLUSTER_NAME" --watch
```
<br>
<br>

### 5. Connect to the VKS cluster
```bash
vcf context create "$CLUSTER_NAME" \
  --endpoint "$SUPERVISOR_IP" \
  --username "$SUPERVISOR_USERNAME" \
  --workload-cluster-namespace "$SUPERVISOR_NAMESPACE_NAME" \
  --workload-cluster-name "$CLUSTER_NAME"

vcf context use "$CLUSTER_NAME":"$CLUSTER_NAME"
```
<details>
<summary>Test command: Get nodes</summary>

```shell
kubectl get nodes -o wide

# Example output from the validation cluster (1 control plane, 3 workers)
NAME                                        STATUS   ROLES           AGE   VERSION            INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
appscode-c1-h4bvq-xzjz9                     Ready    control-plane   51d   v1.36.2+vmware.2   172.26.0.3    <none>        Ubuntu 24.04.4 LTS   6.17.0-35-generic (amd64)   containerd://2.3.2+vmware.3-fips
appscode-c1-node-pool-1-xwbp6-c2tkt-gz26p   Ready    <none>          51d   v1.36.2+vmware.2   172.26.0.6    <none>        Ubuntu 24.04.4 LTS   6.17.0-35-generic (amd64)   containerd://2.3.2+vmware.3-fips
appscode-c1-node-pool-1-xwbp6-c2tkt-tq79r   Ready    <none>          51d   v1.36.2+vmware.2   172.26.0.5    <none>        Ubuntu 24.04.4 LTS   6.17.0-35-generic (amd64)   containerd://2.3.2+vmware.3-fips
appscode-c1-node-pool-1-xwbp6-c2tkt-xlqj8   Ready    <none>          51d   v1.36.2+vmware.2   172.26.0.4    <none>        Ubuntu 24.04.4 LTS   6.17.0-35-generic (amd64)   containerd://2.3.2+vmware.3-fips
```
</details>
<br>
<br>

### 6. Confirm the vSAN StorageClass and volume expansion
KubeDB volume expansion relies on `ALLOWVOLUMEEXPANSION` being `true`.
```bash
kubectl get storageclass
```
<details>
<summary>Expected output</summary>

```shell
NAME                                       PROVISIONER              VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
vsan-esa-default-policy-raid5 (default)    csi.vsphere.vmware.com   Immediate              true
vsan-esa-default-policy-raid5-latebinding  csi.vsphere.vmware.com   WaitForFirstConsumer   true
```
</details>

## Cleanup Procedure

```shell
vcf context use "$SUPERVISOR_CONTEXT":"$SUPERVISOR_NAMESPACE_NAME"
kubectl delete cluster "$CLUSTER_NAME"
```
