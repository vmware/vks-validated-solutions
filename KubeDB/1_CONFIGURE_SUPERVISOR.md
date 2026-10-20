# Configure Supervisor
## Versions
* VCF 9.0
* vCenter Server 9.0.2

## References
* [vSphere Supervisor Platform](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/vsphere-supervisor-installation-and-configuration.html)

## Requirements
* VCF 9.0 deployed and configured
* vSAN ESA storage
* NSX edge networking and VPC configured
* Supervisor (Workload Control Plane) deployed using VPC networking

## Deployment Procedure

### 1. Log in to vCenter
Log in to vCenter with an account that has administrator privileges. The account can be local or in VCF SSO.
<br>
<br>

### 2. Open Supervisor Management
From the main vCenter menu, select **Supervisor Management**, then select **New Namespace**.

Note. This step assumes the Supervisor is already deployed and configured.
<br>
<br>

### 3. Create the Supervisor Namespace
In the Create Namespace window:
1. On the **Location** tab, select the Supervisor.
2. On the **Configuration** tab, enter a DNS-compliant name. This guide uses `kubedb-prod`.
3. On the **Add Zones** tab, select the available zones. Select three vSphere Zones for rack or site-level isolation when they are available.
4. On the **Review** tab, check the information, then click **Finish**.
<br>
<br>

### 4. Configure the Supervisor Namespace
1. Under **Namespaces**, select `kubedb-prod`.
2. On the namespace summary page, in the **Storage** panel, select **Add Storage**.
3. In the **Select Storage Policies** window, select **vSAN ESA Default Policy - RAID5**. It appears in the VKS cluster as the StorageClass `vsan-esa-default-policy-raid5` (and `vsan-esa-default-policy-raid5-latebinding`).
4. In the **VM Service** panel, select **Add VM Class** and add:
   * **guaranteed-large** (control plane nodes)
   * **best-effort-2xlarge** (worker nodes)
5. Check that the **Storage** and **VM Class** panels list the selected policy and classes.

Note. Use guaranteed VM classes for workers that host databases with strict latency targets. With the full KubeDB Platform stack, a single best-effort-medium control plane node ran at 95% memory or more during validation, so use guaranteed-large with three replicas for production.
<br>
<br>

### 5. Assign Permissions (optional)
If the users who manage the namespace are not in the administrators group, add them to the namespace with the **Namespace Owner** role so they can deploy VKS clusters.

1. On the namespace, select the **Permissions** tab, then **Add Permission**.
2. In the **Add Permission** window:
   * Select the domain
   * Select the user or group
   * Assign the **Namespace Owner** role
   * Select **Propagate to Children**
3. Check that the user or group is listed with the correct role.
