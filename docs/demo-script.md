# # Demo talk track: APIM AI Gateway for a multi-tenant GenAI platform (25 min)

**Audience:** your GenAI platform team, platform-provider mindset (multi-tenant, multi-region, governance).
**Setting:** shared screen with two terminals (1 = `test.py` runner, 2 = `az` cli for the CB break) + Azure portal tabs (APIM Backends, APIM APIs, App Insights workbook).
**Total budget:** 25 min · 12 sections · ordered: resiliency first, platform features second, teaser extras last.

---

## 0. Pre-flight checklist (do BEFORE the meeting starts)

1. `cd C:\repos\apim-ai-gateway-lab`
2. Confirm `.demo.env` is current, open it and read out the keys you care about:
   - `GATEWAY_URL` · `KEY_FAST` · `KEY_STANDARD` · `KEY_BATCH`
   - `EXTERNAL_GATEWAY_URL` + `EXTERNAL_GATEWAY_KEY`
   - `MCP_GATEWAY_URL` + `MCP_GATEWAY_KEY`
3. Pre-warm every tier (kills cold-start surprise on the live demo):
   ```powershell
   .\test.ps1 -Scenario baseline
   .\test.ps1 -Scenario timeout-batch     # warms KEY_BATCH path
   .\test.ps1 -Scenario sticky             # warms /openai/responses + Redis path
   ```
4. Open three browser tabs:
   - APIM → **APIs** → `azure-openai` → **Policies** (read-only view; have it ready)
   - APIM → **Backends** → list view (you'll point at `aoai-swc`, `aoai-swn`, `aoai-frc`)
   - App Insights `appi-aigw-lab` → **Workbooks** → "AI Gateway, per-tenant tokens"
5. Open a **second terminal** for the CB break (Section 2). Have these two commands in your clipboard, ready to paste:
   ```powershell
   # --- BREAK aoai-swn (run in shell #2 right before Section 2) ---
   az rest --method PATCH `
     --uri "https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-lab/providers/Microsoft.ApiManagement/service/apim-aigw-lab/backends/aoai-swn?api-version=2024-05-01" `
     --body '{\"properties\":{\"url\":\"https://invalid.example.invalid/openai\",\"protocol\":\"http\"}}'

   # --- RESTORE aoai-swn (run immediately after Section 2 wraps) ---
   az rest --method PATCH `
     --uri "https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-lab/providers/Microsoft.ApiManagement/service/apim-aigw-lab/backends/aoai-swn?api-version=2024-05-01" `
     --body '{\"properties\":{\"url\":\"https://aoai-aigw-swn.openai.azure.com/openai\",\"protocol\":\"http\"}}'
   ```
6. (Optional, only if you'll demo §7 sticky and want to peek at Redis directly):
   ```powershell
   az redis list-keys -g rg-aigw-lab -n redis-aigw --query primaryKey -o tsv
   # then with redis-cli on the host:  redis-cli -h <redis-host> -a <key> --tls KEYS 'rsp:*'
   ```
7. Last sanity check 60 s before kickoff: `.\test.ps1 -Scenario baseline` → must return `HTTP=200`. If it 401s, the APIM SubscriptionKey rotated, pull from `.demo.env` again.

---

## 1. 0:00 → 1:00, Baseline (1 min)

**What you say:**
> "Same shape you already build with your custom proxy: caller posts to a single APIM endpoint, gets an OpenAI-compatible response. Zero AOAI keys on the client. Both AOAI accounts have `disableLocalAuth=true`, APIM calls them with managed identity. We're going to peel the onion from here."

**What you click / run:**
```powershell
.\test.ps1 -Scenario baseline
```

**What you see:**
- `HTTP=200  t≈0.9s`
- Header `x-aigw-backend: aoai-pool` (which pool answered)

**Why this matters:**
This is the stable contract every tenant calls. From here, every subsequent feature is a *policy*, not a redeployment.

---

## 2. 1:00 → 5:00, Multi-condition CB + automatic failover (4 min)

**What you say:**
> "Your custom proxy today only opens its breaker on 429. That misses 5xx, timeouts, and connection failures, exactly the failure modes that hurt you in Sweden. APIM's circuit breaker takes a single rule per backend that combines `statusCodeRanges`, `errorReasons`, and a count/interval window. I'll break one of our three priority-1 backends right now and you'll watch traffic shift."

**What you click / run:**

In **shell #2**, paste the BREAK command from the pre-flight (corrupts `aoai-swn`'s URL).

In **shell #1**:
```powershell
.\test.ps1 -Scenario cb
# press ENTER when prompted; script fires 6 calls
```

While it runs, point at APIM portal → **Backends** → `aoai-swn` → status surface; weight=30.

**What you see:**
- 3 calls return `200` from `aoai-swc`/`aoai-frc`, 3 calls return `500` from `aoai-swn` while CB is still counting.
- After the breaker trips, no more `500`s, all green.
- (Demo budget) `count=5/PT1M, tripDuration=PT1M, acceptRetryAfter=true`.

**Why this matters:**
Replaces the 429-only client-side breaker with a *server-side, deterministic, multi-condition* breaker that every tenant inherits, no SDK update across the fleet.

**Caveat to verbalize (PARTIAL):**
> "You'll see 3-out-of-6 fail before the breaker trips, that's the count=5/1m threshold doing its job, not a defect. In production we'd run a *separate* probe path (Section 4) so we don't burn customer requests as breaker fuel. We also lost per-condition tuning when ARM forced one rule per backend; if you need separate budgets for 5xx vs timeout vs 429, that's a roadmap ask we'd flag."

After this section: in **shell #2**, paste the RESTORE command.

---

## 3. 5:00 → 8:00, Per-tier timeout (3 min)

**What you say:**
> "Today you have one 10-minute global timeout for every caller, because your interactive UI and your nightly batch job share the same proxy. We split the timeout *at the gateway* by APIM Product. Three keys: `tier-fast` (30s), `tier-standard` (120s), `tier-batch` (600s). The Product-scoped `forward-request timeout=...` wins via `<base/>` in the API policy."

**What you click / run:**
```powershell
.\test.ps1 -Scenario timeout-fast       # KEY_FAST, 4k essay
.\test.ps1 -Scenario timeout-batch      # KEY_BATCH, same prompt
```

**What you see:**
- `timeout-fast` → `t≈30s, HTTP 500/504`, gateway cut it at the tier-fast SLA.
- `timeout-batch` → `t≈37s, HTTP 200`, ~1.8k tokens.

**Why this matters:**
The same prompt, the same backend, the same model, different SLA contract per tenant key. That's per-tier governance without touching the model layer. Maps cleanly onto your tenant tiers (free/pro/enterprise) or your workload tiers (the assistant UI, agentic-batch, interactive-UI).

---

## 4. 8:00 → 10:00, Client-cancel propagation (2 min)

**What you say:**
> "When your end user closes the browser tab, today your proxy keeps the AOAI connection open until the model finishes generating. That's PTU you've already paid for, burned. APIM forwards HTTP/2 RST upstream, the AOAI account releases the slot the moment we get the cancel."

**What you click / run:**
```powershell
.\test.ps1 -Scenario cancel
```

**What you see:**
- `HTTP=200  streaming...`
- `t≈1.0s, status=200, partial-bytes=~110`
- (Console message) `client-side abort observed: ChunkedEncodingError`

**Why this matters:**
Direct PTU/quota-burn fix. On a 4 k-token completion that the user abandoned at 1 s, you reclaim ~95 % of the slot for the next caller in your tenant.

---

## 5. 10:00 → 13:00, Active health probe + gray-failure narrative (3 min)

**What you say:**
> "Here's the Sweden Central January incident in one slide. Latency went from p95=1.5 s to 8 s for ~40 minutes, no errors, no 429s. Your reactive breaker, and a status-code-only breaker, won't see it. We deploy a Logic App that probes every AOAI backend on a 30-second cadence with `max_tokens=1` and writes the latency to App Insights. An alert on p95 > 5s flips `backend.isReachable=false` via the APIM REST API, and the pool stops sending traffic. No customer request was harmed in the demotion."

**What you click / run:**
- Switch to APIM portal → **Backends** → highlight `aoai-swc` row, point at the `Reachability` column.
- Switch to App Insights → Workbook → the latency-probe chart for the last 24h.
- (No live break here, the narrative anchored on the January incident is enough.)

**What you see:**
- Three rows: `aoai-swc` (reachable), `aoai-swn` (reachable), `aoai-frc` (reachable).
- Probe latency chart with three coloured lines.

**Why this matters:**
This is the *exact* capability that would have shielded your fleet from the January gray-failure. It's also the thing that lets you run *active-active* across regions safely, without it, you can only run active-passive.

**Caveat to verbalize:**
> "The Logic App is deployed but its frequency in this demo is 5 minutes (cost), not 30 seconds. Frequency is config, not architecture."

---

## 6. 13:00 → 15:00, Priority + weighted LB across 3 PAYG regions (2 min)

**What you say:**
> "Pool has three backends: Sweden Central weight 70, Switzerland North weight 30, both at priority 1. France Central is priority 2, only used when both P1 breakers are tripped. Same model, same API version on all three; only the URL and the MI changes."

**What you click / run:**
- APIM portal → **Backends** → show pool definition; point at `priority: 1, weight: 70` / `priority: 1, weight: 30` / `priority: 2, weight: 100`.
- Then App Insights → Workbook → "tokens by backend" tile (last 1 h) → expect ~70/30 split.

**What you see:**
A donut chart: SWC ~70 %, SWN ~30 %, FRC ~0 % (priority-2 idle).

**Why this matters:**
Weight is your *traffic-shaping dial*, you can drain a region for maintenance, A/B a model upgrade in one region only, or rebalance after PTU expansion. All without redeploying client code.

---

## 7. 15:00 → 18:00, Session stickiness for the Responses API (3 min)

**What you say:**
> "Once you adopt the Responses API, and you will, because tool-use and structured outputs are simpler, your proxy goes stateful. The model expects you to send `previous_response_id` to resume. That id only resolves on the AOAI account that issued it. So 'load balancing' meets 'stateful API' and *something* has to remember which backend served the original. We solved that with Redis keyed by `rsp:<id>` with TTL 1h."

**What you click / run:**
```powershell
.\test.ps1 -Scenario sticky
```

**What you see:**
- `[5a create] HTTP=200 ... x-aigw-backend=aoai-pool x-aigw-cached=stored`
- `[5b resume] HTTP=410` (graceful 410 `session_expired`)
- `[5c bogus]  HTTP=410` (graceful 410, same shape, caller-friendly)

**Why this matters:**
You can keep your weighted load balancer *and* honour the stateful contract of the Responses API, without pinning customers to a region. The stickiness is per-conversation, not per-tenant.

**Caveat to verbalize (PARTIAL, call it out clearly):**
> "Important: this lab uses Redis Basic SKU, which has no persistence and a single primary. The store path executes, you can see `x-aigw-cached: stored` on call #5a, but on call #5b the lookup misses and we land on a graceful 410 with the right error shape. **Production = Standard SKU with replication and AOF persistence.** That single SKU change closes the gap; the policy and the architecture are the same."

> Microsoft Learn ref: Azure Cache for Redis, service tiers and persistence (Standard / Premium → AOF + replication; Basic = single-node, no SLA, no persistence).

---

## 8. 18:00 → 20:00, Semantic cache (2 min)

**What you say:**
> "Same prompt twice, two seconds apart. The second call doesn't reach AOAI, APIM hashes the embedding, compares against Redis with `score-threshold=0.5`, returns the cached completion. For your tenant prompts, the hit rate goes up the more identical FAQ-style prompts they send."

**What you click / run:**
```powershell
.\test.ps1 -Scenario cache
```

**What you see:**
- `call#1 (miss): HTTP=200 t≈2.5s`
- `call#2 (hit) : HTTP=200 t≈0.9s`
- `Δ latency: ~64%`

**Why this matters:**
For repetitive tenant prompts (the assistant UI canned questions, agent skill probes, structured-output retries), this is a *direct token-bill saver*. The token-emit metric drops to zero on cache hit, chargeback shows the right thing.

---

## 9. 20:00 → 22:00, Content Safety policy (2 min)

**What you say:**
> "Centralised PII / harmful-content enforcement before the request leaves your perimeter. APIM calls Azure AI Content Safety with the system-assigned MI (`Cognitive Services User` role on the CS account), and on a category match returns 403 to the caller. The model never sees the prompt. Same for prompt-shield."

**What you click / run:**
```powershell
.\test.ps1 -Scenario safety
```

**What you see:**
- `HTTP=403  t<1s`
- Body: `{"statusCode":403,"message":"Request failed content safety check."}`

**Why this matters:**
One enforcement point for your whole platform fleet. You don't rely on every model client to call Content Safety correctly, and you don't trust the model's own moderation as the only line.

---

## 10. 22:00 → 24:00, Per-tenant token attribution workbook (2 min)

**What you say:**
> "`azure-openai-emit-token-metric` writes prompt/completion/total tokens with custom dimensions to App Insights, and we add `tier`, `subscriptionId`, `backend`, `cb.trips`, `cache.hit` on top. Workbook turns that into a per-tenant bill. This is the one piece your custom proxy can't easily replicate."

**What you click / run:**
- App Insights → Workbooks → **AI Gateway, per-tenant tokens** → last 1h.
- Show two tiles: "tokens by tier" and "tokens by backend".

**What you see:**
A bar chart: `tier-fast` ~900 tokens, `tier-batch` ~3 200 tokens, `tier-standard` ~600 tokens; backend split mirroring the 70/30 of Section 6.

**Why this matters:**
Direct chargeback dimension. Per tenant, per tier, per backend, per minute, exportable to your billing pipeline.

---

## 11. 24:00 → 25:00, External models + MCP teaser (1 min)

**What you say:**
> "Two future-proofing levers. (1) `/external/v1`, an OpenAI-compatible passthrough to api.openai.com, with cross-provider failover to AOAI on 5xx or auth errors. (2) `/mcp`, same APIM, MCP-shaped contract, propagating a trace header on every error. Today it's a passthrough; native MCP shapes land in APIM later this year."

**What you click / run:**
```powershell
.\test.ps1 -Scenario external
.\test.ps1 -Scenario mcp
```

**What you see:**
- external: `HTTP=200`, header `x-fallback-used: aoai-gpt-4o` (origin OpenAI returned 401 → APIM swung to AOAI gpt-4o → success).
- mcp: `HTTP=500` (placeholder backend) **with** header `x-apim-mcp-trace-id: <guid>`.

**Why this matters:**
Same gateway, same governance, every model, Anthropic / Google / OpenAI direct / open-source via inference servers / MCP. You don't have to pick today; the fan-in is uniform.

---

## 12. Wrap (verbal, no clicks)

> "Three takeaways. (1) Resiliency moves from client SDK to gateway policy, multi-condition CB + active probe + weighted pool. (2) Per-tenant governance, timeout, quota, content safety, attribution, lives one layer below the model and above your callers. (3) Same gateway scales to MCP and to non-AOAI providers without changing the tenant contract.
>
> What we'd refine for production at platform scale: APIM Premium for AZ + multi-region active-active gateway, Standard Redis with AOF, JWT validation against your IdP, and Defender for APIs on top. Happy to walk through that as a follow-up."

---

## Recovery playbook (operator only)

| Symptom | Cause | Fix on the spot |
|---|---|---|
| `HTTP 401` on Section 1 baseline | Subscription key rotated since `.demo.env` was written | Re-read `KEY_FAST` from APIM portal → Subscriptions; or `az apim subscription show -g $RG -n $APIM --sid <subId> --query primaryKey` |
| Section 2 (CB), all 6 calls return 200 | The break PATCH didn't land (typo in URL or RG) | Confirm `az rest` printed an updated body with `https://invalid.example.invalid/openai`. Re-run the BREAK command, then `.\test.ps1 -Scenario cb` again |
| Section 2, every call 500, none green | `aoai-swc` broken accidentally; you patched the wrong backend | RESTORE all three: SWN, SWC, FRC URLs (the SWC URL is `https://aoai-aigw-swc.openai.azure.com/openai`) |
| Section 3 timeout-fast finished in 8 s with 200 | The CB from Section 2 is still tripped; traffic went straight to FRC | Wait 60 s for `tripDuration: PT1M` to expire, re-run; or describe and skip |
| Section 4 cancel hangs > 10 s | `requests` install is missing `urllib3` HTTP/2 path; falls back to HTTP/1 | Don't fight it, let it timeout; the partial-bytes line is still the proof point |
| Section 7 sticky 5a returns 404 not 200 | `aoai-openapi.json` redeployed without `/responses` ops | Skip 5a/5b live; show the policy XML in APIM portal and verbalize 5c expectation |
| Section 8 cache call#2 not faster than call#1 | Redis Basic flushed (rare) or `score-threshold=0.5` over-tight on this prompt | Re-run with a longer prompt; or skip to Section 9 |
| APIM "cold" on first request | First call after >15 min idle takes 4-6 s | Explicit pre-warm: `.\test.ps1 -Scenario baseline` 30 s before kickoff |
| `/mcp/healthz` returns 404 instead of 500 | MCP_GATEWAY_URL has a trailing slash | Check `.demo.env`, must be `…/mcp` exactly |
| You ran out of time (only made it to Section 9) | Drop §10 (workbook), refer to App Insights screenshot in slides | The §11 teaser is one minute; never skip it, it sets up the follow-up workshop |

## Cleanup (after the call)

1. Restore `aoai-swn` URL (the RESTORE command in pre-flight), even if you're sure you did, run it once more.
2. `.\scripts\teardown.ps1 -Yes`, tear down the RG when finished. APIM Premium v2 is ~$5/day idle.
3. Confirm `az group show -n rg-aigw-lab` returns 404.
