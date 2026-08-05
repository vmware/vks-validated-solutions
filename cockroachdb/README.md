# CockroachDB on VMware vSphere Kubernetes Service (VKS)

Validated deployment configuration for running CockroachDB on VKS, developed jointly by Cockroach Labs and Broadcom.

## Architecture Overview on VKS

This integration provisions a VKS cluster purpose-built for CockroachDB's distributed, rack-aware topology:

- **Three worker node pools** (`node-pool-1/2/3`), each mapped to a distinct physical rack via a `node` variable override that applies the `topology.kubernetes.io/region` label (`rack1`–`rack3`) to the nodes. CockroachDB uses these labels as locality tiers so that replicas are spread across fault domains, allowing the cluster to survive the loss of an entire rack.
- **One CockroachDB worker per pool** in the baseline configuration, sized `best-effort-large`. Scale each pool symmetrically to grow the cluster while preserving rack balance.
- **Control plane**: single replica, `best-effort-medium` (lab baseline; use 3 replicas for production).
- **Storage**: vSAN ESA with the `vsan-esa-default-policy-raid5` storage policy as the cluster storage class and as the default persistent volume storage class (set via `vsphereOptions.persistentVolumes.defaultStorageClass`). Each worker carries a dedicated 100Gi containerd volume on the same policy, mounted at `/var/lib/containerd`.
- **Kubernetes release**: `v1.35.0+vmware.2-vkr.4` on Ubuntu 24.04, resolved per control plane and node pool via the `run.tanzu.vmware.com/resolve-os-image: os-name=ubuntu,os-version=24.04` annotation.
- **ClusterClass**: `builtin-generic-v3.6.0` (Cluster API `v1beta2`).

## Prerequisites

- vSphere Supervisor enabled with a vSphere Namespace that has:
  - The `best-effort-large` and `best-effort-medium` VM classes associated
  - The `vsan-esa-default-policy-raid5` storage policy assigned
  - A Kubernetes release providing `v1.35.0+vmware.2-vkr.4` (Ubuntu 24.04 OS image available)
  - The `builtin-generic-v3.6.0` ClusterClass available (VKS 3.6)
- `kubectl` with the vSphere plugin, logged in to the Supervisor
- `kubectl` context set to the target vSphere Namespace

## Deployment

1. Review and adjust `manifests/vks.yaml` (cluster name, CIDRs, VM classes, storage policy) for your environment. The manifest deploys into your current vSphere Namespace context.

2. Apply the cluster manifest against the Supervisor:

   ```bash
   kubectl apply -f manifests/vks.yaml -n <your-vsphere-namespace>
   ```

3. Monitor provisioning:

   ```bash
   kubectl get cluster cluster-vks -n <your-vsphere-namespace>
   kubectl get machinedeployments -n <your-vsphere-namespace>
   ```

4. Once the cluster is `Ready`, log in and switch context to the workload cluster, then deploy CockroachDB (Helm chart or Operator) with locality flags keyed to the rack labels, e.g. `--locality=region=rack1`.

## Validation and Testing

Run the bundled validation script with your kubectl context set to the workload cluster:

```bash
./scripts/validate.sh
```

It checks node readiness, rack topology labels across all three fault domains, the vSAN ESA storage class and default-class configuration, and — once CockroachDB is deployed — pod health and rack-balanced replica placement.

Manual equivalents:

- Confirm all three worker nodes are `Ready` and labeled correctly:

  ```bash
  kubectl get nodes -L topology.kubernetes.io/region
  ```

- Verify the default storage class:

  ```bash
  kubectl get storageclass
  ```

- After deploying CockroachDB, check replica distribution across localities in the DB Console (Network Latency / Node map) or via `SHOW RANGES`, and validate rack-failure tolerance by draining one node pool and confirming the cluster remains available.

## Support

For issues with this deployment configuration on VKS, open a GitHub Issue in this repository. For CockroachDB product issues, contact Cockroach Labs support.
