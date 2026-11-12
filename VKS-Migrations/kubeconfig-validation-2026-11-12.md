# Kubeconfig command validation — 12 November 2026

The README workflow was checked against a live VCF 9 lab using VCF CLI **9.0.0**, `kubectl` **1.35.0**, and a VKS cluster whose queried nodes reported **1.35.5+vmware.1**. Authentication created temporary local contexts and private files; API queries and authorization checks did not change cluster resources.

| Check | Result |
|---|---|
| `KUBECONFIG=<dedicated-file> vcf context create <name> --endpoint <Supervisor-URL> --type k8s --username <SSO-user>` | Passed; created Supervisor and authorized namespace contexts in the dedicated file |
| Same command with `--workload-cluster-namespace` and `--workload-cluster-name` | Passed; created a VKS context with a different API endpoint |
| Explicit `--context` plus `config view --raw --minify --flatten` | Passed for Supervisor and VKS; each export contained one context and selected it as `current-context` |
| File permissions | Both exported files were mode `0600` |
| Supervisor `get clusters.cluster.x-k8s.io -n <hosting-namespace>` and `get pvc -n <hosting-namespace>` | Passed |
| VKS `get pvc -n default` and `get nodes` | Passed; empty default PVC list and four Ready nodes |
| Supervisor `auth can-i create cnsregistervolumes.cns.vmware.com -n <hosting-namespace>` | `yes` |
| VKS `auth can-i create persistentvolumes` | `yes` |

The lab login required `--insecure-skip-tls-verify`; CA-trusted login was not validated. Both exported configs used tokens. Login did not select a current context in the dedicated login file, which is why the README exports an explicitly named context. Credentials, internal endpoints and raw kubeconfigs are excluded from this record.

Temporary VCF contexts and credential files were removed after validation. The original VCF context remained selected. Documentation links/anchors, Bash/zsh block syntax and `git diff --check` passed.

An alternative, `vcf cluster kubeconfig get <name> --namespace <namespace> --export-file <path>`, failed here with `failed to get pinniped-info from management cluster`. It is therefore not the documented default; direct workload-context login above succeeded.

Limits: vSphere 8 plugin login was checked against installed `kubectl vsphere login --help` and [Broadcom's documented flow](https://knowledge.broadcom.com/external/article/435399/troubleshooting-kubectl-vsphere-contexts.html), not a live vSphere 8 environment. Non-VKS source login, token expiry/refresh, exec-plugin authentication, VCF Automation/OIDC, and a second Supervisor were not exercised. These access checks do not validate a migration or every permission required by one.
