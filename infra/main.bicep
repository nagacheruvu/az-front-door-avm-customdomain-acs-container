targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Azure region for regional resources (Container Apps, Log Analytics)')
param location string = resourceGroup().location

@description('Name prefix for all resources')
@minLength(2)
@maxLength(10)
param namePrefix string = 'afd'

@description('Custom domain hostname (e.g., www.contoso.com)')
param customDomainHostName string

@description('Container image for the hello world app')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Tags to apply to all resources')
param tags object = {}

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var profileName = '${namePrefix}-afd-${uniqueSuffix}'
var wafPolicyName = '${namePrefix}waf${uniqueSuffix}'
var endpointName = '${namePrefix}-ep-${uniqueSuffix}'
var originGroupName = 'hello-world-og'
var customDomainResourceName = replace(replace(customDomainHostName, '.', '-'), '*', 'wildcard')
var logAnalyticsName = '${namePrefix}-law-${uniqueSuffix}'
var containerEnvName = '${namePrefix}-cae-${uniqueSuffix}'
var containerAppName = '${namePrefix}-ca-${uniqueSuffix}'

// ============================================================================
// Log Analytics Workspace (required by Container Apps)
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================================
// Container Apps Environment
// ============================================================================

module containerAppEnvironment 'br/public:avm/res/app/managed-environment:0.8.1' = {
  name: 'containerAppEnvDeployment'
  params: {
    name: containerEnvName
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalytics.id
    zoneRedundant: false
  }
}

// ============================================================================
// Hello World Container App (Backend Origin)
// ============================================================================

module containerApp 'br/public:avm/res/app/container-app:0.12.0' = {
  name: 'containerAppDeployment'
  params: {
    name: containerAppName
    environmentResourceId: containerAppEnvironment.outputs.resourceId
    location: location
    tags: tags
    ingressTargetPort: 80
    ingressExternal: true
    ingressTransport: 'auto'
    containers: [
      {
        name: 'hello-world'
        image: containerImage
        resources: {
          cpu: '0.25'
          memory: '0.5Gi'
        }
      }
    ]
    scaleMinReplicas: 1
    scaleMaxReplicas: 3
  }
}

// ============================================================================
// WAF Policy with Bot Protection (AVM Module)
// ============================================================================

module wafPolicy 'br/public:avm/res/network/front-door-web-application-firewall-policy:0.3.1' = {
  name: 'wafPolicyDeployment'
  params: {
    name: wafPolicyName
    tags: tags
    sku: 'Premium_AzureFrontDoor'
    policySettings: {
      mode: 'Prevention'
      enabledState: 'Enabled'
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
        }
      ]
    }
  }
}

// ============================================================================
// Azure Front Door Profile with Custom Domain (AVM Module)
// ============================================================================

module frontDoorProfile 'br/public:avm/res/cdn/profile:0.12.0' = {
  name: 'frontDoorProfileDeployment'
  params: {
    name: profileName
    location: 'global'
    tags: tags
    sku: 'Premium_AzureFrontDoor'
    originResponseTimeoutSeconds: 60
    afdEndpoints: [
      {
        name: endpointName
        enabledState: 'Enabled'
        routes: [
          {
            name: 'default-route'
            originGroupName: originGroupName
            patternsToMatch: [
              '/*'
            ]
            forwardingProtocol: 'HttpsOnly'
            httpsRedirect: 'Enabled'
            linkToDefaultDomain: 'Enabled'
            customDomainNames: [
              customDomainResourceName
            ]
          }
        ]
      }
    ]
    originGroups: [
      {
        name: originGroupName
        loadBalancingSettings: {
          sampleSize: 4
          successfulSamplesRequired: 3
          additionalLatencyInMilliseconds: 50
        }
        healthProbeSettings: {
          probePath: '/'
          probeProtocol: 'Https'
          probeIntervalInSeconds: 100
          probeRequestType: 'HEAD'
        }
        origins: [
          {
            name: 'container-app-origin'
            hostName: containerApp.outputs.fqdn
            httpPort: 80
            httpsPort: 443
            originHostHeader: containerApp.outputs.fqdn
            priority: 1
            weight: 1000
          }
        ]
      }
    ]
    customDomains: [
      {
        name: customDomainResourceName
        hostName: customDomainHostName
        certificateType: 'ManagedCertificate'
      }
    ]
    securityPolicies: [
      {
        name: 'bot-waf-policy'
        associations: [
          {
            domains: [
              {
                id: resourceId('Microsoft.Cdn/profiles/afdEndpoints', profileName, endpointName)
              }
            ]
            patternsToMatch: [
              '/*'
            ]
          }
        ]
        wafPolicyResourceId: wafPolicy.outputs.resourceId
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Front Door profile name')
output frontDoorProfileName string = profileName

@description('Front Door endpoint hostname')
output frontDoorEndpointHostName string = frontDoorProfile.outputs.profileName

@description('WAF policy name')
output wafPolicyName string = wafPolicy.outputs.name

@description('WAF policy resource ID')
output wafPolicyResourceId string = wafPolicy.outputs.resourceId

@description('Container App FQDN')
output containerAppFqdn string = containerApp.outputs.fqdn

@description('Custom domain name configured')
output customDomain string = customDomainHostName

@description('DNS validation - Add this TXT record to your DNS')
output dnsValidationMessage string = 'Add a CNAME record: ${customDomainHostName} -> ${endpointName}.z01.azurefd.net'
