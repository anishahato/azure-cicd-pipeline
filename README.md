# Azure CI/CD Pipeline: ACR + App Service

A complete, working example of an automated CI/CD pipeline on Azure:

```
Developer push --> Azure Pipelines --> Build & Test --> Push image to ACR
                                            |
                                            v
                                 Deploy to Azure App Service (dev)
                                            |
                                            v
                                       Health check
                                            |
                                            v
                         [manual approval]  Deploy to prod "staging" slot
                                            |
                                            v
                          Health-check slot --> Swap into production
                                            |
                                            v
                              Health check + Application Insights monitoring
```

## What's in this project

| Path | Purpose |
|---|---|
| `app/` | Minimal Node.js/Express web app (the thing being deployed) |
| `Dockerfile` | Multi-stage build producing a small production image |
| `infra/main.bicep` | Infrastructure as Code: ACR, App Service Plan, Web App, Application Insights |
| `monitoring/alerts.bicep` | Availability test + alert rules (email on downtime or 5xx spikes) |
| `azure-pipelines.yml` | The pipeline itself: build → test → push → deploy → verify |

## Key DevOps concepts this demonstrates

- **CI (Continuous Integration)**: every push to `main` triggers the `Build` stage — install deps, run tests, build a container image. Failures block progress before anything ships.
- **Artifact immutability**: the image is built once, tagged with the pipeline's `Build.BuildId`, pushed to ACR, and that exact tag is what gets deployed — never a rebuild at deploy time.
- **CD (Continuous Deployment)**: the `DeployDev` stage automatically deploys the pushed image to App Service with no manual step, using an Azure DevOps **Environment** (`dev`) so you get deployment history.
- **Continuous Delivery with a human gate for prod**: `DeployProd` targets the `prod` Environment, which you configure with a **required approval** — the pipeline builds and deploys to dev automatically, but a person signs off before anything reaches production. This is the standard line between "continuous deployment" (fully automatic) and "continuous delivery" (automatic up to a deliberate release decision).
- **Zero-downtime releases via slot swap**: `DeployProd` deploys the new image into a `staging` deployment slot on the *same* prod App Service, health-checks that slot directly (so a bad build never sees live traffic), then swaps slots. The swap is a warm, near-instant cutover — no cold start, no dropped requests. If the post-swap health check fails, the pipeline tells you to swap back or redeploy the previous tag.
- **Infrastructure as Code**: `infra/main.bicep` means your ACR/App Service/App Insights setup is versioned, reviewable, and reproducible — not created by hand in the portal.
- **Least-privilege identity**: the Web App uses a **system-assigned managed identity** with the built-in `AcrPull` role instead of ACR admin credentials — no secrets to leak or rotate.
- **Health checks as a deployment gate**: the pipeline doesn't just "deploy and hope" — it polls `/health` after deployment and fails the pipeline if the app doesn't come up healthy.
- **Observability/monitoring**: Application Insights collects telemetry; `monitoring/alerts.bicep` adds an availability ping test and alert rules so you're notified of outages instead of discovering them from a user complaint.

## Setup — one-time steps

### 1. Provision infrastructure
```bash
az login
az group create --name rg-myapp-dev --location eastus

az deployment group create \
  --resource-group rg-myapp-dev \
  --template-file infra/main.bicep \
  --parameters appName=myapp environment=dev
```
Note the `acrLoginServer` and `webAppName` values in the output — you'll need them below.

### 2. (Optional) Provision monitoring alerts
```bash
az deployment group create \
  --resource-group rg-myapp-dev \
  --template-file monitoring/alerts.bicep \
  --parameters appName=myapp environment=dev notifyEmail=you@example.com
```

### 3. Create the Azure DevOps service connections
In your Azure DevOps project: **Project Settings → Service connections → New service connection**
- **Azure Resource Manager** connection, scoped to the resource group `rg-myapp-dev`. Name it `azure-service-connection` (or update `azureSubscription` in the YAML).
- **Docker Registry** connection, type "Azure Container Registry", pointing at the ACR from step 1. Name it `acr-service-connection` (or update `acrServiceConnection` in the YAML).

### 4. Create the pipeline
**Pipelines → New Pipeline → Azure Repos Git / GitHub → select this repo → Existing Azure Pipelines YAML file → `/azure-pipelines.yml`**

### 5. Update variables
Edit the `variables:` block at the top of `azure-pipelines.yml` (or move them into a Library variable group named `azure-cicd-vars`) to match your actual `acrName`, `resourceGroupName`, and `webAppName` from step 1's output.

### 6. Create the Environments
**Pipelines → Environments → New environment**, create two:
- `dev` (matches `environment: 'dev'` in the YAML) — no approvals needed, deploys automatically.
- `prod` (matches `environment: 'prod'`) — open it, go to the **⋮ menu → Approvals and checks → Approvals**, and add yourself or your team as required approvers. Every run will now pause before `DeployProd` until someone approves it.

### 7. Provision prod infrastructure (adds the staging slot)
```bash
az group create --name rg-myapp-prod --location eastus

az deployment group create \
  --resource-group rg-myapp-prod \
  --template-file infra/main.bicep \
  --parameters appName=myapp environment=prod appServicePlanSku=S1 enableStagingSlot=true
```
Note this uses `S1` (Standard tier) — deployment slots require Standard or higher; the dev `B1` (Basic) plan doesn't support them. Update `prodWebAppName` in `azure-pipelines.yml` to match the output.

### 8. Push to `main`
The pipeline runs automatically through `DeployDev`, then pauses at `DeployProd` for approval. Watch progress under **Pipelines → Runs**.

## Extending this

- **Add container vulnerability scanning**: ACR has built-in Microsoft Defender for Cloud image scanning — enable it on the registry and gate the pipeline on scan results.
- **Scale the monitoring**: add Log Analytics queries/workbooks for request latency, dependency failures, and custom business metrics via the Application Insights SDK in `app/server.js`.
- **Automate rollback**: the post-swap health check currently just fails and tells you what to do. You can make the "swap back" step automatic by adding another `AzureAppServiceManage@0` "Swap Slots" task in an `else`-style follow-up (Azure Pipelines doesn't have native if/else on task failure, so this is typically done by checking the previous task's result with a `condition: failed()` step).
- **Multiple prod regions/staging environments**: duplicate the `DeployProd` stage pattern per region, or add a `staging` (pre-prod) Environment between dev and prod for integration testing.
