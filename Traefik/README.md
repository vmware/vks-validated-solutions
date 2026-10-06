# Traefik VKS Deployment

This folder contains the manifests, Helm values and step-by-step procedures used in the
**Traefik on vSphere Kubernetes Service** white paper.

White paper:
https://www.vmware.com/docs/isv-traefik-vks

## Versions
* Traefik Helm chart 41.6.1 / Traefik Proxy v3.7.13 / Traefik Hub v3.21.0
* vSphere Kubernetes Service 3.7.0 / VKr v1.36.2, VCF 9.0 (vCenter 9.0.2)
* Step 3C: the child gateways run an Early Access build of Traefik Hub v3.21 with the `vsphere` and
  `vmoperator` providers. To evaluate Step 3C, [contact Traefik Labs](https://info.traefik.io/en/request-demo), which provides the build and supports the installation.

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)
* [Command line tool (kubectl)](https://kubernetes.io/docs/reference/kubectl/)
* [Installing and Using VCF CLI v9.0](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)
* [Traefik documentation](https://doc.traefik.io/traefik/)
* [Traefik Hub documentation](https://doc.traefik.io/traefik-hub/)
* [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart)

## Deployment Procedure

* [Step 1. Configure Supervisor](1_CONFIGURE_SUPERVISOR.md)
* [Step 2. VKS Deployment](2_VKS_DEPLOYMENT.md)
* Traefik Deployment. **3A, 3B and 3C are cumulative layers on the same Traefik release, not
  alternatives**: 3B upgrades the release of 3A to Traefik Hub, and 3C adds the multicluster parent
  to the release of 3B.
  * [Step 3A - Traefik Proxy with the Gateway API](3A_TRAEFIK_PROXY.md)
  * [Step 3B - Traefik Hub: API Management, AI Gateway, MCP Gateway](3B_TRAEFIK_HUB.md)
  * [Step 3C - Traefik across VMs and containers (multicluster, Early Access)](3C_TRAEFIK_VMS_MULTICLUSTER.md)

The client machine is described in [client-vm-configuration.md](client-vm-configuration.md); the
Traefik steps also need `jq`, `openssl`, and for step 3C `govc`, `ssh` and `scp` on the workstation
and Docker Compose v2 on the child VMs ([Step 2, Requirements](2_VKS_DEPLOYMENT.md#requirements)).

## Conventions
* Every command runs from this folder. Files under `manifests/` and the expected outputs use the
  example environment of the next section; the guides adapt the few environment-specific values with
  the variables of their first step (`-n` for the vSphere Namespace, one `sed` for the domain or the
  VM class, image and storage class).
* Secrets (license token, passwords, keys) are typed at a prompt and go to Kubernetes Secrets, to
  files with mode 0600 under `$WORK` for the duration of a guide (its Cleanup removes them), or to the
  Compose project folder of a child VM; they never appear in this folder, on a command line or in a
  log.
* TLS is verified everywhere: vCenter and the Supervisor through the vCenter root CAs, the gateway
  through the CA of step 3A, the parent and the children through a private CA with mutual TLS.
* Generated files (certificates, keys, downloads, SSH and Compose configuration) go to `$WORK`
  (`~/traefik-vks-work`), outside the repository.

## Example environment
Every guide starts with a "Your values" table: your variables, an example value and where to find
it. Commands, manifests and expected outputs use one example environment, built from names and
ranges reserved for documentation (RFC 2606 domains, RFC 5737 networks), so that a copied example
fails fast instead of reaching someone else's systems. The validation ran on a Broadcom lab; its
addresses and names were replaced by role, one example value per VM, address and host.

| What | Example value |
|---|---|
| Organisation domain `DOMAIN` (routes `echo.`, `dashboard.`, `ai.`, `mcp.`, `idp.`, `migration.`) | `example.com` |
| vCenter `VCENTER` | `vcenter.example.com` |
| Supervisor user | `user@example.com` |
| vCenter certificate chain (Step 2, step 2) | an enterprise root `EXAMPLE-ROOT-CA` and the VMCA `CN = CA, DC = vsphere.local, …, O = vcenter.example.com`; fingerprints are shown as a placeholder, the value you compare with the vSphere Client |
| Supervisor and LoadBalancer network (TEST-NET-3) | `203.0.113.0/24`: Supervisor `203.0.113.10`, Traefik LoadBalancer `203.0.113.53`, child B SSH LoadBalancer `203.0.113.54` |
| vCenter VM network (TEST-NET-1) | `192.0.2.0/24`: child A `192.0.2.53`, application VMs `192.0.2.58` and `192.0.2.59` |
| VM Service VPC subnet (TEST-NET-2) | `198.51.100.0/24`: child B `198.51.100.39`, application VMs `198.51.100.40` and `198.51.100.41` |
| vSphere paths (step 3C) | `VM_FOLDER` `/dc01/vm/traefik-folder`, `RESOURCE_POOL` `/dc01/host/cl01/Resources/traefik-rp`, `DATASTORE` `vsan01`, `VM_NETWORK` `vm-network`, `VM_TEMPLATE` `/dc01/vm/templates/ubuntu-24.04-cloudimg` |
| VM Service image `VMSVC_IMAGE` | `vmi-9f8e7d6c5b4a39281` |
| Names of this validation, kept as they are | vSphere Namespace `traefik-ns`, contexts `traefik-ctx` and `traefik-c2-ctx`, cluster `traefik-c2`, VM class `best-effort-medium`, storage policy `vsan-esa-default-policy-raid5`, cluster CIDRs and cluster-internal addresses |
| `CLUSTER_CONTEXT` | in Step 2 the name given to `vcf context create` (`traefik-c2-ctx`); `vcf context use` then selects the kubeconfig context `traefik-c2-ctx:traefik-c2`, the current context of steps 3A and 3B. Step 3C addresses two clusters and names that kubeconfig context in every command, so its `CLUSTER_CONTEXT` is `traefik-c2-ctx:traefik-c2` |
