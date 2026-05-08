# Kong Helm On-Prem Deployment
## Versions
* Kong Operator 1.0.2
* vSphere Kubernetes 3.5.0 / VKr 1.34.1
<br>

## References
 #### Note -- Select 'on-prem' as the Deployment Platform: 
   https://developer.konghq.com/operator/dataplanes/get-started/kic/install/  
<br>


## Requirements
### CLI Tools
* kubectl cli v1.34: https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl
* vcf cli v9.0.1: https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.1/
* helm cli v3.19: https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz
<br>


## Deployment Procedure

### 1. Install Cert-Manager Addon
Install the VKS addon for Cert Manager
```bash
# Switch to the supervisor context
vcf context use <SUPERVISOR_CONTEXT>

# List available cert-manager release
vcf addon available list cert-manager

# Install cert-manager add-on
vcf addon install create cert-manager --cluster-name <VKS_CLUSTER_NAME> -y

# Verify the install
vcf addon install list --cluster-name <VKS_CLUSTER_NAME>
```
<details>
<summary>Expected output</summary>

```bash
vcf addon available list cert-manager
  NAMESPACE                 ADDONNAME     VERSION                ADDON-RELEASE-NAME                                        PACKAGE
  vmware-system-vks-public  cert-manager  1.18.2+vmware.2-vks.2  cert-manager.kubernetes.vmware.com.1.18.2-vmware.2-vks.2  cert-manager.kubernetes.vmware.com/1.18.2+vmware.2-vks.2


vcf addon install create cert-manager --cluster-name vks-cluster -y
Addon 'cert-manager' is being installed in the cluster vks-cluster


vcf addon install list --cluster-name vks-cluster
  ADDONNAME                   NAMESPACE             PAUSED  READY  DELETE/UPGRADE
  cert-manager                supervisor-namespace  false   False  Allowed
```
</details>
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

### 3. Create namespaces 'kong' and 'kong-system'
Create a 'kong' namespace and set baseline permissions.
```bash
# Create namespaces
kubectl create namespace kong
kubectl create namespace kong-system

# Label both for baseline security
kubectl label ns --overwrite kong pod-security.kubernetes.io/enforce=baseline
kubectl label ns --overwrite kong-system pod-security.kubernetes.io/enforce=baseline
```
<details>
<summary>Expected output</summary>

```bash
namespace/kong created
namespace/kong-system created
namespace/kong labeled 
namespace/kong-system labeled 
```
</details>
<details>
<summary>Test command: List Namespaces</summary>

```bash
# List ns
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

### 4. Create a Kong Gateway Enterprise License 
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

### 5. Install Kong Operator
For release versions see https://github.com/Kong/kong-operator/releases
```bash
helm upgrade --install kong-operator kong/kong-operator -n kong-system \
  --set image.tag=2.0.6 \
  --set image.repository=harbor-test.content.tmm.broadcom.lab/proxy/kong/kong-operator
  --set global.webhooks.options.certManager.enabled=true
```
<details>
<summary>Expected output</summary>

```bash
Release "kong-operator" does not exist. Installing it now.
NAME: kong-operator
LAST DEPLOYED: Fri Jan 23 16:49:48 2026
NAMESPACE: kong-system
STATUS: deployed
REVISION: 3
TEST SUITE: None
NOTES:
kong-operator-kong-operator has been installed. Check its status by running:

  kubectl --namespace kong-system get pods

For more details, please refer to the following documents:

* https://developer.konghq.com/operator/dataplanes/get-started/kic/create-gateway/
* https://developer.konghq.com/operator/dataplanes/konnectextension/
```
</details>


<br>

### 6. Create Kong Gateway Configuration
Create Kong Gateway Configuration.
```bash
kubectl apply -f - <<'EOF'
kind: GatewayConfiguration
apiVersion: gateway-operator.konghq.com/v2beta1
metadata:
  name: kong
  namespace: kong
spec:
  dataPlaneOptions:
    deployment:
      podTemplateSpec:
        spec:
          containers:
          - name: proxy
            image: kong/kong:3.9.1 
EOF

# Verify kong gw
kubectl -n kong describe gatewayconfigurations.gateway-operator.konghq.com kong
```
<details>
<summary>Expected output</summary>

```bash
gatewayconfiguration.gateway-operator.konghq.com/kong configured

kubectl -n kong describe gatewayconfigurations.gateway-operator.konghq.com kong
Name:         kong
Namespace:    kong
Labels:       <none>
Annotations:  <none>
API Version:  gateway-operator.konghq.com/v2beta1
Kind:         GatewayConfiguration
Metadata:
  Creation Timestamp:  2026-01-23T15:28:32Z
  Generation:          1
  Resource Version:    89744946
  UID:                 db70e58e-8ce0-473c-80c3-1e4f44af8d28
Spec:
  Data Plane Options:
    Deployment:
      Pod Template Spec:
        Spec:
          Containers:
            Image:  kong:3.9.1
            Name:   proxy
Events:   
```
</details>

<br>

### 7. Create a Kong Gateway Class & Gateway
Create a Kong Gateway Class & Gateway.
```bash
kubectl apply -f - <<'EOF'
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: kong
  namespace: kong
spec:
  controllerName: konghq.com/gateway-operator
  parametersRef:
    group: gateway-operator.konghq.com
    kind: GatewayConfiguration
    name: kong
    namespace: kong
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kong
  namespace: kong
spec:
  gatewayClassName: kong
  listeners:
    - name: https
      hostname: kong-admin.content.tmm.broadcom.lab
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: kong-admin-tls
            group: ""
      allowedRoutes:
        namespaces:
          from: Same

    - name: http
      hostname: echo.content.tmm.broadcom.lab
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```
<details>
<summary>Expected output</summary>

```bash
gatewayclass.gateway.networking.k8s.io/kong created
gateway.gateway.networking.k8s.io/kong created
```
</details>

<br>

### 8. Create Certificate 
Create a certificate for Kong from cert-manager. Here we create a self-signed certificate (amend as needed)
```bash
# Here we'll create a self-signed cluster issuer
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF


# Create a certificate using the self-signed issuer
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kong-admin-cert
  namespace: kong
spec:
  secretName: kong-admin-tls
  secretTemplate:
    labels:
      konghq.com/secret: "true"   # required for Kong Operator default selector
  dnsNames:
    - kong-admin.content.tmm.broadcom.lab
  issuerRef:
    kind: ClusterIssuer
    name: selfsigned   # Your Issuer/ClusterIssuer
EOF
```
<details>
</details>

<br>

### 9. Verify Gateway
Ensure gateway class status is *True* and *Accepted* and gateway has an IP and is *programmed*

```bash
kubectl -n kong describe gatewayclasses.gateway.networking.k8s.io kong
Name:         kong
Namespace:
Labels:       <none>
Annotations:  <none>
API Version:  gateway.networking.k8s.io/v1
Kind:         GatewayClass
Metadata:
  Creation Timestamp:  2026-01-23T15:30:20Z
  Generation:          1
  Resource Version:    89746251
  UID:                 a07e9e50-d48b-4378-a738-d3dd0af2a360
Spec:
  Controller Name:  konghq.com/gateway-operator
  Parameters Ref:
    Group:      gateway-operator.konghq.com
    Kind:       GatewayConfiguration
    Name:       kong
    Namespace:  kong
Status:
  Conditions:
    Last Transition Time:  2026-01-23T15:30:20Z
    Message:               GatewayClass is accepted
    Observed Generation:   1
    Reason:                Accepted
    Status:                True
    Type:                  Accepted
Events:                    <none>


kubectl get -n kong gateway kong -o wide

NAME   CLASS   ADDRESS        PROGRAMMED   AGE
kong   kong    10.163.44.47   True         82m
```
<details>
<summary>Expected output</summary>

```bash
secret/kong-enterprise-license created
```
</details>
<br>



## Validation
### 1. Obtain Proxy IP
Fetch the LoadBalancer address for the kong-dp service and store it in the PROXY_IP environment variable:
```bash
PROXY_IP=$(kubectl -n kong get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
echo "Proxy IP is: "$PROXY_IP
```
<details>
<summary>Expected output</summary>

```bash
Proxy IP is: 10.138.216.219
```
</details>
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


### 3. Add a test service ('echo')
Create a test service that will respond to requests.
```bash
kubectl -n kong apply -f https://developer.konghq.com/manifests/kic/echo-service.yaml
```
<details>
<summary>Expected output</summary>

```bash
service/echo created
deployment.apps/echo created
```
</details>
<br>


### 4. Create a route to the test service
Configure HTTPRoute.
```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-http
  namespace: kong
spec:
  parentRefs:
    - name: kong
      sectionName: echo-http
  hostnames:
    - echo.content.tmm.broadcom.lab
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: echo
          port: 1027
EOF          
```
<details>
<summary>Expected output</summary>

```bash
httproute.gateway.networking.k8s.io/kong-admin created
```
</details>
<br>



### 5. Test using curl
Test the echo service using curl.
```bash
# http
curl http://$PROXY_IP/ -H 'Host: echo.content.tmm.broadcom.lab'

# https
curl -k https://$PROXY_IP/ -H 'Host: echo.content.tmm.broadcom.lab'       
```
<details>
<summary>Expected output</summary>

```bash
Welcome, you are connected to node kubernetes-cluster-kmnr-kubernetes-cluster-kmnr-nodepool-eck6qq.
Running on Pod echo-6f4786c4b4-scth9.
In namespace kong.
With IP address 192.168.152.43.

Welcome, you are connected to node kubernetes-cluster-kmnr-kubernetes-cluster-kmnr-nodepool-eck6qq.
Running on Pod echo-6f4786c4b4-scth9.
In namespace kong.
With IP address 192.168.152.43.
```
</details>
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
<br>

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
