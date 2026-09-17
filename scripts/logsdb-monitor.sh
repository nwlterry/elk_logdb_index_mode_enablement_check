#!/usr/bin/env bash
# logsdb-monitor.sh
# Snapshot cluster + data-stream resource usage before/after enabling LogsDB.
# Designed to be run:
#   1) as a 7-day baseline (standard mode)
#   2) after a canary rollover onto LogsDB
#   3) after expanding to more streams
#
# Captures:
#   - which backing indices are already logsdb
#   - bytes/doc per data stream
#   - node CPU / JVM / disk / indexing / merge
#   - write + merge thread pools
#   - license (synthetic _source availability)
#
# Usage:
#   export ES_URL ES_USER ES_PASS   # or ES_API_KEY
#   ./logsdb-monitor.sh [--pattern "logs-*"] [--out-dir ./logsdb-monitor]
#
set -euo pipefail

ES_URL="${ES_URL:-http://localhost:9200}"
ES_USER="${ES_USER:-}"
ES_PASS="${ES_PASS:-}"
ES_API_KEY="${ES_API_KEY:-}"
PATTERN="logs-*"
OUT_DIR="${OUT_DIR:-./logsdb-monitor}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern) PATTERN="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--pattern logs-*] [--out-dir DIR]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y%m%dT%H%M%S)"
DEST="${OUT_DIR}/${TS}"
mkdir -p "$DEST"

auth_args=()
if [[ -n "$ES_API_KEY" ]]; then
  auth_args=(-H "Authorization: ApiKey ${ES_API_KEY}")
elif [[ -n "$ES_USER" ]]; then
  auth_args=(-u "${ES_USER}:${ES_PASS}")
fi

es() {
  local method="$1" path="$2"
  shift 2
  curl -sS -k -X "$method" "${ES_URL}${path}" \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    "$@"
}

echo "Snapshot ${TS} -> ${DEST}"

es GET "/_cluster/health" > "${DEST}/cluster-health.json"
es GET "/?filter_path=version" > "${DEST}/version.json"
es GET "/_license?filter_path=license.type,license.status,license.expiry_date" > "${DEST}/license.json"

# Which backing indices already run LogsDB
es GET "/.ds-${PATTERN}/_settings?flat_settings=true&filter_path=**.index.mode,**.index.codec,**.index.sort.field,**.index.mapping.source.mode,**.index.logsdb*" \
  > "${DEST}/ds-index-mode.json" || true

# Per-index store + docs + indexing (normalize later as bytes/doc)
es GET "/_cat/indices/.ds-${PATTERN}?format=json&h=index,docs.count,pri,rep,pri.store.size,store.size,creation.date.string,health" \
  > "${DEST}/cat-indices.json" || true

es GET "/.ds-${PATTERN}/_stats?filter_path=indices.*.primaries.docs,indices.*.primaries.store,indices.*.primaries.indexing,indices.*.primaries.merges,indices.*.primaries.segments,indices.*.primaries.query_cache,indices.*.primaries.search,indices.*.uuid" \
  > "${DEST}/ds-stats.json" || true

# Data streams list + generation (to see which backing index is write index)
es GET "/_data_stream/${PATTERN}" > "${DEST}/data-streams.json" || true

# Templates that will control the NEXT rollover
es GET "/_index_template/${PATTERN}" > "${DEST}/index-templates.json" || true
es GET "/_component_template/*@custom" > "${DEST}/component-templates-custom.json" || true

# Node resources — this is the LogsDB CPU/IO watch surface
es GET "/_nodes/stats/os,jvm,fs,indices?filter_path=nodes.*.name,nodes.*.roles,nodes.*.os.cpu,nodes.*.jvm.mem,nodes.*.jvm.gc,nodes.*.fs.total,nodes.*.indices.indexing,nodes.*.indices.merge,nodes.*.indices.search,nodes.*.indices.store,nodes.*.indices.segments,nodes.*.indices.translog" \
  > "${DEST}/nodes-stats.json"

es GET "/_cat/thread_pool/write,search,force_merge,refresh?format=json&h=node_name,name,active,queue,rejected,completed,core,max" \
  > "${DEST}/thread-pools.json"

es GET "/_cat/allocation?format=json&v" > "${DEST}/allocation.json"
es GET "/_cluster/pending_tasks" > "${DEST}/pending-tasks.json"

# ILM explain for hot indices (LogsDB applies on rollover; confirm policy)
es GET "/.ds-${PATTERN}/_ilm/explain?only_errors=false" > "${DEST}/ilm-explain.json" || true

python3 - "$DEST" <<'PY'
import json, os, sys
from collections import defaultdict
dest = sys.argv[1]

def load(name):
    p = os.path.join(dest, name)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None
    with open(p) as f:
        try:
            return json.load(f)
        except Exception:
            return None

lic = load("license.json") or {}
ver = load("version.json") or {}
health = load("cluster-health.json") or {}
modes = load("ds-index-mode.json") or {}
stats = load("ds-stats.json") or {}
cat = load("cat-indices.json") or []

print("=== Cluster ===")
print("status:", health.get("status"), "nodes:", health.get("number_of_nodes"))
print("version:", (ver.get("version") or {}).get("number"))
print("license:", (lic.get("license") or {}))
print()

mode_counts = defaultdict(int)
for idx, body in (modes or {}).items():
    settings = body.get("settings", {})
    mode = settings.get("index.mode") or settings.get("index.mode".replace(".", "\0"))
    # flat or nested
    if not mode:
        mode = (body.get("settings") or {}).get("index", {}).get("mode", "standard/unset")
    if isinstance(settings, dict) and "index.mode" in settings:
        mode = settings["index.mode"]
    mode_counts[str(mode)] += 1
print("=== Backing-index index.mode counts ===")
if mode_counts:
    for k, v in sorted(mode_counts.items(), key=lambda x: -x[1]):
        print(f"  {k}: {v}")
else:
    print("  (no .ds-logs-* settings returned — check --pattern / privileges)")
print()

# bytes/doc from _stats
rows = []
for name, body in (stats.get("indices") or {}).items():
    p = body.get("primaries") or {}
    docs = ((p.get("docs") or {}).get("count")) or 0
    store = ((p.get("store") or {}).get("size_in_bytes")) or 0
    idx_ms = ((p.get("indexing") or {}).get("index_time_in_millis")) or 0
    merge_ms = ((p.get("merges") or {}).get("total_time_in_millis")) or 0
    bpd = (store / docs) if docs else 0
    rows.append((store, name, docs, store, bpd, idx_ms, merge_ms))
rows.sort(reverse=True)

print("=== Top backing indices by primary store (bytes/doc) ===")
print(f"{'index':<72} {'docs':>10} {'MB':>10} {'B/doc':>8}")
for _, name, docs, store, bpd, idx_ms, merge_ms in rows[:25]:
    print(f"{name:<72} {docs:10d} {store/1024/1024:10.1f} {bpd:8.1f}")

# rollup by data-stream family (strip generation)
fam = defaultdict(lambda: {"docs": 0, "store": 0, "n": 0})
for _, name, docs, store, bpd, idx_ms, merge_ms in rows:
    # .ds-logs-foo-bar-2026.09.16-000012
    fam_name = name
    if name.startswith(".ds-"):
        parts = name.rsplit("-", 2)
        fam_name = parts[0][4:] if len(parts) >= 3 else name
    fam[fam_name]["docs"] += docs
    fam[fam_name]["store"] += store
    fam[fam_name]["n"] += 1

print()
print("=== Per data-stream family (sum of backing primaries) ===")
print(f"{'family':<56} {'idx':>4} {'docs':>12} {'GB':>8} {'B/doc':>8}")
fam_rows = []
for k, v in fam.items():
    bpd = v["store"] / v["docs"] if v["docs"] else 0
    fam_rows.append((v["store"], k, v["n"], v["docs"], v["store"], bpd))
fam_rows.sort(reverse=True)
for _, k, n, docs, store, bpd in fam_rows[:30]:
    print(f"{k:<56} {n:4d} {docs:12d} {store/1024/1024/1024:8.2f} {bpd:8.1f}")

print()
print("KPI to watch across snapshots:")
print("  1. B/doc per family  — should drop after LogsDB rollover + merge")
print("  2. node indexing.index_time_in_millis growth rate — write tax")
print("  3. node merges.total_time_in_millis — merge tax")
print("  4. write thread-pool queue/rejected — ingest backup")
print("  5. hot disk used vs high watermark")
print()
print("Snapshots live in:", dest)
PY

echo
echo "Wrote ${DEST}"
echo "Re-run daily; diff bytes/doc and node indexing/merge times after a LogsDB rollover."
