# paste the contents of gm.sh here
# #!/usr/bin/env bash
# Shows Grafana-managed PoC rules and their alert states (NoData / Error / Alerting / Normal).
#   ./gm.sh          one time
#   ./gm.sh watch    refresh every 15s
# Set your Grafana admin password if you changed it:  export GRAFANA_PASS='yourpassword'
set -euo pipefail
cd "$(dirname "$0")"
show() {
  docker compose exec -T adtech-app python - "${GRAFANA_PASS:-admin1}" << 'PY'
import base64, json, sys, urllib.request, urllib.error
auth = base64.b64encode(f"admin:{sys.argv[1]}".encode()).decode()
req = urllib.request.Request("http://grafana:3000/api/prometheus/grafana/api/v1/rules",
                             headers={"Authorization": "Basic " + auth})
try:
    data = json.load(urllib.request.urlopen(req, timeout=10))
except urllib.error.HTTPError as e:
    sys.exit(f"Grafana API error {e.code}. Wrong password? export GRAFANA_PASS='...'")
print(f"{'GRAFANA-MANAGED RULE':42} {'HEALTH':8} {'INSTANCE':26} STATE")
print("-" * 95)
for g in data["data"]["groups"]:
    for r in g["rules"]:
        if not r["name"].startswith("GM "):
            continue
        alerts = r.get("alerts") or []
        if not alerts:
            print(f"{r['name'][:42]:42} {r.get('health',''):8} {'-':26} Normal (no active instances)")
        for a in alerts:
            l = a.get("labels", {})
            name = l.get("alertname", "")
            inst = name if name.startswith("Datasource") else (l.get("exchange") or l.get("campaign_id") or "-")
            print(f"{r['name'][:42]:42} {r.get('health',''):8} {inst[:26]:26} {a.get('state','')}")
PY
}
if [ "${1:-}" = "watch" ]; then
  while true; do clear; date; echo; show; sleep 15; done
else
  show
fi
