// Provisions the infrastructure this pipeline deploys into:
//   Azure Container Registry -> App Service Plan -> Web App for Containers -> Application Insights
// Deploy once (per environment) before the pipeline runs, e.g.:
//   az deployment group create -g <rg-name> -f infra/main.bicep -p appName=myapp environment=dev

@description('Base name used to derive resource names (letters/numbers only recommended)')
param appName string

@description('Environment suffix, e.g. dev, staging, prod')
param environment string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('App Service Plan SKU. B1 is a low-cost default; use P1v3+ for production.')
param appServicePlanSku string = 'B1'

@description('Provision a "staging" deployment slot for slot-swap releases. Requires Standard (S1+) tier or higher — Basic plans do not support slots.')
param enableStagingSlot bool = false

var resourceSuffix = '${appName}-${environment}'
var acrName = replace('acr${appName}${environment}', '-', '') // ACR names must be alphanumeric only

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false // pipeline and App Service authenticate via managed identity, not admin keys
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${resourceSuffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceSuffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'plan-${resourceSuffix}'
  location: location
  sku: {
    name: appServicePlanSku
  }
  kind: 'linux'
  properties: {
    reserved: true // required for Linux plans
  }
}

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: 'app-${resourceSuffix}'
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned' // used to pull images from ACR without storing credentials
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acr.properties.loginServer}/${appName}:latest'
      acrUseManagedIdentityCreds: true
      appSettings: [
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'WEBSITES_PORT'
          value: '8080'
        }
      ]
      healthCheckPath: '/health'
    }
    httpsOnly: true
  }
}

// Grant the Web App's managed identity permission to pull images from ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, webApp.id, 'AcrPull')
  scope: acr
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // built-in "AcrPull" role
    )
  }
}

// Optional "staging" slot: the pipeline deploys here first, health-checks it,
// then swaps it into production for a zero-downtime release.
resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = if (enableStagingSlot) {
  parent: webApp
  name: 'staging'
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acr.properties.loginServer}/${appName}:latest'
      acrUseManagedIdentityCreds: true
      appSettings: [
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'WEBSITES_PORT'
          value: '8080'
        }
      ]
      healthCheckPath: '/health'
    }
    httpsOnly: true
  }
}

resource stagingSlotAcrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableStagingSlot) {
  name: guid(acr.id, webApp.id, 'staging', 'AcrPull')
  scope: acr
  properties: {
    principalId: stagingSlot.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // built-in "AcrPull" role
    )
  }
}

output acrLoginServer string = acr.properties.loginServer
output webAppName string = webApp.name
output webAppDefaultHostName string = webApp.properties.defaultHostName
output stagingSlotHostName string = enableStagingSlot ? stagingSlot.properties.defaultHostName : ''
output appInsightsConnectionString string = appInsights.properties.ConnectionString
