# Example Client VM Configuration & Tooling #

Based on Ubuntu. Tools used in this guide: vcf CLI, kubectl v1.35 or later, helm (option B only), openssl, and the kubectl-kubestash plugin.

Connecting to Supervisor and VKS Clusters:
https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/configuring-identity-and-access-for-tkg-service-clusters/connecting-to-vsphere-with-tanzu-clusters.html

VCF CLI command reference:
https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/command-reference2.html


## Install VCF Command Line
```bash
curl -fsSL https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.0/vcf-cli.tar.gz | tar xz
sudo install -m 755 vcf-cli-linux_amd64 /usr/local/bin/vcf
```

## Install vCenter Certificate
```bash
VCENTER_IP=<vCenter IP>
curl -k -fsSL -o /tmp/vccert.zip https://${VCENTER_IP}/certs/download.zip
unzip /tmp/vccert.zip -d /tmp
sudo cp /tmp/certs/lin/* /etc/ssl/certs
sudo update-ca-certificates
```

## Install kubectl
Use kubectl v1.35 or later, within the supported version skew of the v1.36 VKS cluster.
```bash
curl -fsSLO "https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kubectl"
sudo install -m 755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

## Install Helm (option B only). See https://helm.sh/docs/intro/install/
```bash
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh
```

## Install the kubectl-kubestash plugin
Used to trigger on-demand backups. Pick a release from https://github.com/kubestash/cli/releases.
```bash
KUBESTASH_CLI_VERSION=<version>
curl -fsSL https://github.com/kubestash/cli/releases/download/${KUBESTASH_CLI_VERSION}/kubectl-kubestash-linux-amd64.tar.gz | tar xz
sudo install -m 755 kubectl-kubestash-linux-amd64 /usr/local/bin/kubectl-kubestash
kubectl kubestash --help
```

## Install openssl
```bash
sudo apt update
sudo apt install -y openssl
```
