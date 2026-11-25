#!/usr/bin/env bash
# Creates (or updates) the Grafana-managed PoC rules through the Grafana API with
# X-Disable-Provenance, so they are EDITABLE in the Grafana UI.
#   export GRAFANA_PASS='your-grafana-admin-password'
#   ./gm-editable.sh
set -euo pipefail
cd "$(dirname "$0")"
docker compose exec -T adtech-app python - "${GRAFANA_PASS:-admin}" << 'PY'
import base64, json, sys, urllib.request, urllib.error

BASE = "http://grafana:3000"
AUTH = "Basic " + base64.b64encode(f"admin:{sys.argv[1]}".encode()).decode()
EDITABLE = {"X-Disable-Provenance": "true"}
FOLDER, GROUP = "AdTech PoC", "adtech-grafana-managed"

def call(method, path, body=None, extra=None):
    headers = {"Authorization": AUTH, "Content-Type": "application/json"}
    headers.update(extra or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def query(expr):
    return {"refId": "A", "relativeTimeRange": {"from": 600, "to": 0}, "datasourceUid": "mimir",
            "model": {"refId": "A", "expr": expr, "instant": True, "range": False,
                      "datasource": {"type": "prometheus", "uid": "mimir"},
                      "intervalMs": 1000, "maxDataPoints": 43200}}

def threshold(op, value):
    return {"refId": "C", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
            "model": {"refId": "C", "type": "threshold", "expression": "A",
                      "datasource": {"type": "__expr__", "uid": "__expr__"},
                      "conditions": [{"evaluator": {"type": op, "params": [value]}}]}}

RULES = [
    ("gm-exchange-low-bids", "GM ExchangeLowBidRequests",
     "sum by (exchange) (rate(bid_requests_total[2m]))", "lt", 10,
     "Bid requests from {{ $labels.exchange }} below 10/s"),
    ("gm-exchange-b-bids", "GM exchange_b BidRequests (single series)",
     'sum(rate(bid_requests_total{exchange="exchange_b"}[2m]))', "lt", 10,
     "Bid requests from exchange_b below 10/s"),
    ("gm-exchange-low-winrate", "GM ExchangeLowWinRate",
     "sum by (exchange) (rate(bids_won_total[2m])) / sum by (exchange) (rate(bid_responses_total[2m]))", "lt", 0.05,
     "Win rate on {{ $labels.exchange }} below 5%"),
    ("gm-campaign-low-impressions", "GM CampaignLowImpressions",
     "sum by (campaign_id) (rate(impressions_total[2m]))", "lt", 0.01,
     "Campaign {{ $labels.campaign_id }} is not serving"),
]

# 1. Folder
status, folders = call("GET", "/api/folders?limit=1000")
if status != 200:
    sys.exit(f"Cannot reach Grafana API ({status}): {folders}\nWrong password? export GRAFANA_PASS='...'")
folder_uid = next((f["uid"] for f in folders if f["title"] == FOLDER), None)
if not folder_uid:
    status, f = call("POST", "/api/folders", {"title": FOLDER})
    if status not in (200, 201):
        sys.exit(f"Cannot create folder ({status}): {f}")
    folder_uid = f["uid"]
print(f"Folder '{FOLDER}' uid={folder_uid}")

# 2. Rules (create or update, always editable)
for uid, title, expr, op, value, summary in RULES:
    body = {"uid": uid, "title": title, "orgID": 1, "folderUID": folder_uid, "ruleGroup": GROUP,
            "condition": "C", "data": [query(expr), threshold(op, value)],
            "noDataState": "NoData", "execErrState": "Error", "for": "1m",
            "labels": {"ruleset": "grafana", "severity": "warning"},
            "annotations": {"summary": summary}, "isPaused": False}
    status, existing = call("GET", f"/api/v1/provisioning/alert-rules/{uid}")
    if status == 200:
        if isinstance(existing, dict) and existing.get("provenance") == "file":
            sys.exit(f"'{title}' is still file-provisioned (read-only). Restart Grafana first:\n"
                     "  docker compose restart grafana")
        status, resp = call("PUT", f"/api/v1/provisioning/alert-rules/{uid}", body, EDITABLE)
        action = "updated"
    else:
        status, resp = call("POST", "/api/v1/provisioning/alert-rules", body, EDITABLE)
        action = "created"
    if status not in (200, 201):
        sys.exit(f"Failed on '{title}' ({status}): {resp}")
    print(f"  {action}: {title}")

# 3. Group evaluation interval = 30s
path = f"/api/v1/provisioning/folder/{folder_uid}/rule-groups/{GROUP}"
status, group = call("GET", path)
if status == 200 and isinstance(group, dict):
    group["interval"] = 30
    status, resp = call("PUT", path, group, EDITABLE)
    print("Group interval set to 30s" if status == 200 else f"Could not set interval ({status}): {resp}")

print("\nDone. In Grafana: Alerting > Alert rules > folder 'AdTech PoC' - the rules can now be edited.")
PY
