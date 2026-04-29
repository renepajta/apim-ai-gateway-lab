// Multi-condition circuit breaker for an APIM backend pool member.
// Today the platform team trips on 429 only. We add 5XX, gateway timeouts, and 429-with-Retry-After.
// Rules are additive: ANY rule reaching its failureThreshold trips the breaker.

resource backendSwc 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: 'aoai-swc'
  properties: {
    url: 'https://${aoaiSwc.name}.openai.azure.com/openai'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        // Rule 1: server-side errors -> trip after 3 in 60s for 30s
        {
          name: 'serverErrors'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [ { min: 500, max: 599 } ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: false
        }
        // Rule 2: gateway/upstream timeouts (504 + 408) -> trip after 2 in 60s for 30s
        // This is the rule the platform team missed in Jan/Feb: AOAI didn't 5XX, it slow-failed
        // and APIM produced 504s. With this rule, a slow-fail trips the breaker.
        {
          name: 'timeouts'
          failureCondition: {
            count: 2
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 504, max: 504 }
              { min: 408, max: 408 }
            ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: false
        }
        // Rule 3: 429 with Retry-After -> honour the backend's hint, do not hammer.
        // acceptRetryAfter=true: APIM will keep the breaker open until Retry-After expires.
        {
          name: 'rateLimitsWithBackoff'
          failureCondition: {
            count: 1
            interval: 'PT1M'
            statusCodeRanges: [ { min: 429, max: 429 } ]
          }
          tripDuration: 'PT10S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}
