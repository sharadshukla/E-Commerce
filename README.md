# Azure E-Commerce Platform on AKS

**Infrastructure as Code and deployment of the Robot Shop microservices sample on Microsoft Azure.**

This project takes the upstream [Robot Shop](https://github.com/instana/robot-shop) demonstration application and adds an Azure platform deployment: infrastructure provisioned with Bicep, an Azure Container Registry (ACR), Azure Kubernetes Service (AKS), and a Helm chart.

The application is an upstream sample, not a production commerce platform. This repository’s engineering focus is the Azure infrastructure and deployment workflow around it.

## Table of contents

- [What this project implements](#what-this-project-implements)
- [Architecture](#architecture)
- [Architecture decisions](#architecture-decisions)
- [Deployment workflow](#deployment-workflow)
  - [Prerequisites](#prerequisites)
  - [Provision ACR and AKS](#1-provision-acr-and-aks)
  - [Grant AKS permission to pull from ACR](#2-grant-aks-permission-to-pull-from-acr)
  - [Build and push the application images](#3-build-and-push-the-application-images)
  - [Deploy the application with Helm](#4-deploy-the-application-with-helm)
  - [Verify the deployment](#5-verify-the-deployment)
- [Deployment evidence](#deployment-evidence)
- [Operational learning](#operational-learning)
- [Scope and limitations](#scope-and-limitations)
- [Next iterations](#next-iterations)
- [Repository areas](#repository-areas)
- [Upstream project and license](#upstream-project-and-license)

## What this project implements

- Azure infrastructure defined in Bicep: ACR and AKS, with the AKS resource in a reusable module.
- An Azure DevOps pipeline that validates the Bicep template, authenticates through a workload identity federation service connection, and deploys infrastructure into an existing resource group.
- An AKS system node pool configured for cluster autoscaling from one to three nodes.
- An AKS Helm chart configured to use version-tagged images in ACR.
- A Kubernetes LoadBalancer Service for the web frontend.

**The pipeline provisions infrastructure only.** Container image builds and pushes, the AKS kubelet identity’s `AcrPull` role assignment, and the Helm application deployment are manual steps in this release.

## Architecture

```mermaid
flowchart TD
    Dev["Engineer"]
    Pipe["Azure DevOps pipeline<br/>manual run · workload identity federation"]
    Bicep["Bicep<br/>in existing resource group"]
    ACR["Azure Container Registry"]
    AKS["AKS<br/>autoscaling system node pool"]
    Images["Build and push images<br/>manual"]
    Pull["Assign AcrPull to kubelet identity<br/>manual"]
    Helm["Install Robot Shop with Helm<br/>manual"]
    Web["Web Service<br/>LoadBalancer :8080"]
    App["Robot Shop microservices"]

    Dev --> Pipe --> Bicep
    Bicep --> ACR
    Bicep --> AKS
    Dev --> Images --> ACR
    Dev --> Pull --> AKS
    Dev --> Helm --> AKS
    ACR -->|"image pulls"| AKS
    AKS --> App
    App --> Web
```

The Bicep deployment expects the resource group to exist already. The application’s web Service used port **8080** in the recorded AKS deployment; the remaining application Services were internal cluster Services. No Application Gateway or Ingress-based public entry point was part of the verified deployment.

## Architecture decisions

| Decision | Reason and trade-off |
|---|---|
| Bicep for Azure resources | Keeps ACR and AKS configuration declarative and repeatable. The pipeline deploys to an existing resource group rather than creating the resource group. |
| Azure DevOps workload identity federation | Lets the pipeline authenticate to Azure through its service connection without storing a client secret in the YAML. The service connection and its permissions are configured in Azure DevOps. |
| ACR admin account disabled | Avoids using the registry’s shared admin credentials. AKS image-pull access was granted separately to its kubelet managed identity. That role assignment was manual in this release. |
| Helm for application resources | Groups the microservice Kubernetes resources and image settings in one chart. The chart install was a separate manual operation from infrastructure provisioning. |
| LoadBalancer Service on port 8080 | Provided a direct browser-accessible endpoint for this learning deployment. It creates a public Azure endpoint and is not a production ingress/TLS design. |
| One autoscaling system node pool | Kept the learning cluster simple while allowing the node count to vary between one and three. This is cluster autoscaling; the project does not configure application HPA. |

## Deployment workflow

### Prerequisites

- An Azure subscription and an **existing** resource group.
- Azure DevOps access and a configured workload identity federation service connection with permission to deploy into that resource group.
- A self-hosted Azure Pipelines agent with Azure CLI and the required tooling.
- Docker, Azure CLI, kubectl, and Helm for the manual application steps.

### 1. Provision ACR and AKS

Run the Azure Pipeline manually. It checks Bicep availability, builds the Bicep template, verifies Azure and resource-group access, then deploys `infra/main.bicep`.

The template creates ACR and AKS. It does not create the resource group, assign ACR permissions to the kubelet identity, build container images, or install the Helm chart.

### 2. Grant AKS permission to pull from ACR

After AKS and ACR exist, assign the `AcrPull` role to the AKS **kubelet identity** at the registry scope. This step was manual for this release. Use the kubelet identity object ID, not the AKS control-plane identity.

### 3. Build and push the application images

Log in to ACR, then build and push the image repositories and tag expected by the Helm chart. Set these values for your registry before running the commands:

```bash
ACR_NAME="your-acr-name"
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)
az acr login --name "$ACR_NAME"
docker build -t "$ACR_LOGIN_SERVER/rs-web:v1" ./web
docker push "$ACR_LOGIN_SERVER/rs-web:v1"
```

Repeat for the other application images referenced by `AKS/helm/templates`. The Redis image is specified separately in the chart. Image publication is not automated by the Azure Pipeline in this version.

### 4. Deploy the application with Helm

Install the chart with the registry and tag for your deployment:

```bash
helm upgrade --install robot-shop ./AKS/helm \
  --namespace robot-shop \
  --create-namespace \
  --wait \
  --timeout 10m \
  --set "image.repo=$ACR_LOGIN_SERVER" \
  --set image.version=v1
```

### 5. Verify the deployment

```bash
kubectl get pods -n robot-shop
kubectl get services -n robot-shop
helm status robot-shop -n robot-shop
```

Confirm that the pods are ready, the `web` Service has an external address, and the storefront responds on the Service’s exposed port.

## Deployment evidence

The deployment was verified on **11 October 2026**. The Azure resources have since been removed, so the outputs below are historical evidence and this repository does not provide a live demo endpoint.

![AKS application pods showing Ready and Running status during verification](docs/images/aks-pods-2026-10-11.png)

*AKS pod status captured during the 11 October 2026 deployment verification.*

All 12 application pods were ready and running at capture time:

```text
NAME       READY   STATUS
cart       1/1     Running
catalogue  1/1     Running
dispatch   1/1     Running
mongodb    1/1     Running
mysql      1/1     Running
payment    1/1     Running
rabbitmq   1/1     Running
ratings    1/1     Running
redis      1/1     Running
shipping   1/1     Running
user       1/1     Running
web        1/1     Running
```

The Services showed the expected internal microservice endpoints and a public LoadBalancer for the web frontend. Addresses are omitted because they belonged to the temporary cluster:

| Service | Type | Port(s) |
|---|---|---|
| cart, catalogue, payment, shipping, user | ClusterIP | 8080/TCP |
| dispatch | ClusterIP (headless) | 55555/TCP |
| mongodb | ClusterIP | 27017/TCP |
| mysql | ClusterIP | 3306/TCP |
| rabbitmq | ClusterIP | 5672/TCP, 15672/TCP, 4369/TCP |
| ratings | ClusterIP | 80/TCP |
| redis | ClusterIP | 6379/TCP |
| web | LoadBalancer | 8080/TCP |

Both AKS nodes were `Ready`, and the storefront was reachable through the web Service during verification.

## Operational learning

During startup, MySQL’s initialization took unusually long and dependent services, including Ratings and Shipping, were not initially ready. MySQL logs showed extended initialization delays. A controlled MySQL restart restored TCP connectivity, after which those dependent services recovered and the storefront became reachable. No MySQL image or source patch was made, and the precise cause of the delay was not established.

The initial Helm install used `--wait` and timed out while the application was still initializing. Although the workloads later recovered, the captured Helm release status remained `failed`; a subsequent Helm upgrade/reconciliation was not run before cleanup. This is why the historical evidence distinguishes application recovery from Helm’s recorded operation status.

## Scope and limitations

- Robot Shop is an upstream demonstration application and is **not intended for production use**; its own upstream documentation notes limited error handling and missing application security.
- The resource group must be created before the pipeline runs.
- Container builds and ACR pushes, the kubelet `AcrPull` assignment, and Helm deployment are manual.
- The MySQL workload has no persistent volume in this chart, so database data is not durable across pod replacement.
- The web Service uses a public LoadBalancer on port 8080; ingress, custom domain, and TLS are not configured.
- The chart uses the `v1` image tag in the recorded deployment. A digest-pinned or immutable-tag release process is a future improvement.
- The recorded Helm install timed out and its release status was not reconciled after application recovery.

## Next iterations

The next versions can build on this working infrastructure and application deployment path in small, verifiable steps:

1. **Automate application delivery:** build and push service images with immutable tags, then deploy the Helm release from Azure Pipelines.
2. **Automate Azure permissions:** provision the AKS kubelet identity’s `AcrPull` role assignment as part of the infrastructure workflow, with least-privilege scope.
3. **Improve application operations:** add persistent storage and backup for stateful services, then configure health checks and application autoscaling where the upstream app supports them.
4. **Add secure public access:** introduce an ingress or gateway, TLS, and a custom domain; move application secrets into an appropriate secret-management flow.
5. **Add observability and controlled load testing:** integrate Azure Monitor/Log Analytics and run a documented non-production load test. The repository’s Fluentd and Locust examples, if retained, should be treated as optional examples until they are wired into and tested with this Azure deployment.

These are candidate improvements, not features delivered by v1. The application itself remains an upstream demonstration project and is not being presented as production-ready.

## Repository areas

- `infra/` — Bicep entry point and AKS module.
- `AKS/helm/` — Helm chart and Kubernetes templates.
- `azure-pipelines.yml` — Azure DevOps infrastructure pipeline.
- Application service directories — upstream Robot Shop source and Dockerfiles.
- `docker-compose.yaml` — upstream local development path.
- `docs/images/` — selected, sanitized deployment evidence screenshots.
- Optional upstream examples such as `fluentd/` and `load-gen/` are outside the verified Azure v1 deployment scope.

## Upstream project and license

The application is based on [Instana Robot Shop](https://github.com/instana/robot-shop). The application source and its microservice design are upstream work; this project adds the Azure infrastructure and deployment workflow described above. The repository includes the upstream Apache 2.0 license; see [LICENSE](LICENSE).

---

**Release scope:** v1.0 documents the Azure infrastructure and AKS application deployment path, including its manual handoffs and deployment evidence. The next iterations above describe possible automation, operations, security, and observability improvements.

