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
#   SKIP_BUILD, SKIP_BINARY_DEPLOY -- passed through to find_max_tps.sh as given, but only for
#                            the first shard count in the sweep; every shard count after that
#                            forces both to true, since the binary doesn't depend on NUM_SHARDS
#                            and is already built/deployed after the first iteration.
#   BUILD_PROFILE           (default release)
#   OUT_DIR                 (default ./results/tps_vs_shards/<timestamp>)
#   CLIENT_HOST             (default yiannis-testbed) -- must match find_max_tps.sh's own
#                            default/override, since this script fetches from and then wipes
#                            ${REMOTE_DIR}/results/lite_benchmark on this host after every
#                            shard count (see below)
#   REMOTE_DIR              (default linera) -- ditto
#
# find_max_tps.sh writes every ramp level's raw client output (wallet/keystore copies,
# transfers.csv, logs) under ${REMOTE_DIR}/results/lite_benchmark/ on CLIENT_HOST and never
# deletes it -- fine for a single find_max_tps.sh run, but across a full shard sweep (many
# shard counts x many ramp levels each) it silently fills up CLIENT_HOST's disk (typically a
# ramdisk there). So after each shard count's ramp finishes, this script rsyncs that directory
# down to OUT_DIR/shards_<n>_client_results/ (on the machine this script is launched from) and
# then removes it from CLIENT_HOST, keeping the client host's disk usage bounded regardless of
# sweep length.

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
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/tps_vs_shards/${RUN_ID}}"
mkdir -p "${OUT_DIR}"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms" > "${SUMMARY_CSV}"
echo "==> Output: ${OUT_DIR}"

# Save experiment config
env > "${OUT_DIR}/.env"

shard_values="${SHARD_LIST:-$(seq "${MIN_SHARDS}" "${MAX_SHARDS}")}"
first_iteration=true
for n in ${shard_values}; do
  echo "==================== NUM_SHARDS=${n} ($(date +%H:%M:%S)) ===================="
  log="${OUT_DIR}/shards_${n}.log"
  if [ "${first_iteration}" = true ]; then
    iter_skip_build="${SKIP_BUILD}"
    iter_skip_binary_deploy="${SKIP_BINARY_DEPLOY}"
    first_iteration=false
  else
    # Binary doesn't depend on NUM_SHARDS -- already built/deployed by the first iteration.
    iter_skip_build=true
    iter_skip_binary_deploy=true
  fi
  set +e
  BUILD_PROFILE="${BUILD_PROFILE}" \
  SKIP_BUILD="${iter_skip_build}" SKIP_BINARY_DEPLOY="${iter_skip_binary_deploy}" \
  NUM_SHARDS="${n}" CORES_PER_SHARD="${CORES_PER_SHARD}" RESERVED_CORES="${RESERVED_CORES}" \
  CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT}" TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK}" \
  TRAFFIC_MODE="${TRAFFIC_MODE}" BPS_PER_CLIENT="${BPS_PER_CLIENT}" \
  START_CLIENTS="${START_CLIENTS}" CLIENT_STEP="${CLIENT_STEP}" MAX_CLIENTS="${MAX_CLIENTS}" \
  RUNTIME_SECONDS="${RUNTIME_SECONDS}" CLIENT_HOST="${CLIENT_HOST}" REMOTE_DIR="${REMOTE_DIR}" \
  "${LOCAL_DIR}/scripts/find_max_tps.sh" > "${log}" 2>&1
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    echo "  find_max_tps.sh exited ${status} for NUM_SHARDS=${n} -- see ${log}" >&2
  fi

  # Pull this shard count's raw client results off CLIENT_HOST's disk and free it there,
  # so a long sweep doesn't fill up the client's (typically ramdisk-backed) storage.
  client_results_dir="${OUT_DIR}/shards_${n}_client_results"
  set +e
  if ssh "${CLIENT_HOST}" "[ -d ${REMOTE_DIR}/results/lite_benchmark ]" 2>/dev/null; then
    mkdir -p "${client_results_dir}"
    rsync -az "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/" "${client_results_dir}/"
    if [ $? -eq 0 ]; then
      ssh "${CLIENT_HOST}" "rm -rf ${REMOTE_DIR}/results/lite_benchmark"
      if [ $? -ne 0 ]; then
        echo "  warning: failed to clean up ${REMOTE_DIR}/results/lite_benchmark on ${CLIENT_HOST} for NUM_SHARDS=${n}" >&2
      fi
    else
      echo "  warning: failed to fetch client results for NUM_SHARDS=${n} from ${CLIENT_HOST} -- leaving them in place" >&2
    fi
  fi
  set -e

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
