# Quick S3 endpoint on VKS (for testing)

---  

## first install the cli (tested on Ubuntu Jammy)
```
OS="linux"
ARCH=amd64
VERSION=$(curl -s https://api.github.com/repos/noobaa/noobaa-operator/releases/latest | jq -r '.name')

curl -LO https://github.com/noobaa/noobaa-operator/releases/download/$VERSION/noobaa-operator-$VERSION-$OS-$ARCH.tar.gz
tar -xvzf noobaa-operator-$VERSION-$OS-$ARCH.tar.gz
chmod +x noobaa-operator
sudo mv noobaa-operator /usr/local/bin/noobaa
```

## create the namespace and label
```
vks create ns noobaa
vks label --overwrite ns noobaa \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

## create a command alias 
```
alias nb='noobaa --kubeconfig=${VKS_KUBECONFIG} -n noobaa'
```
## install the noobaa operator
```
nb install  
```
## get the external S3 IP
```
S3_IP=$(vks -n noobaa get svc s3 -o json | jq -r '.status.loadBalancer.ingress[0].ip')
```
## create bucket
```
nb obc create my-bucket --exact=true
```
## get credentials
```
vks -n noobaa get secret my-bucket -o json | jq '.data|map_values(@base64d)'
```
## write a test file
```
nb status > me.txt
```

## install aws cli
```
sudo pip install awscli
```
## configure aws cli, add credentials above
```
aws configure 
```

## upload test file
```
aws s3 cp me.txt s3://my-bucket --endpoint-url https://${S3_IP} --no-verify-ssl
```