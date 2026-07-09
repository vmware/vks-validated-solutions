# Quick S3 endpoint on VKS (for testing) using noobaa


## First install the cli (tested on Ubuntu Jammy)
```
OS="linux"
ARCH=amd64
VERSION=$(curl -s https://api.github.com/repos/noobaa/noobaa-operator/releases/latest | jq -r '.name')

curl -LO https://github.com/noobaa/noobaa-operator/releases/download/$VERSION/noobaa-operator-$VERSION-$OS-$ARCH.tar.gz
tar -xvzf noobaa-operator-$VERSION-$OS-$ARCH.tar.gz
chmod +x noobaa-operator
sudo mv noobaa-operator /usr/local/bin/noobaa
```

## Create the namespace and label
```
vks create ns noobaa
vks label --overwrite ns noobaa \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

## Create a command alias 
```
alias nb='noobaa --kubeconfig=${VKS_KUBECONFIG} -n noobaa'
```
## Install the noobaa operator
```
nb install  
```
## Get the external S3 IP
```
S3_IP=$(vks -n noobaa get svc s3 -o json | jq -r '.status.loadBalancer.ingress[0].ip')
```
## Create bucket
```
nb obc create my-bucket --exact=true
```
## Get credentials
```
vks -n noobaa get secret my-bucket -o json | jq '.data|map_values(@base64d)'
```
## Write a test file
```
nb status > me.txt
```

## Install aws cli
```
sudo pip install awscli
```
## Configure aws cli, add credentials above
```
aws configure 
```

## Upload test file
```
aws s3 cp me.txt s3://my-bucket --endpoint-url https://${S3_IP} --no-verify-ssl
```