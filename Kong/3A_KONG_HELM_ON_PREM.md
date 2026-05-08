# Kong Helm On-Prem Deployment
## Versions
* Kong Gateway 3.9
* vSphere Kubernetes 3.5.0 / VKr 1.34.1

## References
* https://developer.konghq.com/gateway/install/kubernetes/on-prem/

## Requirements
### CLI Tools
* openssl: https://github.com/openssl/openssl
* kubectl cli v1.34: https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl
* vcf cli v9.0.1: https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/
* helm cli v3.19: https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz

## Deployment Procedure

### 1. Install Kong Helm Charts
Kong provides a Helm chart for deploying Kong Gateway. Add the charts.konghq.com repository and run helm repo update to ensure that you have the latest version of the chart.
```bash
helm repo add kong https://charts.konghq.com
helm repo update kong
```
<details>
<summary>Expected output</summary>

```bash
helm repo update kong
"kong" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "kong" chart repository
Update Complete. ⎈Happy Helming!⎈

```
</details>

<details>
<summary>Test command: Get Kong operator versions</summary>

```bash
helm search repo kong/kong-operator  --versions

NAME              	CHART VERSION	APP VERSION  	DESCRIPTION         
kong/kong-operator	1.0.2        	2.0          	Deploy Kong Operator
kong/kong-operator	1.0.1        	2.0          	Deploy Kong Operator
kong/kong-operator	1.0.0        	2.0.0        	Deploy Kong Operator
kong/kong-operator	0.0.7        	2.0.0-alpha.5	Deploy Kong Operator
kong/kong-operator	0.0.6        	2.0.0-alpha.5	Deploy Kong Operator
kong/kong-operator	0.0.5        	2.0.0-alpha.4	Deploy Kong Operator
kong/kong-operator	0.0.4        	2.0.0-alpha.3	Deploy Kong Operator
kong/kong-operator	0.0.3        	2.0.0-alpha.2	Deploy Kong Operator
kong/kong-operator	0.0.2        	2.0.0-alpha.2	Deploy Kong Operator
kong/kong-operator	0.0.1        	2.0.0-alpha.0	Deploy Kong Operator
```
</details>
<br>
<br>


### 2. Create namespace 'kong'
Create a 'kong' namespace.
```bash
kubectl create namespace kong
```
<details>
<summary>Expected output</summary>

```bash
namespace/kong created
```
</details>
<details>
<summary>Test command: List Namespaces</summary>

```bash
# List certificates
kubectl get namespaces

# Expected output
NAME                                 STATUS   AGE
default                              Active   26m
kong                                 Active   14m # <---- kong namespace
kong-vks-ns                          Active   22m
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


### 3. Create a Kong Gateway Enterprise License 
Create a Kong Gateway Enterprise license secret.

**Note**. Ensure you are in the directory that contains a license.json file before running this command.
```bash
kubectl create secret generic kong-enterprise-license \
  --from-file=license=license.json \
  --namespace kong
```
<details>
<summary>Expected output</summary>

```bash
secret/kong-enterprise-license created
```
</details>
<br>
<br>


### 4. Create clustering certificates 
Kong Gateway uses mTLS to secure the control plane/data plane communication when running in hybrid mode. We Generate a TLS certificate using OpenSSL.
```bash
openssl req -new -x509 -nodes -newkey ec:<(openssl ecparam -name secp384r1) \
  -keyout ./tls.key -out ./tls.crt -days 1095 -subj "/CN=kong_clustering"ls
```
<details>
<summary>Expected output</summary>

```bash
-----
```
</details>
<details>
<summary>Test command: List certificates</summary>

```bash
# List certificates
ls -l tls*

# Expected output
-rw-rw-r-- 1 vmware vmware 676 Jan 20 19:36 tls.crt
-rw------- 1 vmware vmware 306 Jan 20 19:36 tls.key
```
</details>
<br>
<br>


### 5. Create Kubernetes secret
Create a Kubernetes secret containing the certificate.
```bash
kubectl create secret tls kong-cluster-cert \
  --cert=./tls.crt \
  --key=./tls.key \
  --namespace kong
```
<details>
<summary>Expected output</summary>

```bash
secret/kong-cluster-cert created
```
</details>
<br>
<br>


### 6. Deploy Postgres Database (Optional)
If you want to deploy a Postgres database within the cluster for testing purposes, you can install the Cloud Native Postgres operator within your cluster.

**Note**. The postgres manifest contains a username and password that should be changed.

```bash
# Add repo
helm repo add cnpg https://cloudnative-pg.github.io/charts

# Install operator
helm upgrade --install cnpg \
  --namespace cnpg \
  --create-namespace \
  cnpg/cloudnative-pg
  
# Create the database and secret
echo 'apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: kong-cp-db
  namespace: kong
spec:
  instances: 1

  bootstrap:
    initdb:
      database: kong
      owner: kong
      secret:
        name: kong-db-secret

  storage:
    size: 10Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: kong-db-secret
  namespace: kong
type: Opaque
stringData:
  username: kong
  password: demo123' | kubectl apply -f -
```
<details>
<summary>Expected output</summary>

```bash
"cnpg" has been added to your repositories

Release "cnpg" does not exist. Installing it now.
NAME: cnpg
LAST DEPLOYED: Tue Jan 20 20:00:05 2026
NAMESPACE: cnpg
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
CloudNativePG operator should be installed in namespace "cnpg".
You can now create a PostgreSQL cluster with 3 nodes as follows:

cat <<EOF | kubectl apply -f -
# Example of PostgreSQL cluster
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-example
  
spec:
  instances: 3
  storage:
    size: 1Gi
EOF

kubectl get -A cluster


cluster.postgresql.cnpg.io/kong-cp-db created
secret/kong-db-secret created

```
</details>
<br>
<br>

### 7. Create control plane manifest
The control plane contains all Kong Gateway configurations. The configuration is stored in a PostgreSQL database.

**Note 1**. The following manifest connects to a local Postgres instance that was optionally configured in the previous step. Update the Database section with the appropriate values.

**Note 2**. The Kong Manager super admin password is configured in the ```env.password``` field.

```bash
echo '
# Do not use Kong Ingress Controller
ingressController:
  enabled: false
   
image:
  repository: kong/kong-gateway
  tag: "'3.13'"
   
# Mount the secret created earlier
secretVolumes:
  - kong-cluster-cert
   
env:
  # This is a control_plane node
  role: control_plane
  # These certificates are used for control plane / data plane communication
  cluster_cert: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/kong-cluster-cert/tls.key
   
  # Database
  # CHANGE THESE VALUES
  database: postgres
  pg_database: kong
  pg_user: kong
  pg_password: demo123
  pg_host: kong-cp-db-rw.kong.svc.cluster.local
  pg_ssl: "on"
  pg_ssl_version: tlsv1_3        # <- this is KONG_PG_SSL_VERSION
   
  # Kong Manager password
  password: kong_admin_password
   
# Enterprise functionality
enterprise:
  enabled: true
  license_secret: kong-enterprise-license
   
# The control plane serves the Admin API
admin:
  enabled: true
  http:
    enabled: true
   
# Clustering endpoints are required in hybrid mode
cluster:
  enabled: true
  tls:
    enabled: true
   
clustertelemetry:
  enabled: true
  tls:
    enabled: true
   
manager:
  enabled: false
   
# These roles will be served by different Helm releases
proxy:
  enabled: false
' > values-cp.yaml
```
<br>
<br>


### 8. Install the control plane
```bash
helm install kong-cp kong/kong \
 --namespace kong \
 --values ./values-cp.yaml
```

<details>
<summary>Expected output</summary>

```bash
NAME: kong-cp
LAST DEPLOYED: Tue Jan 20 20:16:44 2026
NAMESPACE: kong
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
To connect to Kong, please execute the following commands:

HOST=$(kubectl get svc --namespace kong kong-cp-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PORT=$(kubectl get svc --namespace kong kong-cp-kong-proxy -o jsonpath='{.spec.ports[0].port}')
export PROXY_IP=${HOST}:${PORT}
curl $PROXY_IP

Once installed, please follow along the getting started guide to start using
Kong: https://docs.konghq.com/kubernetes-ingress-controller/latest/guides/getting-started/
```
</details>

<details>
<summary>Test Command: Get pods</summary>

```shell
# Get Pods
kubectl get pods -n kong

# Expected output: 
NAME                                 READY   STATUS      RESTARTS   AGE
kong-cp-db-1                         1/1     Running     0          36m  
kong-cp-kong-5dc755f866-k6sgm        1/1     Running     0          4m14s # <----- Control Plane
kong-cp-kong-init-migrations-j6kng   0/1     Completed   0          4m14s

```
</details>
<br>
<br>


### 9. Create data plane manifest
```bash
echo '
# Do not use Kong Ingress Controller
ingressController:
  enabled: false
   
image:
  repository: kong/kong-gateway
  tag: "3.13"
   
# Mount the secret created earlier
secretVolumes:
  - kong-cluster-cert
   
env:
  # data_plane nodes do not have a database
  role: data_plane
  database: "off"
   
  # Tell the data plane how to connect to the control plane
  cluster_control_plane: kong-cp-kong-cluster.kong.svc.cluster.local:8005
  cluster_telemetry_endpoint: kong-cp-kong-clustertelemetry.kong.svc.cluster.local:8006
   
  # Configure control plane / data plane authentication
  lua_ssl_trusted_certificate: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/kong-cluster-cert/tls.key
   
# Enterprise functionality
enterprise:
  enabled: true
  license_secret: kong-enterprise-license
   
# The data plane handles proxy traffic only
proxy:
  enabled: true
   
# These roles are served by the kong-cp deployment
admin:
  enabled: false
   
manager:
  enabled: false
' > ./values-dp.yaml

```

### 10. Install the data plane
```bash
helm install kong-dp kong/kong \
 --namespace kong \
 --values ./values-dp.yaml
```

<details>
<summary>Expected output</summary>

```bash
NAME: kong-dp
LAST DEPLOYED: Tue Jan 20 20:56:07 2026
NAMESPACE: kong
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
To connect to Kong, please execute the following commands:

HOST=$(kubectl get svc --namespace kong kong-dp-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PORT=$(kubectl get svc --namespace kong kong-dp-kong-proxy -o jsonpath='{.spec.ports[0].port}')
export PROXY_IP=${HOST}:${PORT}
curl $PROXY_IP

Once installed, please follow along the getting started guide to start using
Kong: https://docs.konghq.com/kubernetes-ingress-controller/latest/guides/getting-started/
```
</details>

<details>
<summary>Test Command: Get pods</summary>

```shell
# Get Pods
kubectl get pods -n kong

# Expected output: 
NAME                                 READY   STATUS      RESTARTS   AGE
kong-cp-db-1                         1/1     Running     0          53m
kong-cp-kong-5dc755f866-k6sgm        1/1     Running     0          21m
kong-cp-kong-init-migrations-j6kng   0/1     Completed   0          21m
kong-dp-kong-7b49b8754f-4z2rc        1/1     Running     0          2m1s  # <----- Data Plane
```
</details>
<br>
<br>

## Validation
### 1. Obtain Proxy IP
Fetch the LoadBalancer address for the kong-dp service and store it in the PROXY_IP environment variable:
```bash
PROXY_IP=$(kubectl get service \
  --namespace kong kong-dp-kong-proxy \
  --output jsonpath='{range .status.loadBalancer.ingress[0]}{@.ip}{@.hostname}{end}')
echo "Proxy IP is: "$PROXY_IP
```
<details>
<summary>Expected output</summary>

```bash
Proxy IP is: 10.138.216.219
```
</details>
<br>
<br>

### 2. Test Connection (Failed)
Make an HTTP request to your $PROXY_IP. This will return a HTTP 404 served by Kong Gateway.
```bash
curl --verbose $PROXY_IP/mock/anything 
```

<details>
<summary>Expected output</summary>

```bash
*   Trying 10.138.216.219:80...
* Connected to 10.138.216.219 (10.138.216.219) port 80
> GET /mock/anything HTTP/1.1
> Host: 10.138.216.219
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 404 Not Found               # <---- HTTP/404
< Date: Tue, 20 Jan 2026 21:00:36 GMT
< Content-Type: application/json; charset=utf-8
< Connection: keep-alive
< Content-Length: 103
< X-Kong-Response-Latency: 0
< Server: kong/3.13.0.0-enterprise-edition
< X-Kong-Request-Id: 555731159aaea053565fec5f96869b69
< 
{
  "message":"no Route matched with those values",
  "request_id":"555731159aaea053565fec5f96869b69"
* Connection #0 to host 10.138.216.219 left intact
```
</details>
<br>
<br>

### 3. Create Port-Forward
In another terminal, run kubectl port-forward to set up port forwarding and access the Admin API.
```bash
kubectl port-forward -n kong service/kong-cp-kong-admin 8001
```

<details>
<summary>Expected output</summary>

```bash
Forwarding from 127.0.0.1:8001 -> 8001
Forwarding from [::1]:8001 -> 8001
```
</details>
<br>
<br>

### 4. Create Service and Route
Create a mock Service and Route.
```bash
curl localhost:8001/services -d name=mock -d url="https://httpbin.konghq.com" | jq
curl localhost:8001/services/mock/routes -d "paths=/mock" | jq
```

<details>
<summary>Expected output</summary>

```bash
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   485  100   474  100    11  15125    351 --:--:-- --:--:-- --:--:-- 15645
{
  "regex_priority": 0,
  "destinations": null,
  "methods": null,
  "request_buffering": true,
  "response_buffering": true,
  "created_at": 1769014956,
  "headers": null,
  "strip_path": true,
  "protocols": [
    "http",
    "https"
  ],
  "snis": null,
  "service": {
    "id": "131f324c-7a0e-4a6d-b245-ac83a6e2ce18"
  },
  "tags": null,
  "id": "9af925fb-5d75-4df0-8e74-d075610b8ef5",
  "path_handling": "v0",
  "paths": [
    "/mock"
  ],
  "preserve_host": false,
  "https_redirect_status_code": 426,
  "updated_at": 1769014956,
  "hosts": null,
  "name": null,
  "sources": null
}

  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   485  100   474  100    11  15472    359 --:--:-- --:--:-- --:--:-- 16166
{
  "regex_priority": 0,
  "destinations": null,
  "methods": null,
  "request_buffering": true,
  "response_buffering": true,
  "created_at": 1769015030,
  "headers": null,
  "strip_path": true,
  "protocols": [
    "http",
    "https"
  ],
  "snis": null,
  "service": {
    "id": "131f324c-7a0e-4a6d-b245-ac83a6e2ce18"
  },
  "tags": null,
  "id": "dbb22096-a535-45a9-8486-268f741a91b5",
  "path_handling": "v0",
  "paths": [
    "/mock"
  ],
  "preserve_host": false,
  "https_redirect_status_code": 426,
  "updated_at": 1769015030,
  "hosts": null,
  "name": null,
  "sources": null
}
```
</details>
<br>
<br>

### 5. Test Connection (Success)
Make an HTTP request to your $PROXY_IP again. This time Kong Gateway will route the request to httpbin.
```bash
curl --verbose $PROXY_IP/mock/anything 
```

<details>
<summary>Expected output</summary>

```bash
*   Trying 10.138.216.219:80...
* Connected to 10.138.216.219 (10.138.216.219) port 80
> GET /mock/anything HTTP/1.1
> Host: 10.138.216.219
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 200 OK                   # <---- HTTP/200
< Content-Type: application/json
< Content-Length: 498
< Connection: keep-alive
< Server: gunicorn/19.9.0
< Date: Wed, 21 Jan 2026 17:05:58 GMT
< Access-Control-Allow-Origin: *
< Access-Control-Allow-Credentials: true
< X-Kong-Upstream-Latency: 144
< X-Kong-Proxy-Latency: 0
< Via: 1.1 kong/3.13.0.0-enterprise-edition
< X-Kong-Request-Id: 3b28415ba15b0b66ecaabf246a376878
< 
{
  "args": {}, 
  "data": "", 
  "files": {}, 
  "form": {}, 
  "headers": {
    "Accept": "*/*", 
    "Connection": "keep-alive", 
    "Host": "httpbin.konghq.com", 
    "User-Agent": "curl/8.5.0", 
    "X-Forwarded-Host": "10.138.216.219", 
    "X-Forwarded-Path": "/mock/anything", 
    "X-Forwarded-Prefix": "/mock", 
    "X-Kong-Request-Id": "3b28415ba15b0b66ecaabf246a376878"
  }, 
  "json": null, 
  "method": "GET", 
  "origin": "192.168.3.1", 
  "url": "http://10.138.216.219/anything"
}
* Connection #0 to host 10.138.216.219 left intact
```
</details>
<br>
<br>



## Cleanup Procedure

```shell
# Remove kong 
helm uninstall kong-dp
helm uninstall kong-cp

# Delete Postgres (if deployed)
kubectl delete cluster kong-cp-db -n kong
helm uninstall cnpg -n cnpg
kubectl delete ns cnpg

# Delete kong namespace
kubectl delete ns kong

# Switch to supervisor context 
vcf context use "$SUPERVISOR_CONTEXT":"$SUPERVISOR_NAMESPACE_NAME"

# Delete VKS cluster
kubectl delete "$CLUSTER_NAME"
```


## Troubleshooting

### Useful Commands
```shell
# List all
kubectl get all

# Get detailed pod information
kubectl get pods -o wide

# Get container logs
kubectl logs -f <container name>

# Get all services
kubectl get svc

# Expose a service
kubectl expose service <service_name>  --type=LoadBalancer --name=<service_name>-external

# Get the external IP
kubectl get svc <service_name>-external

# Get TKR releases
kubectl get tkr -l '!kubernetes.vmware.com/kubernetesrelease'

# Get TKE releaase specs
# e.g. kubectl get tkr 'v1.34.1---vmware.1-vkr.4' -o yaml
kubectl get tkr TKR_NAME -o yaml  
```

