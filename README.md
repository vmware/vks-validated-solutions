# VKS Validated Solutions & ISV Integrations

## Overview

This repository serves as the official registry for VKS Validated Solutions. It contains tested configurations, deployment manifests, and integration patterns for Independent Software Vendors (ISVs) and partner ecosystem tools operating on VKS.

The goal of this project is to provide platform engineers and cluster administrators with production-ready, vendor-approved deployment strategies that reduce integration overhead and ensure predictable performance on VKS.

-----

## Repository Structure

The project is structured in a modular fashion, segmented by ISV/Partner. Each directory functions as an isolated module containing its own targeted documentation, architectural considerations, and deployment manifests (e.g., standard YAML, Helm values, or Kustomize overlays).

```plaintext
.
├── partner-name-a/             # Validated integration for Partner A
│   ├── manifests/              # Any deployment YAMLs and/or Helm values
│   ├── scripts/                # Any utility and validation scripts
|   ├── charts/                 # Any Helm charts
│   └── README.md               # Partner-specific deployment guide
├── partner-name-c/             # Validated integration for Partner C
├── partner-name-d/             # Validated integration for Partner D
└── README.md                   # Repository root documentation
```

-----

## Getting Started

To utilize these validated configurations in your VKS environment, locate the specific partner solution you are implementing and review its dedicated local documentation.

### Prerequisites

- A running VKS Cluster.
- `kubectl` configured with the appropriate cluster context.
- `helm` (v3+) or `kustomize` (depending on the specific partner’s deployment method).

### Standard Deployment Workflow

1. **Clone the repository:**

```bash
git clone https://github.com/your-org/vks-validated-solutions.git
cd vks-validated-solutions
```

2. **Navigate to the target integration:**

```bash
cd kong/  # Replace with your target partner directory
```

3. **Deploy the solution:**

Follow the deployment instructions detailed in the partner-specific `README.md`. 

-----

## Partner Onboarding & Contribution

We welcome contributions from ISVs and internal engineering teams. To maintain the integrity of these validated solutions, please adhere to the following workflow when introducing a new partner integration:

1. **Branching:** Fork the repository and create a feature branch (`feature/add-partner-name`).
2. **Directory Initialization:** Create a new root-level directory using a standardized, lowercase naming convention (e.g., `partner-name`).
3. **Artifact Guidelines:**
- Include all necessary deployment artifacts in a `manifests/` or `charts/` subdirectory.
- Ensure manifests are linted and compatible with supported Kubernetes versions.
4. **Documentation:** You must include a local `README.md` within the partner directory. This document should cover:
- Architecture overview on VKS.
- Prerequisites and dependencies.
- Step-by-step deployment instructions.
- Validation and testing steps.
5. **Pull Request:** Submit a PR against the `main` branch. Ensure your commit messages are descriptive and link to any relevant issue trackers.

-----

## Support

For issues specifically related to these deployment configurations on VKS, please open a **GitHub Issue** in this repository. For product-specific issues regarding the partner software itself, please reach out to the respective vendor’s support channels.