# Scality RING object storage on VKS with the Scality COSI driver

Manifests for the reference architecture "Scality RING COSI on VMware vSphere Kubernetes Service". Validated with Scality COSI driver 1.0.2, COSI controller v0.2.2 (API v1alpha1) and Scality RING 9.5.3.

Prerequisites: a VKS cluster, a kubectl context with cluster-admin rights, Helm 3, and a RING account whose keys can create buckets and IAM users.

## Install

```bash
# 1. COSI CRDs and controller (v0.2.2 matches the driver's v1alpha1 API)
kubectl apply -k "github.com/kubernetes-sigs/container-object-storage-interface//?ref=v0.2.2"
kubectl -n container-object-storage-system wait deploy --all --for=condition=Available --timeout=300s

# 2. Pod Security level for the driver namespace
kubectl label ns --overwrite container-object-storage-system \
  pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged

# 3. Scality COSI driver
helm upgrade --install scality-cosi-driver \
  oci://ghcr.io/scality/cosi-driver/helm-charts/scality-cosi-driver --version 1.0.2 \
  --namespace container-object-storage-system --wait

# 4. RING connection Secret (edit the placeholders first) and the classes
kubectl apply -f manifests/01-ring-cosi-secret.yaml
kubectl apply -f manifests/02-cosi-classes.yaml
```

## Validate

```bash
# Team A: namespace, bucket and credentials, then the application pod
kubectl apply -f manifests/03-app-team-a.yaml
kubectl -n app-team-a wait bucketclaim/app-bucket --for=jsonpath='{.status.bucketReady}'=true --timeout=300s
kubectl -n app-team-a wait bucketaccess/app-access --for=jsonpath='{.status.accessGranted}'=true --timeout=300s
kubectl -n app-team-a apply -f manifests/04-app-pod.yaml
kubectl -n app-team-a wait pod/app-a --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl -n app-team-a logs app-a

# Team B: second namespace (Retain class), then the isolation check against team A's bucket
kubectl apply -f manifests/05-app-team-b.yaml
kubectl -n app-team-b wait bucketaccess/app-access-b --for=jsonpath='{.status.accessGranted}'=true --timeout=300s
BUCKET_A=$(kubectl get bucket \
  $(kubectl -n app-team-a get bucketclaim app-bucket -o jsonpath='{.status.bucketName}') \
  -o jsonpath='{.status.bucketID}')
sed "s/<TEAM_A_BUCKET>/$BUCKET_A/" manifests/06-isolation-check.yaml | kubectl -n app-team-b apply -f -
kubectl -n app-team-b wait pod/isolation-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl -n app-team-b logs isolation-check | tail -1   # OK: access denied

# Revocation: the driver deletes the IAM user and keys, the Secret is removed
kubectl -n app-team-b delete bucketaccess app-access-b
kubectl -n app-team-b get secret app-bucket-b-creds   # NotFound

# Delete policy: remove the objects first (for example from the app-a pod), then
kubectl -n app-team-a delete bucketaccess app-access
kubectl -n app-team-a delete bucketclaim app-bucket
kubectl get bucket   # the Bucket record is gone
```

## Clean up

Delete the COSI objects before the namespaces: their finalizers are cleared only by the COSI controller and driver.

```bash
for ns in app-team-a app-team-b; do
  kubectl -n $ns delete pod --all
  kubectl -n $ns delete bucketaccess --all   # removes IAM users and keys
  kubectl -n $ns delete bucketclaim --all    # removes Delete-policy buckets
  kubectl delete namespace $ns
done
```

Team B's claim uses `scality-retain`, so its bucket stays on RING after clean-up. Remove it with an S3 client using the RING account keys.

## References

- Scality COSI driver: https://github.com/scality/cosi-driver
- COSI: https://github.com/kubernetes-sigs/container-object-storage-interface
