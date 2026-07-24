# i-exceed
Welcome to the VKS Validated Solutions repository i-exceed subfolder 
This subfoler is for partner i-exceed
It contains specific documentation, scripts, or configuration files tailored to a particular partner's environment.


## Topology Diagram

Note: a detailed SVG is available in the folder [TopologyDiagram](TopologyDiagram/)

```mermaid
flowchart TB
    subgraph NS["Namespace: appzillon (VMware VKS)"]
        MOCK["vks-microservice-mockserver<br/>Helm chart · Deployment + Service"]
        ACCT["vks-microservice-retailbanking-accounts<br/>Helm chart · Deployment + Service"]

        subgraph SERVER["vks-retailbanking-server"]
            direction LR
            SRVP["Primary<br/>Deploy + Svc + Pods"]
            SRVC["Canary<br/>Deploy + Svc + Pods"]
        end

        subgraph WEB["vks-retailbanking-web"]
            direction LR
            WEBP["Primary<br/>Deploy + Svc + Pods"]
            WEBC["Canary<br/>Deploy + Svc + Pods"]
        end

        ROLLOUTS["Argo Rollouts controller<br/>+ canary success-rate analysis"]
        CONFIG["Shared platform config<br/>Istio mTLS certs · fluent-bit logging<br/>common DB config · K8s root CA"]
    end

    ROLLOUTS -. drives canary/primary split .-> SERVER
    ROLLOUTS -. drives canary/primary split .-> WEB
    CONFIG -. mounted by .-> MOCK
    CONFIG -. mounted by .-> ACCT
    CONFIG -. mounted by .-> SERVER
    CONFIG -. mounted by .-> WEB
 ```



