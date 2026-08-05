#!/usr/bin/env bash
set -euo pipefail

# Per-worker throughput ceiling: unlike find_max_tps.sh (many chains across many shards,
# ramping client *count*), this isolates a single chain on a single shard/worker and ramps
# the *bps requested from that one chain* (via one linera-lite-benchmark process) until
# latency degrades -- matching the paper's Fig. 4.a methodology (single-worker capacity,
# given a CPU allocation matching what one worker gets in the multi-worker/global setup).
#
# The validator runs with NUM_SHARDS=1 so there's exactly one worker in existence; that one
# shard is pinned to CORES_PER_SHARD cores (storage-server/proxy are left generously
# resourced, not meaningfully constrained). mixed/full traffic modes need other chains to
# address messages to; NUM_DESTINATION_CHAINS such chains are provisioned but never
# actively driven (see lite_benchmark's --destination-chains / run_lite_benchmark.sh's
# DESTINATION_CHAIN_IDS_FILE), so they consume none of the single worker's capacity -- their
# inboxes are simply left unprocessed, as intended.
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT, BUILD_PROFILE,
#     LINERA_SRC -- as in find_max_tps.sh
#   CORES_PER_SHARD        (default 2) cores for the single worker under test
#   RESERVED_CORES         (default 19) cores for the proxy (generous, not meant to bind)
#   STORAGE_CORES          (default 19) cores for storage-server (generous, not meant to bind)
#   STORAGE_TOKIO_THREADS  (default 8) storage-server's own worker-thread cap (see run_node.sh)
#   NUM_DESTINATION_CHAINS (default 5) passive chains for mixed/full traffic modes
#   TRANSACTIONS_PER_BLOCK (default 10)
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   START_BPS              (default 5) first ramp level
#   BPS_STEP               (default 5) bps increment per level
#   MAX_BPS                (default 300) ramp ceiling
#   RUNTIME_SECONDS        (default 15) duration of each level
#   LATENCY_DEGRADATION_FACTOR (default 3.0) stop when p95 exceeds this multiple of the
#                          first level's p95
#   MIN_ACHIEVED_FRACTION  (default 0.8) stop when achieved bps falls below this fraction
#                          of requested bps
#   STOP_NODE_AFTER        (default true)
#   SKIP_BUILD             (default false)
#   SKIP_BINARY_DEPLOY     (default false)

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-19}"
STORAGE_CORES="${STORAGE_CORES:-19}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-8}"
NUM_DESTINATION_CHAINS="${NUM_DESTINATION_CHAINS:-5}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
START_BPS="${START_BPS:-5}"
BPS_STEP="${BPS_STEP:-5}"
MAX_BPS="${MAX_BPS:-300}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-15}"
LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR:-3.0}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOCAL_SUMMARY_DIR="$(mktemp -d)"
SUMMARY_CSV="${LOCAL_SUMMARY_DIR}/max_single_chain_tps_summary.csv"
echo "requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms" > "${SUMMARY_CSV}"

cargo_flags=()
target_dir="debug"
case "${BUILD_PROFILE}" in
  release) cargo_flags=(--release --config profile.release.debug=false); target_dir="release" ;;
  debug) ;;
  *) echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2; exit 1 ;;
esac
bin_src="${LINERA_SRC}/target/${target_dir}"

if [ "${SKIP_BUILD}" = "true" ]; then
  echo "==> [1/5] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/5] Building validator + client binaries natively (${BUILD_PROFILE})"
  ( cd "${LINERA_SRC}" && cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server )
fi

echo "==> [2/5] Deploying to ${SPARTA_HOST}:${REMOTE_DIR}/ (validator)"
ssh "${SPARTA_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-server" "${bin_src}/linera-proxy" \
    "${bin_src}/linera-storage-server" "${SPARTA_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/run_node.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
  "${SPARTA_HOST}:${REMOTE_DIR}/scripts/"
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [2/5] Deploying to ${CLIENT_HOST}:${REMOTE_DIR}/ (client)"
ssh "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/5] Starting validator on ${SPARTA_HOST}: 1 shard x ${CORES_PER_SHARD} cores (RESERVED_CORES=${RESERVED_CORES}, STORAGE_CORES=${STORAGE_CORES})"
ssh "${SPARTA_HOST}" "pkill -9 -f 'linera-server|linera-proxy|linera-storage-server'" 2>/dev/null || true
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
sleep 2
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} \
   NUM_SHARDS=1 CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} \
   STORAGE_CORES=${STORAGE_CORES} STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} \
   START_FAUCET=false ${REMOTE_DIR}/scripts/run_node.sh"
sleep 3

cleanup_node() {
  if [ "${STOP_NODE_AFTER}" = "true" ]; then
    echo "==> Stopping validator on ${SPARTA_HOST}"
    ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" || true
  else
    echo "==> Leaving validator running on ${SPARTA_HOST} (STOP_NODE_AFTER=false)"
  fi
}
trap cleanup_node EXIT

echo "==> Relaying admin wallet + genesis config"
tmp_wallet_dir="$(mktemp -d)"
scp "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_wallet.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_keystore.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/genesis.json" "${tmp_wallet_dir}/"
scp "${tmp_wallet_dir}/admin_wallet.json" "${tmp_wallet_dir}/admin_keystore.json" \
  "${tmp_wallet_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/"
rm -rf "${tmp_wallet_dir}"

total_chains=$((1 + NUM_DESTINATION_CHAINS))
echo "==> [4/5] Provisioning 1 tested chain + ${NUM_DESTINATION_CHAINS} passive destination chain(s)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${total_chains} OUTPUT_FILE=./single_chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  head -n 1 single_chain_pool.txt > tested_chain.txt && \
  tail -n +2 single_chain_pool.txt > destination_chains.txt"

percentile() {
  local file="$1" pct="$2" n idx
  n="$(wc -l < "${file}")"
  [ "${n}" -eq 0 ] && return
  idx=$(( (pct * n + 99) / 100 ))
  [ "${idx}" -lt 1 ] && idx=1
  [ "${idx}" -gt "${n}" ] && idx="${n}"
  sed -n "${idx}p" "${file}"
}

echo "==> [5/5] Ramping bps on a single chain (traffic-mode=${TRAFFIC_MODE}, ${RUNTIME_SECONDS}s per level)"
printf "%-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s\n" \
  "requested_bps" "committed" "failed" "achieved_bps" "achieved_tps" "p25_ms" "p50_ms" "p95_ms"

baseline_p95=""
first_level=true

for bps in $(seq "${START_BPS}" "${BPS_STEP}" "${MAX_BPS}"); do
  experiment_name="single_${RUN_ID}_${bps}"

  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./tested_chain.txt DESTINATION_CHAIN_IDS_FILE=./destination_chains.txt \
    BPS=${bps} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} TRAFFIC_MODE=${TRAFFIC_MODE} \
    RUNTIME_SECONDS=${RUNTIME_SECONDS} EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name} \
    ./scripts/run_lite_benchmark.sh" > /dev/null

  level_dir="$(mktemp -d)"
  scp -r "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/${experiment_name}" "${level_dir}/" > /dev/null

  csv="${level_dir}/${experiment_name}/transfers.csv"
  durations_file="${level_dir}/durations.txt"
  committed=0
  failed=0
  total_tx=0
  if [ -f "${csv}" ]; then
    committed="$(awk -F, 'NR>1 && $4=="committed"' "${csv}" | wc -l)"
    failed="$(awk -F, 'NR>1 && $4=="failed"' "${csv}" | wc -l)"
    total_tx="$(awk -F, 'NR>1 && $4=="committed" {s+=$3} END{print s+0}' "${csv}")"
    awk -F, 'NR>1 && $4=="committed" { print $5 }' "${csv}" | sort -n > "${durations_file}"
  else
    : > "${durations_file}"
  fi

  p25_us="$(percentile "${durations_file}" 25)"
  p50_us="$(percentile "${durations_file}" 50)"
  p95_us="$(percentile "${durations_file}" 95)"
  p25_ms="$(awk -v v="${p25_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p50_ms="$(awk -v v="${p50_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p95_ms="$(awk -v v="${p95_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  achieved_bps="$(awk -v c="${committed}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"
  achieved_tps="$(awk -v c="${total_tx}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"

  printf "%-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s\n" \
    "${bps}" "${committed}" "${failed}" "${achieved_bps}" "${achieved_tps}" "${p25_ms}" "${p50_ms}" "${p95_ms}"
  echo "${bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25_ms},${p50_ms},${p95_ms}" >> "${SUMMARY_CSV}"

  rm -rf "${level_dir}"

  if [ "${first_level}" = "true" ]; then
    baseline_p95="${p95_ms}"
    first_level=false
  fi

  stop_reason=""
  if [ "${failed}" -gt 0 ]; then
    stop_reason="${failed} failed block(s)"
  elif awk -v p="${p95_ms}" -v b="${baseline_p95}" -v f="${LATENCY_DEGRADATION_FACTOR}" 'BEGIN{exit !(b>0 && p>b*f)}'; then
    stop_reason="p95 latency ${p95_ms}ms exceeds ${LATENCY_DEGRADATION_FACTOR}x baseline (${baseline_p95}ms)"
  elif awk -v a="${achieved_bps}" -v r="${bps}" -v f="${MIN_ACHIEVED_FRACTION}" 'BEGIN{exit !(a < r*f)}'; then
    stop_reason="achieved ${achieved_bps} bps is below ${MIN_ACHIEVED_FRACTION}x requested ${bps}"
  fi

  if [ -n "${stop_reason}" ]; then
    echo
    echo "==> Stopping ramp at ${bps} bps: ${stop_reason}"
    break
  fi
done

echo
echo "==> Full per-level results: ${SUMMARY_CSV}"
