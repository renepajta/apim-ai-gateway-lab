param name string
param location string
param tags object
param modelName string
param modelVersion string
param deploymentAlias string
param capacity int
param workspaceId string
@description('Optional principal id (APIM MI) to grant Cognitive Services OpenAI User on this account.')
param apimPrincipalId string = ''

@description('If true, also deploy an embeddings model on this account (used for semantic cache).')
param deployEmbeddings bool = false
@description('Embeddings model name (only used if deployEmbeddings=true).')
param embeddingsModelName string = 'text-embedding-3-small'
@description('Embeddings model version.')
param embeddingsModelVersion string = '1'
@description('Embeddings deployment alias.')
param embeddingsDeploymentAlias string = 'embeddings'
@description('Embeddings deployment SKU type. SWC has no plain Standard quota for text-embedding-3-small in this subscription, GlobalStandard has 2000k.')
param embeddingsSkuName string = 'GlobalStandard'
@description('Embeddings capacity (TPM in thousands).')
param embeddingsCapacity int = 50

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: deploymentAlias
  sku: {
    name: 'Standard'
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

// Optional embeddings deployment (semantic cache support). Sequenced AFTER chat deployment
// because AOAI rejects parallel deployment puts on the same account.
resource embeddingsDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployEmbeddings) {
  parent: aoai
  name: embeddingsDeploymentAlias
  sku: {
    name: embeddingsSkuName
    capacity: embeddingsCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingsModelName
      version: embeddingsModelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
  dependsOn: [
    deployment
  ]
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aoai
  name: 'to-law'
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Audit', enabled: true }
      { category: 'RequestResponse', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  scope: aoai
  name: guid(aoai.id, apimPrincipalId, openAiUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output id string = aoai.id
output name string = aoai.name
output endpoint string = aoai.properties.endpoint
output embeddingsDeploymentName string = deployEmbeddings ? embeddingsDeploymentAlias : ''
