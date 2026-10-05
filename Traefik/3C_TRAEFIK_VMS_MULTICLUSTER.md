# Traefik Across VMs and Containers (Multicluster, Early Access)
## Versions
* Parent gateway: the Traefik Hub v3.21.0 release of [Step 3B](3B_TRAEFIK_HUB.md) (chart 41.6.1)
* Child gateways: Traefik Hub v3.21 **validation build** with the `vsphere` and `vmoperator`
  providers, image `ghcr.io/traefik/traefik-hub:vmware-vks.ea0`, run by Docker Compose v2 on the
  child VMs (2.24.6 or later; Ubuntu 24.04 ships 2.24.6, and 2.40.3 from noble-updates)
* vCenter 9.0.2, vSphere Kubernetes Service 3.7.0, VM Service API `vmoperator.vmware.com/v1alpha3`

> **Early Access.** The multicluster provider is Early Access in Traefik Hub v3.21. The `vsphere`
> and `vmoperator` providers are delivered in a validation build; do not use it in production.

## Architecture
A parent gateway (the Traefik Hub release in the VKS cluster) fronts two child gateways, one per
estate. Each child discovers the VMs of its own control plane and advertises the Uplink `vm-app`;
the parent polls both over mutual TLS on port 9443 and builds `vm-app-estate-vcenter@multicluster`
and `vm-app-estate-vmservice@multicluster`. A weighted TraefikService splits the traffic: a cutover
is a weight change.

| | Child A: vCenter-managed VMs | Child B: VM Service VMs |
|---|---|---|
| Runs on | a VM cloned from a template in vCenter | a `VirtualMachine` in the vSphere Namespace |
| Provider | `vsphere` (vCenter, read-only session) | `vmoperator` (Supervisor API, namespace-scoped token) |
| Routing labels | VM **Configuration Parameters** (`extraConfig`) | **annotations** on the `VirtualMachine` |

The routing labels are the same on both sides:
```text
traefik.enable=true
traefik.tags=vm
traefik.http.services.vmapp.loadbalancer.server.port=80
```

Each child runs Traefik Hub as one Docker Compose project (`manifests/3c/child-a/compose.yaml`,
`manifests/3c/child-b/compose.yaml`): the static configuration is embedded in the Compose file and
filled from a `.env` file, the license token and the Supervisor token are Compose file secrets. The
commands of this guide copy the project folder to the VM with `scp` and start it with
`docker compose up -d`.

## Requirements
* [Step 3B](3B_TRAEFIK_HUB.md) completed (the parent), the cluster context and the supervisor context
  of [Step 2](2_VKS_DEPLOYMENT.md), and `$WORK/vcenter-ca.crt` from Step 2.
* A vCenter account that can clone VMs and set Configuration Parameters in a folder and resource pool
  (privileges `VirtualMachine.Inventory.Create`, `VirtualMachine.Provisioning.DeployTemplate`,
  `VirtualMachine.Config.AdvancedConfig`, `Resource.AssignVMToPool`, `Network.Assign`,
  `Datastore.AllocateSpace`). The child A provider only needs **Read-only** on the folder of the
  application VMs: in production give it a dedicated read-only user, never at the vCenter root (the
  provider reads all Configuration Parameters of the VMs it can see).
* An Ubuntu 24.04 cloud-image template in vCenter and a VM Service image of Ubuntu 24.04 (a
  content library associated with the vSphere Namespace provides it; `VMSVC_IMAGE` in step 1 is its
  `vmi-…` name).
* Network: the VKS worker nodes reach both children on TCP 9443; child A reaches vCenter on 443;
  child B reaches the Supervisor API on 443. The workstation reaches child A on 22, and child B on
  22 through the LoadBalancer created in step 3 (the namespace VPC is not routed to it).
* An SSH key pair on the workstation that works without a prompt (no passphrase, or loaded in
  `ssh-agent`): steps 4, 6 and 7 call `ssh` and `scp` about twelve times, some inside loops. A Linux
  workstation (`base64 -w0`) with curl 7.84 or later (the dashboard credentials are read from a
  quoted netrc file).
* CLI tools: `kubectl`, `helm`, `govc`, `ssh`, `scp`, `openssl`, `curl`, `jq`. On the child VMs,
  cloud-init installs Docker and Docker Compose v2 (`docker-compose-v2`).

## Deployment Procedure

### 1. Set environment variables and enter the secrets
Your values, and where to find them. The examples are the [example environment](README.md#example-environment)
used in every expected output of this folder.

| Variable | Example | Where to find it |
|---|---|---|
| `DOMAIN` | `example.com` | the DNS domain of your routes; no record is needed, the checks use `curl --resolve` |
| `CHART_VERSION` | `41.6.1` | fixed by this validation (Traefik Hub v3.21.0) |
| `VCENTER` | `vcenter.example.com` | the vCenter FQDN in the vSphere Client address bar |
| `SUPERVISOR_IP` | `203.0.113.10` | vSphere Client → Workload Management → Supervisors → Control Plane Node Address |
| `SUPERVISOR_CONTEXT` | `traefik-ctx` | the name you gave the Supervisor context in [Step 2, step 3](2_VKS_DEPLOYMENT.md) (`vcf context list`) |
| `VSPHERE_NAMESPACE` | `traefik-ns` | Workload Management → Namespaces, the namespace created in [Step 1, step 3](1_CONFIGURE_SUPERVISOR.md) |
| `CLUSTER_CONTEXT` | `traefik-c2-ctx:traefik-c2` | `kubectl config get-contexts` after [Step 2, step 7](2_VKS_DEPLOYMENT.md): the kubeconfig context `<context>:<cluster name>` (Step 2 uses `CLUSTER_CONTEXT` for the `<context>` part only: this guide addresses two clusters and names the context in every command) |
| `VM_FOLDER` | `/dc01/vm/traefik-folder` | `govc find / -type f`, or VMs and Templates → the folder's path |
| `RESOURCE_POOL` | `/dc01/host/cl01/Resources/traefik-rp` | `govc find / -type p`, or Hosts and Clusters → the pool's path |
| `DATASTORE` | `vsan01` | `govc datastore.info`, or the Storage view |
| `VM_NETWORK` | `vm-network` | `govc find / -type n`: a port group with DHCP that reaches vCenter and the VKS nodes |
| `VM_TEMPLATE` | `/dc01/vm/templates/ubuntu-24.04-cloudimg` | `govc find / -type m -config.template true`: the inventory path of the Ubuntu 24.04 cloud image imported as a template (any folder; the discovery user of Requirements does not need to see it) |
| `VMSVC_IMAGE` | `vmi-9f8e7d6c5b4a39281` | `kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get virtualmachineimages`: the `vmi-…` name of the Ubuntu 24.04 VM Service image of Requirements |
| `VM_CLASS` | `best-effort-medium` | fixed by this validation; the class added in [Step 1, step 4](1_CONFIGURE_SUPERVISOR.md) |
| `STORAGE_CLASS` | `vsan-esa-default-policy-raid5` | `kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get storageclasses`: the storage policy assigned in [Step 1, step 4](1_CONFIGURE_SUPERVISOR.md) |
| `HUB_CHILD_IMAGE` | `ghcr.io/traefik/traefik-hub:vmware-vks.ea0` | fixed by this validation (validation build) |
| `SSH_KEY` | `~/.ssh/id_ed25519` | your SSH private key; its public key `$SSH_KEY.pub` goes into the cloud-init of the VMs |
| `WORK` | `~/traefik-vks-work` | fixed: the working directory of all guides, outside the repository |
| `HUB_TOKEN` (prompt) | | Traefik Hub Online Dashboard → the gateway you created → token (offline, multi-cluster feature) |
| `VCENTER_USER`, `VCENTER_PASSWORD` (prompts) | | the vCenter account of Requirements |
| `DASHBOARD_PASSWORD` (prompt) | | the password you typed in [Step 3B, step 1](3B_TRAEFIK_HUB.md) (step 5 stored its hash) |

```bash
# Update with your values (see the table above)
export DOMAIN="<your_domain>"
export CHART_VERSION="41.6.1"
export VCENTER="<vcenter_fqdn>"
export SUPERVISOR_IP="<supervisor_ip>"
export SUPERVISOR_CONTEXT="<supervisor_context>"
export VSPHERE_NAMESPACE="<vsphere_namespace>"
export CLUSTER_CONTEXT="<cluster_context>:<vks_cluster_name>"
export VM_FOLDER="<vm_folder_path>"
export RESOURCE_POOL="<resource_pool_path>"
export DATASTORE="<datastore>"
export VM_NETWORK="<vm_portgroup>"
export VM_TEMPLATE="<template_inventory_path>"
export VMSVC_IMAGE="<vm_service_image_name>"
export VM_CLASS="best-effort-medium"
export STORAGE_CLASS="vsan-esa-default-policy-raid5"
export HUB_CHILD_IMAGE="ghcr.io/traefik/traefik-hub:vmware-vks.ea0"
export SSH_KEY="$HOME/.ssh/id_ed25519"
export WORK="$HOME/traefik-vks-work"; mkdir -p "$WORK"; chmod 700 "$WORK"
env | grep -E '^(DOMAIN|VCENTER|SUPERVISOR_IP|SUPERVISOR_CONTEXT|VSPHERE_NAMESPACE|CLUSTER_CONTEXT|VM_FOLDER|RESOURCE_POOL|DATASTORE|VM_NETWORK|VM_TEMPLATE|VMSVC_IMAGE|HUB_CHILD_IMAGE)=.*<' \
  && echo "Replace the <placeholders> above first"
test -r "$SSH_KEY.pub" || echo "Public key $SSH_KEY.pub not found"

# Derived values: the public key for the cloud-init files, the govc connection
SSH_PUBLIC_KEY=$(cat "$SSH_KEY.pub")
export GOVC_URL="https://$VCENTER/sdk" GOVC_TLS_CA_CERTS="$WORK/vcenter-ca.crt"

# Secrets: typed at the prompt, never on the command line
read -rsp 'Traefik Hub license token for the children: ' HUB_TOKEN; echo
read -rp  'vCenter user: ' VCENTER_USER
read -rsp 'vCenter password: ' VCENTER_PASSWORD; echo
read -rsp 'Dashboard password for admin (step 3B): ' DASHBOARD_PASSWORD; echo
export GOVC_USERNAME="$VCENTER_USER" GOVC_PASSWORD="$VCENTER_PASSWORD"
# The dashboard checks of this guide read the credentials from this file (mode 0600)
printf 'machine dashboard.%s login admin password "%s"\n' "$DOMAIN" "$DASHBOARD_PASSWORD" > "$WORK/dashboard.netrc"
chmod 600 "$WORK/dashboard.netrc"

# Values of the previous steps
TRAEFIK_IP=$(kubectl --context "$CLUSTER_CONTEXT" -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl --context "$CLUSTER_CONTEXT" -n traefik get secret traefik-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/gateway-ca.crt"
govc about | head -2
```

A dashboard password that contains `"` or `\` is not supported by the netrc file; a vCenter password
that contains `'` is not supported by step 6.
<br>
<br>


### 2. Create child A and the application VMs in vCenter
The VMs are cloned from the template, and cloud-init comes through `guestinfo` (base64), set before
the first power-on. The cloud-init carries no secret: only your SSH public key. The application VMs
run whoami and get the routing labels as Configuration Parameters.
```bash
# Child A: clone, inject the cloud-init through guestinfo, resize the disk, power on
USERDATA=$(sed "s|REPLACE_ME_SSH_PUBLIC_KEY|$SSH_PUBLIC_KEY|" manifests/3c/child-a/cloud-init.yaml | base64 -w0)
METADATA=$(printf 'instance-id: %s\nlocal-hostname: %s\n' traefik-child-a traefik-child-a | base64 -w0)
govc vm.clone -vm "$VM_TEMPLATE" -folder "$VM_FOLDER" -pool "$RESOURCE_POOL" -ds "$DATASTORE" -net "$VM_NETWORK" -c 2 -m 4096 -on=false traefik-child-a
govc vm.change -vm "$VM_FOLDER/traefik-child-a" -e guestinfo.userdata="$USERDATA" -e guestinfo.userdata.encoding=base64 -e guestinfo.metadata="$METADATA" -e guestinfo.metadata.encoding=base64
govc vm.disk.change -vm "$VM_FOLDER/traefik-child-a" -disk.label "Hard disk 1" -size 20G
govc vm.power -on "$VM_FOLDER/traefik-child-a"

# The two application VMs: the same four commands with the whoami cloud-init, plus the routing labels
USERDATA=$(sed "s|REPLACE_ME_SSH_PUBLIC_KEY|$SSH_PUBLIC_KEY|" manifests/3c/app-vm-cloud-init.yaml | base64 -w0)
for n in 1 2; do
  METADATA=$(printf 'instance-id: %s\nlocal-hostname: %s\n' "traefik-app-$n" "traefik-app-$n" | base64 -w0)
  govc vm.clone -vm "$VM_TEMPLATE" -folder "$VM_FOLDER" -pool "$RESOURCE_POOL" -ds "$DATASTORE" -net "$VM_NETWORK" -c 2 -m 4096 -on=false "traefik-app-$n"
  govc vm.change -vm "$VM_FOLDER/traefik-app-$n" -e guestinfo.userdata="$USERDATA" -e guestinfo.userdata.encoding=base64 -e guestinfo.metadata="$METADATA" -e guestinfo.metadata.encoding=base64
  govc vm.change -vm "$VM_FOLDER/traefik-app-$n" -e traefik.enable=true -e traefik.tags=vm -e traefik.http.services.vmapp.loadbalancer.server.port=80
  govc vm.disk.change -vm "$VM_FOLDER/traefik-app-$n" -disk.label "Hard disk 1" -size 20G
  govc vm.power -on "$VM_FOLDER/traefik-app-$n"
done

# Wait for the guest addresses (VMware Tools), then keep the address of child A
govc vm.ip -wait 5m "$VM_FOLDER/traefik-child-a" "$VM_FOLDER/traefik-app-1" "$VM_FOLDER/traefik-app-2"
CHILD_A_IP=$(govc vm.ip "$VM_FOLDER/traefik-child-a")
govc vm.info -e "$VM_FOLDER/traefik-app-1" | grep 'traefik\.'
```

<details>
<summary>Expected output (abridged)</summary>

```text
192.0.2.53
192.0.2.58
192.0.2.59
    traefik.enable:                                        true
    traefik.http.services.vmapp.loadbalancer.server.port:  80
    traefik.tags:                                          vm
```
</details>
<br>
<br>


### 3. Create child B and the application VMs with VM Service
`child-b-vm.yaml` creates the VM, its cloud-init Secret and a LoadBalancer on port 22 for SSH from the
workstation. `app-vms.yaml` creates two whoami VMs with the routing labels as annotations. The `sed`
line adapts the VM class, the image and the storage class of the example environment and inserts your
SSH public key; `-n` selects your vSphere Namespace.
```bash
for f in manifests/3c/child-b/child-b-vm.yaml manifests/3c/child-b/app-vms.yaml; do
  sed -e "s/best-effort-medium/$VM_CLASS/" -e "s/vmi-9f8e7d6c5b4a39281/$VMSVC_IMAGE/" \
      -e "s/vsan-esa-default-policy-raid5/$STORAGE_CLASS/" -e "s|REPLACE_ME_SSH_PUBLIC_KEY|$SSH_PUBLIC_KEY|" "$f" \
    | kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" apply -f -
done
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" wait vm/traefik-child-b --for=jsonpath='{.status.network.primaryIP4}' --timeout=10m
CHILD_B_IP=$(kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get vm traefik-child-b -o jsonpath='{.status.network.primaryIP4}')
# The LoadBalancer gets its address a few seconds after the VM
until CHILD_B_SSH=$(kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get virtualmachineservice traefik-child-b-ssh -o jsonpath='{.status.loadBalancer.ingress[0].ip}') && [ -n "$CHILD_B_SSH" ]; do sleep 10; done
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get vm -o custom-columns='NAME:.metadata.name,POWER:.status.powerState,IP:.status.network.primaryIP4'
```

<details>
<summary>Expected output (abridged)</summary>

```text
secret/traefik-child-b-cloud-init created
virtualmachine.vmoperator.vmware.com/traefik-child-b created
virtualmachineservice.vmoperator.vmware.com/traefik-child-b-ssh created
...
virtualmachine.vmoperator.vmware.com/traefik-child-b condition met
NAME                  POWER        IP
traefik-child-b       PoweredOn    198.51.100.39
traefik-vmsvc-app-1   PoweredOn    198.51.100.40
traefik-vmsvc-app-2   PoweredOn    198.51.100.41
```
</details>
<br>
<br>


### 4. Write the SSH configuration and wait for cloud-init
The file `$WORK/ssh_config` holds everything `ssh` and `scp` need for the two children: their
addresses, the user, your key and a `known_hosts` file of their own. `-F` makes the commands of this
guide use this file instead of your own and the system's SSH configuration. Child B is reached through
a LoadBalancer address that is not the VM's own, so `HostKeyAlias` records its host key under a fixed
name; child A is recorded under its address.
```bash
cat > "$WORK/ssh_config" <<EOF
Host child-a
  HostName $CHILD_A_IP
Host child-b
  HostName $CHILD_B_SSH
  HostKeyAlias traefik-child-b
Host child-a child-b
  User ubuntu
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  UserKnownHostsFile $WORK/known_hosts
  StrictHostKeyChecking accept-new
  ConnectTimeout 10
EOF
# Retries until sshd answers. If it does not within two minutes: Ctrl-C, then check the HostName
# lines of $WORK/ssh_config. If a child VM was recreated since the last run, remove its old host key first:
# ssh-keygen -R "$CHILD_A_IP" -f "$WORK/known_hosts"; ssh-keygen -R traefik-child-b -f "$WORK/known_hosts"
until ssh -n -F "$WORK/ssh_config" child-a true 2>/dev/null; do sleep 10; done
until ssh -n -F "$WORK/ssh_config" child-b true 2>/dev/null; do sleep 10; done
ssh -n -F "$WORK/ssh_config" child-a 'cloud-init status --wait; docker compose version'
ssh -n -F "$WORK/ssh_config" child-b 'cloud-init status --wait; docker compose version'
```

<details>
<summary>Expected output</summary>

```text
status: done
Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1
status: done
Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1
```
</details>
<br>
<br>


### 5. Create the certificates for mutual TLS
A private CA, a server certificate for each child (its IP in the subjectAltName) and a client
certificate for the parent. The commands run in a subshell with `umask 077`, so the keys are created
private. Keep `mtls-ca.key` private.
```bash
( umask 077; cd "$WORK" || exit
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 -sha256 -keyout mtls-ca.key -out mtls-ca.crt \
    -subj '/CN=traefik-multicluster-ca' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
  for c in "child-a:$CHILD_A_IP" "child-b:$CHILD_B_IP"; do
    n=${c%%:*}; ip=${c#*:}
    openssl req -newkey rsa:2048 -nodes -keyout "$n.key" -out "$n.csr" -subj "/CN=$n"
    printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$ip" > "$n.ext"
    openssl x509 -req -in "$n.csr" -CA mtls-ca.crt -CAkey mtls-ca.key -CAcreateserial -days 365 -sha256 \
      -extfile "$n.ext" -out "$n.crt"
  done
  openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj '/CN=traefik-parent'
  printf 'extendedKeyUsage=clientAuth\n' > client.ext
  openssl x509 -req -in client.csr -CA mtls-ca.crt -CAkey mtls-ca.key -CAcreateserial -days 365 -sha256 \
    -extfile client.ext -out client.crt ) 2>/dev/null
ls "$WORK"/{mtls-ca,child-a,child-b,client}.{crt,key}
```
<br>
<br>


### 6. Configure and run child A
The project folder `$WORK/child-a` is assembled on the workstation (the Compose file, the dynamic
configuration, the certificates, the license token and the `.env` file with the vCenter connection),
copied to the VM with `scp` and started with `docker compose up -d`. The token and the password are
written to files with mode 0600 for the duration of the step, copied to the VM and deleted from the
workstation; on the VM they belong to `ubuntu` (0600), whose account has passwordless sudo. Compose
reads the token as a secret and fills the password into the configuration (mounted 0400); the vCenter
root CAs are the file `SSL_CERT_FILE` points to, next to the system roots. A re-run replaces the
project folder on the VM and re-creates the container.
```bash
install -d -m 0700 "$WORK/child-a"
cp manifests/3c/child-a/compose.yaml manifests/3c/child-a/dynamic.yaml "$WORK/child-a/"
cp "$WORK/mtls-ca.crt" "$WORK/child-a.crt" "$WORK/child-a.key" "$WORK/vcenter-ca.crt" "$WORK/child-a/"
printf '%s' "$HUB_TOKEN" > "$WORK/child-a/hub-token"
# Every value is single-quoted: a vCenter password with ' is the only unsupported case
printf "VCENTER='%s'\nVCENTER_USER='%s'\nVCENTER_PASSWORD='%s'\nHUB_CHILD_IMAGE='%s'\n" \
  "$VCENTER" "$VCENTER_USER" "$VCENTER_PASSWORD" "$HUB_CHILD_IMAGE" > "$WORK/child-a/.env"
chmod 600 "$WORK/child-a/hub-token" "$WORK/child-a/.env" "$WORK/child-a/child-a.key"
ssh -n -F "$WORK/ssh_config" child-a 'rm -rf child-a'      # a re-run replaces the project folder
scp -rpq -F "$WORK/ssh_config" "$WORK/child-a" child-a:
rm "$WORK/child-a/hub-token" "$WORK/child-a/.env"          # the VM holds the only copy
ssh -n -F "$WORK/ssh_config" child-a 'sudo docker compose --project-directory child-a up -d --force-recreate'
# The provider logs in to vCenter and discovers the VMs: poll until both servers are listed. If nothing
# appears within two minutes: Ctrl-C, then ssh -n -F "$WORK/ssh_config" child-a 'sudo docker compose --project-directory child-a logs'
until ssh -n -F "$WORK/ssh_config" child-a 'curl -sf http://127.0.0.1:8080/api/http/services/vmapp@vsphere | jq -e ".loadBalancer.servers | length == 2"' >/dev/null 2>&1; do sleep 5; done
ssh -n -F "$WORK/ssh_config" child-a 'curl -s http://127.0.0.1:8080/api/http/services/vmapp@vsphere | jq -c "{status, servers: .loadBalancer.servers}"'
```

<details>
<summary>Expected output</summary>

```text
 Volume traefik-child-a_traefik-hub-data  Creating
 Volume traefik-child-a_traefik-hub-data  Created
 Container traefik-hub  Creating
 Container traefik-hub  Created
 Container traefik-hub  Starting
 Container traefik-hub  Started
{"status":"enabled","servers":[{"url":"http://192.0.2.58:80"},{"url":"http://192.0.2.59:80"}]}
```
</details>
<br>
<br>


### 7. Configure and run child B
`rbac.yaml` gives the ServiceAccount `traefik-vmoperator` read access (get, list, watch) to the
VirtualMachines of the namespace. Its token goes to a file the step copies to the child, like the
license token; the Supervisor certificate is verified with the vCenter roots (it is signed by the
VMCA). The project folder `$WORK/child-b` is assembled, copied and started like child A.
```bash
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" apply -f manifests/3c/child-b/rbac.yaml
# --as needs the impersonate verb: a Namespace Owner may see "Forbidden" here; the poll at the end of the step is the real check
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" auth can-i list virtualmachines.vmoperator.vmware.com --as="system:serviceaccount:$VSPHERE_NAMESPACE:traefik-vmoperator"
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" wait secret/traefik-vmoperator-token --for=jsonpath='{.data.token}' --timeout=60s

install -d -m 0700 "$WORK/child-b"
cp manifests/3c/child-b/compose.yaml manifests/3c/child-b/dynamic.yaml "$WORK/child-b/"
cp "$WORK/mtls-ca.crt" "$WORK/child-b.crt" "$WORK/child-b.key" "$WORK/vcenter-ca.crt" "$WORK/child-b/"
printf '%s' "$HUB_TOKEN" > "$WORK/child-b/hub-token"
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" get secret traefik-vmoperator-token -o jsonpath='{.data.token}' | base64 -d > "$WORK/child-b/vmoperator-token"
printf "SUPERVISOR_IP='%s'\nVSPHERE_NAMESPACE='%s'\nHUB_CHILD_IMAGE='%s'\n" "$SUPERVISOR_IP" "$VSPHERE_NAMESPACE" "$HUB_CHILD_IMAGE" > "$WORK/child-b/.env"
chmod 600 "$WORK/child-b/hub-token" "$WORK/child-b/vmoperator-token" "$WORK/child-b/.env" "$WORK/child-b/child-b.key"
ssh -n -F "$WORK/ssh_config" child-b 'rm -rf child-b'
scp -rpq -F "$WORK/ssh_config" "$WORK/child-b" child-b:
rm "$WORK/child-b/hub-token" "$WORK/child-b/vmoperator-token" "$WORK/child-b/.env"
ssh -n -F "$WORK/ssh_config" child-b 'sudo docker compose --project-directory child-b up -d --force-recreate'
# Same two-minute rule as step 6 (docker compose … logs on child-b)
until ssh -n -F "$WORK/ssh_config" child-b 'curl -sf http://127.0.0.1:8080/api/http/services/vmapp@vmoperator | jq -e ".loadBalancer.servers | length == 2"' >/dev/null 2>&1; do sleep 5; done
ssh -n -F "$WORK/ssh_config" child-b 'curl -s http://127.0.0.1:8080/api/http/services/vmapp@vmoperator | jq -c "{status, servers: .loadBalancer.servers}"'
```

<details>
<summary>Expected output (a first run prints <code>created</code> instead of <code>unchanged</code>)</summary>

```text
serviceaccount/traefik-vmoperator unchanged
role.rbac.authorization.k8s.io/traefik-vmoperator unchanged
rolebinding.rbac.authorization.k8s.io/traefik-vmoperator unchanged
secret/traefik-vmoperator-token unchanged
yes
secret/traefik-vmoperator-token condition met
 Volume traefik-child-b_traefik-hub-data  Creating
 Volume traefik-child-b_traefik-hub-data  Created
 Container traefik-hub  Creating
 Container traefik-hub  Created
 Container traefik-hub  Starting
 Container traefik-hub  Started
{"status":"enabled","servers":[{"url":"http://198.51.100.40:80"},{"url":"http://198.51.100.41:80"}]}
```
</details>
<br>
<br>


### 8. Configure the parent gateway
```bash
kubectl --context "$CLUSTER_CONTEXT" -n traefik create secret generic multicluster-mtls \
  --from-file=ca.crt="$WORK/mtls-ca.crt" --from-file=client.crt="$WORK/client.crt" \
  --from-file=client.key="$WORK/client.key" --dry-run=client -o yaml | kubectl --context "$CLUSTER_CONTEXT" apply --server-side -f -
helm --kube-context "$CLUSTER_CONTEXT" upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" \
  --reuse-values -f manifests/3c/values-multicluster.yaml \
  --set "hub.providers.multicluster.children.estate-vcenter.address=https://$CHILD_A_IP:9443" \
  --set "hub.providers.multicluster.children.estate-vmservice.address=https://$CHILD_B_IP:9443"
kubectl --context "$CLUSTER_CONTEXT" -n traefik rollout status deployment/traefik --timeout=180s
kubectl --context "$CLUSTER_CONTEXT" apply -f manifests/3c/migration-traefikservice.yaml
sed "s/example.com/$DOMAIN/g" manifests/3c/vm-app-ingressroute.yaml | kubectl --context "$CLUSTER_CONTEXT" apply -f -
```
<br>
<br>


## Verification: traffic migration between control planes

### 1. Uplink discovery and mutual TLS
```bash
curl -sS --cacert "$WORK/mtls-ca.crt" --cert "$WORK/client.crt" --key "$WORK/client.key" \
  "https://$CHILD_A_IP:9443/api/uplinks"; echo
curl -sS --cacert "$WORK/mtls-ca.crt" "https://$CHILD_A_IP:9443/api/uplinks" \
  || echo "exit $? (expected: the child requires a client certificate)"
```

<details>
<summary>Expected output</summary>

```text
[{"name":"vm-app","entryPoints":["multicluster"],"weight":1}]

curl: (56) OpenSSL SSL_read: OpenSSL/3.0.13: error:0A00045C:SSL routines::tlsv13 alert certificate required, errno 0
exit 56 (expected: the child requires a client certificate)
```
</details>
<br>
<br>


### 2. Services on the parent
The dashboard API of step 3B answers with the admin password, read from `$WORK/dashboard.netrc`
(step 1). The parent polls the children every 5 seconds: the first command waits until the
multicluster services are listed.
```bash
# If this does not return within two minutes: Ctrl-C and check kubectl --context "$CLUSTER_CONTEXT" -n traefik logs deploy/traefik
until curl -sS --fail --cacert "$WORK/gateway-ca.crt" --resolve "dashboard.$DOMAIN:443:$TRAEFIK_IP" --netrc-file "$WORK/dashboard.netrc" \
  "https://dashboard.$DOMAIN/api/http/services" | grep -q vm-app-estate-vmservice; do sleep 5; done
curl -sS --fail --cacert "$WORK/gateway-ca.crt" --resolve "dashboard.$DOMAIN:443:$TRAEFIK_IP" --netrc-file "$WORK/dashboard.netrc" \
  "https://dashboard.$DOMAIN/api/http/services" | jq -r '.[] | select(.provider == "multicluster") | .name'
```

<details>
<summary>Expected output</summary>

```text
vm-app-estate-vcenter@multicluster
vm-app-estate-vmservice@multicluster
vm-app@multicluster
```
</details>
<br>
<br>


### 3. Weighted cutover
20 requests at 90/10, then the weights change to 0/100: the route, the certificate and the
policies stay the same. The `RemoteAddr` of whoami is the child that forwarded the request.
```bash
# Wait until the route answers
curl -sS -o /dev/null --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$WORK/gateway-ca.crt" \
  --resolve "migration.$DOMAIN:443:$TRAEFIK_IP" "https://migration.$DOMAIN/"
# 20 requests: how many each child forwarded
for _ in $(seq 20); do
  curl -sS --cacert "$WORK/gateway-ca.crt" --resolve "migration.$DOMAIN:443:$TRAEFIK_IP" "https://migration.$DOMAIN/" \
    | sed -n 's/^RemoteAddr: \([^:]*\).*/\1/p'
done | sort | uniq -c
kubectl --context "$CLUSTER_CONTEXT" -n traefik patch traefikservice migration --type=json \
  -p='[{"op":"replace","path":"/spec/weighted/services/0/weight","value":0},{"op":"replace","path":"/spec/weighted/services/1/weight","value":100}]'
# Wait until the parent has loaded the new weights (it reloads within seconds). Same two-minute rule as Verification 2
until curl -sS --fail --cacert "$WORK/gateway-ca.crt" --resolve "dashboard.$DOMAIN:443:$TRAEFIK_IP" --netrc-file "$WORK/dashboard.netrc" "https://dashboard.$DOMAIN/api/http/services" \
  | jq -e '[.[] | select(.name | endswith("migration@kubernetescrd")) | .weighted.services[] | select(.name | startswith("vm-app-estate-vmservice")) | .weight] == [100]' >/dev/null; do sleep 1; done
for _ in $(seq 20); do
  curl -sS --cacert "$WORK/gateway-ca.crt" --resolve "migration.$DOMAIN:443:$TRAEFIK_IP" "https://migration.$DOMAIN/" \
    | sed -n 's/^RemoteAddr: \([^:]*\).*/\1/p'
done | sort | uniq -c
```

<details>
<summary>Expected output</summary>

```text
     18 192.0.2.53
      2 198.51.100.39
traefikservice.traefik.io/migration patched
     20 198.51.100.39
```
</details>
<br>
<br>


## Cleanup Procedure
Run it in a shell where step 1 of this guide was run. The parent goes back to the step 3B state.
```bash
# Rebuild the release from the values of steps 3A and 3B (drop values-tcp.yaml if you skipped
# 3A Verification 3); the Secret multicluster-mtls is deleted only after the rollout
helm --kube-context "$CLUSTER_CONTEXT" upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" \
  --reset-values -f manifests/3a/values-proxy.yaml -f manifests/3a/values-tcp.yaml \
  -f manifests/3b/values-hub.yaml -f manifests/3b/values-dashboard.yaml \
  --set "ingressRoute.dashboard.matchRule=Host(\`dashboard.$DOMAIN\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))"
kubectl --context "$CLUSTER_CONTEXT" -n traefik rollout status deployment/traefik --timeout=180s
kubectl --context "$CLUSTER_CONTEXT" -n traefik delete ingressroute vm-app --ignore-not-found
kubectl --context "$CLUSTER_CONTEXT" -n traefik delete traefikservice migration --ignore-not-found
kubectl --context "$CLUSTER_CONTEXT" -n traefik delete secret multicluster-mtls --ignore-not-found
kubectl --context "$SUPERVISOR_CONTEXT" -n "$VSPHERE_NAMESPACE" delete -f manifests/3c/child-b/app-vms.yaml -f manifests/3c/child-b/child-b-vm.yaml --ignore-not-found
for vm in traefik-child-a traefik-app-1 traefik-app-2; do govc vm.destroy "$VM_FOLDER/$vm"; done
# rbac.yaml: delete those objects only if you created them; another tool may manage them.
rm -rf "$WORK/child-a" "$WORK/child-b"
rm -f "$WORK"/mtls-ca.* "$WORK"/child-a.* "$WORK"/child-b.* "$WORK"/client.* "$WORK/known_hosts" "$WORK/ssh_config" "$WORK/dashboard.netrc"
unset HUB_TOKEN VCENTER_PASSWORD GOVC_PASSWORD DASHBOARD_PASSWORD
```

> Validation status: steps 2, 3, 5 and 8 and Cleanup validated on VKS 3.7.0 / vCenter 9.0.2 on
> 2026-10-02 with the validation build `vmware-vks.ea0` (Traefik Hub commit b63513d5); steps 2, 3, 8
> and Cleanup changed shape in this revision without a re-run (same govc, kubectl and helm operations,
> written out; the step 7 token poll became `kubectl wait`). Steps 1, 4, 6, 7 and Verification 1–3
> re-run verbatim on the same lab on 2026-10-04 with the Compose-based procedure of this revision
> (Docker Compose 2.40.3 from Ubuntu 24.04 noble-updates on the children; child image built from the
> same provider branch as the validation build); the step 5 certificates and the step 8 parent
> configuration of 2026-10-02 were reused. Expected outputs show the example environment of the
> README, with the lab's addresses and names replaced by role (each VM and address keeps one example
> value across runs). The child A provider ran with the operator's account, already limited to the
> application folder; a dedicated read-only user was not validated in this lab (it requires a vCenter
> SSO administrator).
