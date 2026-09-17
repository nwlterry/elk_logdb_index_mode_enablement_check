# elk_logdb_index_mode_enablement_check

Tools and a phased plan to **measure** Elasticsearch LogsDB (`index.mode: logsdb`) vs standard mode, then **enable it one data stream at a time**.

Built for a self-managed Elastic Stack **8.18.x** cluster that will roll to **9.x**. Existing `logs-*-*` streams are **not** flipped automatically on upgrade.

## What LogsDB is

One index setting:

```json
"index.mode": "logsdb"
```

Elasticsearch then applies index sort (`host.name`, `@timestamp` by default), `best_compression` (ZSTD + numeric codecs), and — on Enterprise / Serverless — synthetic `_source`.

Published Elastic numbers (your dataset will differ):

| Source | Result |
|---|---|
| [search-labs announcement](https://www.elastic.co/search-labs/blog/elasticsearch-logsdb-index-mode) | up to ~65% smaller logs |
| [Observability Labs tutorial](https://www.elastic.co/observability-labs/blog/elasticsearch-logsdb-index-mode-storage-savings) | 15.37 MB → 8.6 MB (**44%**) on Apache sample |
| Nightly benches + synthetic `_source` | 162.7 GB → 39.4 GB (**76%**) |

Trade-off: slightly more CPU on ingest/merge. Elastic Security 8.18 warns that enabling LogsDB without hot-tier CPU headroom can back up ingest and time out detection rules.

Do **not** enable LogsDB on metrics (`time_series`) or APM trace streams.

## Repo contents

| File | Purpose |
|---|---|
| [docs/logsdb-enablement-plan.md](docs/logsdb-enablement-plan.md) | Phase 0–4 plan, go/no-go KPIs, rollback |
| [scripts/logsdb-compare.sh](scripts/logsdb-compare.sh) | Offline A/B: same docs into standard vs logsdb, force-merge, bytes/doc |
| [scripts/logsdb-monitor.sh](scripts/logsdb-monitor.sh) | Cluster snapshot: index.mode inventory, bytes/doc by family, node CPU/JVM/disk |
| [console/logsdb-devtools.console](console/logsdb-devtools.console) | Same flow for Kibana Dev Tools, plus `@custom` enable / rollover / rollback |

## Quick start

```bash
export ES_URL="https://es.example:9200"
export ES_USER="elastic"
export ES_PASS="..."          # or: export ES_API_KEY="id:key"

chmod +x scripts/logsdb-compare.sh scripts/logsdb-monitor.sh

# 7-day baseline before any template change
./scripts/logsdb-monitor.sh --pattern "logs-*" --out-dir ./logsdb-monitor

# Canary compare against ONE real backing index (prefer tens of GB)
./scripts/logsdb-compare.sh \
  --source ".ds-logs-system.syslog-default-YYYY.MM.DD-000NNN" \
  --max-docs 200000 \
  --keep \
  --log-dir ./logsdb-compare-logs
```

The compare script does **not** change production templates. Force-merge runs only on the canary indices it created.

## Live enablement (one stream)

Prefer a Fleet `@custom` component template so managed integration templates are not overwritten. Takes effect on the **next rollover** only:

```http
PUT _component_template/logs-system.syslog@custom
{
  "template": {
    "settings": {
      "index.mode": "logsdb"
    }
  }
}

POST /logs-system.syslog-default/_rollover
GET /logs-system.syslog-default/_settings?filter_path=**.index.mode
```

Only the new backing index becomes LogsDB. That is the live A/B. See the [enablement plan](docs/logsdb-enablement-plan.md) for phases, KPIs, and rollback.

## Requirements

- Elasticsearch 8.17+ (LogsDB GA). These notes target **8.18.4**.
- `curl`, `bash`, `python3` on the jump host.
- Cluster privilege to create/delete canary indices, reindex, and read `_stats` / `_nodes/stats`.
- Enterprise license for synthetic `_source` (the extra 20–40%). Sort + ZSTD still apply on Standard/Gold/Platinum.

## Safety

- Never force-merge a live hot write index.
- Never enable LogsDB on many integrations in one change window.
- Rollback = remove `index.mode` from `@custom` and rollover again. You cannot convert an existing backing index back to standard.

## References

- https://www.elastic.co/search-labs/blog/elasticsearch-logsdb-index-mode
- https://www.elastic.co/observability-labs/blog/elasticsearch-logsdb-index-mode-storage-savings
- https://www.elastic.co/docs/manage-data/data-store/data-streams/logs-data-stream
- https://www.elastic.co/guide/en/security/8.18/detections-logsdb-index-mode-impact.html
