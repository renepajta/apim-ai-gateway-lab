// =====================================================================================
// APIM service + AI Gateway API + 3-tier products + backends + load-balanced pool
// v3 changes:
//   - 3rd AOAI backend (Switzerland North) — priority 1 / weight 30 (SWC=70)
//   - FRC moved to priority 2 / weight 100 (active fallback only)
//   - Multi-rule circuit breaker per backend: rule-5xx, rule-timeout, rule-429
//   - Embeddings backend for semantic-cache-lookup
//   - Content Safety backend for llm-content-safety policy
//   - 3 products: tier-fast (30s), tier-standard (120s), tier-batch (600s) with
//     product-scoped policy fragments enforcing per-tier forward-request timeouts
//   - Each product gets its own subscription key, all subscribed to the same API
//   - APIM external cache (Redis) wired via Microsoft.ApiManagement/service/caches
// =====================================================================================
param name string
param location string
param tags object
param publisherEmail string
param publisherName string
param appInsightsId string
param appInsightsInstrKey string
param workspaceId string

// AOAI endpoints (3 backends now)
param aoaiPrimaryEndpoint string
param aoaiSecondaryEndpoint string
param aoaiTertiaryEndpoint string

// Embeddings deployment lives on the SWC AOAI account; backend points to its base URL
param embeddingsAoaiEndpoint string

// Content Safety endpoint
param contentSafetyEndpoint string

// Redis (external APIM cache)
param redisHostName string
param redisSslPort int
@secure()
@description('Redis primary access key for APIM external cache connection string. Pass via -p or KV ref at deploy time.')
param redisPrimaryKey string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
  }
}

// Logger -> App Insights
resource logger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apim
  name: 'appi-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'App Insights logger for AI Gateway'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrKey
    }
  }
}

resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'to-law'
  properties: {
    workspaceId: workspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// =====================================================================================
// External cache (Redis) — used for both session-stickiness and semantic cache.
// Note: caches resource takes a connection string. We compose it from the Redis
// host + the @secure() primary key parameter so no secrets land in the template.
// =====================================================================================
resource externalCache 'Microsoft.ApiManagement/service/caches@2024-06-01-preview' = {
  parent: apim
  name: 'redis-session'
  properties: {
    description: 'Redis backing for session-stickiness map and semantic cache'
    connectionString: '${redisHostName}:${redisSslPort},password=${redisPrimaryKey},ssl=true,abortConnect=False'
    useFromLocation: 'default'
  }
}

// =====================================================================================
// Backends (3 AOAI backends + embeddings + content-safety)
//
// Doc note: Microsoft Learn currently states "you can configure only one rule for a
// backend circuit breaker" but the rules[] schema accepts multiple. We define three
// named rules per backend (rule-5xx, rule-timeout, rule-429) per the brief; if APIM
// rejects multi-rule at runtime we'll consolidate at deploy time. Tracked in README.
//
// errorReasons enum: APIM exposes "Server errors" plus connectivity reasons. We use
// "Timeout" and "BackendConnectionFailure" for rule-timeout per the JS/.NET SDK
// docs and CircuitBreakerFailureCondition reference.
// =====================================================================================
// APIM currently only allows ONE rule per backend circuit breaker.
// We collapse 5xx + 429 + timeout/connection errors into a single rule with
// statusCodeRanges + errorReasons, threshold sized for the broadest of the
// three original rules. acceptRetryAfter=true so 429 Retry-After is honored.
var cbRulesPerBackend = [
  {
    name: 'rule-failures'
    failureCondition: {
      count: 5
      interval: 'PT1M'
      statusCodeRanges: [
        { min: 429, max: 429 }
        { min: 500, max: 599 }
      ]
      errorReasons: [ 'Server errors', 'Timeout', 'BackendConnectionFailure' ]
    }
    tripDuration: 'PT1M'
    acceptRetryAfter: true
  }
]

resource backendPrimary 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'aoai-swc'
  properties: {
    description: 'AOAI Sweden Central (priority 1 / weight 70)'
    url: '${aoaiPrimaryEndpoint}openai'
    protocol: 'http'
    type: 'Single'
    circuitBreaker: {
      rules: cbRulesPerBackend
    }
  }
}

resource backendTertiary 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'aoai-swn'
  properties: {
    description: 'AOAI Switzerland North (priority 1 / weight 30) — 3rd PAYG backend, see modules/aoai.bicep header for region selection trace'
    url: '${aoaiTertiaryEndpoint}openai'
    protocol: 'http'
    type: 'Single'
    circuitBreaker: {
      rules: cbRulesPerBackend
    }
  }
}

resource backendSecondary 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'aoai-frc'
  properties: {
    description: 'AOAI France Central (priority 2 / weight 100) — fallback group'
    url: '${aoaiSecondaryEndpoint}openai'
    protocol: 'http'
    type: 'Single'
    circuitBreaker: {
      rules: cbRulesPerBackend
    }
  }
}

resource backendPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'aoai-pool'
  properties: {
    description: 'Priority + weighted load-balanced AOAI pool. P1: SWC(70) + SWN(30). P2: FRC(100) used only when all P1 breakers tripped.'
    type: 'Pool'
    pool: {
      services: [
        { id: backendPrimary.id, priority: 1, weight: 70 }
        { id: backendTertiary.id, priority: 1, weight: 30 }
        { id: backendSecondary.id, priority: 2, weight: 100 }
      ]
    }
  }
}

// Embeddings backend — used by azure-openai-semantic-cache-lookup
resource embeddingsBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'embeddings-backend'
  properties: {
    description: 'AOAI embeddings deployment (text-embedding-3-small) on SWC for semantic-cache-lookup'
    url: '${embeddingsAoaiEndpoint}openai'
    protocol: 'http'
    type: 'Single'
    credentials: {
      // Auth header injected at runtime by the semantic-cache-lookup policy
      // (embeddings-backend-auth="system-assigned"). No static credential here.
      header: {}
    }
  }
}

// Content Safety backend — used by llm-content-safety policy.
// Auth: APIM MI -> Cognitive Services User on the Content Safety account.
resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'content-safety-backend'
  properties: {
    description: 'Azure AI Content Safety endpoint for llm-content-safety policy'
    url: contentSafetyEndpoint
    protocol: 'http'
    type: 'Single'
  }
}

// =====================================================================================
// API surface (unchanged path, new policy)
// =====================================================================================
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    displayName: 'Azure OpenAI (multi-backend)'
    path: 'openai'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    apiType: 'http'
    type: 'http'
    serviceUrl: '${aoaiPrimaryEndpoint}openai'
    format: 'openapi'
    value: loadTextContent('../policies/aoai-openapi.json')
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/api-policy.xml')
  }
  dependsOn: [
    backendPool
    embeddingsBackend
    contentSafetyBackend
    externalCache
    logger
  ]
}

// =====================================================================================
// Three products with per-tier read timeouts (policy fragments)
// Each product fragment defines `<forward-request timeout="X" buffer-response="false"/>`.
// Tiers: tier-fast 30s | tier-standard 120s | tier-batch 600s.
// =====================================================================================
resource productFast'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'tier-fast'
  properties: {
    displayName: 'Fast tier (30s)'
    description: 'Chat / the embedded assistant UI short turns. forward-request timeout 30s.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productStandard 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'tier-standard'
  properties: {
    displayName: 'Standard tier (120s)'
    description: 'General LLM workloads. forward-request timeout 120s.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productBatch 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'tier-batch'
  properties: {
    displayName: 'Batch tier (600s)'
    description: 'Long completions / agentic / batch summarisation. forward-request timeout 600s.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productFastPolicy 'Microsoft.ApiManagement/service/products/policies@2024-06-01-preview' = {
  parent: productFast
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/product-fast.xml')
  }
}
resource productStandardPolicy 'Microsoft.ApiManagement/service/products/policies@2024-06-01-preview' = {
  parent: productStandard
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/product-standard.xml')
  }
}
resource productBatchPolicy 'Microsoft.ApiManagement/service/products/policies@2024-06-01-preview' = {
  parent: productBatch
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/product-batch.xml')
  }
}

resource productFastApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: productFast
  name: api.name
}
resource productStandardApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: productStandard
  name: api.name
}
resource productBatchApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: productBatch
  name: api.name
}

// One subscription per tier
resource subFast 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'sub-tier-fast'
  properties: {
    displayName: 'Demo client (fast)'
    scope: productFast.id
    state: 'active'
    allowTracing: true
  }
}
resource subStandard 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'sub-tier-standard'
  properties: {
    displayName: 'Demo client (standard)'
    scope: productStandard.id
    state: 'active'
    allowTracing: true
  }
}
resource subBatch 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'sub-tier-batch'
  properties: {
    displayName: 'Demo client (batch)'
    scope: productBatch.id
    state: 'active'
    allowTracing: true
  }
}

output name string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId

// Per-tier subscription keys — listed via listSecrets so deploy can write them out.
#disable-next-line outputs-should-not-contain-secrets
output subscriptionKeyFast string = subFast.listSecrets().primaryKey
#disable-next-line outputs-should-not-contain-secrets
output subscriptionKeyStandard string = subStandard.listSecrets().primaryKey
#disable-next-line outputs-should-not-contain-secrets
output subscriptionKeyBatch string = subBatch.listSecrets().primaryKey
