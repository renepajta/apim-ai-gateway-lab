// =====================================================================================
// Azure AI Content Safety account — used by the APIM <llm-content-safety> policy
// to enforce harm-category filtering and prompt-shield on inbound LLM requests.
// APIM MI is granted Cognitive Services User on this account so the policy can
// authenticate without shared keys.
// =====================================================================================
targetScope = 'resourceGroup'

param name string
param location string
param tags object
@description('APIM system-assigned MI principal id. Granted Cognitive Services User on this account.')
param apimPrincipalId string = ''

resource cs 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'ContentSafety'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

// Cognitive Services User — needed by APIM MI to call Content Safety analyze APIs
var cogServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  scope: cs
  name: guid(cs.id, apimPrincipalId, cogServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cogServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output id string = cs.id
output name string = cs.name
output endpoint string = cs.properties.endpoint
