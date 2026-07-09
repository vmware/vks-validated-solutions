# Coherent Spark on VKS Deployment

This directory contains the example manifests and supporting configuration used to validate the **Coherent Spark Hybrid Runner on vSphere Kubernetes Service** reference architecture.

Coherent Spark converts spreadsheet-driven business logic — pricing engines, actuarial models, compliance calculators, risk scoring rules — into governed, versioned, and executable services. In the hybrid deployment model validated here, service authoring, versioning, and identity remain in Coherent Spark SaaS, while the runtime that executes published services (the Hybrid Runner, `nodegen-server`) runs as a standard Kubernetes Deployment on a VKS cluster.

## Versions
* VCF 9.0.1
* vSphere Kubernetes 3.6.0 / VKr 1.35.5
* Coherent Spark Hybrid Runner (nodegen-server) v1.53.4

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Coherent Spark Documentation](https://docs.coherent.global)


## Deployment Procedure

* [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md)
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md)
* [Step 3. Coherent Spark Hybrid Runner Deployment](3_COHERENT_SPARK_DEPLOYMENT.md)

## Manifests

* [manifests/vks.yaml](manifests/vks.yaml) — VKS Cluster definition (3 control-plane / 3 worker nodes, vSAN ESA RAID5 storage)
* [manifests/rwx-pvc.yaml](manifests/rwx-pvc.yaml) — `ReadWriteMany` PersistentVolumeClaim used for the shared Wasm model cache
* [manifests/hybrid-runner-k8s-sample.config.yml](manifests/hybrid-runner-k8s-sample.config.yml) — Hybrid Runner Deployment, Service, and HorizontalPodAutoscaler

## Deployment Model
Coherent Spark supports three deployment models:
* **SaaS** — authoring, identity, publication, and execution are all hosted in Coherent's managed platform.
* **On-Premises** — execution runs fully inside customer infrastructure with no runtime dependency on outbound SaaS connectivity (Hybrid Runner configured with `USE_SAAS=false`, Wasm modules manually mounted or baked into a custom image).
* **Hybrid** — authoring and governance remain in Spark SaaS, while execution runs in a customer-controlled environment such as VKS. This is the model validated in this directory.

Across all three models the service contract — `Xinput_*` / `Xoutput_*` named ranges and the v3/v4 Execute API surface — is identical, so a service authored in Spark SaaS can move between deployment models without changes to its callers.
