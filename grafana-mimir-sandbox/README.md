# Grafana 13 + Mimir 3.x alerting sandbox

See **POC-ADTECH.md** for the ad-tech custom-metrics PoC plan.

PoC environment to compare **Grafana-managed** and **data source-managed (Mimir ruler)** alert rules,
especially No Data / Error handling.

## Components

| Service       | Purpose                                                    | URL                     |
|---------------|------------------------------------------------------------|-------------------------|
| grafana       | Grafana 13.x, Mimir + Mimir Alertmanager data sources      | http://localhost:3000   |
| mimir         | Monolithic Mimir 3.x with ruler + Alertmanager             | http://localhost:9009   |
| prometheus    | Scrapes targets and remote-writes to Mimir (tenant `sandbox`) | internal             |
| node-exporter | Demo target; stop it to simulate missing data              | internal                |

## 1. Match production first

Edit `.env` and set `GRAFANA_VERSION` / `MIMIR_VERSION` to the exact production versions.
In `mimir/mimir.yaml`, match production for:
- `multitenancy_enabled`
- `ingest_storage.enabled` (Kafka-based architecture vs classic)
- storage backend (filesystem here; S3/GCS/Azure in most production setups)
- any per-tenant limits that affect the ruler

## 2. Start

```bash
docker compose up -d
curl -s http://localhost:9009/ready          # wait for "ready"
```

Log in to Grafana at http://localhost:3000 (admin / admin).
Check **Connections > Data sources > Mimir > Save & test**.

## 3. Load data source-managed rules

Either through the CLI:

```bash
docker compose run --rm mimirtool rules load /rules/poc-rules.yaml \
  --address=http://mimir:9009 --id=sandbox
docker compose run --rm mimirtool rules list --address=http://mimir:9009 --id=sandbox
```

or in Grafana: **Alerting > Alert rules > New alert rule**, choose the **Mimir** data source
and select **Data source-managed**. Note that there are no No Data / Error options.

## 4. Create the Grafana-managed equivalent

**Alerting > Alert rules > New alert rule > Grafana-managed**, query
`node_cpu_seconds_total{job="node"}`, and under *Configure no data and error handling* set:
- Alert state if no data: `No Data` (or `Alerting`)
- Alert state if execution error or timeout: `Error` (or `Alerting`)

## 5. Test scenarios

| Scenario | How | Expected: Grafana-managed | Expected: data source-managed |
|---|---|---|---|
| No data | `docker compose stop node-exporter` | Rule goes to the configured No Data state | `NodeExporterDown` fires; `NodeMetricsMissing` fires after ~2–3 min |
| Query error | `docker compose stop mimir` | Rule goes to the configured Error state | Ruler is down too; nothing fires (that is why the ruler must be monitored from outside) |
| Recovery | `docker compose start node-exporter mimir` | Rule returns to Normal | Alerts resolve |

Active ruler alerts: `curl -H 'X-Scope-OrgID: sandbox' http://localhost:9009/prometheus/api/v1/alerts`

## Tear down

```bash
docker compose down -v
```
