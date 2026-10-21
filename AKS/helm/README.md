# Robot Shop Helm Chart on AKS

This Helm chart deploys the upstream Robot Shop sample application to an Azure Kubernetes Service (AKS) cluster. It creates the application’s Kubernetes workloads and Services.

The chart does not provision AKS or Azure Container Registry (ACR), build or push container images, or grant AKS permission to pull from ACR. Those steps must be completed separately. Robot Shop is a demonstration application and is not intended for production use.

## Prerequisites

- An AKS cluster with `kubectl` access.
- Helm 3.
- The application images published to ACR with the repository names and tag listed below.
- The AKS kubelet identity granted the `AcrPull` role on the registry.
- A Kubernetes StorageClass named `default` for the Redis volume, unless the chart template is updated to use a different StorageClass.

Check cluster access and available StorageClasses:

```bash
kubectl get nodes
kubectl get storageclass
```

## Container images

The chart builds application image names from `image.repo` and `image.version`. The following images must be available in that registry with the selected tag:

```text
rs-cart
rs-catalogue
rs-dispatch
rs-mongodb
rs-mysql-db
rs-payment
rs-ratings
rs-shipping
rs-user
rs-web
```

Redis is pulled separately from Docker Hub as `redis:4.0.6`.

## Azure DevOps Helm CD

The primary deployment path is the manually queued [`pipelines/helm-aks-cd.yml`](../../pipelines/helm-aks-cd.yml) pipeline. It validates WIF access and Kubernetes RBAC, then runs Helm against the `robot-shop` namespace. Before queueing it, configure AKS access, the namespace Role and RoleBinding, and `AcrPull` for the AKS kubelet identity as described in the [root README](../../README.md).

Supply the `imageTag` parameter explicitly. It must match an image tag already published to ACR; the v1.2.0 deployment used `77`. The pipeline does not build or push images.

## Manual Helm install or upgrade (fallback)

Use this procedure when deploying outside Azure DevOps. Run these commands from the repository root. Replace the registry hostname and tag with values that match the images you pushed:

```bash
ACR_LOGIN_SERVER="your-registry.azurecr.io"
IMAGE_VERSION="77"

helm lint ./AKS/helm

helm upgrade --install robot-shop ./AKS/helm \
  --namespace robot-shop \
  --create-namespace \
  --wait \
  --timeout 10m \
  --set "image.repo=$ACR_LOGIN_SERVER" \
  --set "image.version=$IMAGE_VERSION"
```

## Verify the release

```bash
helm status robot-shop --namespace robot-shop
kubectl get pods --namespace robot-shop
kubectl get services --namespace robot-shop
kubectl get pvc --namespace robot-shop
```

By default, the `web` Service is type `LoadBalancer` and listens on port `8080`. Wait for Azure to assign an external address, then open `http://<EXTERNAL-IP>:8080` in a browser. This chart does not configure an Ingress, custom domain, or TLS.

## Common configuration values

| Value | Current default | Purpose |
|---|---|---|
| `image.repo` | Set in `values.yaml` | Base registry hostname for the Robot Shop application images. Override it with your ACR login server. |
| `image.version` | `v1` | Chart default tag. Override it with the tag published to ACR; the v1.2.0 deployment used `77`. |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy. |
| `nodeport` | `false` | When false, exposes `web` through a LoadBalancer. When true, uses a NodePort instead. |
| `payment.gateway` | `null` | Optional URL used by the sample payment service. |
| `eum.key`, `eum.url` | No key; upstream endpoint | Optional Instana website monitoring configuration. Do not pass real secrets directly on a command line. |
| `<workload>.affinity` | `{}` | Optional scheduling affinity for an individual workload. |
| `<workload>.nodeSelector` | `{}` | Optional node labels for scheduling an individual workload. |
| `<workload>.tolerations` | `[]` | Optional tolerations for scheduling an individual workload. |

Workload scheduling values can be set for `cart`, `catalogue`, `dispatch`, `mongodb`, `mysql`, `payment`, `rabbitmq`, `ratings`, `redis`, `shipping`, `user`, and `web`.

Example override file:

```yaml
web:
  nodeSelector:
    kubernetes.io/os: linux
  tolerations: []
```

Apply it with `-f my-values.yaml` on the `helm upgrade --install` command.

## AKS chart notes

- The Redis StatefulSet requests a 1 Gi persistent volume and currently specifies the StorageClass name `default` directly in its template. The `redis.storageClassName` value in `values.yaml` is not currently wired into that template. Confirm that `default` exists in the cluster, or update the template before installing.
- The MySQL workload in this chart does not have a persistent volume. Its data is not durable across pod replacement.
- Keep `psp.enabled` set to `false`; Pod Security Policy support is a legacy chart option and is not part of this AKS deployment.
- NodePort and Instana monitoring are optional upstream settings; they are not required for the Azure deployment described here.

## Uninstall

```bash
helm uninstall robot-shop --namespace robot-shop
```

Review and remove any remaining PVCs separately if you also want to delete the Redis volume and its data.
