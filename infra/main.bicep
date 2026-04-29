// =====================================================================================
// APIM AI Gateway Lab, main deployment template
//
// Provisions:
//   - 3 PAYG Azure OpenAI backends in 3 regions for active-active failover.
//   - Embeddings deployment (text-embedding-3-small) used by azure-openai-semantic-cache-lookup.
//   - Azure Cache for Redis wired to APIM as external cache "redis-session".
//   - Azure AI Content Safety for the <llm-content-safety> policy (Prompt Shields).
//   - 3 APIM products with per-tier forward-request timeouts (30 / 120 / 600s).
//   - Logic App (Consumption) stub for active health-probes.
//   - Workbook resource with KPI tiles for Application Insights.
//   - 3 APIs: azure-openai (chat + responses), external-models (OpenAI/Anthropic + AOAI fallback), mcp-gateway.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Random suffix to keep names globally unique.')
param rand string = take(uniqueString(resourceGroup().id), 6)

@description('Primary region (must match RG).')
param primaryLocation string = resourceGroup().location

@description('Secondary AOAI region.')
param secondaryLocation string = 'francecentral'

@description('Tertiary AOAI region, chosen by quota probe (see header).')
param tertiaryLocation string = 'switzerlandnorth'

@description('Common tags.')
param tags object = {
  Owner: 'admin@example.com'
  Project: 'apim-ai-gateway-lab'
  SecurityControl: 'Ignore'
}

@description('Model name to deploy in all AOAI accounts.')
param modelName string = 'gpt-4o'

@description('Model version.')
param modelVersion string = '2024-11-20'

@description('Deployment (alias) name used in the OpenAI API path.')
param deploymentAlias string = 'chat'

@description('Per-deployment Standard capacity (TPM in thousands).')
param deploymentCapacity int = 50

@description('APIM publisher email.')
param publisherEmail string = 'admin@example.com'

@description('APIM publisher name.')
param publisherName string = 'APIM AI Gateway Lab'

@description('Embeddings deployment alias on the SWC AOAI account.')
param embeddingsDeploymentAlias string = 'embeddings'

@description('Embeddings model name.')
param embeddingsModelName string = 'text-embedding-3-small'

@description('Embeddings model version.')
param embeddingsModelVersion string = '1'

@description('Embeddings SKU (GlobalStandard chosen because plain Standard quota for text-embedding-3-small is 0 in this subscription on SWC).')
param embeddingsSkuName string = 'GlobalStandard'

@description('Embeddings TPM capacity (thousands).')
param embeddingsCapacity int = 50

// ---------------------- Monitoring ----------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: primaryLocation
    tags: tags
    workspaceName: 'law-aigw-lab'
    appInsightsName: 'appi-aigw-lab'
  }
}

// ---------------------- Redis (external APIM cache) ----------------------
module redis 'modules/redis.bicep' = {
  name: 'redis'
  params: {
    name: 'redis-aigw-${rand}'
    location: primaryLocation
    tags: tags
  }
}

// ---------------------- Content Safety ----------------------
// Created BEFORE APIM so the backend URL is known at APIM time, but the role
// assignment to APIM MI happens after APIM through the redeployment of the module.
module contentSafety 'modules/content-safety.bicep' = {
  name: 'content-safety'
  params: {
    name: 'cs-aigw-${rand}'
    location: primaryLocation
    tags: tags
    apimPrincipalId: ''
  }
}

// ---------------------- APIM ----------------------
// Redis primary key fetched via existing-resource reference inside main.bicep
// so no secret literal touches the template. APIM module receives it via @secure().
resource redisExisting 'Microsoft.Cache/redis@2024-03-01' existing = {
  name: 'redis-aigw-${rand}'
  dependsOn: [ redis ]
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    name: 'apim-aigw-lab-${rand}'
    location: primaryLocation
    tags: tags
    publisherEmail: publisherEmail
    publisherName: publisherName
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrKey: monitoring.outputs.appInsightsInstrKey
    workspaceId: monitoring.outputs.workspaceId
    aoaiPrimaryEndpoint: 'https://aoai-aigw-swc-${rand}.openai.azure.com/'
    aoaiSecondaryEndpoint: 'https://aoai-aigw-frc-${rand}.openai.azure.com/'
    aoaiTertiaryEndpoint: 'https://aoai-aigw-swn-${rand}.openai.azure.com/'
    embeddingsAoaiEndpoint: 'https://aoai-aigw-swc-${rand}.openai.azure.com/'
    contentSafetyEndpoint: contentSafety.outputs.endpoint
    redisHostName: redisExisting.properties.hostName
    redisSslPort: redisExisting.properties.sslPort
    redisPrimaryKey: redisExisting.listKeys().primaryKey
  }
}

// ---------------------- AOAI accounts ----------------------
module aoaiPrimary 'modules/aoai.bicep' = {
  name: 'aoai-primary'
  params: {
    name: 'aoai-aigw-swc-${rand}'
    location: primaryLocation
    tags: tags
    modelName: modelName
    modelVersion: modelVersion
    deploymentAlias: deploymentAlias
    capacity: deploymentCapacity
    workspaceId: monitoring.outputs.workspaceId
    apimPrincipalId: apim.outputs.principalId
    deployEmbeddings: true
    embeddingsModelName: embeddingsModelName
    embeddingsModelVersion: embeddingsModelVersion
    embeddingsDeploymentAlias: embeddingsDeploymentAlias
    embeddingsSkuName: embeddingsSkuName
    embeddingsCapacity: embeddingsCapacity
  }
}

module aoaiSecondary 'modules/aoai.bicep' = {
  name: 'aoai-secondary'
  params: {
    name: 'aoai-aigw-frc-${rand}'
    location: secondaryLocation
    tags: tags
    modelName: modelName
    modelVersion: modelVersion
    deploymentAlias: deploymentAlias
    capacity: deploymentCapacity
    workspaceId: monitoring.outputs.workspaceId
    apimPrincipalId: apim.outputs.principalId
  }
}

module aoaiTertiary 'modules/aoai.bicep' = {
  name: 'aoai-tertiary'
  params: {
    name: 'aoai-aigw-swn-${rand}'
    location: tertiaryLocation
    tags: tags
    modelName: modelName
    modelVersion: modelVersion
    deploymentAlias: deploymentAlias
    capacity: deploymentCapacity
    workspaceId: monitoring.outputs.workspaceId
    apimPrincipalId: apim.outputs.principalId
  }
}

// ---------------------- Content Safety role assignment ----------------------
// Re-applied here once APIM MI is known, granting Cognitive Services User on CS.
module contentSafetyRa 'modules/content-safety.bicep' = {
  name: 'content-safety-ra'
  params: {
    name: 'cs-aigw-${rand}'
    location: primaryLocation
    tags: tags
    apimPrincipalId: apim.outputs.principalId
  }
}

// ---------------------- Health probe Logic App (stub) ----------------------
module healthProbe 'modules/health-probe-logicapp.bicep' = {
  name: 'health-probe'
  params: {
    name: 'logic-lab-aigw-probe-${rand}'
    location: primaryLocation
    tags: tags
  }
}

// ---------------------- External Models API (OpenAI/Anthropic + AOAI failover) -----------
module externalApi 'apim/external-models-api.bicep' = {
  name: 'external-models-api'
  params: {
    apimName: apim.outputs.name
    tags: tags
    openaiApiKey: ''
    anthropicApiKey: ''
    aoaiTierStdKey: ''
  }
  dependsOn: [ apim ]
}

// ---------------------- MCP Gateway API ----------------------
module mcpApi 'apim/mcp-gateway-api.bicep' = {
  name: 'mcp-gateway-api'
  params: {
    apimName: apim.outputs.name
    tags: tags
  }
  dependsOn: [ apim ]
}

// ---------------------- Workbook ----------------------
module workbook 'modules/workbook.bicep' = {
  name: 'workbook'
  params: {
    name: 'wb-lab-aigw-ops-${rand}'
    displayName: 'AI Gateway, Operations'
    location: primaryLocation
    tags: tags
    appInsightsId: monitoring.outputs.appInsightsId
  }
}

// ---------------------- Outputs ----------------------
output apimGatewayUrl string = apim.outputs.gatewayUrl
output apimName string = apim.outputs.name
output aoaiPrimaryName string = aoaiPrimary.outputs.name
output aoaiSecondaryName string = aoaiSecondary.outputs.name
output aoaiTertiaryName string = aoaiTertiary.outputs.name
output aoaiPrimaryEndpoint string = aoaiPrimary.outputs.endpoint
output aoaiSecondaryEndpoint string = aoaiSecondary.outputs.endpoint
output aoaiTertiaryEndpoint string = aoaiTertiary.outputs.endpoint
output deploymentAlias string = deploymentAlias
output embeddingsDeploymentAlias string = embeddingsDeploymentAlias
output modelName string = modelName
output appInsightsName string = monitoring.outputs.appInsightsName
output workspaceName string = monitoring.outputs.workspaceName
output redisName string = redis.outputs.name
output contentSafetyName string = contentSafety.outputs.name
output healthProbeLogicAppName string = healthProbe.outputs.name
output workbookId string = workbook.outputs.workbookId

@secure()
output subscriptionKeyFast string = apim.outputs.subscriptionKeyFast
@secure()
output subscriptionKeyStandard string = apim.outputs.subscriptionKeyStandard
@secure()
output subscriptionKeyBatch string = apim.outputs.subscriptionKeyBatch

@secure()
output externalSubscriptionKey string = externalApi.outputs.externalSubscriptionKey
output externalApiPath string = externalApi.outputs.externalApiPath
@secure()
output mcpSubscriptionKey string = mcpApi.outputs.mcpSubscriptionKey
output mcpApiPath string = mcpApi.outputs.mcpApiPath
