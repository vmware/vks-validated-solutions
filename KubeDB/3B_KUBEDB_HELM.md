# KubeDB Deployment - Helm
Installs KubeDB and KubeStash only, from the AppsCode OCI Helm charts. Use this path when the KubeDB Platform console and multi-cluster management are not needed. The validation run used [option A](3A_KUBEDB_PLATFORM_INSTALLER.md); this path installs the same KubeDB and KubeStash charts at the same version.

## Versions
* KubeDB v2026.10.12
* KubeStash v2026.10.12
* kube-prometheus-stack 69.2.2
* cert-manager (VKS add-on)
* vSphere Kubernetes Service 3.7 / VKr v1.36.2+vmware.2-vkr.3

## References
* [KubeDB documentation](https://kubedb.com/docs)
* [KubeStash documentation](https://kubestash.com/docs)
* [Add-on Packages for VKS (cert-manager)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html)

## Requirements
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md) completed, with the VKS cluster context active
* The VKS cert-manager add-on installed
* helm v3 or later (see [client-vm-configuration.md](client-vm-configuration.md))

## Deployment Procedure

### 1. Obtain a license
KubeDB and KubeStash licenses are issued for a specific cluster, identified by the UID of the `kube-system` namespace. Request a license from the [AppsCode License Server](https://appscode.com/issue-license?p=kubedb) or from your AppsCode account team, and save it as `license.txt`.
```bash
kubectl get ns kube-system -o jsonpath='{.metadata.uid}'
```
<br>
<br>

### 2. Install KubeDB and KubeStash
```bash
helm install kubedb oci://ghcr.io/appscode-charts/kubedb \
  --version v2026.10.12 \
  --namespace kubedb --create-namespace \
  --set-file global.license=./license.txt \
  --set global.networkPolicy.enabled=true \
  --wait --burst-limit=10000 --debug

helm install kubestash oci://ghcr.io/appscode-charts/kubestash \
  --version v2026.10.12 \
  --namespace stash --create-namespace \
  --set-file global.license=./license.txt \
  --wait --burst-limit=10000 --debug
```
The kubedb chart enables Elasticsearch, Kafka, MariaDB, MongoDB, MySQL, PostgreSQL, and Redis by default. Add `--set global.featureGates.<Engine>=true` for each additional engine, for example `--set global.featureGates.MSSQLServer=true`.
<br>
<br>

### 3. Install kube-prometheus-stack
The `monitoring` namespace is labeled privileged because node-exporter needs host access, which the baseline Pod Security Standard does not allow.
```bash
kubectl create namespace monitoring
kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 69.2.2 \
  --namespace monitoring \
  --wait
```
This provides the Prometheus part of the monitoring test. The KubeDB Grafana dashboards are installed by [option A](3A_KUBEDB_PLATFORM_INSTALLER.md), or can be imported as described in the KubeDB monitoring documentation.
<br>
<br>

### 4. Verify the operators
```bash
kubectl get pods -n kubedb
kubectl get pods -n stash
kubectl get postgresversions
```
All kubedb-* pods (provisioner, ops-manager, autoscaler, webhook-server, petset) and the kubestash operator pods report `Running`.

For disconnected sites, mirror the AppsCode images to Harbor and add the registry overrides documented in the KubeDB air-gapped installation guide.

Next: [Step 4. PostgreSQL HA Validation](4_POSTGRES_HA_VALIDATION.md)

## Cleanup Procedure
```bash
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall kubestash -n stash
helm uninstall kubedb -n kubedb
```
