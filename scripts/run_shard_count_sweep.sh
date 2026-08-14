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
# shares the proxy's small range, the simplest/default run_validators.sh behavior) -- so
# MAX_SHARDS*CORES_PER_SHARD + RESERVED_CORES must not exceed this machine's core count;
# with the defaults, MAX_SHARDS=19 uses exactly 19*2+2=40 cores on sparta.
#
# Configuration (env vars):
#   MIN_SHARDS, MAX_SHARDS  (default 1, 19)
#   CORES_PER_SHARD         (default 2)
#   RESERVED_CORES          (default 2)
#   CHAINS_PER_CLIENT, TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, BPS_PER_CLIENT, START_CLIENTS,
#   CLIENT_STEP, CLIENT_STEP_SCHEDULE, CONFIRM_STOP_RETRIES, MAX_CLIENTS, RUNTIME_SECONDS,
#   LATENCY_DEGRADATION_FACTOR, MIN_ACHIEVED_FRACTION, FAILURES_ONLY -- passed straight
#   through to find_max_tps.sh per shard count (defaults here are deliberately short/coarse
#   -- RUNTIME_SECONDS=8, CLIENT_STEP=2 -- since this runs the ramp up to
#   MAX_SHARDS-MIN_SHARDS+1 times)
#
#   Prefer CLIENT_STEP_SCHEDULE (e.g. "25 5 1") over a single CLIENT_STEP here: a single
#   coarse step quantizes every shard count's answer onto the same
#   START_CLIENTS + k*CLIENT_STEP grid, which turns this script's whole output -- a TPS
#   vs. shard-count curve -- into a staircase whose step height is an artifact of the search,
#   not a property of the system. See find_max_tps.sh for the details.
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
# Raw client output (transfers.csv + logs) is harvested off CLIENT_HOST into
# OUT_DIR/shards_<n>_client_results/ by find_max_tps.sh itself, one level at a time, as each
# level finishes (CLIENT_ARCHIVE_DIR/CLEAN_LEVEL_ON_CLIENT). That per-level cadence is what
# bounds CLIENT_HOST's disk use to a single level; harvesting only once per shard count is
# not enough, because a single ramp can write more than the client's (ramdisk-backed) results
# dir holds -- and when it does, the failure surfaces mid-level as a `cp: No space left on
# device` that takes out every remaining shard count in the sweep. The end-of-shard-count
# sweep below is kept only as a safety net for anything a level failed to harvest.
#
# Per-level CSVs (every load level probed, not just the winning one) are written to
# OUT_DIR/shards_<n>_levels.csv -- that is the load-vs-latency curve behind each summary row.

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
CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE:-${CLIENT_STEP}}"
CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES:-1}"
MAX_CLIENTS="${MAX_CLIENTS:-40}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-8}"
LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR:-3.0}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
FAILURES_ONLY="${FAILURES_ONLY:-false}"
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
# first_bad_clients is the lowest client count that failed, so (num_clients, first_bad_clients)
# brackets the true limit and (first_bad - num_clients) * BPS_PER_CLIENT is this row's
# measurement resolution -- worth recording alongside the estimate rather than inferring it
# from the step schedule after the fact.
echo "num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,first_bad_clients" > "${SUMMARY_CSV}"
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
  client_results_dir="${OUT_DIR}/shards_${n}_client_results"
  set +e
  BUILD_PROFILE="${BUILD_PROFILE}" \
  SKIP_BUILD="${iter_skip_build}" SKIP_BINARY_DEPLOY="${iter_skip_binary_deploy}" \
  NUM_SHARDS="${n}" CORES_PER_SHARD="${CORES_PER_SHARD}" RESERVED_CORES="${RESERVED_CORES}" \
  CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT}" TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK}" \
  TRAFFIC_MODE="${TRAFFIC_MODE}" BPS_PER_CLIENT="${BPS_PER_CLIENT}" \
  START_CLIENTS="${START_CLIENTS}" CLIENT_STEP="${CLIENT_STEP}" \
  CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE}" \
  CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES}" MAX_CLIENTS="${MAX_CLIENTS}" \
  LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR}" \
  MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION}" FAILURES_ONLY="${FAILURES_ONLY}" \
  SUMMARY_CSV_PATH="${OUT_DIR}/shards_${n}_levels.csv" \
  CLIENT_ARCHIVE_DIR="${client_results_dir}" \
  RUNTIME_SECONDS="${RUNTIME_SECONDS}" CLIENT_HOST="${CLIENT_HOST}" REMOTE_DIR="${REMOTE_DIR}" \
  "${LOCAL_DIR}/scripts/find_max_tps.sh" > "${log}" 2>&1
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    echo "  find_max_tps.sh exited ${status} for NUM_SHARDS=${n} -- see ${log}" >&2
  fi

  # Safety net only: find_max_tps.sh already harvests and deletes each level as it finishes,
  # so this normally finds an empty directory. It still runs so that a level whose own
  # harvest failed (or a run that predates per-level cleanup) can't leak onto the client's
  # ramdisk. Wallet/keystore copies are excluded for the same reason they are excluded there.
  set +e
  if ssh "${CLIENT_HOST}" "[ -d ${REMOTE_DIR}/results/lite_benchmark ]" 2>/dev/null; then
    mkdir -p "${client_results_dir}"
    rsync -az --exclude='wallet.json' --exclude='keystore.json' \
      "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/" "${client_results_dir}/"
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
  # "==> Limit bracketed to (96, 101) clients: ..." -> 101. Absent when the ramp hit the
  # MAX_CLIENTS ceiling without any level failing, in which case the limit is un-bracketed
  # above and the row is flagged by the warning check below.
  first_bad="$(grep -o 'Limit bracketed to ([0-9]*, [0-9]*)' "${log}" | tail -1 | sed 's/.*, \([0-9]*\))/\1/')"
  ceiling_hit="$(grep -c 'no level failed up to the MAX_CLIENTS' "${log}")"
  set -e
  if [ -z "${line}" ]; then
    echo "  NUM_SHARDS=${n}: no sustained level found (even the first client count degraded/failed) -- see ${log}"
    echo "${n},,,,,,,,,," >> "${SUMMARY_CSV}"
    continue
  fi
  read -r num_clients requested_bps committed failed achieved_bps achieved_tps p25 p50 p95 _rest <<< "${line}"
  if [ "${ceiling_hit}" -gt 0 ]; then
    echo "  NUM_SHARDS=${n}: WARNING -- never saturated below MAX_CLIENTS=${MAX_CLIENTS}; this row is a lower bound, not a maximum" >&2
  fi
  resolution_note=""
  if [ -n "${first_bad}" ]; then
    resolution_note=" [bracket ${num_clients}..${first_bad}, +/-$(( (first_bad - num_clients) * BPS_PER_CLIENT )) bps]"
  fi
  echo "  NUM_SHARDS=${n}: max sustained at ${num_clients} client(s) -> ${achieved_tps} tx/s (${achieved_bps} bps), p50=${p50}ms${resolution_note}"
  echo "${n},${num_clients},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25},${p50},${p95},${first_bad}" >> "${SUMMARY_CSV}"
done

echo
echo "==> Done. Summary: ${SUMMARY_CSV}"
