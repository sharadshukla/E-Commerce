# Robot Shop Helm Chart on AKS

This chart deploys the upstream Robot Shop sample application to Azure Kubernetes Service (AKS). It creates the Kubernetes workloads and Services; it does not provision Azure resources, build or publish images, configure Azure identities or service connections, or grant ACR pull access.

## Deployment through Azure DevOps

The v1.3.0 path is the [`ecommerce-master-deployment`](../../azure-pipelines-master.yml) pipeline, which runs Infrastructure, Docker CI, and Helm CD in order. The Helm stage receives the same `Build.BuildId` tag used by Docker CI and verifies the Helm release and rollout status of Deployments and StatefulSets.

Use the released documentation and deployment workflow from the repository's `main` branch. The root README covers the checkout, prerequisites, full pipeline run, application access, and cleanup.

Before running it, complete the manual Azure DevOps and AKS prerequisites in the [root README](../../README.md): configure WIF service connections, bootstrap the `robot-shop` namespace and Kubernetes RBAC, and ensure the AKS kubelet identity can pull from ACR. The standalone [`pipelines/helm-aks-cd.yml`](../../pipelines/helm-aks-cd.yml) entry point is available for an isolated Helm deployment and requires an explicit `imageTag` already present in ACR.

## Requirements

- AKS access and Helm 3 for a manual deployment.
- Ten application images in ACR with a common tag: `rs-cart`, `rs-catalogue`, `rs-dispatch`, `rs-mongodb`, `rs-mysql-db`, `rs-payment`, `rs-ratings`, `rs-shipping`, `rs-user`, and `rs-web`.
- The AKS kubelet managed identity granted `AcrPull` on the registry.
- A StorageClass named `default` for the Redis PVC; the chart template currently specifies this name directly.
- Outbound access from AKS nodes to Docker Hub for `redis:4.0.6` and other upstream images used by the chart.

## Manual Helm deployment (fallback)

Run from the repository root in PowerShell. Set the ACR hostname and image tag to values that exist in the registry. The chart defaults to `image.version: v1`; the v1.3.0 master pipeline overrides that value with `Build.BuildId`.

```powershell
$acrLoginServer = 'ecommerceregistrynew.azurecr.io'
$imageTag = '<Build.BuildId from your Docker CI run>'

helm lint .\AKS\helm

helm upgrade --install robot-shop .\AKS\helm `
  --namespace robot-shop `
  --create-namespace `
  --wait `
  --timeout 15m `
  --set "image.repo=$acrLoginServer" `
  --set-string "image.version=$imageTag"
```

The manual command assumes the signed-in identity has the required Kubernetes permissions. It does not install the chart's namespace-scoped Helm Role or RoleBinding.

## Verify the release

```powershell
helm status robot-shop --namespace robot-shop
kubectl get pods --namespace robot-shop
kubectl get deployments,statefulsets --namespace robot-shop
kubectl get services --namespace robot-shop
kubectl get pvc --namespace robot-shop
```

The `web` Service is a public LoadBalancer on port `8080`. Open `http://<EXTERNAL-IP>:8080` after Azure assigns an address. This chart does not configure ingress, TLS, or a custom domain.

## Common values

| Value | Chart default | Purpose |
|---|---|---|
| `image.repo` | `ecommerceregistrynew.azurecr.io` | Base ACR hostname for the ten Robot Shop images. |
| `image.version` | `v1` | Image tag. The master pipeline overrides it with the current `Build.BuildId`. |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy. |
| `nodeport` | `false` | Uses a LoadBalancer for the web Service; `true` selects NodePort. |
| `payment.gateway` | `null` | Optional upstream sample payment gateway URL. |
| `eum.key`, `eum.url` | No key; upstream endpoint | Optional Instana website monitoring configuration. Do not put credentials in the chart or command history. |
| `<workload>.affinity`, `.nodeSelector`, `.tolerations` | `{}`, `{}`, `[]` | Optional scheduling controls for individual workloads. |

Scheduling values may be set for `cart`, `catalogue`, `dispatch`, `mongodb`, `mysql`, `payment`, `rabbitmq`, `ratings`, `redis`, `shipping`, `user`, and `web`, for example in a values file passed with `-f`.

## Chart notes

- The Redis StatefulSet requests a 1 Gi persistent volume. Its template hard-codes `storageClassName: default`; the `redis.storageClassName` value is not wired into the template.
- The MySQL workload has no persistent volume, so its data is not durable across pod replacement.
- Keep `psp.enabled` set to `false`; Pod Security Policy is a legacy option.
- NodePort and Instana monitoring are optional upstream settings and are not used by the documented Azure deployment.

## Uninstall

```powershell
helm uninstall robot-shop --namespace robot-shop
```

Review and remove any remaining PVCs separately if you also intend to delete the Redis volume and its data. For full Azure resource cleanup, use the guarded procedure in the [root README](../../README.md).
