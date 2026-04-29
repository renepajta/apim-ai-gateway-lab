// =====================================================================================
// Active health-probe plane (STUB).
//
// What this is: an Azure Logic App (Consumption) with an HTTP-trigger workflow.
// What it WILL do (out of scope for this PR, see README "Active health probe plane"):
//   1. Azure Monitor metric alert (AOAI latency p95 > X OR error rate > Y%) fires.
//   2. Alert action group calls this workflow's HTTP trigger with the alert payload.
//   3. Workflow PATCHes the APIM backend resource via ARM REST to flip
//      properties.circuitBreaker.rules[].tripDuration up (effectively quarantining
//      the backend), or sets a custom property our policy reads.
// What is wired today: the trigger + a Compose action echoing the payload, so the
// URL exists and can be exercised end-to-end. Alert + ARM PATCH are README-only.
// =====================================================================================
targetScope = 'resourceGroup'

param name string
param location string
param tags object

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                schemaId: { type: 'string' }
                data: { type: 'object' }
              }
            }
          }
        }
      }
      actions: {
        EchoPayload: {
          type: 'Compose'
          inputs: {
            note: 'STUB, replace with PATCH on Microsoft.ApiManagement/service/backends/<id> to flip circuit breaker.'
            received: '@triggerBody()'
          }
          runAfter: {}
        }
        Response: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            body: '@outputs(\'EchoPayload\')'
          }
          runAfter: {
            EchoPayload: [ 'Succeeded' ]
          }
        }
      }
    }
  }
}

output id string = logicApp.id
output name string = logicApp.name
