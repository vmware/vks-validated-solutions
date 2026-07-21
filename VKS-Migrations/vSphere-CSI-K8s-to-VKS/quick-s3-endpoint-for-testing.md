# Temporary S3-compatible endpoint for migration testing

## Purpose

This procedure deploys `NooBaa` on a VKS cluster to provide an S3-compatible endpoint for Velero lab testing.

> [!WARNING]
> This is a convenience configuration for a non-production environment. It uses a privileged namespace and the examples disable TLS certificate verification. Do not treat it as a production backup architecture.

## Prerequisites

- A non-production VKS cluster.
- A default StorageClass suitable for NooBaa.
- A working LoadBalancer implementation, or another supported way to expose the S3 service.
- `kubectl`, `curl`, `tar`, `jq` and the AWS CLI.

## 1. Configure access

```bash
export VKS_KUBECONFIG="${HOME}/vks-kubeconfig"
alias vks='kubectl --kubeconfig="${VKS_KUBECONFIG}"'
```

## 2. Install the NooBaa CLI

Pin and review a tested release for repeatable deployments. The following command discovers the latest release and is therefore intended only for ad hoc lab use.

```bash
OS="linux"
ARCH="amd64"
VERSION="$(
  curl -fsSL https://api.github.com/repos/noobaa/noobaa-operator/releases/latest \
    | jq -r '.tag_name // .name'
)"

curl -fLO \
  "https://github.com/noobaa/noobaa-operator/releases/download/${VERSION}/noobaa-operator-${VERSION}-${OS}-${ARCH}.tar.gz"

tar -xzf "noobaa-operator-${VERSION}-${OS}-${ARCH}.tar.gz"
chmod +x noobaa-operator
sudo install -m 0755 noobaa-operator /usr/local/bin/noobaa

noobaa version
```

Release asset naming may change. Check the release page if the download URL is not valid for the selected version.

## 3. Create the namespace

```bash
vks create namespace noobaa --dry-run=client -o yaml | vks apply -f -

vks label namespace noobaa --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

## 4. Install NooBaa

```bash
noobaa --kubeconfig="${VKS_KUBECONFIG}" -n noobaa install

noobaa --kubeconfig="${VKS_KUBECONFIG}" -n noobaa status
vks -n noobaa get pod,pvc,service
```

Wait until the NooBaa components are ready before continuing.

## 5. Create an ObjectBucketClaim

```bash
export BUCKET_CLAIM="velero-bucket"

noobaa --kubeconfig="${VKS_KUBECONFIG}" -n noobaa \
  obc create "${BUCKET_CLAIM}" --exact=true

vks -n noobaa get obc "${BUCKET_CLAIM}"
vks -n noobaa get secret "${BUCKET_CLAIM}"
vks -n noobaa get configmap "${BUCKET_CLAIM}"
```

Read the generated connection details without printing them into shared logs:

```bash
export AWS_ACCESS_KEY_ID="$(
  vks -n noobaa get secret "${BUCKET_CLAIM}" \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
)"

export AWS_SECRET_ACCESS_KEY="$(
  vks -n noobaa get secret "${BUCKET_CLAIM}" \
    -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d
)"

export BUCKET_NAME="$(
  vks -n noobaa get configmap "${BUCKET_CLAIM}" \
    -o jsonpath='{.data.BUCKET_NAME}'
)"

export BUCKET_HOST="$(
  vks -n noobaa get configmap "${BUCKET_CLAIM}" \
    -o jsonpath='{.data.BUCKET_HOST}'
)"

export BUCKET_PORT="$(
  vks -n noobaa get configmap "${BUCKET_CLAIM}" \
    -o jsonpath='{.data.BUCKET_PORT}'
)"

export S3_ENDPOINT="https://${BUCKET_HOST}:${BUCKET_PORT}"
```

If the generated host is cluster-internal, expose the NooBaa S3 service through the platform's approved LoadBalancer or ingress method and update `S3_ENDPOINT` accordingly.

## 6. Test object access

```bash
printf 'Velero S3 test: %s\n' "$(date -Iseconds)" > s3-test.txt

aws --endpoint-url "${S3_ENDPOINT}" \
  --no-verify-ssl \
  s3 cp s3-test.txt "s3://${BUCKET_NAME}/s3-test.txt"

aws --endpoint-url "${S3_ENDPOINT}" \
  --no-verify-ssl \
  s3 ls "s3://${BUCKET_NAME}/"
```

The `--no-verify-ssl` option is only appropriate for this temporary lab endpoint. Configure trusted certificates for a durable service.

## 7. Velero credential file

Create a local credential file with restrictive permissions:

```bash
cat > credentials-velero <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF

chmod 0600 credentials-velero
```

Use `BUCKET_NAME`, `S3_ENDPOINT` and this credentials file when installing or configuring Velero.

## Cleanup

Remove the test object and local credential material when no longer required:

```bash
aws --endpoint-url "${S3_ENDPOINT}" --no-verify-ssl \
  s3 rm "s3://${BUCKET_NAME}/s3-test.txt"

rm -f s3-test.txt credentials-velero
```

Delete the NooBaa installation only after confirming that no Velero backups still depend on it.
