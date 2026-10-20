# KubeDB VKS Deployment

This repository contains the example manifests and supporting configuration used in the **KubeDB on vSphere Kubernetes Service on VMware Cloud Foundation** reference architecture.

KubeDB by AppsCode is a Kubernetes-native Database-as-a-Service. It supports more than 30 database engines; this validation covers a highly available PostgreSQL cluster with TLS, monitoring, day-2 OpsRequests, and KubeStash backup and restore.

White paper:
KubeDB on vSphere Kubernetes Service on VMware Cloud Foundation (link to be added when published on vmware.com/docs)

## Versions
* KubeDB v2026.10.12
* KubeStash v2026.10.12
* KubeDB Platform (ACE) v2026.10.12
* PostgreSQL 18.3
* vSphere Kubernetes Service 3.7 / VKr v1.36.2+vmware.2-vkr.3
* vCenter Server 9.0.2 / VMware Cloud Foundation 9.0

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Add-on Packages for VKS](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html)
* [KubeDB documentation](https://kubedb.com/docs)
* [KubeStash documentation](https://kubestash.com/docs)
* [AppsCode License Server](https://appscode.com/issue-license?p=kubedb)

## Deployment Procedure

* [Client VM configuration](client-vm-configuration.md)
* [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md)
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md)
* KubeDB Deployment
  * [Step 3 - Option A - KubeDB Platform with the AppsCode installer (recommended)](3A_KUBEDB_PLATFORM_INSTALLER.md)
  * [Step 3 - Option B - KubeDB and KubeStash with Helm](3B_KUBEDB_HELM.md)
* [Step 4. PostgreSQL HA Validation](4_POSTGRES_HA_VALIDATION.md)

## Manifests

| File | Purpose |
|---|---|
| [vks.yaml](manifests/vks.yaml) | VKS cluster (3 control plane, 3 workers, vSAN ESA RAID-5) |
| [pg-ca-issuer.yaml](manifests/pg-ca-issuer.yaml) | cert-manager CA Issuer for database TLS |
| [pg-ha.yaml](manifests/pg-ha.yaml) | PostgreSQL 18.3, 3 members, TLS, Prometheus monitoring |
| [ops-volume-expansion.yaml](manifests/ops-volume-expansion.yaml) | Online volume expansion 50Gi → 100Gi |
| [ops-horizontal-scale-up.yaml](manifests/ops-horizontal-scale-up.yaml) / [ops-horizontal-scale-down.yaml](manifests/ops-horizontal-scale-down.yaml) | Horizontal scaling 3 → 4 → 3 |
| [ops-vertical-scaling.yaml](manifests/ops-vertical-scaling.yaml) | Vertical scaling of the postgres container |
| [ops-reconfigure-tls.yaml](manifests/ops-reconfigure-tls.yaml) | TLS certificate rotation |
| [backup-storage.yaml](manifests/backup-storage.yaml), [retention-policy.yaml](manifests/retention-policy.yaml), [backup-configuration.yaml](manifests/backup-configuration.yaml) | KubeStash backup to S3-compatible storage |
| [pg-restored.yaml](manifests/pg-restored.yaml), [restore-session.yaml](manifests/restore-session.yaml) | Restore the latest snapshot into a new database |
