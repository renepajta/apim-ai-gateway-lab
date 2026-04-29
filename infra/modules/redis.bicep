// =====================================================================================
// Azure Cache for Redis (Basic, C0) — used by APIM as external cache for:
//   - session-stickiness map (responseId -> backendId, TTL 1h)
//   - azure-openai-semantic-cache-store / -lookup vector cache backing store
// 14-day demo: SecurityControl=Ignore exemption applies.
// =====================================================================================
targetScope = 'resourceGroup'

param name string
param location string
param tags object

resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'
    }
    publicNetworkAccess: 'Enabled'
  }
}

output id string = redis.id
output name string = redis.name
output hostName string = redis.properties.hostName
output sslPort int = redis.properties.sslPort
