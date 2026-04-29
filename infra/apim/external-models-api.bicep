// =====================================================================================
// External Models API, OpenAI-direct + Anthropic-direct fronted by APIM
// Cross-provider failover to the AOAI gateway is implemented in policy.
// =====================================================================================

@description('Name of the existing APIM service.')
param apimName string

@description('Common tags.')
param tags object = {
  Owner: 'admin@example.com'
  Project: 'apim-ai-gateway-lab'
  ExpiresOn: '2026-05-12'
  SecurityControl: 'Ignore'
}

@description('OpenAI API key. Leave empty in IaC; populate post-deploy from KV.')
@secure()
param openaiApiKey string = ''

@description('Anthropic API key (declarative, demo-only).')
@secure()
param anthropicApiKey string = ''

@description('AOAI tier-standard subscription key (from resiliency module). Filled post-deploy.')
@secure()
param aoaiTierStdKey string = ''

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// ---------------- Backends ----------------
resource openaiBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'openai-direct'
  properties: {
    description: 'OpenAI public API (api.openai.com)'
    url: 'https://api.openai.com/v1'
    protocol: 'http'
    type: 'Single'
  }
}

resource anthropicBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'anthropic-direct'
  properties: {
    description: 'Anthropic public API (api.anthropic.com), demo declarative only'
    url: 'https://api.anthropic.com/v1'
    protocol: 'http'
    type: 'Single'
  }
}

// ---------------- Named-values (secrets, empty default) ----------------
resource nvOpenAi 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'openai-api-key'
  properties: {
    displayName: 'openai-api-key'
    secret: true
    value: empty(openaiApiKey) ? 'placeholder-set-from-kv' : openaiApiKey
    tags: [ 'external-models', 'demo' ]
  }
}

resource nvAnthropic 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'anthropic-api-key'
  properties: {
    displayName: 'anthropic-api-key'
    secret: true
    value: empty(anthropicApiKey) ? 'placeholder-set-from-kv' : anthropicApiKey
    tags: [ 'external-models', 'demo' ]
  }
}

resource nvAoaiTierStd 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'aoai-tier-std-key'
  properties: {
    displayName: 'aoai-tier-std-key'
    secret: true
    value: empty(aoaiTierStdKey) ? 'placeholder-set-post-deploy' : aoaiTierStdKey
    tags: [ 'external-models', 'failover' ]
  }
}

// ---------------- Product ----------------
resource externalProduct 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'external-tier'
  properties: {
    displayName: 'External Models Tier'
    description: 'Subscription product for external model providers (OpenAI, Anthropic) brokered via APIM'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// ---------------- API ----------------
resource externalApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'external-models'
  properties: {
    displayName: 'External Models (OpenAI / Anthropic)'
    path: 'external/v1'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    apiType: 'http'
    type: 'http'
    serviceUrl: 'https://api.openai.com/v1'
  }
}

// Catch-all wildcard operation so /external/v1/* routes through policy
resource externalCatchAll 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: externalApi
  name: 'catch-all'
  properties: {
    displayName: 'Catch-all'
    method: 'POST'
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}

resource externalApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: externalApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/external-models-policy.xml')
  }
  dependsOn: [
    openaiBackend
    anthropicBackend
    nvOpenAi
    nvAnthropic
    nvAoaiTierStd
  ]
}

resource externalProductApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: externalProduct
  name: externalApi.name
}

// Subscription with its own key
resource externalSub 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'external-tier-sub'
  properties: {
    displayName: 'External Tier Demo Subscription'
    scope: externalProduct.id
    state: 'active'
    allowTracing: true
  }
}

#disable-next-line outputs-should-not-contain-secrets
output externalSubscriptionKey string = externalSub.listSecrets().primaryKey
output externalApiPath string = externalApi.properties.path
output externalProductId string = externalProduct.id
