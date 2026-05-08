# VKS Deployment
## Versions
* vSphere Kubernetes 3.5.0 / VKr 1.34.1

## References
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Add-on Packages for VKS (e.g. cert-manager)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html)

## Requirements
### Linux CLI Tools
* [kubectl cli v1.34](https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl)
* [vcf cli v9.0.1](https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/)
* [helm cli v3.19](https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz)

### Required vSphere Steps
These steps require access to vCenter and typically handled by an infrastructure administrator.

1. In WCP, create a supervisor namespace (e.g. 'kong')
2. Add storage policy to supervisor namespace
   * vsan-esa-default-policy-raid5
3. Add VM classes to supervisor namespace
   * best-effort-medium
   * best-effort-2xlarge

**Note**: We are using the previous storage policies and VM classes as an example. If different policies and classes are desired, update the sample vks.yaml file with the required values.


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
export SUPERVISOR_NAMESPACE_NAME="kong"
export SUPERVISOR_CONTEXT="kong-ctx"
export CLUSTER_NAME="kong-vks"
export CLUSTER_CONTEXT="kong-vks-ctx"
export CLUSTER_NAMESPACE_NAME="kong-vks-ns"
export KONG_PAT="kpat_abc123..."
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
   kong-ctx
   kong-ctx:kong

If the namespace context you wish to use is not in this list, you may need to
refresh the context again, or contact your cluster administrator.

To change context, use `vcf context use <context_name>`
[ok] successfully created context: kong-ctx
[ok] successfully created context: kong-ctx:kong
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
[ok] Token is still active. Skipped the token refresh for context "kong-ctx:kong"
[i] Successfully activated context 'kong-ctx:kong' (Type: kubernetes) 
[i] Fetching recommended plugins for active context 'kong-ctx:kong'...
[i] No image repository override information was found
[ok] All recommended plugins are already installed and up-to-date. 
```
</details>
<br>
<br>


### 7. Create VKS cluster
In this step we create a VKS cluster as defined in vks.yaml. 
```bash
sed "s/cluster-vks/$CLUSTER_NAME/" vks.yaml | kubectl apply -f -
```

<details>
<summary>Expected output</summary>

```shell
cluster.cluster.x-k8s.io/kong-vks created
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
NAME         CLUSTERCLASS             AVAILABLE   CP DESIRED   CP AVAILABLE   CP UP-TO-DATE   W DESIRED   W AVAILABLE   W UP-TO-DATE   PHASE         AGE   VERSION
kong-vks   builtin-generic-v3.5.0   False       1            0              1               4           0             4              Provisioned   67s   v1.34.1+vmware.1
[...]
kong-vks   builtin-generic-v3.5.0   False       1            1              1               4           3             4              Provisioned   3m18s   v1.34.1+vmware.1
kong-vks   builtin-generic-v3.5.0   True        1            1              1               4           3             4              Provisioned   3m18s   v1.34.1+vmware.1
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
[i] Logging in to Kubernetes cluster (kong-vks) (kong)
[i] Successfully logged in to Kubernetes cluster 10.138.216.200

You have access to the following contexts:
    vks
    vks:kong-vks

If the namespace context you wish to use is not in this list, you may need to
refresh the context again, or contact your cluster administrator.
 
To change context, use `vcf context use <context_name>`
[ok] successfully created context: vks
[ok] successfully created context: vks:kong-vks
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
[ok] Token is still active. Skipped the token refresh for context "vks:kong-vks"
[i] Successfully activated context 'vks:kong-vks' (Type: kubernetes) 
[i] Fetching recommended plugins for active context
```
</details>
<details>
<summary>Test Command: Get nodes</summary>

```shell
# Get Nodes
kubectl get nodes -o wide

# Expected output: 
NAME                                       STATUS   ROLES           AGE   VERSION            INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
kong-vks-node-pool-1-8jzgf-bhrz2-vmnw7   Ready    <none>          36m   v1.34.1+vmware.1   172.26.0.5    <none>        Ubuntu 24.04.3 LTS   6.8.0-86-generic   containerd://2.1.4+vmware.3-fips
kong-vks-node-pool-2-zd45h-59jlx-mrr64   Ready    <none>          36m   v1.34.1+vmware.1   172.26.0.6    <none>        Ubuntu 24.04.3 LTS   6.8.0-86-generic   containerd://2.1.4+vmware.3-fips
kong-vks-node-pool-3-v8j28-bjm5t-w2h2q   Ready    <none>          36m   v1.34.1+vmware.1   172.26.0.4    <none>        Ubuntu 24.04.3 LTS   6.8.0-86-generic   containerd://2.1.4+vmware.3-fips
kong-vks-node-pool-4-btqp5-z4ts9-sx9bd   Ready    <none>          36m   v1.34.1+vmware.1   172.26.0.7    <none>        Ubuntu 24.04.3 LTS   6.8.0-86-generic   containerd://2.1.4+vmware.3-fips
kong-vks-trdx9-gmtbm                     Ready    control-plane   38m   v1.34.1+vmware.1   172.26.0.3    <none>        Ubuntu 24.04.3 LTS   6.8.0-86-generic   containerd://2.1.4+vmware.3-fips

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
# e.g. kubectl get tkr 'v1.34.1---vmware.1-vkr.4' -o yaml
kubectl get tkr TKR_NAME -o yaml  
```


