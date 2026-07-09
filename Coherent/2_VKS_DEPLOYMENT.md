# VKS Deployment
## Versions
* vSphere Kubernetes 3.6.0 / VKr 1.35.5

## References
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Add-on Packages for VKS (e.g. cert-manager)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html)

## Requirements
### Linux CLI Tools
* [kubectl cli v1.35](https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl)
* [vcf cli v9.0.1](https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/)

**Note**: Unlike some other ISV integrations in this repository, the Coherent Spark Hybrid Runner is deployed using plain Kubernetes manifests (Deployment, Service, PersistentVolumeClaim). Helm is not required.

### Required vSphere Steps
These steps require access to vCenter and typically handled by an infrastructure administrator.

1. In WCP, create a supervisor namespace (e.g. 'coherent')
2. Add storage policy to supervisor namespace
   * vsan-esa-default-policy-raid5
3. Add VM classes to supervisor namespace
   * best-effort-medium
   * best-effort-large

**Note**: We are using the previous storage policies and VM classes as an example. If different policies and classes are desired, update the sample manifests/vks.yaml file with the required values.


## Deployment Procedure

### 1. Set environment variables
To facilitate the creation of multiple deployments in different environments we create and use variables throughout this sample deployment procedure.
```bash
# Update with correct values
export SUPERVISOR_IP="<supervisor_ip>"
export SUPERVISOR_USERNAME="<username>"
export SUPERVISOR_NAMESPACE_NAME="<supervisor_namespace>"

# These variables will be used to create things
export SUPERVISOR_CONTEXT="<supervisor_context>"
export CLUSTER_CONTEXT="<cluster_context>"
export CLUSTER_NAME="<vks_cluster_name>"
export CLUSTER_NAMESPACE_NAME="vks_cluster_namespace"
```
<details>
<summary>Example</summary>

```bash
# Example
export VCENTER_IP="10.138.242.199"
export SUPERVISOR_IP="10.139.8.6" 
export SUPERVISOR_USERNAME="user@vsphere.local"
export SUPERVISOR_NAMESPACE_NAME="coherent"
export SUPERVISOR_CONTEXT="coherent-ctx"
export CLUSTER_NAME="coherent-vks"
export CLUSTER_CONTEXT="coherent-vks-ctx"
export CLUSTER_NAMESPACE_NAME="coherent-vks-ns"
```
</details>
<br>
<br>


### 2. Clean kubectl and vcf configs
This step is not required but helps avoid issues related to stale contexts or collisions between environments using the same context names.
```shell
rm ~/.kube/config
rm -rf ~/.config/vcf/
```
<br>
<br>

### 3. Setup VCF and kubectl command completion
This step is not required but helps with commands
```shell
# (Optional) Add autocomplete and shorthand 'k' for Kubectl (bash shell)
cat << 'EOF' >> ~/.bashrc 
echo "source <(vcf completion bash)"
source <(kubectl completion bash)
alias k=kubectl 
complete -o default -F __start_kubectl k
EOF
source ~/.bashrc 
```
<br>
<br>

### 4. Obtain vCenter certificates 
This step is required for TLS comms to vCenter
```shell
# Get vCenter certs & install
# Download the zip file to /tmp using curl (insecure mode required)
curl -k -fsSL -o /tmp/vccert.zip https://${VCENTER_IP}/certs/download.zip

# Unzip and copy to SSL directory
unzip /tmp/vccert.zip -d /tmp
sudo cp /tmp/certs/lin/* /etc/ssl/certs

# Update system certs
sudo update-ca-certificates
```
<br>
<br>


### 5. Create supervisor context 
```bash
vcf context create "$SUPERVISOR_CONTEXT" \
  --endpoint "$SUPERVISOR_IP" \
  --username "$SUPERVISOR_USERNAME"
```

<details>
<summary>Expected output</summary>

```bash
[i] Some initialization of the CLI is required.
[i] Lets set things up for you.  This will just take a few seconds.

[i] 
[i] Initialization done!
[i] ==
[i] Auth type vSphere SSO detected. Proceeding for authentication...
Provide Password: 

Logged in successfully.

You have access to the following contexts:
   coherent-ctx
   coherent-ctx:coherent

If the namespace context you wish to use is not in this list, you may need to
refresh the context again, or contact your cluster administrator.

To change context, use `vcf context use <context_name>`
[ok] successfully created context: coherent-ctx
[ok] successfully created context: coherent-ctx:coherent
```
</details>
<br>
<br>


### 6. Set supervisor context
```bash
vcf context use "$SUPERVISOR_CONTEXT":"$SUPERVISOR_NAMESPACE_NAME"
```

<details>
<summary>Expected output</summary>

```shell
[ok] Token is still active. Skipped the token refresh for context "coherent-ctx:coherent"
[i] Successfully activated context 'coherent-ctx:coherent' (Type: kubernetes) 
[i] Fetching recommended plugins for active context 'coherent-ctx:coherent'...
[i] No image repository override information was found
[ok] All recommended plugins are already installed and up-to-date. 
```
</details>
<br>
<br>


### 7. Create VKS cluster
In this step we create a VKS cluster as defined in manifests/vks.yaml. 
```bash
sed "s/cluster-vks/$CLUSTER_NAME/" manifests/vks.yaml | kubectl apply -f -
```

<details>
<summary>Expected output</summary>

```shell
cluster.cluster.x-k8s.io/coherent-vks created
```
</details>
<br>
<br>


### 8. Wait for VKS cluster creation
Wait until output shows "Available: True" 
```bash
kubectl get cluster "$CLUSTER_NAME" --watch
```

<details>
<summary>Expected output</summary>

```shell
NAME           CLUSTERCLASS             AVAILABLE   CP DESIRED   CP AVAILABLE   CP UP-TO-DATE   W DESIRED   W AVAILABLE   W UP-TO-DATE   PHASE         AGE   VERSION
coherent-vks   builtin-generic-v3.6.0   False       3            0              3               3           0             3              Provisioned   67s   v1.35.5+vmware.1
[...]
coherent-vks   builtin-generic-v3.6.0   False       3            3              3               3           2             3              Provisioned   4m2s   v1.35.5+vmware.1
coherent-vks   builtin-generic-v3.6.0   True        3            3              3               3           3             3              Provisioned   4m2s   v1.35.5+vmware.1
```
</details>
<br>
<br>


### 9. Connect to VKS cluster
```shell
vcf context create "$CLUSTER_CONTEXT" \
  --endpoint "$SUPERVISOR_IP" \
  --username "$SUPERVISOR_USERNAME" \
  --workload-cluster-namespace="$SUPERVISOR_NAMESPACE_NAME" \
  --workload-cluster-name="$CLUSTER_NAME" 
```

<details>
<summary>Expected output</summary>

```shell
[i] Logging in to Kubernetes cluster (coherent-vks) (coherent)
[i] Successfully logged in to Kubernetes cluster 10.138.216.200

You have access to the following contexts:
    vks
    vks:coherent-vks

If the namespace context you wish to use is not in this list, you may need to
refresh the context again, or contact your cluster administrator.
 
To change context, use `vcf context use <context_name>`
[ok] successfully created context: vks
[ok] successfully created context: vks:coherent-vks
```
</details>
<br>
<br>


### 10. Set VKS Cluster Context
```bash
vcf context use "$CLUSTER_CONTEXT":"$CLUSTER_NAME"
```

<details>
<summary>Expected output</summary>

```shell
[ok] Token is still active. Skipped the token refresh for context "vks:coherent-vks"
[i] Successfully activated context 'vks:coherent-vks' (Type: kubernetes) 
[i] Fetching recommended plugins for active context
```
</details>
<details>
<summary>Test Command: Get nodes</summary>

```shell
# Get Nodes
kubectl get nodes -o wide

# Expected output: 
NAME                                          STATUS   ROLES           AGE   VERSION           INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
coherent-vks-node-pool-1-8jzgf-bhrz2-vmnw7   Ready    <none>          36m   v1.35.5+vmware.1   172.26.0.5    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
coherent-vks-node-pool-1-8jzgf-bhrz2-x9k2q   Ready    <none>          36m   v1.35.5+vmware.1   172.26.0.6    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
coherent-vks-node-pool-1-8jzgf-bhrz2-p3n8r   Ready    <none>          36m   v1.35.5+vmware.1   172.26.0.7    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
coherent-vks-trdx9-gmtbm                     Ready    control-plane   38m   v1.35.5+vmware.1   172.26.0.3    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
coherent-vks-trdx9-hn4wc                     Ready    control-plane   38m   v1.35.5+vmware.1   172.26.0.4    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
coherent-vks-trdx9-kq7zs                     Ready    control-plane   38m   v1.35.5+vmware.1   172.26.0.8    <none>        Ubuntu 24.04.3 LTS   6.8.0-90-generic    containerd://2.1.4+vmware.3-fips
```
</details>
<br>
<br>

### 11. (Optional) Create Secret with Docker.io Credentials
May be required if the deployment hits errors about the site hitting image pull limits.
```bash
# Create secret with Docker login credentials in Kubernetes
kubectl create secret docker-registry regcred \
  --docker-server=docker.io \
  --docker-username=<docker_username> \
  --docker-password=<docker_password> \
  --docker-email=<docker_email> 
  --namespace=$CLUSTER_NAMESPACE_NAME

# Automatically use credentials for all pods in namespace 
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```


## Cleanup Procedure

```shell
# Switch to supervisor context 
vcf context use "$SUPERVISOR_CONTEXT":"$SUPERVISOR_NAMESPACE_NAME"

# Delete VKS cluster
kubectl delete "$CLUSTER_NAME"
```


## Troubleshooting

### Useful Commands
```shell
# List all
kubectl get all

# Get detailed pod information
kubectl get pods -o wide

# Get container logs
kubectl logs -f <container name>

# Get all services
kubectl get svc

# Expose a service
kubectl expose service <service_name>  --type=LoadBalancer --name=<service_name>-external

# Get the external IP
kubectl get svc <service_name>-external

# Get TKR releases
kubectl get tkr -l '!kubernetes.vmware.com/kubernetesrelease'

# Get TKR releaase specs
# e.g. kubectl get tkr 'v1.35.5---vmware.1-vkr.1' -o yaml
kubectl get tkr TKR_NAME -o yaml  
```

