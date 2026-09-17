# LogsDB enablement plan

Cluster context: Elasticsearch **8.18.4** self-managed, ~16 uniform data nodes
(data/master/ingest/transform/remote_cluster_client) + dedicated ML, Kibana,
Fleet. Logs from OpenShift Vector / system / Kafka-adjacent observability.
Planned rolling upgrade toward **9.4.x**.

References:

- Announcement (mechanisms + license split):
  https://www.elastic.co/search-labs/blog/elasticsearch-logsdb-index-mode
- Hands-on compare method used by the tools in this folder:
  https://www.elastic.co/observability-labs/blog/elasticsearch-logsdb-index-mode-storage-savings
- Official logs data stream behavior (8.x vs 9.x):
  https://www.elastic.co/docs/manage-data/data-store/data-streams/logs-data-stream
- Security CPU warning (8.18):
  https://www.elastic.co/guide/en/security/8.18/detections-logsdb-index-mode-impact.html

## What LogsDB actually changes

One setting: `"index.mode": "logsdb"` on the **next** backing index.

Elasticsearch then applies:

| Mechanism | What it does | Typical share of saving |
|---|---|---|
| Index sort (`host.name`, `@timestamp` by default) | Similar log lines sit together so codecs compress | ~30% |
| `best_compression` (ZSTD) + numeric doc-value codecs | Smaller stored fields and doc values | remainder of Basic-tier saving |
| Synthetic `_source` (Enterprise / Serverless only) | Drop raw JSON, rebuild on read | extra 20–40% |
| `route_on_sort_fields` (8.18+, licensed) | Shard routing by sort fields | extra ~20% in Elastic benches |

Published numbers (not a promise for this cluster):

- Announcement: **up to 65%** smaller logs vs recent standard mode.
- Apache tutorial (same docs, force-merged): **15.37 MB → 8.6 MB = 44%**.
- Nightly benches with synthetic `_source`: **162.7 GB → 39.4 GB = 76%**.
- Indexing: historically a **~5–15%** ingest tax on 8.17-era LogsDB; 9.1+
  reduced write I/O and merge CPU. Security docs: need **hot-tier CPU
  headroom** or ingest backs up and detection rules time out.

On **8.18.4**, existing `logs-*-*` streams stay **standard** until you opt in.
A later 9.x upgrade will **not** flip those existing streams automatically.

Do **not** put LogsDB on metrics (`time_series`) or APM trace streams.

## Tools in this folder

| File | Purpose |
|---|---|
| `scripts/logsdb-compare.sh` | Canary: copy N docs into standard + logsdb, force-merge, print bytes/doc + index/merge time |
| `scripts/logsdb-monitor.sh` | Cluster snapshot: which backing indices are already logsdb, bytes/doc by family, node CPU/JVM/disk, write/merge pools |
| `console/logsdb-devtools.console` | Same flow, paste into Kibana Dev Tools |

```bash
export ES_URL="https://es.example:9200"
export ES_USER="elastic"
export ES_PASS="..."          # or ES_API_KEY

chmod +x scripts/logsdb-compare.sh scripts/logsdb-monitor.sh

# Baseline (repeat daily for 7 days before any template change)
./scripts/logsdb-monitor.sh --pattern "logs-*" --out-dir ./logsdb-monitor

# Canary compare against ONE real backing index
./scripts/logsdb-compare.sh \
  --source ".ds-logs-system.syslog-default-YYYY.MM.DD-000NNN" \
  --max-docs 200000 \
  --keep \
  --log-dir ./logsdb-compare-logs
```

Prefer a source index of **tens of GB**. Sub-GB samples understate compression.

## Success criteria (go / no-go)

Record these from the compare tool **and** from a 48h post-rollover monitor snapshot.

| KPI | Go | Hold / rollback next rollover |
|---|---|---|
| Primary store bytes/doc | ≥ 25% drop vs paired standard canary | < 15% drop (check license, mappings, force-merge) |
| Reindex / live ingest rate | Slowdown ≤ 15% | Persistent write-pool queue or bulk rejects |
| Hot node CPU | Headroom remains (peak < ~75% user+sys on data nodes) | CPU pegged, merge queue growth |
| Query | p95 of 5 real Lens/ES\|QL/alert queries within 20% | Timeouts, mapping surprises on `_source` |
| Doc count | Equal on both canary arms | Investigate reindex failures |
| Cluster health | Green, no pending-task storm | Yellow + relocation storm |

Also confirm:

```
GET /cmp-logsdb-logsdb/_settings?flat_settings=true
```

shows `index.mode: logsdb`. If it does not, the experiment is invalid.

## Phased rollout

### Phase 0 — Inventory (day 0)

1. Snapshot with `logsdb-monitor.sh`.
2. Note license type. If not Enterprise, plan for the **44%-class** saving
   (sort + ZSTD), not the **65–76%** synthetic-source headline.
3. List candidate log streams only (`logs-system.*`, OpenShift / Vector
   app logs). Exclude metrics, APM traces, profiling, ML internals.
4. Confirm ILM rollover is healthy (`_ilm/explain`). LogsDB cannot attach
   to an already-created backing index; it needs a rollover.
5. Confirm hot-tier CPU and disk watermark have slack. vSAN latency
   spikes during force-merge / heavy ingest will show here.

### Phase 1 — Offline canary (day 0–1)

1. Run `logsdb-compare.sh` against the largest **log** backing index.
2. Optionally replay 5 production queries from Dev Tools against both
   canary indices.
3. Read `_disk_usage`: saving should show up in `_source` / stored_fields
   first, then doc_values. If `_source` barely moved and you expected
   Enterprise synthetic source, the license is not applying it.
4. Delete canaries (`compare.sh` does this unless `--keep`).

Stop here if bytes/doc did not drop or if canary reindex CPU on the
coordinating / data node was already painful.

### Phase 2 — One live stream (day 2–9)

Pick **one** high-volume but non-critical log dataset
(example: `logs-system.syslog-default`).

Enable via **`@custom` component template** so Fleet-managed templates
are not overwritten:

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
```

Then:

```http
GET /logs-system.syslog-default/_settings?filter_path=**.index.mode
GET _data_stream/logs-system.syslog-default
```

Only the **new** backing index should show `logsdb`. Old generations stay
standard. That is the live A/B.

For 7 days run `logsdb-monitor.sh` once per day. Compare:

- bytes/doc of the new generation vs the previous generation
- write thread-pool `queue` / `rejected`
- node `indices.indexing` and `indices.merge` time growth
- OpenShift Vector / Kafka Connect bulk lag (ingest side)

Do **not** force-merge the live hot write index. Let ILM force-merge in
warm/cold if that is already in the policy.

### Phase 3 — Expand stream by stream (week 2–4)

Order:

1. Remaining system / syslog / auth logs
2. OpenShift / Kubernetes container logs (after confirming `host.name` or
   an equivalent low-cardinality sort field exists)
3. App logs with repetitive structure
4. Security logs **only after** hot CPU still has headroom (Elastic
   Security 8.18 explicitly warns about rule timeouts)

Never enable LogsDB on many integrations in one change window.

Optional 8.18+ extra (licensed):

```json
"index.logsdb.route_on_sort_fields": true
```

Only if sort fields besides `@timestamp` have useful cardinality. Wrong
sort fields can hurt more than they help.

### Phase 4 — 9.x upgrade interaction

1. Finish Phase 2 on 8.18.4 **before** the rolling upgrade. You want a
   measured baseline on the current major.
2. Upgrade path stays: latest 8.x → 9.x rolling ES, Kibana not rolling.
3. After 9.x: `GET /.ds-logs-*/_settings?filter_path=**.index.mode`
   - Existing streams you did not opt in: still `standard`.
   - Brand-new `logs-*-*` streams created after upgrade: may default to
     `logsdb`.
4. 9.1+ is a better LogsDB ingest profile (lower write I/O, faster doc-
   values merges). If Phase 2 CPU was borderline, wait until after 9.x
   to expand further.

## Rollback

LogsDB is index-creation-time. You cannot flip a live backing index back
to standard.

To stop new LogsDB indices:

1. Remove `index.mode` from the `@custom` component template (or delete
   that custom template if it only held this setting).
2. `POST /<data-stream>/_rollover`
3. New generation is standard. Old LogsDB generations age out via ILM.

Snapshots and searchable snapshots of LogsDB indices stay LogsDB. Plan
restore tests on a canary index if you rely on snapshot restore for
those streams.

## Monitoring after enablement (steady state)

Keep `logsdb-monitor.sh` on a daily cron or run it from an existing
jump host. Minimum Kibana Lens / monitoring charts:

1. Store size / doc count (bytes/doc) per `logs-*` data stream
2. Indexing rate + indexing latency, split by data stream
3. Merge time per data node
4. Write thread-pool rejected
5. Hot disk used vs high watermark
6. Ingest lag (Vector / Elastic Agent / Kafka Connect)

ML node is out of scope — do not place LogsDB data there.

## Mapping / query caveats

- Default LogsDB sort expects `host.name` as keyword. If the dataset has
  no `host.name`, set `index.sort.field` explicitly to a real
  low-cardinality field plus `@timestamp`. Do not sort on two fields
  that co-vary (`host.name` + `host.id`).
- Synthetic `_source` may reorder fields and treat some multi-value
  arrays differently. Fine for most log analytics; review before SIEM
  rules that inspect exact `_source` shape.
- Text `message` inverted index often dominates remaining size. LogsDB
  does not delete that unless you change mappings on purpose.
- `_id` / get-by-id is not the LogsDB design center. Log search and
  range + terms aggs are.

## Decision log (fill in)

| Date | Stream | License | Canary bytes/doc std → ldb | Live ingest delta | CPU | Decision |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |
