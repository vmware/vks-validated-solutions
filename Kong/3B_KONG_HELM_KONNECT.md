# Kong Helm Konnect Deployment
## Versions
* Kong Gateway 3.9
* vSphere Kubernetes 3.5.0 / VKr 1.34.1

## References
* https://developer.konghq.com/gateway/install/kubernetes/konnect/

## Requirements
### CLI Tools
* kubectl cli v1.34: https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl
* vcf cli v9.0.1: https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/
* helm cli v3.19: https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz

## Deployment Procedure

### 1. Set environment variables
To facilitate the creation of multiple deployments in different environments we create and use variables throughout this sample deployment procedure.
```bash
# Kong specific variables
export KONNECT_TOKEN="<kong_personal_access_token>"
```
<details>
<summary>Example</summary>

```bash
# Example
export KONG_PAT="kpat_abc123..."
```
</details>
<br>
<br>

### 2. Install Kong Helm Charts
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


### 3. Create namespace 'kong'
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

### 6. Create Control Plane
Konnect allows you to create a Control Plane in a single API request. Create a Control Plane and capture the details.
```bash
CONTROL_PLANE_DETAILS=$(curl -X POST "https://us.api.konghq.com/v2/control-planes" \
     --no-progress-meter --fail-with-body  \
     -H "Authorization: Bearer $KONNECT_TOKEN" \
     --json '{
       "name": "demo-control-plane"
     }'
)
echo $CONTROL_PLANE_DETAILS | jq
```
<details>
<summary>Expected output</summary>

```bash
{
  "id": "3716f7e4-9ee0-4ebe-884b-54347ef70cc5",
  "name": "demo-control-plane",
  "description": "",
  "labels": {},
  "config": {
    "control_plane_endpoint": "https://xxxxxxxx.us.cp0.konghq.com",
    "telemetry_endpoint": "https://xxxxxxxx.us.tp0.konghq.com",
    "cluster_type": "CLUSTER_TYPE_CONTROL_PLANE",
    "auth_type": "pinned_client_certs",
    "cloud_gateway": false,
    "proxy_urls": []
  },
  "created_at": "2026-01-21T18:55:55.849Z",
  "updated_at": "2026-01-21T18:55:55.849Z"
}
```
</details>
<br>
<br>


### 7. Parse Certificate
Parse the certificates for the Control Plane.
```bash
CONTROL_PLANE_ID=$(echo $CONTROL_PLANE_DETAILS | jq -r .id)
CERT=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' tls.crt);
echo "Cert is: $CERT"
DATA=$(echo '{ "cert": "'$CERT'" }' | jq)
echo "Json is: $DATA"
```

<details>
<summary>Expected output</summary>

```bash
Cert is: -----BEGIN CERTIFICATE-----\nMIIBabc123[...]\n-----END CERTIFICATE-----\n

Json is: {
  "cert": "-----BEGIN CERTIFICATE-----\nMIIBabc123[...]\n-----END CERTIFICATE-----\n"
}
```
</details>
<br>
<br>

### 7. Upload Certificate
Upload the certificates to this Control Plane.
```bash
curl "https://us.api.konghq.com/v2/control-planes/$CONTROL_PLANE_ID/dp-client-certificates" \
     --no-progress-meter \
     --fail-with-body  \
     --header "Authorization: Bearer $KONNECT_TOKEN" \
     --json "$DATA" | jq
```

<details>
<summary>Expected output</summary>

```bash
{
  "item": {
    "id": "abc12345-1234-1234-1234-abcdef123456",
    "created_at": 1769099354,
    "updated_at": 1769099354,
    "cert": "-----BEGIN CERTIFICATE-----\nMIIBabc123[...]\n-----END CERTIFICATE-----\n",
    "metadata": {
      "subject": "CN=kong_clustering",
      "issuer": "CN=kong_clustering",
      "expiry": "1863545805",
      "key_usages": [
        "CERT_KEY_USAGE_TYPE_ENCIPHER_ONLY"
      ],
      "is_ca": true
    }
  }
}
```
</details>
<br>
<br>

### 8. Export Control Plane ID
Export the Control Plane ID and telemetry endpoint for later.
```bash
CONTROL_PLANE_ENDPOINT=$(echo $CONTROL_PLANE_DETAILS | jq -r '.config.control_plane_endpoint | sub("https://";"")')
CONTROL_PLANE_TELEMETRY=$(echo $CONTROL_PLANE_DETAILS | jq -r '.config.telemetry_endpoint | sub("https://";"")')
echo "endpoint: $CONTROL_PLANE_ENDPOINT"
echo "telemetry: $CONTROL_PLANE_TELEMETRY"
```

<details>
<summary>Expected output</summary>

```bash
endpoint: abcd1234df.us.cp0.konghq.com
telemetry: abcd1234df.us.tp0.konghq.com
```
</details>
<br>
<br>


### 9. Create Data Plane YAML
Create a values-dp.yaml file with the following content.
```bash
echo '
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
  konnect_mode: 'on'
  vitals: "off"
  cluster_mtls: pki

  cluster_control_plane: "'$CONTROL_PLANE_ENDPOINT'"
  cluster_telemetry_endpoint: "'$CONTROL_PLANE_ENDPOINT':443"
  cluster_telemetry_server_name: "'$CONTROL_PLANE_ENDPOINT'"
  cluster_cert: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/kong-cluster-cert/tls.key

  lua_ssl_trusted_certificate: system
  proxy_access_log: "off"
  dns_stale_ttl: "3600"
resources:
  requests:
    cpu: 1
    memory: "2Gi"
secretVolumes:
  - kong-cluster-cert
  
# The data plane handles proxy traffic only
proxy:
 enabled: true
  
admin:
 enabled: false
  
manager:
 enabled: false
' > values-dp.yaml
```

### 10. Deploy Data Plane
Deploy the Data Plane using the values-dp.yaml.
```bash
helm install kong kong/kong --values ./values-dp.yaml -n kong --create-namespace
```

<details>
<summary>Expected output</summary>

```bash
NAME: kong
LAST DEPLOYED: Thu Jan 22 16:38:43 2026
NAMESPACE: kong
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
To connect to Kong, please execute the following commands:

HOST=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PORT=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.spec.ports[0].port}')
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
kubectl get pods -o wide

# Expected output: 
NAME                         READY   STATUS    RESTARTS   AGE     IP            NODE                                     NOMINATED NODE   READINESS GATES
kong-kong-abcd123456-9hf4l   1/1     Running   0          4m21s   192.168.1.2   kong-vks-node-pool-4-4s2zp-4dcwb-mb5nt   <none>           <none>
```
</details>
<details>
<summary>Test Command: Curl Proxy</summary>

```shell
# Get IP and Port
HOST=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PORT=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.spec.ports[0].port}')
export PROXY_IP=${HOST}:${PORT}
curl -s $PROXY_IP | jq

# Expected output: 
# This is expected if no services and routes have been setup
{
  "message":"no Route matched with those values",
  "request_id":"259af8281dd2d939b8fe081564445f20"
}
```
</details>
<br>
<br>


## Validation
### 1. Verify Control Plane 
Ensure the control plane created in [Step 6](#6-Create-Control-Plane) is showing up in the [Kong Gateway Manager](https://cloud.konghq.com/us/gateway-manager/).
<details>
<summary>Images</summary>

![Kong Control Panel Gateways](images/img_18.png "Kong Gateways")
</details>
<br>
<br>

### 2. Verify Data Plane
Ensure the data plane created in [Step 10](#10-Deploy-Data-Plane) is showing up in the [Kong Gateway Manager](https://cloud.konghq.com/us/gateway-manager/) under **Data Plane Nodes**.
<details>
<summary>Images</summary>

![Kong Control Panel Data Planes](images/img_19.png "Data Plane Nodes")
</details>
<br>
<br>


### 3. Add Kong-Air Service and Route
1. Select gateway (e.g. demo-control-plane)
2. On the control plane, select **Add a service and route**.
3. On the **Configure New API** page, select **Get Flight Details**.
4. The Service fields should automatically populate
   * Service Name: Kong-Air-Flights-API
   * Service URL: https://api.kong-air.com/flights
5. The Route fields should automatically populate
   * Route Name: Kong-Air-Flights-API
   * Route Path: /first-path
6. Click **Save**
7. On the **Routes** tab, ensure the new route is listed.

<details>
<summary>Images</summary>

![vSphere login with VCF SSO](images/img_20.png "vSphere Login")
![vSphere login with VCF SSO](images/img_21.png "vSphere Login")
![vSphere login with VCF SSO](images/img_22.png "vSphere Login")
![vSphere login with VCF SSO](images/img_23.png "vSphere Login")
</details>
<br>
<br>

### 4. Test Route
Connect to the new route.
```bash
HOST=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PORT=$(kubectl get svc --namespace kong kong-kong-proxy -o jsonpath='{.spec.ports[0].port}')
export PROXY_IP=${HOST}:${PORT}
curl -s $PROXY_IP/first-path | jq
```
<details>
<summary>Expected output</summary>

```json
[
  {
    "number": "KA0284",
    "route_id": "LHR-JFK",
    "scheduled_arrival": "2024-04-05T08:25:00Z",
    "scheduled_departure": "2024-04-05T16:05:00Z"
  },
  {
    "number": "KA0285",
    "route_id": "LHR-SFO",
    "scheduled_arrival": "2024-04-03T11:10:00Z",
    "scheduled_departure": "2024-04-03T22:15:00Z"
  },
  {
    "number": "KA0286",
    "route_id": "LHR-DXB",
    "scheduled_arrival": "2024-03-04T12:40:00Z",
    "scheduled_departure": "2024-03-04T19:45:00Z"
  },
  {
    "number": "KA0287",
    "route_id": "LHR-HKG",
    "scheduled_arrival": "2024-02-10T17:40:00Z",
    "scheduled_departure": "2024-02-11T06:20:00Z"
  },
  {
    "number": "KA0288",
    "route_id": "LHR-BOM",
    "scheduled_arrival": "2024-02-13T09:30:00Z",
    "scheduled_departure": "2024-02-13T18:40:00Z"
  },
  {
    "number": "KA0289",
    "route_id": "LHR-HND",
    "scheduled_arrival": "2024-04-01T08:55:00Z",
    "scheduled_departure": "2024-04-01T22:35:00Z"
  },
  {
    "number": "KA0290",
    "route_id": "LHR-CPT",
    "scheduled_arrival": "2024-01-01T10:00:00Z",
    "scheduled_departure": "2024-01-01T22:35:00Z"
  },
  {
    "number": "KA0291",
    "route_id": "LHR-SYD",
    "scheduled_arrival": "2023-12-31T11:59:00Z",
    "scheduled_departure": "2024-01-01T22:15:00Z"
  },
  {
    "number": "KA0292",
    "route_id": "LHR-SIN",
    "scheduled_arrival": "2024-06-01T03:00:00Z",
    "scheduled_departure": "2024-06-01T16:15:00Z"
  },
  {
    "number": "KA0293",
    "route_id": "LHR-LAX",
    "scheduled_arrival": "2024-04-03T11:10:00Z",
    "scheduled_departure": "2024-04-03T22:15:00Z"
  }
]
```
</details>
<br>
<br>


## Cleanup Procedure

```shell
# Remove kong operator
helm uninstall kong-operator --namespace kong-system

# Delete kong-system namespace
kubectl delete namespace kong-system

#Delete the namespace
kubectl delete namespace $CLUSTER_NAMESPACE_NAME

# Switch to supervisor context 
vcf context use $SUPERVISOR_CONTEXT:$SUPERVISOR_NAMESPACE_NAME

# Delete VKS cluster as defined in vks.yaml
kubectl delete -f vks.yaml
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

