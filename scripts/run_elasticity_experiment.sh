#!/usr/bin/env bash
set -euo pipefail

# Elasticity experiment (paper Fig. 6): a validator with BASE_SHARDS always-running shards
# plus (NUM_SHARDS - BASE_SHARDS) elastic slots, and `linera-server manager` watching load
# and adapting the worker count on its own -- no scripted scaling here, we only vary traffic
# and let the manager react. See scripts/run_node.sh's BASE_SHARDS/START_MANAGER docs and
# linera-service/src/manager.rs for the mechanism itself.
#
# Traffic is a single continuous linera-lite-benchmark run driven by a time-varying
# --bps-schedule (see linera-lite-benchmark --help and run_lite_benchmark_parallel.sh's
# BPS_SCHEDULE) rather than several separate process phases -- one continuous timeline, no
# reconnection gaps, and the schedule itself becomes the "requested workload" line on the
# plot. The default schedule is a diverse multi-level trace (two dips to low, two different
# medium levels, a sustained peak and a second brief spike) rather than a flat low/high/low
# step, loosely in the spirit of DiabloBench's real-world traffic traces
# (https://github.com/NatoliChris/diablo-benchmark) -- its actual named traces (Dota2, FIFA,
# etc.) live in a separate paper artifact we don't have local access to, but its own
# mechanism for expressing a workload (a piecewise time->rate schedule) is exactly what
# --bps-schedule implements.
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT, BUILD_PROFILE,
#     LINERA_SRC, SKIP_BUILD, SKIP_BINARY_DEPLOY -- as in find_max_tps.sh
#   BASE_SHARDS            (default 2) always-running shards
#   NUM_SHARDS             (default 6) total shard slots (elastic = NUM_SHARDS - BASE_SHARDS)
#   CORES_PER_SHARD        (default 0 = unpinned)
#   STORAGE_TOKIO_THREADS  (default 8)
#   MANAGER_INTERVAL_MS, MANAGER_HIGH_WATERMARK, MANAGER_LOW_WATERMARK,
#   MANAGER_MAX_MIGRATIONS_PER_ROUND, MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                          passed straight through to run_node.sh / `linera-server manager`;
#                          defaults: 2000ms interval, high=300 req/s, low=high/4,
#                          max-migrations=8, scale-down-rounds=3, cooldown-rounds=3
#   NUM_CLIENTS            (default 3) parallel lite-benchmark client processes
#   CHAINS_PER_CLIENT      (default 10)
#   TRANSACTIONS_PER_BLOCK (default 10)
#   TRAFFIC_MODE           (default independent)
#   BPS_SCHEDULE           (optional) explicit total (system-wide) schedule, comma-separated
#                          offset:bps pairs -- see linera-lite-benchmark --help. If unset, one
#                          is built from LOW_BPS/PEAK_BPS/the segment durations below.
#   LOW_BPS                (default 120) baseline level, comfortably within BASE_SHARDS alone
#   PEAK_BPS               (required unless BPS_SCHEDULE is set) near the fully-scaled
#                          (NUM_SHARDS) ceiling -- see find_max_tps.sh to calibrate
#   MED1_FRACTION          (default 0.35) first medium level, as a fraction of PEAK_BPS
#   MED2_FRACTION          (default 0.6) second medium level, as a fraction of PEAK_BPS
#   SEG_LOW1, SEG_MED1, SEG_DIP, SEG_PEAK1, SEG_MED2, SEG_PEAK2, SEG_MED1B, SEG_TAIL
#                          segment durations in seconds (defaults: 50,40,20,90,30,20,40,130 --
#                          SEG_TAIL should comfortably exceed
#                          scale_down_rounds*interval_ms/1000 + a cooldown's margin so the
#                          final scale-down is fully visible)
#   STOP_NODE_AFTER        (default true)
#   OUT_DIR                (default ./results/elasticity/<timestamp>)

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
SKIP_BUILD="${SKIP_BUILD:-true}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-true}"

BASE_SHARDS="${BASE_SHARDS:-2}"
NUM_SHARDS="${NUM_SHARDS:-6}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-8}"
MANAGER_INTERVAL_MS="${MANAGER_INTERVAL_MS:-2000}"
MANAGER_HIGH_WATERMARK="${MANAGER_HIGH_WATERMARK:-300}"
MANAGER_LOW_WATERMARK="${MANAGER_LOW_WATERMARK:-}"
MANAGER_MAX_MIGRATIONS_PER_ROUND="${MANAGER_MAX_MIGRATIONS_PER_ROUND:-8}"
MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS:-3}"
MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS:-3}"

NUM_CLIENTS="${NUM_CLIENTS:-3}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-10}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"

LOW_BPS="${LOW_BPS:-120}"
PEAK_BPS="${PEAK_BPS:-}"
MED1_FRACTION="${MED1_FRACTION:-0.35}"
MED2_FRACTION="${MED2_FRACTION:-0.6}"
SEG_LOW1="${SEG_LOW1:-50}"
SEG_MED1="${SEG_MED1:-40}"
SEG_DIP="${SEG_DIP:-20}"
SEG_PEAK1="${SEG_PEAK1:-90}"
SEG_MED2="${SEG_MED2:-30}"
SEG_PEAK2="${SEG_PEAK2:-20}"
SEG_MED1B="${SEG_MED1B:-40}"
SEG_TAIL="${SEG_TAIL:-130}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"

BPS_SCHEDULE="${BPS_SCHEDULE:-}"
if [ -z "${BPS_SCHEDULE}" ]; then
  [ -n "${PEAK_BPS}" ] || { echo "set PEAK_BPS (or BPS_SCHEDULE directly) -- see find_max_tps.sh to calibrate a NUM_SHARDS-shard ceiling" >&2; exit 1; }
  med1_bps="$(awk -v p="${PEAK_BPS}" -v f="${MED1_FRACTION}" 'BEGIN{printf "%d", p*f}')"
  med2_bps="$(awk -v p="${PEAK_BPS}" -v f="${MED2_FRACTION}" 'BEGIN{printf "%d", p*f}')"
  t1=${SEG_LOW1}
  t2=$((t1 + SEG_MED1))
  t3=$((t2 + SEG_DIP))
  t4=$((t3 + SEG_PEAK1))
  t5=$((t4 + SEG_MED2))
  t6=$((t5 + SEG_PEAK2))
  t7=$((t6 + SEG_MED1B))
  total_duration=$((t7 + SEG_TAIL))
  BPS_SCHEDULE="0:${LOW_BPS},${t1}:${med1_bps},${t2}:${LOW_BPS},${t3}:${PEAK_BPS},${t4}:${med2_bps},${t5}:${PEAK_BPS},${t6}:${med1_bps},${t7}:${LOW_BPS}"
else
  total_duration="${RUNTIME_SECONDS:?set RUNTIME_SECONDS when providing BPS_SCHEDULE directly}"
fi
echo "==> Workload schedule (total bps): ${BPS_SCHEDULE}"
echo "==> Total duration: ${total_duration}s"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/elasticity/${RUN_ID}}"
mkdir -p "${OUT_DIR}"
echo "==> Output: ${OUT_DIR}"
{
  echo "base_shards=${BASE_SHARDS}"
  echo "num_shards=${NUM_SHARDS}"
  echo "bps_schedule=${BPS_SCHEDULE}"
} > "${OUT_DIR}/metadata.txt"

cargo_flags=()
target_dir="debug"
case "${BUILD_PROFILE}" in
  release) cargo_flags=(--release --config profile.release.debug=false); target_dir="release" ;;
  debug) ;;
  *) echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2; exit 1 ;;
esac
bin_src="${LINERA_SRC}/target/${target_dir}"

if [ "${SKIP_BUILD}" = "true" ]; then
  echo "==> [1/6] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/6] Building validator + client binaries natively (${BUILD_PROFILE})"
  ( cd "${LINERA_SRC}" && cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server )
fi

echo "==> [2/6] Deploying"
ssh "${SPARTA_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
ssh "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-server" "${bin_src}/linera-proxy" \
    "${bin_src}/linera-storage-server" "${SPARTA_HOST}:${REMOTE_DIR}/bin/"
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/run_node.sh" "${LOCAL_DIR}/scripts/stop_node.sh" "${SPARTA_HOST}:${REMOTE_DIR}/scripts/" > /dev/null
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/" > /dev/null
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/6] Starting validator: ${BASE_SHARDS} base shard(s), ${NUM_SHARDS} total slots, manager watching (high=${MANAGER_HIGH_WATERMARK} req/s)"
ssh "${SPARTA_HOST}" "pkill -9 -f 'linera-server|linera-proxy|linera-storage-server'" 2>/dev/null || true
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
sleep 2
manager_watermark_args=""
[ -n "${MANAGER_LOW_WATERMARK}" ] && manager_watermark_args="MANAGER_LOW_WATERMARK=${MANAGER_LOW_WATERMARK}"
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} \
   NUM_SHARDS=${NUM_SHARDS} BASE_SHARDS=${BASE_SHARDS} CORES_PER_SHARD=${CORES_PER_SHARD} \
   STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} START_FAUCET=false START_MANAGER=true \
   MANAGER_INTERVAL_MS=${MANAGER_INTERVAL_MS} MANAGER_HIGH_WATERMARK=${MANAGER_HIGH_WATERMARK} \
   MANAGER_MAX_MIGRATIONS_PER_ROUND=${MANAGER_MAX_MIGRATIONS_PER_ROUND} \
   MANAGER_SCALE_DOWN_ROUNDS=${MANAGER_SCALE_DOWN_ROUNDS} MANAGER_COOLDOWN_ROUNDS=${MANAGER_COOLDOWN_ROUNDS} \
   ${manager_watermark_args} \
   ${REMOTE_DIR}/scripts/run_node.sh"
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

# Clock-offset correction: manager.log's timestamps are in sparta's clock; everything else
# (experiment_start_epoch, the client's own ts_within_experiment) uses this machine's clock
# transitively (the client process starts moments after experiment_start_epoch is recorded).
sparta_epoch="$(ssh "${SPARTA_HOST}" 'date +%s')"
local_epoch="$(date +%s)"
clock_offset=$((sparta_epoch - local_epoch))
echo "${clock_offset}" > "${OUT_DIR}/sparta_clock_offset_seconds.txt"

echo "==> Relaying admin wallet + genesis config"
tmp_wallet_dir="$(mktemp -d)"
scp "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_wallet.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_keystore.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/genesis.json" "${tmp_wallet_dir}/"
scp "${tmp_wallet_dir}/admin_wallet.json" "${tmp_wallet_dir}/admin_keystore.json" \
  "${tmp_wallet_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/"
rm -rf "${tmp_wallet_dir}"

pool_size=$((NUM_CLIENTS * CHAINS_PER_CLIENT))
echo "==> [4/6] Provisioning ${pool_size} super-owner chains"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${pool_size} OUTPUT_FILE=./elasticity_chains.txt \
  ./scripts/provision_super_owner_chains.sh" > "${OUT_DIR}/provision.log" 2>&1

echo "==> [5/6] Running ${total_duration}s continuous workload"
experiment_start_epoch="$(date +%s)"
echo "${experiment_start_epoch}" > "${OUT_DIR}/experiment_start_epoch.txt"

ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  CHAIN_IDS_FILE=./elasticity_chains.txt NUM_CLIENTS=${NUM_CLIENTS} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
  BPS_SCHEDULE=${BPS_SCHEDULE} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} TRAFFIC_MODE=${TRAFFIC_MODE} \
  RUNTIME_SECONDS=${total_duration} EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=elasticity_${RUN_ID} \
  ./scripts/run_lite_benchmark_parallel.sh" > "${OUT_DIR}/run.log" 2>&1

echo "==> [6/6] Pulling results"
scp -r "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/elasticity_${RUN_ID}/client_*" "${OUT_DIR}/" > /dev/null

COMBINED_CSV="${OUT_DIR}/combined_transfers.csv"
echo "chain_id,ts_within_experiment,num_tx,result,duration_micros" > "${COMBINED_CSV}"
for csv in "${OUT_DIR}"/client_*/transfers.csv; do
  [ -f "${csv}" ] || continue
  tail -n +2 "${csv}" >> "${COMBINED_CSV}"
done

scp "${SPARTA_HOST}:${REMOTE_DIR}/state/manager.log" "${OUT_DIR}/manager.log" > /dev/null

echo "==> Done."
echo "    Combined transfers: ${COMBINED_CSV} ($(($(wc -l < "${COMBINED_CSV}") - 1)) rows)"
echo "    Manager log:        ${OUT_DIR}/manager.log"
echo "    Clock offset (sparta - local, seconds): $(cat "${OUT_DIR}/sparta_clock_offset_seconds.txt")"
