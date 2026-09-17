#!/usr/bin/env bash
# logsdb-compare.sh
# Side-by-side storage + indexing comparison: standard vs LogsDB
# Method from Elastic Observability Labs:
#   https://www.elastic.co/observability-labs/blog/elasticsearch-logsdb-index-mode-storage-savings
# Mechanisms from the LogsDB announcement:
#   https://www.elastic.co/search-labs/blog/elasticsearch-logsdb-index-mode
#
# Safe defaults: 1 primary, 0 replicas, canary index names, optional max docs.
# Does NOT modify production templates or data streams.
#
# Usage:
#   export ES_URL="https://es.example:9200"
#   export ES_USER="elastic"
#   export ES_PASS="..."
#   # or: export ES_API_KEY="base64id:key"
#   ./logsdb-compare.sh --source ".ds-logs-system.syslog-default-*" [--max-docs 200000]
#
set -euo pipefail

ES_URL="${ES_URL:-http://localhost:9200}"
ES_USER="${ES_USER:-}"
ES_PASS="${ES_PASS:-}"
ES_API_KEY="${ES_API_KEY:-}"
SOURCE_INDEX=""
MAX_DOCS=""
PREFIX="cmp-logsdb"
SHARDS=1
REPLICAS=0
REFRESH="30s"
SKIP_FORCEMERGE=0
DRY_RUN=0
KEEP=0
LOG_DIR="${LOG_DIR:-./logsdb-compare-logs}"

usage() {
  cat <<EOF
Usage: $0 --source <index-or-datastream> [options]

Required:
  --source NAME          Source index, backing index, or data stream
                         (example: .ds-logs-system.syslog-default-2026.09.16-000042)

Optional:
  --max-docs N           Cap reindex size (recommended for first run)
  --prefix NAME          Canary index prefix (default: cmp-logsdb)
  --shards N             Primaries for canary indices (default: 1)
  --replicas N           Replicas (default: 0)
  --skip-forcemerge      Measure without collapsing to 1 segment
  --keep                 Do not delete canary indices at the end
  --log-dir DIR          Output directory (default: ./logsdb-compare-logs)
  --dry-run              Print planned calls only
  -h, --help

Env:
  ES_URL       Elasticsearch URL
  ES_USER / ES_PASS   basic auth
  ES_API_KEY   ApiKey header value (id:key or base64)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_INDEX="$2"; shift 2 ;;
    --max-docs) MAX_DOCS="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --shards) SHARDS="$2"; shift 2 ;;
    --replicas) REPLICAS="$2"; shift 2 ;;
    --skip-forcemerge) SKIP_FORCEMERGE=1; shift ;;
    --keep) KEEP=1; shift ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_INDEX" ]]; then
  echo "ERROR: --source is required" >&2
  usage
  exit 1
fi

STD_INDEX="${PREFIX}-standard"
LDB_INDEX="${PREFIX}-logsdb"
TS="$(date +%Y%m%dT%H%M%S)"
mkdir -p "$LOG_DIR"
REPORT="${LOG_DIR}/report-${TS}.txt"
RAW="${LOG_DIR}/raw-${TS}"
mkdir -p "$RAW"

auth_args=()
if [[ -n "$ES_API_KEY" ]]; then
  auth_args=(-H "Authorization: ApiKey ${ES_API_KEY}")
elif [[ -n "$ES_USER" ]]; then
  auth_args=(-u "${ES_USER}:${ES_PASS}")
fi

es() {
  local method="$1" path="$2"
  shift 2
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN ${method} ${ES_URL}${path} $*"
    return 0
  fi
  curl -sS -k -X "$method" "${ES_URL}${path}" \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    "$@"
}

es_code() {
  local method="$1" path="$2"
  shift 2
  curl -sS -k -o /tmp/es_body.$$ -w "%{http_code}" -X "$method" "${ES_URL}${path}" \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    "$@"
}

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

if [[ $DRY_RUN -eq 0 ]]; then
  health="$(es GET "/_cluster/health?filter_path=status,number_of_nodes,active_shards")"
  log "Cluster health: ${health}"
  ver="$(es GET "/?filter_path=version.number,version.build_flavor,version.lucene_version")"
  log "Elasticsearch: ${ver}"
  lic="$(es GET "/_license?filter_path=license.type,license.status,license.expiry_date")"
  log "License: ${lic}"
  log "Synthetic _source (full LogsDB savings, 20-40% extra) needs Enterprise."
  log "Basic/Gold/Platinum still get sort + best_compression."
  log ""
fi

log "=== LogsDB comparison ${TS} ==="
log "Source : ${SOURCE_INDEX}"
log "Canary : ${STD_INDEX}  vs  ${LDB_INDEX}"
log "Shards : ${SHARDS} primaries / ${REPLICAS} replicas"
log ""

# Pull source mappings so both arms stay identical (do not let LogsDB
# default keyword mapping silently change the experiment).
if [[ $DRY_RUN -eq 0 ]]; then
  es GET "/${SOURCE_INDEX}/_mapping?filter_path=*.mappings" > "${RAW}/source-mapping.json" || true
fi

create_index() {
  local name="$1" mode="$2"
  local settings
  if [[ "$mode" == "logsdb" ]]; then
    settings=$(cat <<JSON
{
  "settings": {
    "index.mode": "logsdb",
    "number_of_shards": ${SHARDS},
    "number_of_replicas": ${REPLICAS},
    "refresh_interval": "${REFRESH}"
  }
}
JSON
)
  else
    settings=$(cat <<JSON
{
  "settings": {
    "number_of_shards": ${SHARDS},
    "number_of_replicas": ${REPLICAS},
    "refresh_interval": "${REFRESH}"
  }
}
JSON
)
  fi
  log "Creating ${name} (mode=${mode})"
  es DELETE "/${name}?ignore_unavailable=true" >/dev/null || true
  echo "$settings" | es PUT "/${name}" --data-binary @- | tee -a "$REPORT" | tee "${RAW}/create-${name}.json"
}

create_index "$STD_INDEX" "standard"
create_index "$LDB_INDEX" "logsdb"

reindex_one() {
  local dest="$1"
  local body
  if [[ -n "$MAX_DOCS" ]]; then
    body=$(cat <<JSON
{
  "source": { "index": "${SOURCE_INDEX}", "size": 2000 },
  "dest": { "index": "${dest}" },
  "max_docs": ${MAX_DOCS}
}
JSON
)
  else
    body=$(cat <<JSON
{
  "source": { "index": "${SOURCE_INDEX}", "size": 2000 },
  "dest": { "index": "${dest}" }
}
JSON
)
  fi
  log "Reindex ${SOURCE_INDEX} -> ${dest}"
  local start end
  start=$(date +%s)
  echo "$body" | es POST "/_reindex?wait_for_completion=true&refresh=true" --data-binary @- \
    | tee "${RAW}/reindex-${dest}.json" | tee -a "$REPORT"
  end=$(date +%s)
  log "Reindex wall-clock ${dest}: $((end-start))s"
}

reindex_one "$STD_INDEX"
reindex_one "$LDB_INDEX"

if [[ $SKIP_FORCEMERGE -eq 0 ]]; then
  log "Force-merge both canaries to 1 segment (blog method; canaries only)"
  es POST "/${STD_INDEX}/_forcemerge?max_num_segments=1" | tee "${RAW}/fm-std.json" | tee -a "$REPORT"
  es POST "/${LDB_INDEX}/_forcemerge?max_num_segments=1" | tee "${RAW}/fm-ldb.json" | tee -a "$REPORT"
  es POST "/${STD_INDEX}/_refresh" >/dev/null
  es POST "/${LDB_INDEX}/_refresh" >/dev/null
else
  log "Skipping force-merge (--skip-forcemerge)"
fi

collect_stats() {
  local name="$1" tag="$2"
  es GET "/${name}/_stats?filter_path=indices.*.primaries.docs,indices.*.primaries.store,indices.*.primaries.indexing,indices.*.primaries.merges,indices.*.primaries.segments" \
    | tee "${RAW}/stats-${tag}.json"
  es GET "/${name}/_settings?flat_settings=true&filter_path=*.settings.index.mode,*.settings.index.codec,*.settings.index.sort*,*.settings.index.mapping.source.mode,*.settings.index.logsdb*" \
    | tee "${RAW}/settings-${tag}.json"
  es GET "/_cat/indices/${name}?v&h=index,docs.count,pri,rep,pri.store.size,store.size,health" \
    | tee -a "$REPORT"
}

log ""
log "=== Applied settings (confirm LogsDB actually engaged) ==="
collect_stats "$STD_INDEX" "std" >/dev/null
collect_stats "$LDB_INDEX" "ldb" >/dev/null
if [[ $DRY_RUN -eq 0 ]]; then
  python3 - "$RAW" "$REPORT" "$STD_INDEX" "$LDB_INDEX" <<'PY'
import json, sys, os
raw, report, std, ldb = sys.argv[1:5]

def load(name):
    with open(os.path.join(raw, name)) as f:
        return json.load(f)

def primaries(stats, index):
    # stats may key by exact index name
    idx = stats.get("indices", {})
    if not idx:
        return {}
    body = next(iter(idx.values()))
    return body.get("primaries", {})

std_s = load("stats-std.json")
ldb_s = load("stats-ldb.json")
sp, lp = primaries(std_s, std), primaries(ldb_s, ldb)

def g(p, *ks, default=0):
    cur = p
    for k in ks:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur

std_docs = g(sp, "docs", "count")
ldb_docs = g(lp, "docs", "count")
std_bytes = g(sp, "store", "size_in_bytes")
ldb_bytes = g(lp, "store", "size_in_bytes")
std_idx_ms = g(sp, "indexing", "index_time_in_millis")
ldb_idx_ms = g(lp, "indexing", "index_time_in_millis")
std_merge_ms = g(sp, "merges", "total_time_in_millis")
ldb_merge_ms = g(lp, "merges", "total_time_in_millis")

def bpd(b, d):
    return (b / d) if d else 0

def mb(b):
    return b / 1024 / 1024

red = (1 - (ldb_bytes / std_bytes)) * 100 if std_bytes else 0
lines = []
lines.append("")
lines.append("=== Comparison (primaries only, after optional force-merge) ===")
lines.append(f"{'arm':<18} {'docs':>12} {'store_MB':>12} {'bytes/doc':>12} {'index_ms':>12} {'merge_ms':>12}")
lines.append(f"{'standard':<18} {std_docs:12d} {mb(std_bytes):12.2f} {bpd(std_bytes, std_docs):12.1f} {std_idx_ms:12d} {std_merge_ms:12d}")
lines.append(f"{'logsdb':<18} {ldb_docs:12d} {mb(ldb_bytes):12.2f} {bpd(ldb_bytes, ldb_docs):12.1f} {ldb_idx_ms:12d} {ldb_merge_ms:12d}")
lines.append("")
lines.append(f"Storage reduction: {red:.1f}%")
if std_docs != ldb_docs:
    lines.append(f"WARNING: doc counts differ ({std_docs} vs {ldb_docs}). Re-run or inspect reindex tasks.")
if std_bytes and ldb_bytes >= std_bytes:
    lines.append("NOTE: LogsDB is not smaller. Check license (synthetic _source), mappings,")
    lines.append("      whether index.mode actually applied, and that force-merge completed.")
    lines.append("      Tiny samples understate compression. Prefer tens of GB.")
lines.append("")
lines.append("Blog context (Elastic search-labs, Dec 2024):")
lines.append("  sort ~30%  +  synthetic _source 20-40%  +  ZSTD/codecs  => up to ~65% on logs")
lines.append("  Labs tutorial (Apache sample): 15.37 MB -> 8.6 MB = 44% without claiming Enterprise synthetic.")
lines.append("  Nightly benches with synthetic _source: ~76% (162.7 GB -> 39.4 GB).")
text = "\n".join(lines)
print(text)
with open(report, "a") as f:
    f.write(text + "\n")
PY
fi

log ""
log "=== Field-level disk usage (expensive; canaries only) ==="
if [[ $DRY_RUN -eq 0 ]]; then
  es GET "/${STD_INDEX}/_disk_usage?run_expensive_tasks=true&flush=true" > "${RAW}/disk-std.json" || true
  es GET "/${LDB_INDEX}/_disk_usage?run_expensive_tasks=true&flush=true" > "${RAW}/disk-ldb.json" || true
  log "Wrote ${RAW}/disk-std.json and disk-ldb.json"
  log "Inspect stored_fields vs doc_values vs inverted_index to see where savings landed."
fi

log ""
log "=== Effective LogsDB settings on canary ==="
if [[ $DRY_RUN -eq 0 ]]; then
  cat "${RAW}/settings-ldb.json" | tee -a "$REPORT"
fi

if [[ $KEEP -eq 0 && $DRY_RUN -eq 0 ]]; then
  log ""
  log "Deleting canary indices (pass --keep to retain)"
  es DELETE "/${STD_INDEX}" >/dev/null || true
  es DELETE "/${LDB_INDEX}" >/dev/null || true
fi

log ""
log "Report: ${REPORT}"
log "Raw JSON: ${RAW}"
