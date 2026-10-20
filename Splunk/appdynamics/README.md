# AppDynamics on VKS

Run this extension after the [Observability Cloud installation](../README.md).
Commands assume the repository's `Splunk` directory is the working directory
and use Bash (including the credential prompts).

## Validation story

| Component | Destination | What to demonstrate |
| --- | --- | --- |
| Existing Splunk OpenTelemetry Collector and Astronomy Shop instrumentation | Splunk Observability Cloud | VKS infrastructure health and the application's existing distributed traces |
| AppDynamics Cluster Agent | AppDynamics Controller, **Servers > Clusters** | Kubernetes inventory, workload health, resource metrics, and events for `astro-shop` |
| Optional AppDynamics Java agent | AppDynamics Controller application view | Java application tiers/nodes and business transactions for a separate test workload |

Keep the collector installed and use the same cluster base name and namespace
when comparing the two consoles. This validates coexistence and complementary
visibility; cross-product navigation, identity federation, and shared traces
are outside this procedure.

The default is cluster monitoring only. In
`astronomy-shop/splunk-astronomy-shop.yaml`, `JAVA_TOOL_OPTIONS` already loads a
Splunk Java agent for the ad service and a Java load generator. For this
validation, do not enable namespace-wide AppDynamics Java injection into
`astro-shop`. Use the isolated extension below to avoid changing the existing
Observability Cloud APM demonstration.

Splunk's [installation workflow](https://help.splunk.com/en/appdynamics-saas/infrastructure-visibility/26.9.0/monitor-kubernetes-with-the-cluster-agent/installation-overview/installation-workflow)
is the starting point. Its [Helm installation guidance](https://help.splunk.com/en/appdynamics-saas/infrastructure-visibility/26.3.0/monitor-kubernetes-with-the-cluster-agent/installation-overview/install-the-cluster-agent-with-helm-charts)
describes installing the Cluster Agent before adding auto-instrumentation.
The examples here were checked against chart **1.40.1848**, whose defaults
select Cluster Agent **26.7.0-1848** and Operator **26.7.0-1383**. The documentation
version and chart/agent versions are separate.

## 1. Check the target and prerequisites

```bash
kubectl config current-context
kubectl get namespace astro-shop
kubectl get pods -n astro-shop
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n astro-shop
```

Confirm the intended VKS workload cluster, a working metrics API, an AppDynamics
Controller account with the required entitlement/access key, and network access
from the agents to the Controller over HTTPS. Nodes must be able to pull the
AppDynamics images. Check the agent's supported Kubernetes versions against
the actual VKS Kubernetes version before recording a supported configuration.

The installer needs permission to create CRDs and cluster-scoped RBAC. The
namespace monitoring regex limits collected workload scope; it is not an RBAC
security boundary. The Operator and agent still require cluster API access.

## 2. Prepare the chart and namespace

```bash
helm repo add appdynamics-cloud-helmcharts \
  https://appdynamics.jfrog.io/artifactory/appdynamics-cloud-helmcharts/
helm repo update appdynamics-cloud-helmcharts
helm search repo appdynamics-cloud-helmcharts/cluster-agent --versions
APPD_CHART_VERSION=1.40.1848

kubectl apply -f appdynamics/namespace.yaml
cp appdynamics/values.example.yaml appdynamics/values.yaml
```

Edit `controllerInfo.url`, `controllerInfo.account`, and `clusterAgent.appName`.
Use the same base cluster identity as the collector's `clusterName`; this chart
appends the namespace, so `vks-test` appears as `vks-test-appdynamics`.
Keep the exact namespace regex `^astro-shop$` unless deliberately widening
the monitored scope.

The AppDynamics namespace uses `baseline`, as in the lab notes. This is separate
from the collector's `privileged` namespace. This procedure enables neither
InfraViz nor another OTel Collector. Verify admission for the Operator-created
agent pods on your VKS version; Helm rendering alone cannot establish that.

## 3. Create the Controller access-key Secret

```bash
read -r -s -p 'AppDynamics Controller access key: ' APPD_ACCESS_KEY
printf '\n'
kubectl -n appdynamics create secret generic cluster-agent-secret \
  --from-literal="controller-key=${APPD_ACCESS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset APPD_ACCESS_KEY
```

Create this Secret **before** installing Helm. Inspection of the
[pinned chart](https://appdynamics.jfrog.io/artifactory/appdynamics-cloud-helmcharts/cluster-agent/cluster-agent-1.40.1848.tgz)
shows that its Secret template uses `lookup` and leaves an existing Secret alone
when it lacks the annotation `appdynamics.helm.charts/created-by`. Do not add that
annotation or put `accessKey`, `username`, or `password` in Helm values.
If reusing an earlier Helm-managed Secret, review its ownership before following
this fresh-install procedure.

The Controller access key authenticates agent ingestion. A Controller user's
REST username/password serves a different purpose and is only needed below
for the optional API check and instrumentation setup.

## 4. Inspect and install

```bash
helm template appdynamics-cluster-agent \
  appdynamics-cloud-helmcharts/cluster-agent \
  --version "${APPD_CHART_VERSION}" \
  --namespace appdynamics \
  --values appdynamics/values.yaml \
  --include-crds > /tmp/appdynamics-rendered.yaml

helm upgrade --install appdynamics-cluster-agent \
  appdynamics-cloud-helmcharts/cluster-agent \
  --version "${APPD_CHART_VERSION}" \
  --namespace appdynamics \
  --values appdynamics/values.yaml \
  --wait --timeout 10m
```

Inspect the rendered resources before installation. Offline `helm template`
cannot look up the existing Secret and renders an empty Secret stub; **do not
apply that output** over the pre-created Secret. Use Helm for installation so
the live lookup works. The installation identity must be able to read Secrets
in `appdynamics`.

`appdynamics-cluster-agent` is the release name; `1.40.1848` belongs in
`--version`. Placing the version immediately after `helm install -f ...` would
make it a release name and would not pin the chart.

## 5. Verify both telemetry paths

```bash
helm status appdynamics-cluster-agent -n appdynamics
kubectl -n appdynamics get clusteragents
kubectl -n appdynamics get deployments,pods
kubectl -n appdynamics wait --for=condition=Ready pod \
  -l name=clusterAgent --timeout=300s
kubectl -n appdynamics logs -l name=clusterAgent \
  --all-containers --prefix --tail=100
kubectl -n appdynamics get events --sort-by=.metadata.creationTimestamp
kubectl -n splunk-otel get daemonsets,deployments,pods
```

Helm readiness does not establish successful Controller registration. In the
AppDynamics UI, navigate to **Servers > Clusters**, select the cluster, and
confirm `astro-shop` workloads and fresh metrics after collection has started.
If the agent pod has not yet been created, inspect the Operator pod logs and
the Clusteragent resource; retry the readiness check once the pod exists.
For failures, check admission events, image pulls, metrics API availability,
Controller connectivity, account/access-key pairing, and agent logs.

While the Astronomy Shop load generator runs, confirm that Observability Cloud
still shows current Kubernetes metrics and application traces. Record:

- VKS/Kubernetes, Helm chart, Operator, and Cluster Agent versions.
- Cluster identity, namespace scope, and timestamps from both consoles.
- Healthy agent/operator pods and no admission or authentication errors.
- `astro-shop` workload visibility in AppDynamics and continuing telemetry in
  Observability Cloud.

Do not claim AppDynamics business transactions from this monitoring-only step.
The checks above are validation criteria, not recorded live results.

## Optional: validate Java application instrumentation

Use a separate `appd-java-validation` namespace containing a Java application
with no existing OTel/APM agent. Select a Java agent version compatible with
that application's JVM and pin its image tag in a copy of
`java-instrumentation.example.yaml`. This repository does not supply that
additional application.

Splunk's [auto-instrumentation configuration](https://help.splunk.com/en/appdynamics-saas/infrastructure-visibility/26.1.0/monitor-kubernetes-with-the-cluster-agent/auto-instrument-applications-with-the-cluster-agent/auto-instrumentation-configuration)
supports namespace and workload selection. The overlay targets only the
dedicated Java namespace, while continuing to monitor `astro-shop`.
Auto-instrumentation modifies workloads and triggers application rollouts;
see [enable auto-instrumentation](https://help.splunk.com/en/appdynamics-saas/infrastructure-visibility/26.5.0/monitor-kubernetes-with-the-cluster-agent/auto-instrument-applications-with-the-cluster-agent/enable-auto-instrumentation-for-the-cluster-agent).

For the Controller REST check, enter a permitted local API user's username and
the same account as in the values file. `curl` prompts for the password:

```bash
read -r -p 'Controller URL (https://host:443): ' APPD_CONTROLLER_URL
read -r -p 'Controller account: ' APPD_ACCOUNT
read -r -p 'Controller API username: ' APPD_USERNAME
curl --fail --show-error --user "${APPD_USERNAME}@${APPD_ACCOUNT}" \
  "${APPD_CONTROLLER_URL%/}/controller/rest/applications"
```

A successful response checks REST authentication/access to that endpoint; it
does not validate the ingestion access key or every instrumentation permission.
Add the `api-user` credential while retaining `controller-key`:

```bash
read -r -s -p 'Controller access key: ' APPD_ACCESS_KEY
printf '\n'
read -r -s -p 'Controller API password: ' APPD_PASSWORD
printf '\n'
kubectl -n appdynamics create secret generic cluster-agent-secret \
  --from-literal="controller-key=${APPD_ACCESS_KEY}" \
  --from-literal="api-user=${APPD_USERNAME}@${APPD_ACCOUNT}:${APPD_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset APPD_ACCESS_KEY APPD_PASSWORD APPD_USERNAME APPD_ACCOUNT APPD_CONTROLLER_URL

cp appdynamics/java-instrumentation.example.yaml appdynamics/java-instrumentation.yaml
# Edit the Java agent image tag before running the upgrade.
helm upgrade appdynamics-cluster-agent \
  appdynamics-cloud-helmcharts/cluster-agent \
  --version "${APPD_CHART_VERSION}" \
  --namespace appdynamics \
  --values appdynamics/values.yaml \
  --values appdynamics/java-instrumentation.yaml \
  --wait --timeout 10m
```

Inspect the target Deployment and new pods for the injected init container,
agent volume, and JVM options. Wait for its rollout, generate traffic, then
verify tiers/nodes and business transactions under `VKS-Java-Validation` in the
Controller. Recheck Astronomy Shop traces in Observability Cloud. Capture the
selected Java image tag and results separately from the Cluster Agent checks.

Before reverting instrumentation, follow Splunk's removal procedure for the
selected agent version and restore the application's original pod template;
turning off injection or uninstalling the Operator alone is not proof that an
already-instrumented workload has been restored.
