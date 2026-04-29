// =====================================================================================
// MCP Gateway API, passthrough HTTP API in front of an MCP server.
// APIM native MCP support is experimental as of 2026-04; this implementation governs
// HTTP transport for MCP servers (rate-limit, auth, observability) and is forward-
// compatible with future native MCP apiType.
// =====================================================================================

@description('Name of the existing APIM service.')
param apimName string

@description('MCP backend URL. Placeholder, operator updates post-deploy.')
param mcpBackendUrl string = 'https://mcp.contoso.invalid'

@description('Common tags.')
param tags object = {
  Owner: 'admin@example.com'
  Project: 'apim-ai-gateway-lab'
  ExpiresOn: '2026-05-12'
  SecurityControl: 'Ignore'
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// ---------------- Backend ----------------
resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-server-stub'
  properties: {
    description: 'MCP server (placeholder, swap via az apim backend update post-deploy)'
    url: mcpBackendUrl
    protocol: 'http'
    type: 'Single'
  }
}

// ---------------- Product ----------------
resource mcpProduct 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-tier'
  properties: {
    displayName: 'MCP Gateway Tier'
    description: 'Subscription product for MCP server access via APIM'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// ---------------- API ----------------
resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-gateway'
  properties: {
    displayName: 'MCP Gateway (passthrough)'
    path: 'mcp'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    apiType: 'http'
    type: 'http'
    serviceUrl: mcpBackendUrl
  }
}

resource mcpCatchAll 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'catch-all'
  properties: {
    displayName: 'Catch-all POST'
    method: 'POST'
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}

resource mcpGetCatchAll 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpApi
  name: 'catch-all-get'
  properties: {
    displayName: 'Catch-all GET (SSE / health)'
    method: 'GET'
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}

resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-gateway-policy.xml')
  }
  dependsOn: [
    mcpBackend
  ]
}

resource mcpProductApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: mcpProduct
  name: mcpApi.name
}

resource mcpSub 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-tier-sub'
  properties: {
    displayName: 'MCP Tier Demo Subscription'
    scope: mcpProduct.id
    state: 'active'
    allowTracing: true
  }
}

#disable-next-line outputs-should-not-contain-secrets
output mcpSubscriptionKey string = mcpSub.listSecrets().primaryKey
output mcpApiPath string = mcpApi.properties.path
output mcpProductId string = mcpProduct.id
output mcpBackendName string = mcpBackend.name
