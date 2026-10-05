# Traefik Hub Deployment (API Management, AI Gateway, MCP Gateway)
## Versions
* Traefik Helm chart 41.6.1 / Traefik Hub v3.21.0
* Offline license token (the gateway validates it locally, with no outbound connection)
* vSphere Kubernetes Service 3.7.0 / VKr v1.36.2

## References
* [Traefik Hub documentation](https://doc.traefik.io/traefik-hub/)
* [AI Gateway: chat-completion middleware](https://doc.traefik.io/traefik-hub/ai-gateway/)
* [MCP Gateway](https://doc.traefik.io/traefik-hub/mcp-gateway/)

## Requirements
* [Step 3A](3A_TRAEFIK_PROXY.md) completed: this step upgrades the same Helm release in place.
* A Traefik Hub license token. This validation uses an **offline** token (Traefik Hub Online
  Dashboard, gateway created with the "Offline" toggle). For a connected token, delete the line
  `offline: true` from `manifests/3b/values-hub.yaml`; the gateway then needs outbound HTTPS to the
  Traefik Hub API.
* CLI tools: `kubectl`, `helm`, `curl` (7.84 or later: the dashboard credentials are read from a
  quoted netrc file), `jq`, `openssl`

## Deployment Procedure

### 1. Set environment variables and enter the secrets
Your values, and where to find them. The examples are the [example environment](README.md#example-environment)
used in every expected output of this folder. The secrets are typed at the prompt: they never reach
the command line or the shell history; the dashboard password goes to a file with mode 0600 under
`$WORK`, which the dashboard checks of this guide and of step 3C read.

| Variable | Example | Where to find it |
|---|---|---|
| `DOMAIN` | `example.com` | the DNS domain of your routes; no record is needed, the checks use `curl --resolve` |
| `CHART_VERSION` | `41.6.1` | fixed by this validation (Traefik Hub v3.21.0) |
| `WORK` | `~/traefik-vks-work` | fixed: the working directory of all guides, outside the repository |
| `HUB_TOKEN` (prompt) | | Traefik Hub Online Dashboard → the gateway you created → token (offline) |
| `DASHBOARD_PASSWORD` (prompt) | | a password you choose here for the dashboard user `admin`; step 5 stores its hash |

```bash
# Update with your values (see the table above)
export DOMAIN="<your_domain>"
export CHART_VERSION="41.6.1"
export WORK="$HOME/traefik-vks-work"; mkdir -p "$WORK"; chmod 700 "$WORK"
env | grep -E '^(DOMAIN)=.*<' && echo "Replace the <placeholders> above first"

# Values of step 3A
TRAEFIK_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
kubectl -n traefik get secret traefik-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/gateway-ca.crt"

read -rsp 'Traefik Hub license token: ' HUB_TOKEN; echo
read -rsp 'Dashboard password for admin: ' DASHBOARD_PASSWORD; echo
# The dashboard checks read the credentials from this file (mode 0600, curl 7.84 or later)
printf 'machine dashboard.%s login admin password "%s"\n' "$DOMAIN" "$DASHBOARD_PASSWORD" > "$WORK/dashboard.netrc"
chmod 600 "$WORK/dashboard.netrc"
```

A dashboard password that contains `"` or `\` is not supported by the netrc file.
<br>
<br>


### 2. Store the license token in a Secret
```bash
# --dry-run + apply --server-side: idempotent, and no copy of the token in an annotation
printf '%s' "$HUB_TOKEN" | kubectl -n traefik create secret generic traefik-hub-license \
  --from-file=token=/dev/stdin --dry-run=client -o yaml | kubectl apply --server-side -f -
unset HUB_TOKEN
```
<br>
<br>


### 3. Apply the chart CRDs
Helm does not upgrade CRDs after the first installation, so apply the CRDs of the chart version.
`--force-conflicts` takes over the field ownership of the first installation (these CRDs are not
managed by VKS).
```bash
helm show crds traefik/traefik --version "$CHART_VERSION" \
  | kubectl apply --server-side --force-conflicts -f -
```

<details>
<summary>Expected output (abridged)</summary>

```text
customresourcedefinition.apiextensions.k8s.io/aiservices.hub.traefik.io serverside-applied
...
customresourcedefinition.apiextensions.k8s.io/uplinks.hub.traefik.io serverside-applied
```
</details>
<br>
<br>


### 4. Upgrade the release to Traefik Hub
`manifests/3b/values-hub.yaml` sets the license Secret, Offline Mode and the three gateways. The same
release and namespace are used: there is no operator to install.
```bash
helm upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" --reuse-values \
  -f manifests/3b/values-hub.yaml
kubectl -n traefik rollout status deployment/traefik --timeout=180s
```
<br>
<br>


### 5. Expose the dashboard API with basic authentication
`openssl` reads the password on stdin; only its hash is stored, in the Secret `dashboard-auth`.
```bash
printf 'users=admin:%s\n' "$(printf '%s\n' "$DASHBOARD_PASSWORD" | openssl passwd -apr1 -stdin)" \
  | kubectl -n traefik create secret generic dashboard-auth --from-env-file=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl apply -f manifests/3b/dashboard-auth-middleware.yaml
helm upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" --reuse-values \
  -f manifests/3b/values-dashboard.yaml \
  --set "ingressRoute.dashboard.matchRule=Host(\`dashboard.$DOMAIN\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))"
kubectl -n traefik rollout status deployment/traefik --timeout=180s
```
<br>
<br>


### 6. Verify the image, the startup log and the version
`Start leading` appears when the new pod takes the leader lease, up to about 90 seconds after the
rollout. The version is read through the dashboard API; the password goes to `curl` through the
netrc file of step 1, not the command line. `dashboard` is a shorthand for curl with the gateway CA,
the host mapping and the credentials file.
```bash
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Wait until the previous pod is gone, then for the leader election of the new one
until [ "$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik --no-headers | wc -l)" -eq 1 ]; do sleep 5; done
until kubectl -n traefik logs deploy/traefik | grep -q 'Start leading'; do sleep 10; done
kubectl -n traefik logs deploy/traefik | grep -E 'hub\.Provider|Start leading|ERR|FTL'

# --retry: the LoadBalancer may need a few seconds to reach the new pod
dashboard() { curl -sS --retry 10 --retry-all-errors --retry-delay 5 --fail --cacert "$WORK/gateway-ca.crt" --resolve "dashboard.$DOMAIN:443:$TRAEFIK_IP" \
  --netrc-file "$WORK/dashboard.netrc" "$@"; }
dashboard "https://dashboard.$DOMAIN/api/version"; echo
curl -sS -o /dev/null -w '%{http_code}\n' --cacert "$WORK/gateway-ca.crt" \
  --resolve "dashboard.$DOMAIN:443:$TRAEFIK_IP" "https://dashboard.$DOMAIN/api/version"   # without credentials
```

<details>
<summary>Expected output</summary>

```text
ghcr.io/traefik/traefik-hub:v3.21.0
INF Starting provider *hub.Provider
INF Start leading
{"Version":"3.21.0","Codename":"cheddar","buildDate":"2026-09-30T13:52:38Z", ...}
401
```
</details>
<br>
<br>


## Verification: AI Gateway

### 1. Deploy the model server
A llama.cpp server with the Qwen2.5 0.5B instruct model (about 0.5 GB), downloaded from Hugging Face
at startup; the pod becomes Ready after the model loads.
```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace apps --overwrite pod-security.kubernetes.io/enforce=baseline
kubectl apply -f manifests/3b/llama-cpp.yaml
kubectl -n apps rollout status deployment/llm --timeout=600s
```
<br>
<br>


### 2. Attach the chat-completion middleware to the AI route
The middleware locks the model and adds default parameters; the IngressRoute `ai-local` serves
`ai.$DOMAIN/v1/chat/completions`.
```bash
kubectl apply -f manifests/3b/ai-chatcompletion.yaml
sed "s/example.com/$DOMAIN/g" manifests/3b/ai-route.yaml | kubectl apply -f -
```
<br>
<br>


### 3. Send a request with a different model name and no API key
```bash
# --fail + --retry: wait until Traefik has loaded the new route (404 until then)
curl -s --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$WORK/gateway-ca.crt" \
  --resolve "ai.$DOMAIN:443:$TRAEFIK_IP" \
  "https://ai.$DOMAIN/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"some-other-model","messages":[{"role":"user","content":"Say ping"}]}' \
  | jq '{model, usage}'
```

<details>
<summary>Expected output (the token counts vary)</summary>

```text
{
  "model": "qwen2.5:0.5b",
  "usage": { "completion_tokens": 33, "prompt_tokens": 31, "total_tokens": 64, ... }
}
```
</details>
<br>
<br>


### 4. Confirm the request-size limit and the middleware state
A request above 1 MiB (the default `maxRequestBodySize`) is rejected before it reaches the model.
```bash
{ printf '{"model":"x","messages":[{"role":"user","content":"'
  head -c 2097152 /dev/zero | tr '\0' 'a'
  printf '"}]}'; } > "$WORK/big.json"
curl -sS -o /dev/null -w '%{http_code}\n' --cacert "$WORK/gateway-ca.crt" --resolve "ai.$DOMAIN:443:$TRAEFIK_IP" \
  "https://ai.$DOMAIN/v1/chat/completions" -H 'Content-Type: application/json' --data-binary @"$WORK/big.json"
dashboard "https://dashboard.$DOMAIN/api/http/middlewares/apps-chatcompletion@kubernetescrd" | jq -c '{type, status, error}'
```

<details>
<summary>Expected output</summary>

```text
413
{"type":"chat-completion","status":"enabled","error":null}
```
</details>
<br>
<br>


## Verification: MCP Gateway
The `jwt` middleware authenticates the caller and exposes the token claims; the `mcp` middleware
publishes the OAuth protected-resource metadata and applies Task-Based Access Control (TBAC) to the
MCP method, the tool name and the claims. The order `jwt` then `mcp` is mandatory.

### 1. Deploy the test MCP server
`traefik/whoamimcp`: server `greeter_s1` with one tool, `greet`.
```bash
kubectl apply -f manifests/3b/whoamimcp.yaml
kubectl -n apps rollout status deployment/docs-mcp-server --timeout=180s
```
<br>
<br>


### 2. Create the signing secret and the middlewares
The validation signs HS256 test tokens with a key generated here, in place of your identity provider
(in production, set `jwksUrl` or `trustedIssuers` to the enterprise IdP). The key goes to the Secret on
stdin.
```bash
JWT_SIGNING_SECRET=$(openssl rand -base64 32)
printf '%s' "$JWT_SIGNING_SECRET" | kubectl -n apps create secret generic mcp-jwt-secret \
  --from-file=signingSecret=/dev/stdin --dry-run=client -o yaml | kubectl apply --server-side -f -
sed "s/example.com/$DOMAIN/g" manifests/3b/mcp-middlewares.yaml | kubectl apply -f -
sed "s/example.com/$DOMAIN/g" manifests/3b/mcp-route.yaml | kubectl apply -f -
```
<br>
<br>


### 3. Create two test tokens, one for each group
Two helpers sign a test token with the shared secret, in place of your identity provider. `mcp` is
a shorthand for curl against the MCP route: the token goes to `curl` through a header file under
`$WORK` (mode 0600), not the command line.
```bash
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign_jwt() {
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url); p=$(printf '%s' "$1" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$JWT_SIGNING_SECRET" -binary | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}
EXP=$(( $(date +%s) + 3600 ))
DEV_TOKEN=$(sign_jwt '{"sub":"dev-user","groups":["developer"],"exp":'"$EXP"'}')
ADMIN_TOKEN=$(sign_jwt '{"sub":"admin-user","groups":["admin"],"exp":'"$EXP"'}')
mcp() { tok=$1; shift; printf 'Authorization: Bearer %s\n' "$tok" > "$WORK/mcp.header"; chmod 600 "$WORK/mcp.header"
  curl -sS --cacert "$WORK/gateway-ca.crt" --resolve "mcp.$DOMAIN:443:$TRAEFIK_IP" -H @"$WORK/mcp.header" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "$@" "https://mcp.$DOMAIN/docs/"; }
```
<br>
<br>


### 4. Discovery and authentication
```bash
# --fail + --retry: wait until Traefik has loaded the new route (404 until then)
curl -s --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$WORK/gateway-ca.crt" \
  --resolve "mcp.$DOMAIN:443:$TRAEFIK_IP" "https://mcp.$DOMAIN/.well-known/oauth-protected-resource/docs"; echo
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
curl -sS -i --cacert "$WORK/gateway-ca.crt" --resolve "mcp.$DOMAIN:443:$TRAEFIK_IP" \
  -H 'Content-Type: application/json' -d "$INIT" "https://mcp.$DOMAIN/docs/" | grep -iE '^HTTP|www-authenticate'
```

<details>
<summary>Expected output</summary>

```text
{"resource":"https://mcp.example.com/docs","authorization_servers":["https://idp.example.com"],"bearer_methods_supported":["header"],"scopes_supported":null,"resource_documentation":""}
HTTP/2 401
www-authenticate: https://mcp.example.com/.well-known/oauth-protected-resource/docs
```
</details>
<br>
<br>


### 5. Handshake and tool list with the developer token
```bash
SID=$(mcp "$DEV_TOKEN" -i -d "$INIT" | tr -d '\r' | awk 'tolower($1)=="mcp-session-id:"{print $2}')
mcp "$DEV_TOKEN" -o /dev/null -w '%{http_code}\n' -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
mcp "$DEV_TOKEN" -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -o '"name":"greet"'
```

<details>
<summary>Expected output</summary>

```text
202
"name":"greet"
```
</details>
<br>
<br>


### 6. Call the tool with both tokens
TBAC denies the developer call before it reaches the server and allows the admin call.
```bash
CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet","arguments":{"name":"admin"}}}'
mcp "$DEV_TOKEN" -i -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18' -d "$CALL" \
  | grep -E '^HTTP|"error"'
mcp "$ADMIN_TOKEN" -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18' -d "$CALL" \
  | grep -o 'Hello, admin[^"]*'
```

<details>
<summary>Expected output</summary>

```text
HTTP/2 403
{"jsonrpc":"2.0","id":3,"error":{"code":-32003,"message":"Forbidden"}}
Hello, admin from docs-mcp-server-665f9b469b-s2ld4 :80!
```
</details>
<br>
<br>


## Verification: API Management installation
With an offline token the chart creates the API portal Service and no admission webhooks.
```bash
kubectl get mutatingwebhookconfigurations -o name | grep hub- || echo "no hub webhooks (offline)"
kubectl -n traefik get svc apiportal
```

<details>
<summary>Expected output</summary>

```text
no hub webhooks (offline)
NAME        TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
apiportal   ClusterIP   10.102.91.71    <none>        9903/TCP   2m
```
</details>
<br>
<br>


## Cleanup Procedure
Back to Traefik Proxy (step 3A state). Run it in a shell where step 1 of this guide was run.
```bash
kubectl delete namespace apps --ignore-not-found
# Rebuild the release from the step 3A values (drop values-tcp.yaml if you skipped 3A Verification 3)
helm upgrade traefik traefik/traefik -n traefik --version "$CHART_VERSION" --reset-values \
  -f manifests/3a/values-proxy.yaml -f manifests/3a/values-tcp.yaml
kubectl -n traefik rollout status deployment/traefik --timeout=180s
kubectl -n traefik delete secret traefik-hub-license dashboard-auth --ignore-not-found
kubectl delete -f manifests/3b/dashboard-auth-middleware.yaml --ignore-not-found
rm -f "$WORK/dashboard.netrc" "$WORK/mcp.header"
unset DASHBOARD_PASSWORD JWT_SIGNING_SECRET DEV_TOKEN ADMIN_TOKEN
```

> Validation status: all steps validated on VKS 3.7.0 (VKr v1.36.2) on 2026-10-02 with an offline
> token, Cleanup included. Connected mode is not part of this validation. Steps 1, 3 (MCP) and 6 and
> Cleanup changed shape in this revision without a re-run (the dashboard password and the bearer
> header move from file descriptors to files under `$WORK`); expected outputs show the example
> environment of the README.
