#!/usr/bin/env bash
# Demo helper for the ad-tech alerting PoC. Run from the sandbox folder.
#   ./demo.sh help
set -euo pipefail
cd "$(dirname "$0")"
APP=http://localhost:8000
TENANT=$(grep -E '^TENANT_ID=' .env | cut -d= -f2)
MT=(docker compose run --rm mimirtool)

alerts() {
  # Uses Python inside the adtech-app container (no jq/python needed on the host)
  docker compose exec -T adtech-app python - "$TENANT" << 'PY'
import json, sys, urllib.request
req = urllib.request.Request("http://mimir:9009/prometheus/api/v1/alerts",
                             headers={"X-Scope-OrgID": sys.argv[1]})
data = json.load(urllib.request.urlopen(req, timeout=10))["data"]["alerts"]
rows = sorted((a["labels"].get("ruleset", "-"), a["labels"]["alertname"],
               a["labels"].get("exchange") or a["labels"].get("rule_group") or a["labels"].get("instance", ""),
               a["state"]) for a in data if "ruleset" in a["labels"])
print(f"{'RULESET':8} {'ALERT':28} {'EXCHANGE / TARGET':40} STATE")
print("-" * 88)
for r in rows:
    print(f"{r[0]:8} {r[1]:28} {r[2][:40]:40} {r[3]}")
if not rows:
    print("(no naive/fixed alerts pending or firing)")
for rs in ("naive", "fixed"):
    n = sum(1 for r in rows if r[0] == rs and r[3] == "firing")
    print(f"{rs} firing: {n}")
PY
}

ctl() { curl -s -H 'Accept: text/plain' "$APP/control?exchange=$1&mode=$2"; }

case "${1:-help}" in
  wait-ready)
    echo "Waiting for Mimir..."; until curl -s localhost:9009/ready | grep -q '^ready'; do sleep 5; done; echo "Mimir ready" ;;
  load-rules)
    "${MT[@]}" rules load /rules/adtech-phase1-naive.yaml --address=http://mimir:9009 --id="$TENANT"
    "${MT[@]}" rules load /rules/adtech-phase2-fixed.yaml --address=http://mimir:9009 --id="$TENANT"
    "${MT[@]}" rules list --address=http://mimir:9009 --id="$TENANT" ;;
  unit-tests)
    docker run --rm -v "$PWD/tests:/t" -w /t --entrypoint promtool prom/prometheus:v3.4.0 test rules adtech-rule-tests.yaml ;;
  status)
    curl -s "$APP/status"; echo ;;
  alerts)
    alerts ;;
  watch)
    while true; do clear; date; echo; alerts; sleep 15; done ;;
  set)            # ./demo.sh set exchange_b stopped
    ctl "$2" "$3" ;;
  control-case)   # Step 2: exchange_a idle
    ctl exchange_a idle ;;
  break3)         # Step 3: three silent failures at once
    ctl exchange_b stopped; ctl exchange_c zero_wins; ctl exchange_d timeout
    curl -s -H 'Accept: text/plain' "$APP/restart?lazy=true" ;;
  reset)
    for ex in exchange_a exchange_b exchange_c exchange_d; do ctl "$ex" normal; done
    curl -s -H 'Accept: text/plain' "$APP/restart?lazy=false" ;;
  app-down) docker compose stop adtech-app ;;
  app-up)   docker compose start adtech-app ;;
  pipeline-down) docker compose stop prometheus ;;
  pipeline-up)   docker compose start prometheus ;;
  limit-on)
    sed -i 's/max_fetched_series_per_query: .*/max_fetched_series_per_query: 80/' mimir/runtime.yaml
    grep max_fetched mimir/runtime.yaml ;;
  limit-off)
    sed -i 's/max_fetched_series_per_query: .*/max_fetched_series_per_query: 0/' mimir/runtime.yaml
    grep max_fetched mimir/runtime.yaml ;;
  *)
    cat << 'H'
Usage: ./demo.sh <command>
  wait-ready      wait until Mimir is ready
  load-rules      load naive + fixed rule sets into the Mimir ruler
  unit-tests      run promtool unit tests for the rules
  status          show exchange modes
  alerts          show pending/firing naive vs fixed alerts (one time)
  watch           refresh the alert table every 15s (Ctrl+C to stop)
  set EX MODE     set one exchange (modes: normal drop idle stopped zero_wins timeout slow)
  control-case    demo step 2: exchange_a idle (both rule sets fire)
  break3          demo step 3: stop b, zero wins on c, timeouts on d, lazy restart
  reset           all exchanges normal + eager restart
  app-down|app-up             demo step 4
  pipeline-down|pipeline-up   scenario S9
  limit-on|limit-off          demo step 5 (rule evaluation errors)
H
    ;;
esac
