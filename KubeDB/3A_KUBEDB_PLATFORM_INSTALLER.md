# KubeDB Platform Deployment - AppsCode Installer
This is the recommended path. It installs KubeDB, KubeStash, cert-manager, kube-prometheus-stack, Open Cluster Management, and the KubeDB Platform console as Flux HelmReleases.

## Versions
* KubeDB v2026.10.12
* KubeStash v2026.10.12
* KubeDB Platform (ACE) v2026.10.12
* cert-manager v1.19.3
* kube-prometheus-stack 69.2.2
* Envoy Gateway v1.8.2
* Open Cluster Management v1.2.0
* Flux helm-controller 1.5.5 (VKS add-on)
* vSphere Kubernetes Service 3.7 / VKr v1.36.2+vmware.2-vkr.3

## References
* [Add-on Packages for VKS](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html)
* [KubeDB documentation](https://kubedb.com/docs)

## Requirements
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md) completed, with the VKS cluster context active
* An AppsCode account (https://appscode.com)

## Deployment Procedure

### 1. Enable the VKS helm-controller add-on
Enable the helm-controller add-on (Flux helm-controller and source-controller) on the VKS cluster. The installer uses these controllers instead of installing its own.
```bash
kubectl get packageinstalls -A
```
The helm-controller package must report `Reconcile succeeded`. VKS 3.7 also provides the Gateway API CRDs (v1.5.1) that the KubeDB Platform gateway requires.
<br>
<br>

### 2. Obtain a license
KubeDB and KubeStash licenses are issued for a specific cluster, identified by the UID of the `kube-system` namespace. Request a license from the [AppsCode License Server](https://appscode.com/issue-license?p=kubedb) or from your AppsCode account team.
```bash
kubectl get ns kube-system -o jsonpath='{.metadata.uid}'
```
<br>
<br>

### 3. Generate and run the installer
1. In your AppsCode account, generate an installer for the cluster.
2. Enable the **flux2** feature, but do not mark it as managed, so that the installer uses the VKS helm-controller.
3. If the VKS cert-manager add-on is already installed, disable the **cert-manager** feature.
4. Download the generated archive and run the deployment steps in its README.
<br>
<br>

### 4. Verify the HelmReleases
```bash
kubectl get helmreleases -A
```
Every HelmRelease (34 in the validation run), including `kubedb`, `kubestash`, `cert-manager` and `kube-prometheus-stack`, reports `READY` `True`.
<br>
<br>

### 5. Verify the operators
```bash
kubectl get pods -n kubedb
kubectl get pods -n stash
kubectl get postgresversions
```
<details>
<summary>Example output</summary>

```shell
NAME                                                 READY   STATUS    RESTARTS   AGE
kubedb-kubedb-autoscaler-0                           1/1     Running   0          12d
kubedb-kubedb-ops-manager-0                          1/1     Running   0          12d
kubedb-kubedb-provisioner-0                          1/1     Running   0          12d
kubedb-kubedb-webhook-server-57df456cc4-8m4ln        1/1     Running   0          12d
kubedb-opscenter-kubedb-ui-server-7bdf888fc6-chgm8   1/1     Running   0          12d
kubedb-petset-c778bfdd4-9h78p                        1/1     Running   0          12d

NAME                                                          READY   STATUS    RESTARTS   AGE
kubestash-kubestash-operator-operator-68cdd654f8-8prkq        1/1     Running   0          12d
kubestash-kubestash-operator-webhook-server-845bb6585-7st45   1/1     Running   0          12d
```
</details>
<br>
<br>

### Database engines
The installer enables the Elasticsearch (including OpenSearch), Kafka, MariaDB, MongoDB, MySQL, PostgreSQL, Pgpool, and Redis (including Valkey) engines by default. Other engines are enabled by setting `global.featureGates.<Engine>=true` in the kubedb chart values.

### Pod Security
The VKS cluster enforces the baseline Pod Security Standard. KubeDB, KubeStash, the KubeDB Platform, and the database pods run under baseline without changes. The installer labels only the `monitoring` and `cert-manager` namespaces privileged, because node-exporter and the cert-manager CSI driver need host access.

Next: [Step 4. PostgreSQL HA Validation](4_POSTGRES_HA_VALIDATION.md)
