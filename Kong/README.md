# Kong VKS Deployment

## Versions
* Kong Operator 2.0.6
* vSphere Kubernetes 3.5 / VKr 1.34

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Install Kong Operator with Helm](https://developer.konghq.com/operator/dataplanes/get-started/kic/install/)
* [Kong Operator Configuration Options](https://developer.konghq.com/operator/reference/configuration-options/)


## Get Files 
```shell
git clone https://github.com/cleeistaken/kong-k8s-testing.git
```

## Deployment Procedure

* [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md)
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md)
* Kong Deployment
  * [Step 3 - Option A - Kong Deployment - Helm - On-Prem](3A_KONG_HELM_ON_PREM.md)
  * [Step 3 - Option B - Kong Deployment - Helm - Konnect](3B_KONG_HELM_KONNECT.md) 
  * [Step 3 - Option C - Kong Deployment - Operator - On-Prem](3C_KONG_OPERATOR_ON_PREM.md) 
  * [Step 3 - Option D - Kong Deployment - Operator - Konnect](3D_KONG_OPERATOR_KONNECT.md) 