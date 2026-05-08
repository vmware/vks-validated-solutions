# F5 Ingress on VKS Deployment

This repository contains the example manifests, Helm values, and supporting configuration used in the **F5 BIG-IP Container Ingress Services on vSphere Kubernetes Service** white paper.

White paper:
https://www.vmware.com/docs/isv-f5-vks

## Versions
* VCF 9.0.1
* vSphere Kubernetes 3.6.0 / VKR 1.35.0
* F5 Infrastructure: BIG-IP v17 or v21, CIS v2.20.3, and AS3 v3.56.0. (VM, Appliance or Chassis)

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)



## Deployment Procedure

* [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md)
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md)
* F5 Ingress Deployment:

A detailed procedure is documented here:
https://clouddocs.f5.com/containers/latest/userguide/vmware-vks/

## 3. Configure CNI Integration Mode

Define `pool_member_type` in your Helm `values.yaml` based on your network topology.

**Option A: NodePort Mode (Any CNI)**
Routes traffic to an in-cluster Ingress Controller via VKS node IPs.
Specify the following parameter in the Helm values file:

`pool_member_type: nodeport`

**Option B: Antrea Direct-to-Pod Mode (NodePortLocal)**
Routes traffic directly to backend Pods using NodePortLocal (NPL) mappings.

1. Set `pool_member_type: nodeportlocal`
1. Enable NPL: Ensure `nodePortLocal: enable: true` is configured in the `antrea-config` ConfigMap (`kube-system` namespace).
1. Annotate `ClusterIP` Services for CIS discovery:
   
   ```yaml
   metadata:
     annotations:
       nodeportlocal.antrea.io/enabled: "true"
   ```

**Option C: Calico Direct-to-Pod Mode**
Routes traffic directly to backend Pods using clusterIPs.

- Set `pool_member_type: cluster`
- *Note:* In NSX environments, BIG-IP must have an interface in the exact same VPC segment as the VKS cluster. If impossible, fallback to Option A.

## 4. Execute Helm Installation

Deploy the ingress controller using your customized values file.

```bash
helm repo add f5-stable https://f5networks.github.io/charts/stable
helm install f5-cis f5-stable/f5-bigip-ctlr -f values.yaml -n <target-namespace>
```




