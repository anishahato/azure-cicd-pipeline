// Optional but recommended: alert rules so pipeline/app failures notify a human
// instead of relying on someone checking the portal.
// Deploy after main.bicep, e.g.:
//   az deployment group create -g <rg-name> -f monitoring/alerts.bicep \
//     -p appName=myapp environment=dev notifyEmail=you@example.com

@description('Base name matching what was used in infra/main.bicep')
param appName string

@description('Environment suffix matching infra/main.bicep')
param environment string = 'dev'

@description('Email address to notify on alert')
param notifyEmail string

@description('Location must match the Application Insights resource region')
param location string = resourceGroup().location

var resourceSuffix = '${appName}-${environment}'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${resourceSuffix}'
  location: 'global'
  properties: {
    groupShortName: 'cicdAlerts'
    enabled: true
    emailReceivers: [
      {
        name: 'PrimaryOnCall'
        emailAddress: notifyEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Ping test hitting the app's /health endpoint from multiple regions
resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: 'webtest-${resourceSuffix}'
  location: location
  tags: {
    'hidden-link:${resourceId('Microsoft.Insights/components', 'appi-${resourceSuffix}')}': 'Resource'
  }
  properties: {
    SyntheticMonitorId: 'webtest-${resourceSuffix}'
    Name: 'Health check - ${appName} (${environment})'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'ping'
    RetryEnabled: true
    Locations: [
      { Id: 'us-tx-sn1-azr' }
      { Id: 'emea-nl-ams-azr' }
      { Id: 'apac-sg-sin-azr' }
    ]
    Request: {
      RequestUrl: 'https://app-${resourceSuffix}.azurewebsites.net/health'
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
    }
  }
}

resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-availability-${resourceSuffix}'
  location: 'global'
  properties: {
    severity: 1
    enabled: true
    scopes: [
      resourceId('Microsoft.Insights/components', 'appi-${resourceSuffix}')
      availabilityTest.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: resourceId('Microsoft.Insights/components', 'appi-${resourceSuffix}')
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource serverErrorsAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-server-errors-${resourceSuffix}'
  location: 'global'
  properties: {
    severity: 2
    enabled: true
    scopes: [
      resourceId('Microsoft.Web/sites', 'app-${resourceSuffix}')
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Http5xxErrors'
          metricName: 'Http5xx'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}
