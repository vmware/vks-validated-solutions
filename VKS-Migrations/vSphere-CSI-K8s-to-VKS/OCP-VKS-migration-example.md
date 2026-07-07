
# Example migration from OCP to VKS

## Here we assume:
### 1. We have access to the OCP cluster, the Supervisor and VKS is available
### 2. We have access to an S3 endpoint
### 3. Velero is installed on both OCP and VKS
### 4. The Openshift command line (`oc`) is installed locally



## First, we link to the kubeconfig files
```
export OCP_KUBECONFIG=~/ocp-kubeconfig
export VKS_KUBECONFIG=~/vks-kubeconfig
export SUPERVISOR_KUBECONFIG=~/supervisor-kubeconfig
```

## Next, for convienence we alias commands to the three clusters (Openshift, Superisor, VKS)
```
alias vks='kubectl --kubeconfig=${VKS_KUBECONFIG}'
alias oa='oc --kubeconfig=${OCP_KUBECONFIG}'
alias sup='kubectl --kubeconfig=${SUPERVISOR_KUBECONFIG}'
```

######   
# 1. Define Variables:
######

### get a random UUID
`export UUID=$(cat /proc/sys/kernel/random/uuid)`

### the source namespace in OCP
`export SOURCE_NS=default`

### the target namespace on VKS
`export TARGET_NS=velero-migration-target`

### the supervisor namespace
`export SUPERVISOR_NS=migration-target`

### the s3 url
`export S3_URL=https://my-s3-endpoint`

### name of the velero bucket
`export BUCKET=velerobucket1`

### source PVC 
`export PVC_NAME=data-migration-test`

### source storage class
`export SOURCE_SC=thin-csi`

### get the size of the PVC
`export PVC_SIZE=$(oa get pvc $PVC_NAME -o json | jq -r '.status.capacity.storage')`



######
# 2. Create Snapshot of the source PVC:
######
```
export SNAPSHOT_CLASS=$(
  oa get volumesnapshotclasses.snapshot.storage.k8s.io \
    | awk '/vsphere/{print $1; exit}'
)

oa apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${PVC_NAME}-snapshot
  namespace: ${SOURCE_NS}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF

oa -n ${SOURCE_NS} wait \
  --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/${PVC_NAME}-snapshot \
  --timeout=1800s
```


######
# 3. Create Velero backup and restore (to/from the S3 endpoint)
######

## Scale the source to zero
```
oa -n $SOURCE_NS scale deploy --replicas 0 --all
oa -n $SOURCE_NS wait --for=condition=available=false deploy/<deployment-name> --timeout=120s
```

## Create velero backup
```
velero backup create ${SOURCE_NS}-backup-${UUID} \
  --kubeconfig=${OCP_KUBECONFIG} \
  --include-namespaces ${SOURCE_NS} \
  --include-cluster-resources=false \
  --snapshot-volumes=false
```
## Check velero backup
```
velero backup describe ${SOURCE_NS}-backup-${UUID} \
  --kubeconfig=${OCP_KUBECONFIG} \
  --insecure-skip-tls-verify
```

### --> WAIT until backup is 'complete' <---

## Create velero restore
```
velero restore create ${TARGET_NS}-restore-${UUID} \
  --kubeconfig=${VKS_KUBECONFIG} \
  --from-backup ${SOURCE_NS}-backup-${UUID} \
  --namespace-mappings ${SOURCE_NS}:${TARGET_NS} \
  --exclude-resources persistentvolumeclaims
```
## Check velero restore
```
velero restore describe ${TARGET_NS}-restore-${UUID} \
  --kubeconfig=${VKS_KUBECONFIG} \
  --insecure-skip-tls-verify
```
## Inspect the target namespace
`vks -n ${TARGET_NS} get all,pvc`




######
# 5. Zero-copy PVC adoption
######

## Get the underlying PV name from OCP
```
export PV_NAME=$(
  oa -n ${SOURCE_NS} get pvc ${PVC_NAME} \
    -o jsonpath='{.spec.volumeName}'
)
```
## Get the CSI volume handle
```
export VOL_HANDLE=$(
  oa get pv ${PV_NAME} \
    -o jsonpath='{.spec.csi.volumeHandle}'
)
```
## Set the PV to retain on delete
```
oa patch pv $PV_NAME -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

echo "PV: ${PV_NAME}"
echo "FCD/CNS volume handle: ${VOL_HANDLE}"
```
## Delete the source PVC
```
oa delete pvc $PVC_NAME
```
## Register the volume on the supervisor this will create the corresponding supervisor PV and PVC
```
sup apply -f - << EOF
apiVersion: cns.vmware.com/v1alpha1
kind: CnsRegisterVolume
metadata:
  name: adopt-${PVC_NAME}
  namespace: ${SUPERVISOR_NS}
spec:
  volumeID: "${VOL_HANDLE}"
  accessMode: ReadWriteOnce
  pvcName: "${PV_NAME}-migrated"
EOF
```
## Check the registration... should be 'true'
`sup get cnsregistervolumes.cns.vmware.com -o json | jq -r '.items[].status.registered'`

## Check the supervisor PVC
`sup get pvc ${PV_NAME}-migrated`

## Adopt the FCD in VKS by creating a PV with the volume handle pointing to the Supervisor PVC, also create a PVC 
```
vks apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PVC_NAME}-adopted
spec:
  capacity:
    storage: $PVC_SIZE
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: csi.vsphere.vmware.com
    volumeHandle: "${PV_NAME}-migrated"
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${TARGET_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: ${PVC_NAME}-adopted
  resources:
    requests:
      storage: $PVC_SIZE
EOF


## describe the pvc, check for health accessible: should be "yes"
vks -n ${TARGET_NS} get pvc ${PVC_NAME} -o json | jq -r '.items[].metadata.annotations."pv.kubernetes.io/bind-completed"'

```

######
# 6. Source clean-up or restore 
######

## Once data is confirmed, remove the finalizer from the PV and delete it
```
oa patch pv ${PV_NAME} \
  --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'

oa delete pv ${PV_NAME}
```

## If adoption failed, create a clone from the snapshot and PV handle on OCP

```
oa apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}-clone
  namespace: ${SOURCE_NS}
spec:
  storageClassName: ${SOURCE_CLONE_SC}
  dataSource:
    name: ${PVC_NAME}-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF

oa -n ${SOURCE_NS} wait \
  --for=jsonpath='{.status.phase}'=Bound \
  pvc/${PVC_NAME}-clone \
  --timeout=1800s
  ```


