# Migrating vSphere CSI-based Kubernetes Workloads to VMware vSphere Kubernetes Service (VKS)

## Overview

This repository serves as the companion to the published whitepaper detailing the migration of workloads from vSphere CSI-based Kubernetes Workloads (such as TKGi, Upstream K8s, Openshift, etc.) to VKS. 

## Background

For non-VKS Kubernetes clusters (upstream, OpenShift, etc.) the CSI volumeHandle directly identifies the underlying First Class Disk (FCD) in vCenter

``` 
Source PV
    │ 
    │ .spec.csi.volumeHandle = FCD UUID
    ▼
vCenter FCD
```

<br>

VKS clusters use a modified using a para-virtualized version of the CSI driver. Each VKS PVC points to a Supervisor PVC, which in turn binds to a Supervisor PV with the FCD UUID as the volumeHandle:
 
``` 
VKS PV
    │ 
    │ volumeHandle = Supervisor PVC
    ▼
Supervisor PVC
    │ 
    ▼
Supervisor PV
    │ 
    │ volumeHandle = FCD UUID
    ▼
vCenter FCD
```


<br>

## Using `CnsRegisterVolume` CRD to adopt a volume


The `CnsRegisterVolume` CRD can be invoked to create a Supervisor PV/PVC pair from a vCenter FCD if none exists:

For example, for a given a vSphere CSI PV:

``` 
Source PV
    │ 
    │ .spec.csi.volumeHandle = 2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1
    ▼
vCenter FCD [2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1]
```

<br>

We can invoke the CRD to capture the FCD thus:

```
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: register-application-data
  namespace: destination-supervisor-namespace
spec:
  pvcName: data-volume-adopted
  volumeID: 2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1
  accessMode: ReadWriteOnce
```

<br>

This takes the FCD with UUID `2c5999e4...` and creates a Supervisor PVC named `data-volume-adopted`

```
New Supervisor PVC [data-volume-adopted]
    │ 
    ▼
New Supervisor PV
    │     
    │ volumeHandle = 2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1
    ▼
vCenter FCD [2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1]
```
<br>

This new Supervisor PVC can then be employed by a VKS cluster by creating a new VKS PV object and pointing the CSI `volumeHandle` to the Supervisor PVC:

```
apiVersion: v1
kind: PersistentVolume
metadata:
  name: adopted-vks-pv
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  csi:
    driver: csi.vsphere.vmware.com
    volumeHandle: "data-volume-adopted"
```    

``` 
New VKS PV [adopted-vks-pv]
    │ 
    │ volumeHandle = "data-volume-adopted"
    ▼
New Supervisor PVC [data-volume-adopted]
    │ 
    ▼
New Supervisor PV
    │ 
    │ volumeHandle = 2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1
    ▼
vCenter FCD [2c5999e4-e4a7-4cf8-9220-ac9f2d04f4b1]
```
<br>
No data copy ever takes place.

<br>
<br>

## Using Velero to copy manifest data

In parallel, manifests/etc can be captured by a Velero backup from the source cluster, excluding PVs:

```
velero backup create ${BACKUP_NAME} \
  --kubeconfig=${SOURCE_KUBECONFIG} \
  --include-namespaces ${SOURCE_NS} \
  --include-cluster-resources=false \
  --snapshot-volumes=false \
  --exclude-resources=persistentvolumes
```
<br>
And then restore to the destination cluster, again, excluding PVs

```
velero restore create ${TARGET_NS}-restore-${UUID} \
  --kubeconfig=${VKS_KUBECONFIG} \
  --from-backup ${SOURCE_NS}-backup-${UUID} \
  --namespace-mappings ${SOURCE_NS}:${TARGET_NS} \
  --exclude-resources persistentvolumeclaims
```
<br>
The full migration path is therefore a two-pronged approach:

```
    Manifest path                           Storage adoption path
    ------------                            ---------------------

  OCP namespace manifests                 Original FCD is adopted
        │                                  and moved into VKS path
        │                                        │
        v                                        v
+--------------------+                 +----------------------------+
│ Velero backup      │                 │ Patch OCP PV to Retain      │
│                    │                 │                             │
│ --snapshot-volumes │                 │ Delete / scale source app   │
│ false              │                 │ Delete source PVC           │
│                    │                 │ Wait for VolumeAttachment   │
│ No PVC data copy   │                 │ to disappear                │
+---------+----------+                 +-------------+--------------+
          │                                          │
          │ S3 / NooBaa bucket                       │
          v                                          v
+--------------------+                 +----------------------------+
│ Velero restore     │                 │ vSphere CNS / FCD          │
│ into VKS           │                 │                            │
│                    │                 │ FCD UUID / volumeHandle    │
│ Exclude PVCs       │                 +-------------+--------------+
+---------+----------+                               │
          │                                          │
          v                                          v
+----------------------------+        +-----------------------------+
│ VKS namespace              │        │ Supervisor Namespace        │
│ TARGET_NS                  │        │                             │
│                            │        │ CnsRegisterVolume:          │
│ Restored app manifests     │        │ volumeID: FCD UUID          │
│ initially missing PVC      │        │ pvcName: PV_NAME-migrated   │
+-------------+--------------+        +--------------+--------------+
              │                                      │
              │                                      v
              │                       +-----------------------------+
              │                       │ Supervisor PVC              │
              │                       │                             │
              │                       │ PV_NAME-migrated            │
              │                       +--------------+--------------+
              │                                      │
              v                                      v
+---------------------------------------------------------------+
│ VKS / Workload Cluster                                        │
│                                                               │
│ Static PV                                                     │
│   spec.csi.driver: csi.vsphere.vmware.com                     │
│   spec.csi.volumeHandle: PV_NAME-migrated                     │
│                                                               │
│ Static PVC                                                    │
│   name: PVC_NAME                                              │
│   namespace: TARGET_NS                                        │
│   volumeName: PVC_NAME-adopted                                │
│                                                               │
│ Restored app pod mounts PVC_NAME and uses the adopted FCD     │
+---------------------------------------------------------------+
```
<br>
*Note this is a simplified flow not taking into account any PVC/PV labels, etc.*

<br>
<br>

## Repository Structure

```
├── OCP-VKS-migration-example.md      # Worked example from Openshift to VKS
├── quick-s3-endpoint-for-testing     # Example of a quick S3 endpoint on VKS using `noobaa`
└── README.md                         # Repository root documentation
```