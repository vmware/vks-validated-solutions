# Traefik Proxy Deployment (Gateway API)
## Versions
* Traefik Helm chart 41.6.1 / Traefik Proxy v3.7.13
* Gateway API v1.5.1 (Standard channel from the VKS package, plus the Experimental TCPRoute)
* cert-manager v1.18.2
* vSphere Kubernetes Service 3.7.0 / VKr v1.36.2

## References
* [Traefik Kubernetes Gateway API provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)
* [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart)
* [cert-manager](https://cert-manager.io/docs/)

## Requirements
* The VKS cluster of [Step 2](2_VKS_DEPLOYMENT.md), with the cluster context active
* CLI tools: `kubectl`, `helm`, `curl`, `jq`
* Run every command from the `Traefik/` folder, in one shell session.

## Deployment Procedure

### 1. Set environment variables
Your values, and where to find them. The examples are the [example environment](README.md#example-environment)
used in every expected output of this folder.

| Variable | Example | Where to find it |
|---|---|---|
| `DOMAIN` | `example.com` | the DNS domain of your routes (`echo.$DOMAIN`, later `dashboard.`, `ai.`, `mcp.`, `migration.`); no record is needed, the checks use `curl --resolve` |
| `CHART_VERSION` | `41.6.1` | fixed by this validation (Traefik Proxy v3.7.13; Traefik Hub v3.21.0 in step 3B) |
| `WORK` | `~/traefik-vks-work` | fixed: the working directory of all guides, outside the repository |

```bash
# Update with your values (see the table above)
export DOMAIN="<your_domain>"
export CHART_VERSION="41.6.1"
export WORK="$HOME/traefik-vks-work"; mkdir -p "$WORK"; chmod 700 "$WORK"

env | grep -E '^(DOMAIN)=.*<' && echo "Replace the <placeholders> above first"
```
<br>
<br>


### 2. Add the Experimental-channel Gateway API CRDs
VKS installs the Standard-channel v1.5.1 CRDs with its package manager (kapp), which owns their
fields, and protects them with the `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy.
The Experimental bundle therefore creates only the CRDs that do not exist yet (TCPRoute, UDPRoute and
two `x-k8s.io` CRDs) and reports a conflict for each VKS-managed object. **The command exits with
code 1: this is expected. Do not add `--force-conflicts`.**
```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml \
  || echo "exit $? (expected: conflicts with the VKS-managed CRDs)"
```

<details>
<summary>Expected output (abridged)</summary>

```text
customresourcedefinition.apiextensions.k8s.io/tcproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/xbackendtrafficpolicies.gateway.networking.x-k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/xmeshes.gateway.networking.x-k8s.io serverside-applied
error: Apply failed with 2 conflicts: conflicts with "kapp" using apiextensions.k8s.io/v1:
- .metadata.annotations.gateway.networking.k8s.io/channel
- .spec.versions
...
(10 conflicts in total: 8 Standard CRDs, the ValidatingAdmissionPolicy and its binding)
exit 1 (expected: conflicts with the VKS-managed CRDs)
```
</details>
<details>
<summary>Test command: CRD channels</summary>

```text
kubectl get crd tcproutes.gateway.networking.k8s.io gateways.gateway.networking.k8s.io \
  -o custom-columns='NAME:.metadata.name,CHANNEL:.metadata.annotations.gateway\.networking\.k8s\.io/channel,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version'

NAME                                  CHANNEL        VERSION
tcproutes.gateway.networking.k8s.io   experimental   v1.5.1
gateways.gateway.networking.k8s.io    standard       v1.5.1
```
</details>
<br>
<br>


### 3. Add the Traefik Helm repository and create the traefik namespace
```bash
helm repo add --force-update traefik https://traefik.github.io/charts
helm repo update traefik
kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace traefik --overwrite pod-security.kubernetes.io/enforce=baseline
```
<br>
<br>


### 4. Install Traefik with the Gateway API provider
`manifests/3a/values-proxy.yaml` enables the Gateway API provider with the Experimental channel and
makes the certificate `traefik-tls` (step 5) the default certificate of Traefik. The chart also creates
the GatewayClass `traefik` and a default Gateway `traefik-gateway` with a single HTTP listener on the
`web` entry point; this validation uses its own Gateway `traefik` (step 6), which also terminates HTTPS
on `websecure` with `traefik-tls`, and leaves the default one unused.
```bash
helm upgrade --install traefik traefik/traefik -n traefik --version "$CHART_VERSION" \
  -f manifests/3a/values-proxy.yaml
kubectl -n traefik rollout status deployment/traefik --timeout=180s
```

<details>
<summary>Test command: image and Service</summary>

```text
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
docker.io/traefik:v3.7.13

kubectl -n traefik get svc traefik
NAME      TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)                      AGE
traefik   LoadBalancer   10.96.x.x      203.0.113.53    80:30542/TCP,443:31127/TCP   1m
```
</details>
<br>
<br>


### 5. Install cert-manager and create the TLS certificate
`manifests/3a/clusterissuer.yaml` creates a private CA for the validation (a self-signed root and the
ClusterIssuer `traefik-ca`); in production use your own issuer. `manifests/3a/certificate.yaml` is the
wildcard certificate `traefik-tls` for `*.$DOMAIN`.
```bash
helm repo add --force-update jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.18.2 --set crds.enabled=true
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s

kubectl apply -f manifests/3a/clusterissuer.yaml
kubectl -n cert-manager wait certificate/traefik-root-ca --for=condition=Ready --timeout=120s
sed "s/example.com/$DOMAIN/g" manifests/3a/certificate.yaml | kubectl apply -f -
kubectl -n traefik wait certificate/traefik-tls --for=condition=Ready --timeout=120s

# The CA that clients use to verify the gateway (curl --cacert below)
kubectl -n traefik get secret traefik-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/gateway-ca.crt"
```

<details>
<summary>Expected output</summary>

```text
clusterissuer.cert-manager.io/selfsigned created
certificate.cert-manager.io/traefik-root-ca created
clusterissuer.cert-manager.io/traefik-ca created
certificate.cert-manager.io/traefik-root-ca condition met
certificate.cert-manager.io/traefik-tls created
certificate.cert-manager.io/traefik-tls condition met
```
</details>
<br>
<br>


### 6. Create the Gateway
```bash
sed "s/example.com/$DOMAIN/g" manifests/3a/gateway.yaml | kubectl apply -f -
kubectl -n traefik wait gateway/traefik --for=condition=Programmed --timeout=120s
kubectl -n traefik get gateway traefik
```

<details>
<summary>Expected output</summary>

```text
gateway.gateway.networking.k8s.io/traefik created
gateway.gateway.networking.k8s.io/traefik condition met
NAME      CLASS     ADDRESS       PROGRAMMED   AGE
traefik   traefik   203.0.113.53   True         15s
```
</details>
<br>
<br>


## Verification

### 1. Deploy a test workload and its route
```bash
kubectl apply -f manifests/3a/whoami.yaml
kubectl -n traefik rollout status deployment/echo --timeout=120s
sed "s/example.com/$DOMAIN/g" manifests/3a/httproute.yaml | kubectl apply -f -
```
<br>
<br>


### 2. Send test requests with curl
`--resolve` sends the host name to the LoadBalancer address, so no DNS record is needed. HTTPS is
verified with the CA of step 5.
```bash
TRAEFIK_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# Wait until Traefik has loaded the new route (404 until then), then send the requests
curl -s -o /dev/null --fail --retry 10 --retry-all-errors --retry-delay 3 \
  --resolve "echo.$DOMAIN:80:$TRAEFIK_IP" "http://echo.$DOMAIN/"
curl -sS --resolve "echo.$DOMAIN:80:$TRAEFIK_IP" -i "http://echo.$DOMAIN/" | grep -E '^HTTP|^Hostname|Forwarded-Proto'
# --retry: a client clock a few seconds behind the cluster sees a certificate issued
# seconds ago as "not yet valid"
curl -s --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$WORK/gateway-ca.crt" \
  --resolve "echo.$DOMAIN:443:$TRAEFIK_IP" -i "https://echo.$DOMAIN/" \
  | grep -E '^HTTP|^Hostname|Forwarded-Proto'
```

<details>
<summary>Expected output</summary>

```text
HTTP/1.1 200 OK
Hostname: echo-7698b9cd96-s6bfs
X-Forwarded-Proto: http
HTTP/2 200
Hostname: echo-7698b9cd96-s6bfs
X-Forwarded-Proto: https
```
</details>
<br>
<br>


### 3. (Optional) Expose a TCP service through the Experimental channel
Open the entry point `tcp` on port 9000, add the TCP listener to the Gateway and create the TCPRoute.
```bash
helm upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" --reuse-values \
  -f manifests/3a/values-tcp.yaml
kubectl -n traefik rollout status deployment/traefik --timeout=180s
sed "s/example.com/$DOMAIN/g" manifests/3a/gateway-tcp.yaml | kubectl apply -f -
kubectl apply -f manifests/3a/tcproute.yaml
sleep 10
kubectl -n traefik get tcproute echo-tcp \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
# whoami speaks HTTP; the TCPRoute forwards the raw TCP stream on port 9000
curl -sS --max-time 5 "http://$TRAEFIK_IP:9000/" | grep '^Hostname'
```

<details>
<summary>Expected output</summary>

```text
gateway.gateway.networking.k8s.io/traefik configured
tcproute.gateway.networking.k8s.io/echo-tcp created
True
Hostname: echo-7698b9cd96-s6bfs
```
</details>
<br>
<br>


## Cleanup Procedure
```bash
kubectl delete -f manifests/3a/tcproute.yaml --ignore-not-found
kubectl -n traefik delete httproute echo-http gateway traefik --ignore-not-found
kubectl delete -f manifests/3a/whoami.yaml --ignore-not-found
helm uninstall traefik -n traefik
kubectl -n traefik delete certificate traefik-tls --ignore-not-found
kubectl delete -f manifests/3a/clusterissuer.yaml --ignore-not-found
helm uninstall cert-manager -n cert-manager
kubectl delete namespace traefik cert-manager --ignore-not-found
# The Experimental Gateway API CRDs of step 2 stay: other workloads may use them.
```

> Validation status: all steps validated on VKS 3.7.0 (VKr v1.36.2) on 2026-10-02, Cleanup included.
> Commands unchanged in this revision; expected outputs show the example environment of the README.
