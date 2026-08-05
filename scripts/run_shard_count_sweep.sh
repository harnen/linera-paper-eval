#!/usr/bin/env bash
set -euo pipefail

# Sweeps NUM_SHARDS from MIN_SHARDS to MAX_SHARDS, each shard pinned to CORES_PER_SHARD
# cores (default 2 -- "each worker gets at most 2 cores"), calling find_max_tps.sh once per
# shard count to find its own maximum sustained throughput. Produces the input CSV for
# scripts/plot_tps_vs_shards.py: does max TPS scale ~linearly with worker count?
#
# Reuses find_max_tps.sh's own ramp + stop-condition logic unchanged (latency degradation
# factor / min achieved fraction / failures) rather than reimplementing it -- this script is
# just a driver that loops shard counts and harvests each run's "Estimated max sustained
# throughput" line.
#
# Default core budget: CORES_PER_SHARD=2, RESERVED_CORES=2 (proxy), STORAGE_CORES=0 (storage
# shares the proxy's small range, the simplest/default run_node.sh behavior) -- so
# MAX_SHARDS*CORES_PER_SHARD + RESERVED_CORES must not exceed this machine's core count;
# with the defaults, MAX_SHARDS=19 uses exactly 19*2+2=40 cores on sparta.
#
# Configuration (env vars):
#   MIN_SHARDS, MAX_SHARDS  (default 1, 19)
#   CORES_PER_SHARD         (default 2)
#   RESERVED_CORES          (default 2)
#   CHAINS_PER_CLIENT, TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, BPS_PER_CLIENT, START_CLIENTS,
#   CLIENT_STEP, MAX_CLIENTS, RUNTIME_SECONDS -- passed straight through to find_max_tps.sh
#   per shard count (defaults here are deliberately short/coarse -- RUNTIME_SECONDS=8,
#   CLIENT_STEP=2 -- since this runs the ramp up to MAX_SHARDS-MIN_SHARDS+1 times)
#   BUILD_PROFILE           (default release)
#   OUT_DIR                 (default ./results/tps_vs_shards/<timestamp>)

MIN_SHARDS="${MIN_SHARDS:-1}"
MAX_SHARDS="${MAX_SHARDS:-19}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-2}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-10}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
START_CLIENTS="${START_CLIENTS:-1}"
CLIENT_STEP="${CLIENT_STEP:-2}"
MAX_CLIENTS="${MAX_CLIENTS:-40}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-8}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/tps_vs_shards/${RUN_ID}}"
mkdir -p "${OUT_DIR}"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms" > "${SUMMARY_CSV}"
echo "==> Output: ${OUT_DIR}"

skip_build="false"
shard_values="${SHARD_LIST:-$(seq "${MIN_SHARDS}" "${MAX_SHARDS}")}"
for n in ${shard_values}; do
  echo "==================== NUM_SHARDS=${n} ($(date +%H:%M:%S)) ===================="
  log="${OUT_DIR}/shards_${n}.log"
  set +e
  SKIP_BUILD="${skip_build}" SKIP_BINARY_DEPLOY="${skip_build}" \
  BUILD_PROFILE="${BUILD_PROFILE}" \
  NUM_SHARDS="${n}" CORES_PER_SHARD="${CORES_PER_SHARD}" RESERVED_CORES="${RESERVED_CORES}" \
  CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT}" TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK}" \
  TRAFFIC_MODE="${TRAFFIC_MODE}" BPS_PER_CLIENT="${BPS_PER_CLIENT}" \
  START_CLIENTS="${START_CLIENTS}" CLIENT_STEP="${CLIENT_STEP}" MAX_CLIENTS="${MAX_CLIENTS}" \
  RUNTIME_SECONDS="${RUNTIME_SECONDS}" \
  "${LOCAL_DIR}/scripts/find_max_tps.sh" > "${log}" 2>&1
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    echo "  find_max_tps.sh exited ${status} for NUM_SHARDS=${n} -- see ${log}" >&2
  fi
  skip_build="true"  # binaries are unchanged across iterations; only the first needs a build+deploy

  set +e
  line="$(grep 'Estimated max sustained throughput:' "${log}" | sed 's/.*throughput: //')"
  set -e
  if [ -z "${line}" ]; then
    echo "  NUM_SHARDS=${n}: no sustained level found (even the first client count degraded/failed) -- see ${log}"
    echo "${n},,,,,,,,,," >> "${SUMMARY_CSV}"
    continue
  fi
  read -r num_clients requested_bps committed failed achieved_bps achieved_tps p25 p50 p95 _rest <<< "${line}"
  echo "  NUM_SHARDS=${n}: max sustained at ${num_clients} client(s) -> ${achieved_tps} tx/s (${achieved_bps} bps), p50=${p50}ms"
  echo "${n},${num_clients},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25},${p50},${p95}" >> "${SUMMARY_CSV}"
done

echo
echo "==> Done. Summary: ${SUMMARY_CSV}"
