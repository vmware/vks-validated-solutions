# Splunk Observability Cloud on VKS

This example installs the Splunk OpenTelemetry Collector Helm chart on a
VMware vSphere Kubernetes Service (VKS) cluster. It keeps the VKS-specific
configuration separate from the cluster identity and keeps the Splunk access
token out of Helm values and Helm release history.

The example is intentionally small:

- `namespace.yaml` creates the namespace with the Pod Security Admission (PSA)
  level needed by the node collector.
- `vks-values.yaml` contains only the deliberate VKS non-root override.
- `cluster-values.example.yaml` contains the values that differ between
  clusters.

The chart creates its own ServiceAccount, ClusterRole, and ClusterRoleBinding.
The identity running Helm therefore needs permission to create cluster-scoped
RBAC resources.

## Why the namespace is `privileged`

The default Splunk agent DaemonSet uses node-level facilities in order to
collect node telemetry:

| Chart behaviour | Baseline PSA |
| --- | --- |
| `hostNetwork: true` | Disallowed |
| node `hostPath` mounts | Disallowed |
| non-zero `hostPort` values | Disallowed |

Consequently, `baseline` or `restricted` enforcement cannot admit the standard
agent. Setting `runAsUser: 20000` does not change those violations. A
`privileged` namespace is therefore required for the standard chart on VKS.
This is a namespace admission level; it does not itself set the collector
container to `privileged: true`.

The namespace also audits and warns against the `restricted` standard. Warnings
about the deliberate host access are expected during installation.

## 1. Add the chart repository

```bash
helm repo add splunk-otel-collector-chart \
  https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
```

Pin the chart version used by this example. Version `0.157.0` was current when
the example was prepared:

```bash
CHART_VERSION=0.157.0
```

The chart project warns that minor releases can include breaking changes, so
change this version deliberately after reviewing the release notes and rendered
manifests.

## 2. Create the namespace

```bash
kubectl apply -f namespace.yaml
```

Do not replace this with Helm's `--create-namespace`: the PSA labels must exist
before the chart submits its workloads.

## 3. Set the cluster values

```bash
cp cluster-values.example.yaml cluster-values.yaml
```

Edit `cluster-values.yaml`:

- `clusterName` is required for VKS and should uniquely identify the cluster.
- `splunkObservability.realm` is the realm assigned to the Splunk organisation.
- `environment` is a deployment lifecycle value such as `test` or
  `production`. It should not be set to `vks`; VKS is the platform, not the
  deployment environment.

Leave `distribution` unset. The Splunk chart has no `vks` distribution value
and treats an unset value as Kubernetes/other.

## 4. Create the access-token Secret

The chart expects a pre-existing Secret key named
`splunk_observability_access_token`.

```bash
read -rsp 'Splunk Observability access token: ' SPLUNK_ACCESS_TOKEN
printf '\n'

kubectl --namespace splunk-otel create secret generic \
  splunk-otel-credentials \
  --from-literal="splunk_observability_access_token=${SPLUNK_ACCESS_TOKEN}" \
  --dry-run=client \
  --output=yaml |
kubectl apply -f -

unset SPLUNK_ACCESS_TOKEN
```

The token is neither written to a values file nor passed to Helm. For a
production GitOps workflow, create the same Secret key with the organisation's
normal secret manager.

## 5. Check the rendered resources

This checks both chart rendering and whether the current VKS identity can
submit the resulting objects:

```bash
helm template splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  --version "${CHART_VERSION}" \
  --namespace splunk-otel \
  --values vks-values.yaml \
  --values cluster-values.yaml |
kubectl apply --dry-run=server -f -
```

## 6. Install

```bash
helm upgrade --install splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  --version "${CHART_VERSION}" \
  --namespace splunk-otel \
  --values vks-values.yaml \
  --values cluster-values.yaml \
  --atomic \
  --timeout 10m
```

There is no need to set `gateway.enabled=false`; `false` is already the chart
default.

## 7. Verify

```bash
helm status splunk-otel-collector --namespace splunk-otel
kubectl --namespace splunk-otel get daemonsets,deployments,pods
kubectl --namespace splunk-otel get events \
  --sort-by=.metadata.creationTimestamp
```

For collector startup or export errors:

```bash
kubectl --namespace splunk-otel logs \
  --selector app.kubernetes.io/instance=splunk-otel-collector \
  --all-containers \
  --prefix \
  --tail=100
```

## What this sends

With only `splunkObservability` configured, the chart sends metrics and traces
to Splunk Observability Cloud. Container logs require a Splunk Platform
destination (HEC) and are a separate configuration.

## Optional: use the chart's root default

The chart normally runs the agent as root so it can read node-owned log files.
This example retains the original non-root intent by setting UID and GID
`20000`; the chart then adds an init container to adjust node log-directory
access. To use the upstream root default instead, omit `vks-values.yaml` from
the render and install commands. The namespace must remain `privileged` because
the host network, host ports, and host-path mounts are independent of UID.
