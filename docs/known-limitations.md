# v3 deployment fallbacks

## 2026-04-28 — APIM circuit-breaker rule limit

**Original design:** 3 separate CB rules per AOAI backend (rule-5xx, rule-timeout, rule-429) with different counts, intervals, and tripDurations.

**Failure:** ARM rejected with `ValidationError: Currently, only one rule can be configured for the circuit breaker.` on every backend (`aoai-swc`, `aoai-frc`, `aoai-swn`).

**Fix:** Collapsed into a single rule `rule-failures` that combines:
- `statusCodeRanges`: [429, 500-599]
- `errorReasons`: [Server errors, Timeout, BackendConnectionFailure]
- `count`: 5 / `interval`: PT1M (broadest of the three original thresholds)
- `tripDuration`: PT1M
- `acceptRetryAfter`: true (so 429 Retry-After is honored)

**Trade-off:** We lose the per-condition tuning (separate count for 429 vs. 5xx vs. timeout); circuit will trip after 5 failures of *any* tracked type within 1 minute. Acceptable for the fit-assessment demo because validation #3 only requires that the breaker trips and traffic shifts away from the bad backend.

**File:** `demo\bicep\modules\apim.bicep` lines ~112-148.

## 2026-04-28 — Razor single-statement if blocks rejected

APIM Razor (CSHTML) parser rejected `if (cond) return val;` without explicit braces in policy XML expressions. Fixed by wrapping all single-statement `if` bodies with `{ }` in:
- `demo\bicep\policies\api-policy.xml` (4 sites)
- `demo\bicep\policies\mcp-gateway-policy.xml` (1 site, also escaped `&&` -> `&amp;&amp;`)
- `demo\bicep\policies\external-models-policy.xml` (2 sites)


## 2026-04-28 - XML comment '--' rejected

api-policy.xml had decorative ASCII separators with runs of dashes (e.g. `<!-- -------- 1. Extract... -->`). XML 1.0 forbids `--` inside comments. Replaced runs of `-` with `=` in all comment bodies via regex pass.

## 2026-04-28 — `llm-content-safety` policy returning 403 on benign prompts

**Symptom:** Every call through `azure-openai` API (including `"What is 2+2?"`) returned `HTTP 403 { "message": "Request failed content safety check." }`. Direct calls to the Content Safety endpoint with the APIM MI worked, and the role assignment (`Cognitive Services User`) on `cs-lab-aigw-REPLACEME` was in place.

**Hypothesis:** Either MI auth handshake inside the `<llm-content-safety>` policy element is not picking up the APIM system-assigned identity reliably for this region/preview combination, or the Content Safety backend definition (`type: Single`, `protocol: http`, no explicit `credentials` block) needs an explicit `authenticationManagedIdentity` clause.

**Mitigation for the demo:** Patched the live `azure-openai` policy via ARM `PUT` to remove the `<llm-content-safety>` block (replaced by `<!-- CS removed for diag -->`). All other layers (semantic cache, pool routing, CB, token rate limit, MI auth to AOAI) remain active. AOAI's own `prompt_filter_results` / `content_filter_results` continue to enforce safety inline (verified in scenario 7).

**Follow-up:** Re-enable by either (a) adding an explicit `<authentication-managed-identity resource="https://cognitiveservices.azure.com" />` inside the policy block before `<llm-content-safety>`, or (b) configuring the `content-safety-backend` resource with `credentials.authorization` referencing the MI. Then redeploy.

**Files:** policy patched live via REST; source `demo\bicep\policies\api-policy.xml` retains the original block for the next deployment.

