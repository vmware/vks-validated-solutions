# Example Client VM Configuration & Tooling

The administrator workstation of this validation is an Ubuntu 24.04 VM built from the cloud image
(https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.ova). Any Linux machine
with the tools below works; the guides use `base64 -w0`, which is GNU coreutils.

The versions are the ones of the validation ([Step 2, Requirements](2_VKS_DEPLOYMENT.md#requirements)):
VCF CLI v9.0.2, kubectl v1.36, Helm v4, govc v0.55.0.

References:
* Connecting to Supervisor and VKS clusters:
  https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/configuring-identity-and-access-for-tkg-service-clusters/connecting-to-vsphere-with-tanzu-clusters.html
* VCF CLI command reference:
  https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/command-reference2.html

## Base packages
```bash
sudo apt-get update
sudo apt-get install -y curl unzip openssl jq git
```

## Install the VCF command line (v9.0.2)
```bash
cd "$(mktemp -d)"
curl -fsSL -O https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.2/vcf-cli.tar.gz
curl -fsSL -O https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.2/sha256sum.txt
sha256sum -c sha256sum.txt --ignore-missing
tar xzf vcf-cli.tar.gz
sudo install -m 755 vcf-cli-linux_amd64 /usr/local/bin/vcf
vcf version

# (Optional) bash completion
echo 'source <(vcf completion bash)' >> ~/.bashrc
```

The contexts for the Supervisor and the VKS cluster are created in [Step 2](2_VKS_DEPLOYMENT.md)
(steps 3 and 7), with the vCenter roots passed through `--ca-certificate`.

## Install kubectl (v1.36)
```bash
curl -fsSL -o kubectl https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl
curl -fsSL -o kubectl.sha256 https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c
sudo install -m 755 kubectl /usr/local/bin/kubectl

# (Optional) bash completion and the alias k
cat <<'EOF' >> ~/.bashrc
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion bash)
  alias k=kubectl
  complete -o default -F __start_kubectl k
fi
EOF
```

## Install Helm (v4)
```bash
curl -fsSL -o get-helm-4 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get-helm-4
./get-helm-4
helm version
```

## Install govc (v0.55.0, step 3C only)
```bash
cd "$(mktemp -d)"
curl -fsSL -O https://github.com/vmware/govmomi/releases/download/v0.55.0/govc_Linux_x86_64.tar.gz
curl -fsSL -O https://github.com/vmware/govmomi/releases/download/v0.55.0/checksums.txt
sha256sum -c checksums.txt --ignore-missing
tar xzf govc_Linux_x86_64.tar.gz govc
sudo install -m 755 govc /usr/local/bin/govc
govc version
```

## vCenter and Supervisor certificates
The guides do not change the system trust store: they download the vCenter root CAs once
([Step 2, step 2](2_VKS_DEPLOYMENT.md#2-trust-the-vcenter-and-supervisor-certificates)) into
`$WORK/vcenter-ca.crt` and pass that file to each tool (`vcf context create --ca-certificate`,
`curl --cacert`, `GOVC_TLS_CA_CERTS`). If you prefer to trust the roots system-wide, run the following
after that step, which unpacks the vCenter bundle into `$WORK/vc-certs`: it installs the roots as `.crt`
files under `/usr/local/share/ca-certificates/` (files copied into `/etc/ssl/certs/` with the `.0`
extension are ignored by `update-ca-certificates`).
```bash
export WORK="$HOME/traefik-vks-work"   # the same value as Step 2, step 1
sudo mkdir -p /usr/local/share/ca-certificates/vcenter
for f in "$WORK"/vc-certs/certs/lin/*.0; do
  sudo cp "$f" "/usr/local/share/ca-certificates/vcenter/$(basename "$f" .0).crt"
done
sudo update-ca-certificates
```
