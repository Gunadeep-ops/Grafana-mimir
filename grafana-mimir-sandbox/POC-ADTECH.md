# PoC: Evaluating ad-tech custom-metric alert rules on the Mimir ruler

## 1. Objective

Show, with reproducible evidence, which of our current custom-metric alert rules (data source-managed,
evaluated by the Mimir ruler) **go silent** when data is missing or evaluation fails, and verify that the
hardened rule patterns **detect** those conditions, before rolling the patterns out to production.

## 2. Scope

| In scope | Out of scope (later) |
|---|---|
| Data source-managed rules on Mimir | AMP |
| Custom ad-tech metrics (per-exchange traffic, win rate, latency, campaigns) | Notification routing / receivers |
| No Data cases, rule evaluation errors, app/pipeline down | Load / scale testing of the ruler |

## 3. Setup

| Component | Purpose |
|---|---|
| `adtech-app` | Demo exporter: per-exchange `bid_requests_total`, `bid_responses_total`, `bids_won_total`, `bid_timeouts_total`, `bid_latency_seconds` (histogram), `impressions_total{campaign_id}`. Control page at **http://localhost:8000** |
| Prometheus | Scrapes `adtech-app` every 15s, remote-writes to Mimir tenant `sandbox` |
| Mimir 3.x | Ruler evaluates rules every 30s; `mimir/runtime.yaml` holds per-tenant limits (reloaded every 10s) |
| Grafana 13.x | Alerting UI + Explore for evidence |

### Rule sets (loaded side by side, compared with the `ruleset` label)

| File | Group | Contents |
|---|---|---|
| `rules/adtech-phase1-naive.yaml` | `adtech / naive` | Rules written the usual way: low bid requests, low win rate, high p99 latency, campaign not serving |
| `rules/adtech-phase2-fixed.yaml` | `adtech / fixed` | Same alerts hardened + `ExchangeNoTraffic`, `ExchangeLowResponseRate` |
| | `adtech / platform-health` | `AdtechAppDown`, `AdtechAppMetricsMissing`, `RuleEvaluationFailures`, `RuleGroupMissedIterations` |

### Patterns under test

| # | Failure pattern | Naive behaviour | Fix in phase 2 |
|---|---|---|---|
| P1 | One exchange's series disappear | Per-exchange alerts return nothing → silent | `ExchangeNoTraffic` (`last_over_time ... unless rate > 0`) |
| P2/P4 | Wins counter missing (lazy counters after restart) | Ratio returns nothing → silent | `or ... * 0` in win rate; app should pre-initialise counters |
| P3 | Requests arrive, no responses | Latency and win rate become NaN → silent | `ExchangeLowResponseRate` |
| P6 | High-cardinality rule hits a query limit | Rule fails → silent (rule health = error) | `RuleEvaluationFailures` |
| P7 | App down / pipeline down | Everything silent | `AdtechAppDown`, `AdtechAppMetricsMissing` |

## 4. Preparation (Windows, PowerShell, from the sandbox folder)

```powershell
docker compose up -d --build
curl.exe http://localhost:9009/ready
docker compose run --rm mimirtool rules load /rules/adtech-phase1-naive.yaml --address=http://mimir:9009 --id=sandbox
docker compose run --rm mimirtool rules load /rules/adtech-phase2-fixed.yaml --address=http://mimir:9009 --id=sandbox
docker compose run --rm mimirtool rules list --address=http://mimir:9009 --id=sandbox
```

Optional, no Docker stack needed: run the rule unit tests (they encode the expected results below):

```powershell
docker run --rm -v ${PWD}/tests:/t -w /t --entrypoint promtool prom/prometheus:v3.4.0 test rules adtech-rule-tests.yaml
```

### Evidence view (keep open during all tests)

Grafana → **Explore** → Mimir, range *Last 30 minutes*, query:

```promql
ALERTS{alertstate="firing", ruleset=~"naive|fixed"}
```

Also keep **Alerting → Alert rules** open, filtered on namespace `adtech`.

### Rules for running the tests

- Start every scenario from a clean state: all exchanges `normal`, counters **eager**, no `ruleset` alerts firing.
- Record the start time, wait **5 minutes**, record which alerts fired and when.
- Revert, then wait until all alerts clear (about 3–5 min) before the next scenario.
- Controls can be clicked on http://localhost:8000 or sent with `curl.exe`, e.g.
  `curl.exe "http://localhost:8000/control?exchange=exchange_b&mode=stopped"`

## 5. Test scenarios and expected results

Scenarios marked **control** are cases the naive rules already handle; they prove the setup works and
that the fixed rules don't break anything.

| ID | Scenario | Action | Expected: naive | Expected: fixed |
|---|---|---|---|---|
| S0 | Baseline | Everything normal for 5 min | No alerts | No alerts |
| S1 | Exchange disappears (P1) | `exchange_b` → **stopped** | **Silent** | `ExchangeNoTraffic{exchange_b}` |
| S2 | Exchange flat (control) | `exchange_b` → **idle** | `ExchangeLowBidRequests{exchange_b}` | `ExchangeLowBidRequests` + `ExchangeNoTraffic` |
| S3 | Traffic drop (control) | `exchange_b` → **drop** | `ExchangeLowBidRequests{exchange_b}` | `ExchangeLowBidRequests{exchange_b}` |
| S4a | Zero wins, eager counters (control) | `exchange_c` → **zero_wins** | `ExchangeLowWinRate{exchange_c}` | `ExchangeLowWinRate{exchange_c}` |
| S4b | Zero wins, lazy counters (P2/P4) | `exchange_c` → **zero_wins**, then **Restart pod (lazy counters)** | **Silent** | `ExchangeLowWinRate{exchange_c}` |
| S5 | All requests time out (P3) | `exchange_d` → **timeout** | **Silent** (win rate and latency are NaN) | `ExchangeLowResponseRate{exchange_d}` |
| S6 | Slow responses (control) | `exchange_d` → **slow** | `ExchangeHighLatencyP99{exchange_d}` | `ExchangeHighLatencyP99{exchange_d}` |
| S7 | Rule evaluation error (P6) | Edit `mimir/runtime.yaml`: `max_fetched_series_per_query: 80`, save | **Silent**; `CampaignLowImpressions` shows an error in Alerting | `RuleEvaluationFailures` for the `naive` group |
| S8 | App down (P7) | `docker compose stop adtech-app` | **Silent** | `AdtechAppDown` + `ExchangeNoTraffic` for all exchanges |
| S9 | Pipeline down (P7) | `docker compose stop prometheus` | **Silent** | `AdtechAppMetricsMissing` (+ `ExchangeNoTraffic`); `AdtechAppDown` stays silent |

Reverting:
- S1–S6: set the exchange back to **normal**; after S4b also click **Restart pod (eager init)**.
- S7: set `max_fetched_series_per_query: 0` and save.
- S8/S9: `docker compose start adtech-app` / `docker compose start prometheus`.

Timing notes:
- Most alerts fire 2–4 minutes after the action (2m rate window + 1m `for` + 30s evaluation).
- S1: `ExchangeNoTraffic` keeps firing only while the exchange is still inside the 30m lookback window;
  after that it resolves on its own. Note this as a finding; production needs a longer window (1h–24h).
- S7: rule failures show as soon as the limit reloads (about 10–40s). If your Mimir version does not fail
  on this limit, try `max_fetched_chunks_per_query: 50` instead. Grafana Explore queries over many
  series may also fail while the limit is set.
- S9: after Prometheus restarts it replays buffered data; brief extra alerts are expected.

## 6. Optional comparison: Grafana-managed rule

Create a Grafana-managed version of `ExchangeLowWinRate` (same query, No data = Alerting) and run S1.
Expect it **not** to raise No Data either: No Data only applies when the *whole* query is empty. A single
exchange whose series disappear is treated as a missing series and resolved. Per-label disappearance
needs the P1 pattern regardless of where the rule runs.

## 7. Results (fill in)

| ID | Start time | Naive fired? | Fixed fired? | Time to detect | Matches expected? | Notes |
|---|---|---|---|---|---|---|
| S0 | | | | | | |
| S1 | | | | | | |
| S2 | | | | | | |
| S3 | | | | | | |
| S4a | | | | | | |
| S4b | | | | | | |
| S5 | | | | | | |
| S6 | | | | | | |
| S7 | | | | | | |
| S8 | | | | | | |
| S9 | | | | | | |

## 8. Success criteria

1. Every **Silent** case in the naive column is reproduced (proves the gap exists).
2. Every case is detected by the fixed rule set within 5 minutes.
3. Control scenarios (S2, S3, S4a, S6) fire in both rule sets (no regression).
4. S0 produces no alerts from either rule set (no false positives).

## 9. Moving to production

1. Inventory current rules and map each to P1–P7.
2. Rewrite using the phase 2 patterns with real metric/label names.
3. Choose lookback windows: `ExchangeNoTraffic` 1h–24h; use `offset 7d` comparisons for traffic drops with daily patterns.
4. Ask the app team to pre-initialise counters for known label values (removes P2/P4 at the source).
5. Add `AppDown` / `MetricsMissing` per job, `RuleEvaluationFailures`, and a Watchdog to an external heartbeat.
6. Add promtool unit tests (like `tests/adtech-rule-tests.yaml`) to CI for every rule change.
