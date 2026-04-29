// Tenant -> Product mapping for declarative isolation.
// Replaces per-tenant routing code paths in your gateway with APIM-native config.
// Each product gets its own policy (timeout tier, rate limit, quota, hedge on/off).

var products = [
  {
    name: 'tier-fast'
    displayName: 'Fast tier (5s budget)'
    description: 'Interactive UI, the assistant UI autocomplete. Hedge enabled. 30k TPM.'
    state: 'published'
    subscriptionRequired: true
  }
  {
    name: 'tier-standard'
    displayName: 'Standard tier (60s budget)'
    description: 'Chat, RAG. Default product. 60k TPM.'
    state: 'published'
    subscriptionRequired: true
  }
  {
    name: 'tier-batch'
    displayName: 'Batch tier (10min budget)'
    description: 'Offline summarisation, evals. 200k TPM. NOT default.'
    state: 'published'
    subscriptionRequired: true
  }
]

resource product 'Microsoft.ApiManagement/service/products@2023-09-01-preview' = [for p in products: {
  parent: apim
  name: p.name
  properties: {
    displayName: p.displayName
    description: p.description
    state: p.state
    subscriptionRequired: p.subscriptionRequired
    approvalRequired: false
  }
}]

// Per-product policy attaches the right forward-request timeout (see
// forward-request-{fast,standard,long-batch}.xml).
resource productPolicy 'Microsoft.ApiManagement/service/products/policies@2023-09-01-preview' = [for (p, i) in products: {
  parent: product[i]
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/forward-request-${p.name == 'tier-fast' ? 'fast' : p.name == 'tier-standard' ? 'standard' : 'long-batch'}.xml')
  }
}]

// Example tenant-class subscriptions:
//   the assistant UI-prod          -> tier-fast    (interactive UI)
//   the assistant UI-batch-eval    -> tier-batch   (offline runs)
//   build-code-gen  -> tier-standard
//   isv-partner-x       -> tier-standard with quota
// Each subscription key carries its tenant identity; APIM enforces tier
// per request - no code branching in the LLM Proxy.
