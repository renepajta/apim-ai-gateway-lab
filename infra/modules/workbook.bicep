// =====================================================================================
// AI Gateway operational workbook
//   - Tile 1: tokens by tier (last 1h)           , customMetrics, dim subscription-id
//   - Tile 2: tokens by backend (last 1h)        , customMetrics, dim backend-id
//   - Tile 3: latency p50/p95 by backend         , APIM Gateway logs (LAW)
//   - Tile 4: CB trips count                     , customMetrics namespace=aigateway, name=apim.cb.trips
//   - Tile 5: cache hit ratio                    , APIM Gateway logs (cache hits vs total)
//
// Note: tiles 3 and 5 query AzureDiagnostics, which lives in the Log Analytics workspace,
// not in App Insights. Those two tiles use resourceType=microsoft.operationalinsights/workspaces
// + crossComponentResources to point at the LAW directly. The other tiles stay on the
// App Insights component so customMetrics resolves natively.
// =====================================================================================
targetScope = 'resourceGroup'

param name string
param displayName string
param location string
param tags object
@description('App Insights resource id (used as workbook source).')
param appInsightsId string
@description('Log Analytics workspace resource id (target for APIM gateway log tiles).')
param workspaceId string

var workbookJson = '''
{
  "version": "Notebook/1.0",
  "items": [
    {
      "type": 1,
      "content": {
        "json": "# AI Gateway, Operations\nLab demo. Last refreshed automatically by the workbook timeRange picker."
      },
      "name": "header"
    },
    {
      "type": 9,
      "content": {
        "version": "KqlParameterItem/1.0",
        "parameters": [
          {
            "id": "tr",
            "version": "KqlParameterItem/1.0",
            "name": "TimeRange",
            "type": 4,
            "isRequired": true,
            "value": { "durationMs": 3600000 },
            "typeSettings": {
              "selectableValues": [
                { "durationMs": 1800000 },
                { "durationMs": 3600000 },
                { "durationMs": 14400000 },
                { "durationMs": 86400000 }
              ]
            }
          }
        ]
      },
      "name": "params"
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "customMetrics\n| where customDimensions.namespace == 'aigateway'\n| where name in ('Total Tokens','Prompt Tokens','Completion Tokens')\n| summarize Tokens = sum(valueSum) by Tier = tostring(customDimensions['subscription-id']), bin(timestamp, 1m)\n| render timechart",
        "size": 0,
        "title": "Tile 1, tokens by tier (last 1h)",
        "timeContext": { "durationMs": 3600000 },
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.insights/components"
      },
      "name": "t1"
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "customMetrics\n| where customDimensions.namespace == 'aigateway'\n| where name == 'Total Tokens'\n| summarize Tokens = sum(valueSum) by Backend = tostring(customDimensions['backend-id']), bin(timestamp, 1m)\n| render timechart",
        "size": 0,
        "title": "Tile 2, tokens by backend (last 1h)",
        "timeContext": { "durationMs": 3600000 },
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.insights/components"
      },
      "name": "t2"
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "AzureDiagnostics\n| where ResourceProvider == 'MICROSOFT.APIMANAGEMENT' and Category == 'GatewayLogs'\n| where isnotempty(backendId_s)\n| summarize p50=percentile(backendTime_d,50), p95=percentile(backendTime_d,95) by BackendId=backendId_s, bin(TimeGenerated, 5m)\n| render timechart",
        "size": 0,
        "title": "Tile 3, APIM backend latency p50 / p95",
        "timeContext": { "durationMs": 3600000 },
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces",
        "crossComponentResources": [ "__WORKSPACE_ID__" ]
      },
      "name": "t3"
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "customMetrics\n| where customDimensions.namespace == 'aigateway'\n| where name == 'apim.cb.trips'\n| summarize Trips = sum(valueCount) by Backend = tostring(customDimensions['backend-id']), bin(timestamp, 5m)\n| render columnchart",
        "size": 0,
        "title": "Tile 4, circuit breaker trips",
        "timeContext": { "durationMs": 3600000 },
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.insights/components"
      },
      "name": "t4"
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "AzureDiagnostics\n| where ResourceProvider == 'MICROSOFT.APIMANAGEMENT' and Category == 'GatewayLogs'\n| where isnotempty(cache_s)\n| summarize Total = count(), Hits = countif(cache_s == 'hit') by bin(TimeGenerated, 5m)\n| extend HitRatio = todouble(Hits) / todouble(Total)\n| project TimeGenerated, HitRatio\n| render timechart",
        "size": 0,
        "title": "Tile 5, semantic cache hit ratio",
        "timeContext": { "durationMs": 3600000 },
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces",
        "crossComponentResources": [ "__WORKSPACE_ID__" ]
      },
      "name": "t5"
    }
  ],
  "fallbackResourceIds": [],
  "$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
}
'''

var workbookSerialized = replace(workbookJson, '__WORKSPACE_ID__', workspaceId)

resource wb 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, name)
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: displayName
    serializedData: workbookSerialized
    sourceId: appInsightsId
    category: 'workbook'
    version: '1.0'
  }
}

output id string = wb.id
output workbookId string = wb.name
