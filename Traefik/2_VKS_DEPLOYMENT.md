# VKS Deployment
## Versions
* VMware Cloud Foundation 9.0 (vCenter 9.0.2)
* vSphere Kubernetes Service 3.7.0 (ClusterClass `builtin-generic-v3.7.0`) / VKr v1.36.2+vmware.2

## References
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)

## Requirements
### Linux CLI Tools
* [kubectl cli v1.36](https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl)
* [vcf cli v9.0.2](https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.2/)
* [helm cli v4](https://get.helm.sh/helm-v4.0.0-linux-amd64.tar.gz)
* `curl` (7.84 or later: steps 3B and 3C read credentials from a quoted netrc file), `unzip`, `openssl`,
  `jq` (Ubuntu: `sudo apt-get install -y curl unzip openssl jq`)
* For step 3C only: [govc v0.55](https://github.com/vmware/govmomi/releases/tag/v0.55.0), `ssh` and
  `scp`

### Required vSphere Steps
These steps require access to vCenter and are typically handled by an infrastructure administrator.

1. In the Supervisor, create a vSphere Namespace (e.g. `traefik-ns`)
2. Add a storage policy to the namespace
   * vsan-esa-default-policy-raid5
3. Add VM classes to the namespace
   * best-effort-medium

**Note**: these are the storage policy and VM class of the validation. If you use others, update
`manifests/vks.yaml`; step 3C adapts its manifests from the variables of its step 1.


## Deployment Procedure

### 1. Set environment variables
Your values, and where to find them. The examples are the [example environment](README.md#example-environment)
used in every expected output of this folder.

| Variable | Example | Where to find it |
|---|---|---|
| `VCENTER` | `vcenter.example.com` | the vCenter FQDN in the vSphere Client address bar |
| `SUPERVISOR_IP` | `203.0.113.10` | vSphere Client → Workload Management → Supervisors → Control Plane Node Address |
| `SUPERVISOR_USERNAME` | `user@example.com` | an SSO user with the **Namespace Owner** role on the namespace ([Step 1, step 5](1_CONFIGURE_SUPERVISOR.md)), or a member of the administrators group |
| `VSPHERE_NAMESPACE` | `traefik-ns` | Workload Management → Namespaces, the namespace created in [Step 1, step 3](1_CONFIGURE_SUPERVISOR.md) |
| `SUPERVISOR_CONTEXT` | `traefik-ctx` | a name you choose for the Supervisor context (step 3) |
| `CLUSTER_NAME` | `traefik-c2` | a name you choose for the VKS cluster (step 5) |
| `CLUSTER_CONTEXT` | `traefik-c2-ctx` | a name you choose for the cluster context (step 7); the kubeconfig context it creates is `<context>:<cluster name>`, which step 3C uses |
| `WORK` | `~/traefik-vks-work` | fixed: the working directory of all guides, outside the repository |

```bash
# Update with your values (see the table above)
export VCENTER="<vcenter_fqdn>"
export SUPERVISOR_IP="<supervisor_ip>"
export SUPERVISOR_USERNAME="<username>"
export VSPHERE_NAMESPACE="<vsphere_namespace>"
export SUPERVISOR_CONTEXT="<supervisor_context>"
export CLUSTER_NAME="<vks_cluster_name>"
export CLUSTER_CONTEXT="<cluster_context>"
# A working directory outside the repository for certificates and downloads
export WORK="$HOME/traefik-vks-work"; mkdir -p "$WORK"; chmod 700 "$WORK"

env | grep -E '^(VCENTER|SUPERVISOR_IP|SUPERVISOR_USERNAME|VSPHERE_NAMESPACE|SUPERVISOR_CONTEXT|CLUSTER_NAME|CLUSTER_CONTEXT)=.*<' \
  && echo "Replace the <placeholders> above first"
```
<br>
<br>


### 2. Trust the vCenter and Supervisor certificates
vCenter publishes its trusted root CAs at `/certs/download.zip`: the VMware Certificate Authority
(VMCA) and, when vCenter uses one, the enterprise root CA. The Supervisor API presents a certificate
signed by the VMCA, without the chain, and names itself by IP address only. The first download
cannot be verified yet (trust on first use): compare the printed fingerprints with
**vSphere Client > Administration > Certificates > Trusted Root Certificates** before you go on.
```bash
curl -k -fsSL -o "$WORK/vc-certs.zip" "https://$VCENTER/certs/download.zip"
unzip -o -q "$WORK/vc-certs.zip" -d "$WORK/vc-certs"
cat "$WORK"/vc-certs/certs/lin/*.0 > "$WORK/vcenter-ca.crt"
for f in "$WORK"/vc-certs/certs/lin/*.0; do
  openssl x509 -in "$f" -noout -subject -fingerprint -sha256
done

# From now on, vCenter is verified with the bundle
curl -fsS --cacert "$WORK/vcenter-ca.crt" -o /dev/null -w '%{http_code}\n' "https://$VCENTER/"
```

<details>
<summary>Expected output</summary>

```text
subject=DC = com, DC = example, CN = EXAMPLE-ROOT-CA
sha256 Fingerprint=<fingerprint: compare it with the vSphere Client>
subject=CN = CA, DC = vsphere.local, C = US, ST = California, O = vcenter.example.com, OU = VMware Engineering
sha256 Fingerprint=<fingerprint: compare it with the vSphere Client>
200
```
</details>
<br>
<br>


### 3. Create supervisor context
`--ca-certificate` makes the VCF CLI verify the Supervisor with the vCenter roots. Use the
Supervisor IP address as the endpoint: its certificate has no host name.
The command prompts for the password: run it in an interactive terminal.
```bash
vcf context create "$SUPERVISOR_CONTEXT" \
  --endpoint "https://$SUPERVISOR_IP" \
  --ca-certificate "$WORK/vcenter-ca.crt" \
  --username "$SUPERVISOR_USERNAME"
```

<details>
<summary>Expected output</summary>

```text
[i] Auth type vSphere SSO detected. Proceeding for authentication...
Provide Password:

Logged in successfully.

You have access to the following contexts:
   traefik-ctx
   traefik-ctx:traefik-ns
[ok] successfully created context: traefik-ctx
[ok] successfully created context: traefik-ctx:traefik-ns
```
</details>
<br>
<br>


### 4. Set supervisor context
```bash
vcf context use "$SUPERVISOR_CONTEXT":"$VSPHERE_NAMESPACE"
```
<br>
<br>


### 5. Create VKS cluster
In this step we create a VKS cluster as defined in `manifests/vks.yaml`: one control plane node and
two workers of class `best-effort-medium`, Kubernetes v1.36.2. The `sed` sets your cluster name; `-n`
selects your vSphere Namespace.
```bash
sed "s/traefik-c2/$CLUSTER_NAME/" manifests/vks.yaml | kubectl -n "$VSPHERE_NAMESPACE" apply -f -
```

<details>
<summary>Expected output</summary>

```text
cluster.cluster.x-k8s.io/traefik-c2 created
```
</details>
<br>
<br>


### 6. Wait for VKS cluster creation
Wait until the output shows `AVAILABLE True` (about 7 minutes in the validation lab).
```bash
kubectl get cluster "$CLUSTER_NAME" --watch
```

<details>
<summary>Expected output</summary>

```text
NAME         CLUSTERCLASS             AVAILABLE   CP DESIRED   CP AVAILABLE   CP UP-TO-DATE   W DESIRED   W AVAILABLE   W UP-TO-DATE   PHASE         AGE     VERSION
traefik-c2   builtin-generic-v3.7.0   True        1            1              1               2           2             2              Provisioned   7m11s   v1.36.2+vmware.2
```
</details>
<br>
<br>


### 7. Connect to VKS cluster
```bash
vcf context create "$CLUSTER_CONTEXT" \
  --endpoint "https://$SUPERVISOR_IP" \
  --ca-certificate "$WORK/vcenter-ca.crt" \
  --username "$SUPERVISOR_USERNAME" \
  --workload-cluster-namespace "$VSPHERE_NAMESPACE" \
  --workload-cluster-name "$CLUSTER_NAME"
vcf context use "$CLUSTER_CONTEXT":"$CLUSTER_NAME"
```

<details>
<summary>Test Command: Get nodes</summary>

```text
kubectl get nodes

NAME                                       STATUS   ROLES           AGE   VERSION
traefik-c2-9hbkg-rk29p                     Ready    control-plane   10m   v1.36.2+vmware.2
traefik-c2-node-pool-1-9hhdh-gzn44-cvcv9   Ready    <none>          7m    v1.36.2+vmware.2
traefik-c2-node-pool-1-9hhdh-gzn44-wwr99   Ready    <none>          7m    v1.36.2+vmware.2
```
</details>
<br>
<br>


## Cleanup Procedure

```bash
# Switch to the supervisor context and delete the VKS cluster
vcf context use "$SUPERVISOR_CONTEXT":"$VSPHERE_NAMESPACE"
kubectl delete cluster "$CLUSTER_NAME"
```

> Validation status: all steps (1–7) validated on 2026-10-02 with VCF CLI v9.0.2 and this exact
> `manifests/vks.yaml`. Step 5 changed shape in this revision without a re-run (same manifest, applied
> with `-n`); expected outputs show the example environment of the README.
