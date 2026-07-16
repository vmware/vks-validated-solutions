# Coherent Spark Hybrid Runner Deployment
## Versions
* Coherent Spark Hybrid Runner (nodegen-server) v1.53.4
* vSphere Kubernetes 3.6.0 / VKr 1.35.5

## References
* [Coherent Spark Documentation](https://docs.coherent.global)
* [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)

## Requirements
### CLI Tools
* kubectl cli v1.35: https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
* vcf cli v9.0.1: https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/

### Deployment Model
Coherent Spark supports SaaS, on-premises, and hybrid deployment models. This procedure validates the **hybrid** model: service authoring, versioning, and identity remain in Coherent Spark SaaS, while the Hybrid Runner (`nodegen-server`) that executes published services runs as a standard Kubernetes Deployment on VKS, resolving compiled WebAssembly (Wasm) service modules from a mounted `ReadWriteMany` volume (`coherent-pvc`). This fits environments that want a single source of truth for service definitions in Spark while keeping execution traffic inside the customer's own network.

The Hybrid Runner is delivered as an OCI image from `ghcr.io/coherent-partners/nodegen-server` and is deployed using standard Kubernetes resources — a Deployment, a Service, a HorizontalPodAutoscaler, and a PersistentVolumeClaim for the mounted Wasm models. It does not require a Helm chart or custom resource definitions.

## Deployment Procedure

### 1. Create namespace 'coherent-spark'
```bash
kubectl create namespace coherent-spark
```
<details>
<summary>Expected output</summary>

```bash
namespace/coherent-spark created
```
</details>
<details>
<summary>Test command: List Namespaces</summary>

```bash
kubectl get namespaces

# Expected output
NAME                                 STATUS   AGE
coherent-spark                       Active   4s   # <---- coherent-spark namespace
default                              Active   26m
kube-node-lease                      Active   26m
kube-public                          Active   26m
kube-system                          Active   26m
secretgen-controller                 Active   25m
tkg-system                           Active   25m
velero-vsphere-plugin-backupdriver   Active   25m
vmware-system-antrea                 Active   25m
vmware-system-auth                   Active   25m
vmware-system-cloud-provider         Active   25m
vmware-system-csi                    Active   25m
vmware-system-tkg                    Active   25m
```
</details>
<br>
<br>

### 2. Deploy the models PersistentVolumeClaim
The Hybrid Runner resolves Wasm service modules from a mounted volume. [manifests/rwx-pvc.yaml](manifests/rwx-pvc.yaml) requests a `ReadWriteMany` claim so every `hybrid-runner` replica shares the same model cache.
```bash
kubectl apply -n coherent-spark -f manifests/rwx-pvc.yaml
```
<details>
<summary>Expected output</summary>

```bash
persistentvolumeclaim/coherent-pvc created
```
</details>
<details>
<summary>Test command: Get PVC</summary>

```bash
kubectl get pvc -n coherent-spark

# Expected output
NAME            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                     AGE
coherent-pvc    Bound    pvc-3f2e1a9c-...                           1Gi        RWX            vsan-esa-default-policy-raid5    12s
```
</details>
<br>
<br>

**Note**: `manifests/rwx-pvc.yaml` does not set `storageClassName`, so the claim is bound using the cluster's default storage class (`vsan-esa-default-policy-raid5`, per [manifests/vks.yaml](manifests/vks.yaml)). Uncomment and set `storageClassName` explicitly if the target cluster has a different default.

### 3. Deploy the Hybrid Runner
[manifests/hybrid-runner-k8s-sample.config.yml](manifests/hybrid-runner-k8s-sample.config.yml) deploys the `nodegen-server` image as a Deployment fronted by a `LoadBalancer` Service, plus a `HorizontalPodAutoscaler` that scales between 4 and 8 replicas on memory utilization. Pod anti-affinity is enforced across zones with a `topologySpreadConstraint`.
```bash
kubectl apply -n coherent-spark -f manifests/hybrid-runner-k8s-sample.config.yml
```
<details>
<summary>Expected output</summary>

```bash
service/hybrid-runner-service created
deployment.apps/hybrid-runner created
horizontalpodautoscaler.autoscaling/hybrid-runner-hpa created
```
</details>
<br>
<br>

### 4. Wait for rollout
```bash
kubectl rollout status deployment/hybrid-runner \
  --namespace coherent-spark --timeout=180s
```
<details>
<summary>Test Command: Get pods, service, HPA</summary>

```bash
kubectl get pods,svc,hpa -n coherent-spark

# Expected output
NAME                                READY   STATUS    RESTARTS   AGE
pod/hybrid-runner-7c9b8d6f5b-fxp4k   1/1     Running   0          3m
pod/hybrid-runner-7c9b8d6f5b-q2v9t   1/1     Running   0          3m
pod/hybrid-runner-7c9b8d6f5b-r7m2s   1/1     Running   0          3m
pod/hybrid-runner-7c9b8d6f5b-t4w1x   1/1     Running   0          3m

NAME                            TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)          AGE
service/hybrid-runner-service   LoadBalancer   10.96.142.18   10.138.216.219  3000:31234/TCP   3m

NAME                                        REFERENCE                  TARGETS          MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/hybrid-runner-hpa   Deployment/hybrid-runner   34%/75%          4         8         4          3m
```
</details>
<br>
<br>

Both replicas should report `Running` with `1/1` ready containers. Restart counts above zero on a fresh deployment usually indicate a failed probe or missing PVC — inspect logs first.

### 5. (Optional) Expose behind a Gateway with TLS termination
The `LoadBalancer` Service above exposes plaintext HTTP on port 3000 and is sufficient for internal validation. For production exposure, terminate TLS at the cluster edge using the Kubernetes Gateway API (VKS core package) and cert-manager (VKS add-on), and route to the `hybrid-runner-service` `ClusterIP`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: spark-gateway
  namespace: coherent-spark
spec:
  gatewayClassName: <vks-gateway-class>
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: spark-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: spark-route
  namespace: coherent-spark
spec:
  parentRefs:
    - name: spark-gateway
  hostnames:
    - "spark.<customer-domain>"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: hybrid-runner-service
          port: 3000
```

The Hybrid Runner itself does not perform authentication or authorization. Access controls (mutual TLS, JWT validation, API key checks, IP allow-listing) must be enforced by the Gateway, an upstream API gateway, or a sidecar policy enforcement point.
<br>
<br>

## Validation
Validation confirms three properties of the deployed runtime: the workload is healthy, the runtime starts correctly and resolves models from the mounted PVC, and the Spark execution API responds as documented.

### 1. Confirm runtime startup in logs
```bash
kubectl logs deployment/hybrid-runner -n coherent-spark --tail=20
```
<details>
<summary>Expected output</summary>

```bash
{"Level":"INFO",...,"EventType":"WorkerManager.Load","TextMessage":"Loading model with UUID 287e4d67-ad8b-4078-9ebc-094db838c038 for \"my-tenant\" tenant.","JSONPayload":"{\"tenant\":\"my-tenant\",\"versionId\":\"287e4d67-ad8b-4078-9ebc-094db838c038\",\"modelPath\":\"/models/my-tenant/finance/simple-interest/0.3.1/287e4d67-ad8b-4078-9ebc-094db838c038.zip\",\"size\":1}","SystemIP":"172.17.0.2","TimeStamp":"2026-07-09T22:06:05.857Z"}
{"Level":"INFO",...,"EventType":"WorkerManager.Load","TextMessage":"Model initialization completed successfully","JSONPayload":"{\"tenant\":\"my-tenant\",\"versionId\":\"287e4d67-ad8b-4078-9ebc-094db838c038\"}","SystemIP":"172.17.0.2","TimeStamp":"2026-07-09T22:06:05.947Z"}
```
</details>
<br>
<br>

### 2. Confirm the health endpoint
```bash
kubectl port-forward -n coherent-spark service/hybrid-runner-service 3000:3000
```
In another terminal:
```bash
curl -sS http://localhost:3000/healthcheck
```
<details>
<summary>Expected output</summary>

```bash
{"msg":"ok"}
```
</details>
<br>
<br>

### 3. Execute a Spark service
Given a published Spark service that takes numeric inputs `principal` and `rate` and returns an output `interest`, a representative call against the v3 Execute API is:
```bash
curl -X POST "http://localhost:3000/<tenant>/api/v3/execute" \
  -H "Content-Type: application/json" \
  -d '{
    "request_data": {
      "inputs": {
        "principal": 100000,
        "rate": 0.045
      }
    },
    "request_meta": {
      "service_uri": "folders/finance/services/simple-interest",
      "version": "1.0.0"
    }
  }'
```
<details>
<summary>Expected output</summary>

```json
{
  "status": "Success",
  "response_data": {
    "outputs": {
      "interest": 4500
    }
  },
  "response_meta": {
    "service_id": "...",
    "version_id": "...",
    "process_time": 12
  }
}
```
</details>
<br>
<br>

A successful response with the expected outputs payload proves that the Wasm module was loaded from the mounted PVC, the input contract (`Xinput_*`) was honored, and the output contract (`Xoutput_*`) was satisfied — i.e. the full Spark execution path is functional inside the VKS cluster.

### 4. Confirm autoscaling behavior (optional)
```bash
kubectl get hpa hybrid-runner-hpa -n coherent-spark --watch
```
Generating sustained load against the Service should increase memory utilization and drive `REPLICAS` toward `maxReplicas: 8`; utilization dropping below the `averageUtilization: 75` target should scale back down toward `minReplicas: 4`.


## Cleanup Procedure

```shell
# Delete the Hybrid Runner, Service, and HPA
kubectl delete -n coherent-spark -f manifests/hybrid-runner-k8s-sample.config.yml

# Delete the models PVC
kubectl delete -n coherent-spark -f manifests/rwx-pvc.yaml

# Delete coherent-spark namespace
kubectl delete ns coherent-spark
```


## Troubleshooting

### Useful Commands
```shell
# List all resources in the namespace
kubectl get all -n coherent-spark

# Get detailed pod information
kubectl get pods -n coherent-spark -o wide

# Get container logs
kubectl logs -f deployment/hybrid-runner -n coherent-spark

# Describe the PVC (useful for stuck/pending binds)
kubectl describe pvc coherent-pvc -n coherent-spark

# Get HPA status
kubectl get hpa -n coherent-spark
```
