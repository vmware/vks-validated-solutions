# Splunk Astronomy Shop — clean Kubernetes setup

Deploy the Splunk Astronomy Shop on a Kubernetes cluster that is already running and still empty of this demo: no Splunk OpenTelemetry Collector, and no Astronomy Shop workloads.

This path uses `kubectl` and Helm. It applies to bare metal, AKS, EKS, Rancher, and any other distribution that can run a DaemonSet with host ports.

The shop manifest is plain Kubernetes YAML. The `*-values.yaml` file is only for the [Splunk OpenTelemetry Collector Helm chart](https://github.com/signalfx/splunk-otel-collector-chart).

## What you need before you start

| Requirement | Detail |
| --- | --- |
| Kubernetes | 1.24 or newer |
| Capacity | Minimum about 8 CPU, 16 GB RAM, 50 GB disk. 16 CPU and 32 GB RAM is a comfortable size for the full shop. |
| Tools | `kubectl` aimed at this cluster, Helm 3+ |
| Splunk Observability Cloud | Realm (for example `us0`, `eu0`), an ingest access token, and a RUM token |
| Node-local collector | The agent DaemonSet must be allowed to bind host ports **4317** (OTLP gRPC) and **4318** (OTLP HTTP). Shop pods export to `http://$(NODE_IP):4318`. |

EKS Fargate and GKE Autopilot do not fit this export path. Those platforms restrict DaemonSets and host ports. Use node pools that can run a privileged host-network DaemonSet.

Optional, for logs in Splunk Cloud or Splunk Enterprise:

- HTTP Event Collector (HEC) URL
- HEC token
- Target index

Optional shop features, stored in the same Kubernetes Secret:

- AppDynamics account token (datacenter dual-instrumentation)
- FlagD username and password
- ThousandEyes agent account token

Confirm the cluster is empty of this demo:

```bash
kubectl config current-context
kubectl get pods -A
```

You should see only the cluster's own system pods. There should be no `splunk-otel-collector` release and no shop components such as `frontend`, `checkout`, or `kafka`.

## 1. Download the release assets

Stitched manifests are published as GitHub Release assets. They are not committed under `kubernetes/` (older copies live in `kubernetes/old-versions/` and are kept for reference only).

The current promoted version is recorded in [`kubernetes/PROMOTED-VERSION`](PROMOTED-VERSION) (2.0.8 at the time of this guide). Download that version:

```bash
VERSION=$(curl -fsSL https://raw.githubusercontent.com/splunk/opentelemetry-demo/main/kubernetes/PROMOTED-VERSION)
# from a clone of the repo you can also run: VERSION=$(cat kubernetes/PROMOTED-VERSION)

BASE=https://github.com/splunk/opentelemetry-demo/releases/download/v${VERSION}

curl -fsSLO "${BASE}/splunk-astronomy-shop-${VERSION}.yaml"
curl -fsSLO "${BASE}/splunk-astronomy-shop-${VERSION}-values.yaml"
```

| File | Use |
| --- | --- |
| `splunk-astronomy-shop-${VERSION}.yaml` | Core Astronomy Shop. Apply with `kubectl`. |
| `splunk-astronomy-shop-${VERSION}-values.yaml` | Helm values for the collector. Requires `splunk-otel-collector-chart` **0.157.0 or newer** (the chart renamed `kubeletstats` to `kubelet_stats` in 0.157.0). |

Release page: `https://github.com/splunk/opentelemetry-demo/releases/tag/v${VERSION}`

Add-on manifests, applied only after the core shop is Ready:

| Asset | Purpose |
| --- | --- |
| `splunk-astronomy-shop-${VERSION}-lambda.yaml` | Lambda / planning scenario |
| `splunk-astronomy-shop-${VERSION}-throttle-demo.yaml` | Order-validation CPU throttle scenario |
| `splunk-astronomy-shop-${VERSION}-dc-shim.yaml` | Datacenter shim, its database, and its load generator |

`splunk-astronomy-shop-${VERSION}-diab.yaml` includes a Traefik ingress. Use it only when this cluster already runs Traefik. AKS, EKS, and Rancher ingress controllers are covered in [Access the store](#5-access-the-store).

## 2. Create the workshop Secret first

The collector values file reads `realm` and `instance` from a Secret named `workshop-secret` in the `default` namespace (`WORKSHOP_REALM`, `WORKSHOP_ENVIRONMENT`). Shop pods read the same Secret for RUM, the load generator URL, and optional integrations.

Create the Secret before Helm. If the collector starts first, the agent and cluster receiver fail with `CreateContainerConfigError` until `realm` and `instance` exist.

Copy the template below to `secrets.yaml` on your workstation. Fill the placeholders from your shell environment. Keep the file out of git.

```bash
export REALM="us0"                          # your Splunk Observability realm
export ENV_NAME="dev-shop"                  # deployment.environment and RUM env
export SPLUNK_ACCESS_TOKEN=""               # ingest token; also used as api_token below
export SPLUNK_API_TOKEN=""                  # set if you use a separate API token
export SPLUNK_RUM_TOKEN=""
export HEC_TOKEN=""                          # leave empty when you are not sending logs via HEC
export HEC_URL=""                            # e.g. https://http-inputs-<stack>.splunkcloud.com:443/services/collector/event
export HEC_INDEX=""                          # e.g. main or o11y-demo-us
export APP_URL="http://localhost:8080"       # public URL of the store once you expose it
```

`APP_URL` is what the browser load generator opens. After you expose the store with a LoadBalancer or ingress, set this to that `https://...` address and roll the load generator so it picks up the new value.

`secrets.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: workshop-secret
  namespace: default
type: Opaque
stringData:
  instance: "dev-shop"                              # same value as ENV_NAME
  app: "dev-shop-store"                             # RUM application name: <ENV_NAME>-store
  env: "dev-shop"
  deployment: "deployment.environment=dev-shop"
  realm: "us0"
  access_token: ""                                  # SPLUNK_ACCESS_TOKEN
  api_token: ""                                     # SPLUNK_API_TOKEN, or the same ingest token
  rum_token: ""                                     # SPLUNK_RUM_TOKEN
  hec_token: ""
  hec_url: ""
  url: "http://localhost:8080"                      # APP_URL
  # Optional. Leave the token empty to skip AppDynamics.
  appd_token: ""
  flagd_auth: "false"
  flagd_user: ""
  flagd_pw: ""
  shipping_api: "false"
```

ThousandEyes is optional. The upstream example stores `TEAGENT_ACCOUNT_TOKEN` under `data`, which Kubernetes treats as base64. Add this block only when you have a token, and encode it with no line breaks:

```bash
printf '%s' "$TE_TOKEN" | base64 | tr -d '\n'
```

```yaml
data:
  TEAGENT_ACCOUNT_TOKEN: "<paste-the-base64-output>"
```

Apply and check the keys exist. The output lists key names, not values.

```bash
kubectl apply -f secrets.yaml
kubectl get secret workshop-secret -n default
kubectl describe secret workshop-secret -n default
```

Keep the filled-in tokens in this local file and in the environment variables passed to Helm. Do not commit `secrets.yaml`.

## 3. Install the Splunk OpenTelemetry Collector

The values file configures the agent DaemonSet and the cluster receiver: Database Monitoring discovery, Kafka metrics, SecureApp log routing, and the resource attributes the shop expects. Install chart **0.157.0** so those values validate.

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update

helm upgrade --install splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.157.0 \
  --namespace default \
  --set "splunkObservability.realm=${REALM}" \
  --set "splunkObservability.accessToken=${SPLUNK_ACCESS_TOKEN}" \
  --set "clusterName=${ENV_NAME}-cluster" \
  --set "environment=${ENV_NAME}" \
  --set "splunkObservability.profilingEnabled=true" \
  --set "splunkObservability.secureAppEnabled=true" \
  --set "agent.service.enabled=true" \
  -f "splunk-astronomy-shop-${VERSION}-values.yaml"
```

`--namespace default` matters: the values file looks up `workshop-secret` in the release namespace.

When you are sending logs to Splunk Cloud or Splunk Enterprise, add the HEC settings to the same command:

```bash
  --set "splunkPlatform.endpoint=${HEC_URL}" \
  --set "splunkPlatform.token=${HEC_TOKEN}" \
  --set "splunkPlatform.index=${HEC_INDEX}" \
```

`agent.service.enabled=true` publishes a Service for the agent. The chart also runs the agent with `hostNetwork` and host ports 4317 and 4318, which is how a shop pod on that node reaches `http://$(NODE_IP):4318`. Leave those defaults in place.

Wait until the agent and the cluster receiver are running:

```bash
kubectl rollout status daemonset/splunk-otel-collector-agent -n default --timeout=300s
kubectl rollout status deployment/splunk-otel-collector-k8s-cluster-receiver -n default --timeout=300s
kubectl get pods -n default -l app=splunk-otel-collector
```

If the DaemonSet or Deployment name differs on your chart patch, list the release:

```bash
kubectl get daemonset,deployment -n default -l app=splunk-otel-collector
```

Read a few agent log lines and confirm export attempts are succeeding before you install the shop:

```bash
kubectl logs -n default -l app=splunk-otel-collector --tail=50
```

## 4. Deploy the Astronomy Shop

```bash
kubectl apply -f "splunk-astronomy-shop-${VERSION}.yaml"
kubectl get pods -n default -w
```

Most services become Ready within a minute. Java services and SQL Server often take two to five minutes.

When the core pods are Ready, optional scenarios are separate files:

```bash
kubectl apply -f "splunk-astronomy-shop-${VERSION}-lambda.yaml"
kubectl apply -f "splunk-astronomy-shop-${VERSION}-throttle-demo.yaml"
kubectl apply -f "splunk-astronomy-shop-${VERSION}-dc-shim.yaml"
```

## 5. Access the store

`frontend-proxy` listens on port 8080. Pick the exposure that matches your cluster.

### Port-forward

Works everywhere, including a cluster with no ingress controller:

```bash
kubectl port-forward -n default svc/frontend-proxy 8080:8080
```

Open `http://localhost:8080`. For this mode, `url` in `workshop-secret` should be `http://localhost:8080` so the load generator targets the same address from a workstation that can reach it. On a remote cluster the load generator runs inside the cluster, so prefer a LoadBalancer or ingress URL that pods can resolve.

### Cloud LoadBalancer

On AKS, EKS, or any cluster with a cloud load balancer, expose the existing Service:

```bash
kubectl patch svc frontend-proxy -n default -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc frontend-proxy -n default --watch
```

Set `url` in `workshop-secret` to `http://<EXTERNAL-IP>` (or `https://...` if you terminate TLS in front of it), then restart the load generator:

```bash
kubectl apply -f secrets.yaml
kubectl rollout restart deployment/astronomy-loadgen -n default
```

### Ingress you already run

Use the ingress class installed on the cluster (`nginx`, `alb`, `traefik`, and so on). Example for an nginx class, with TLS left to your controller:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: astronomy-shop
  namespace: default
spec:
  ingressClassName: nginx
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-proxy
                port:
                  number: 8080
```

```bash
kubectl apply -f ingress.yaml
```

Point `url` at `https://shop.example.com` and restart `astronomy-loadgen` as above.

This guide does not install cert-manager or embed certificates. If you terminate TLS, use the certificate workflow your cluster already has. A hardcoded PEM in the manifest is hard to rotate and still needs an expiration, key-size, signature, and issuer check before it is trusted.

## 6. Verify

### Pods

```bash
kubectl get pods -n default
kubectl get pods -n default --field-selector=status.phase!=Running
```

An empty second list means every pod is Running. `Completed` Jobs, if the manifest includes any, are fine.

### Store

Browse the UI, open a product, add it to the cart, and check out. The load generator (`astronomy-loadgen`) produces the same traffic on its own once `url` is reachable from that pod:

```bash
kubectl logs -n default deployment/astronomy-loadgen --tail=30
```

### Splunk Observability Cloud

| Product | What to look for |
| --- | --- |
| APM | Services filtered by `deployment.environment` equal to your `ENV_NAME` (`instance` / `env` in the Secret) |
| Infrastructure | Kubernetes navigator for cluster `${ENV_NAME}-cluster` (`clusterName`) |
| RUM | Application `${ENV_NAME}-store` (`app` in the Secret) |
| Log Observer | Logs in the HEC index, when HEC settings were supplied |

Metrics such as `k8s.pod.phase` filtered by that cluster name confirm the collector is exporting.

## Troubleshooting

**Collector pods stay pending on the Secret.** `workshop-secret` is missing, is in another namespace, or lacks `realm` / `instance`. Fix the Secret, then `kubectl delete pod -n default -l app=splunk-otel-collector` so the pods restart with the env vars.

**No telemetry in Observability Cloud.** Check realm and access token, and that nodes can reach `https://ingest.<realm>.signalfx.com` on port 443. Confirm an agent pod is Running on the same node as the shop pod (`kubectl get pods -n default -o wide`).

**`ImagePullBackOff`.** The manifest pulls `ghcr.io/splunk/opentelemetry-demo/...`. The node needs outbound access to `ghcr.io`. Describe the pod for the exact image name.

**`CrashLoopBackOff` on a shop pod.** `kubectl logs <pod> --previous` usually shows a missing Secret key or a database that is still starting. SQL Server and Java pods need several minutes on a cold cluster.

**Shop is up and the UI works, but APM is empty.** Confirm the collector was installed with `agent.service.enabled=true` and that host ports 4317/4318 are free on the nodes. Shop containers set `OTEL_EXPORTER_OTLP_ENDPOINT` to `http://$(NODE_IP):4318`.

**Load generator errors.** `url` in the Secret must be an address the generator pod can open. `http://localhost:8080` only works for a port-forward from your laptop, not from inside the cluster.

## Remove the demo

```bash
kubectl delete -f "splunk-astronomy-shop-${VERSION}.yaml"
# also delete any add-on files you applied:
# kubectl delete -f "splunk-astronomy-shop-${VERSION}-lambda.yaml"

helm uninstall splunk-otel-collector --namespace default
kubectl delete secret workshop-secret -n default
```

Delete `secrets.yaml` from the workstation when you are done. It contains the tokens you filled in.

## Related docs

- [`kubernetes/NEW-FILE-LOCATION.MD`](NEW-FILE-LOCATION.MD) — where release manifests live
- [`kubernetes/example-secrets.yaml`](example-secrets.yaml) — Secret key reference
- [`HOW-TO-DEPLOY-AND-RUN.md`](../HOW-TO-DEPLOY-AND-RUN.md) — short deploy overview
- [Splunk OpenTelemetry Collector Helm chart](https://github.com/signalfx/splunk-otel-collector-chart)
