#!/usr/bin/env bash
set -euo pipefail

# Sweeps the committee size (NUM_VALIDATORS) at a *fixed* shard count, calling find_max_tps.sh
# once per validator count to find each committee's maximum sustained throughput. The
# validator-count counterpart of run_shard_count_sweep.sh, and deliberately a separate script
# rather than a generalization of it, so the shard sweep it mirrors stays untouched.
#
# What this measures, and what it does not: every validator gets its own dedicated block of
# NUM_SHARDS*CORES_PER_SHARD cores (see run_validators.sh), so per-validator resources are
# constant and the committee size is the only thing that varies. Total machine load therefore
# *grows* with the committee -- this measures the cost of replication at constant per-validator
# capacity, not the throughput of a fixed hardware budget divided n ways.
#
# Expect throughput to fall, not rise, as n grows: a block needs a quorum of signatures, and
# the quorum threshold is ceil((n + ceil(n/3)) / 2) -- n=1 -> 1, n=2 -> 2 of 2, n=3 -> 2 of 3,
# n=4 -> 3 of 4. At n=2 every request waits on both validators, so the slowest one sets the
# pace; n=3 and n=4 can each ride out one straggler.
#
# Configuration (env vars):
#   MIN_VALIDATORS, MAX_VALIDATORS  (default 1, 4)
#   VALIDATOR_LIST          explicit list, overrides MIN/MAX (e.g. "1 2 3 4")
#   NUM_SHARDS              (default 5) shards *per validator*, held fixed across the sweep
#   CORES_PER_SHARD         (default 2)
#   RESERVED_CORES          (default 0) proxies + storage-servers left unpinned
#   CHAINS_PER_CLIENT, TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, BPS_PER_CLIENT, START_CLIENTS,
#   CLIENT_STEP, CLIENT_STEP_SCHEDULE, CONFIRM_STOP_RETRIES, MAX_CLIENTS, RUNTIME_SECONDS,
#   LATENCY_DEGRADATION_FACTOR, MIN_ACHIEVED_FRACTION, FAILURES_ONLY
#                           -- passed straight through to find_max_tps.sh per validator count.
#                           Prefer CLIENT_STEP_SCHEDULE (e.g. "25 5 1") over a single
#                           CLIENT_STEP; see find_max_tps.sh for why a single coarse step
#                           quantizes the whole curve onto the search grid.
#   SKIP_BUILD, SKIP_BINARY_DEPLOY -- honored for the first validator count only; every count
#                           after that forces both true, since the binary does not depend on
#                           the committee size.
#   BUILD_PROFILE           (default release)
#   OUT_DIR                 (default ./results/tps_vs_validators/<timestamp>)
#   CLIENT_HOST, REMOTE_DIR
#
# Before running for real, check that every validator's proxy port is reachable from the
# client: clients broadcast to the whole committee and wait for a quorum, so a firewall that
# opens only the first port leaves n>1 unable to reach quorum. With the defaults that is
# PROXY_PUBLIC_PORT..PROXY_PUBLIC_PORT+MAX_VALIDATORS-1 (4001-4004).

MIN_VALIDATORS="${MIN_VALIDATORS:-1}"
MAX_VALIDATORS="${MAX_VALIDATORS:-4}"
NUM_SHARDS="${NUM_SHARDS:-5}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-0}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-20}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-100}"
START_CLIENTS="${START_CLIENTS:-1}"
CLIENT_STEP="${CLIENT_STEP:-5}"
CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE:-${CLIENT_STEP}}"
CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES:-1}"
MAX_CLIENTS="${MAX_CLIENTS:-100}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR:-3.0}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
FAILURES_ONLY="${FAILURES_ONLY:-false}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# find_max_tps.sh only grew NUM_VALIDATORS support alongside run_validators.sh. Without it,
# every validator count in this sweep would start exactly one validator and the run would
# produce a flat, entirely wrong curve -- with nothing in the output to reveal it. Refuse.
if ! grep -q 'NUM_VALIDATORS' "${LOCAL_DIR}/scripts/find_max_tps.sh"; then
  cat >&2 <<EOF
scripts/find_max_tps.sh does not support NUM_VALIDATORS yet, so every validator count would
silently start a single validator. Install the prepared version first:

    mv scripts/find_max_tps.sh.new scripts/find_max_tps.sh

(kept as a separate file so it could be written while a shard sweep was mid-run).
EOF
  exit 1
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/tps_vs_validators/${RUN_ID}}"
mkdir -p "${OUT_DIR}"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "num_validators,num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,first_bad_clients" > "${SUMMARY_CSV}"
echo "==> Output: ${OUT_DIR}"

env | sort > "${OUT_DIR}/.env"

validator_values="${VALIDATOR_LIST:-$(seq "${MIN_VALIDATORS}" "${MAX_VALIDATORS}")}"
first_iteration=true
for n in ${validator_values}; do
  quorum=$(( (n + (n + 2) / 3 + 1) / 2 ))
  echo "==================== NUM_VALIDATORS=${n} (quorum ${quorum}/${n}, ${NUM_SHARDS} shards each) $(date +%H:%M:%S) ===================="
  log="${OUT_DIR}/validators_${n}.log"
  if [ "${first_iteration}" = true ]; then
    iter_skip_build="${SKIP_BUILD}"
    iter_skip_binary_deploy="${SKIP_BINARY_DEPLOY}"
    first_iteration=false
  else
    iter_skip_build=true
    iter_skip_binary_deploy=true
  fi
  client_results_dir="${OUT_DIR}/validators_${n}_client_results"
  set +e
  BUILD_PROFILE="${BUILD_PROFILE}" \
  SKIP_BUILD="${iter_skip_build}" SKIP_BINARY_DEPLOY="${iter_skip_binary_deploy}" \
  NUM_VALIDATORS="${n}" NUM_SHARDS="${NUM_SHARDS}" \
  CORES_PER_SHARD="${CORES_PER_SHARD}" RESERVED_CORES="${RESERVED_CORES}" \
  CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT}" TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK}" \
  TRAFFIC_MODE="${TRAFFIC_MODE}" BPS_PER_CLIENT="${BPS_PER_CLIENT}" \
  START_CLIENTS="${START_CLIENTS}" CLIENT_STEP="${CLIENT_STEP}" \
  CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE}" \
  CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES}" MAX_CLIENTS="${MAX_CLIENTS}" \
  LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR}" \
  MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION}" FAILURES_ONLY="${FAILURES_ONLY}" \
  SUMMARY_CSV_PATH="${OUT_DIR}/validators_${n}_levels.csv" \
  CLIENT_ARCHIVE_DIR="${client_results_dir}" \
  RUNTIME_SECONDS="${RUNTIME_SECONDS}" CLIENT_HOST="${CLIENT_HOST}" REMOTE_DIR="${REMOTE_DIR}" \
  "${LOCAL_DIR}/scripts/find_max_tps.sh" > "${log}" 2>&1
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    echo "  find_max_tps.sh exited ${status} for NUM_VALIDATORS=${n} -- see ${log}" >&2
  fi

  # Safety net; find_max_tps.sh already harvests and deletes each level as it finishes.
  set +e
  if ssh "${CLIENT_HOST}" "[ -d ${REMOTE_DIR}/results/lite_benchmark ]" 2>/dev/null; then
    mkdir -p "${client_results_dir}"
    rsync -az --exclude='wallet.json' --exclude='keystore.json' \
      "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/" "${client_results_dir}/"
    if [ $? -eq 0 ]; then
      ssh "${CLIENT_HOST}" "rm -rf ${REMOTE_DIR}/results/lite_benchmark" \
        || echo "  warning: failed to clean up lite_benchmark on ${CLIENT_HOST} for NUM_VALIDATORS=${n}" >&2
    else
      echo "  warning: failed to fetch client results for NUM_VALIDATORS=${n}" >&2
    fi
  fi
  set -e

  set +e
  line="$(grep 'Estimated max sustained throughput:' "${log}" | sed 's/.*throughput: //')"
  first_bad="$(grep -o 'Limit bracketed to ([0-9]*, [0-9]*)' "${log}" | tail -1 | sed 's/.*, \([0-9]*\))/\1/')"
  ceiling_hit="$(grep -c 'no level failed up to the MAX_CLIENTS' "${log}")"
  set -e
  if [ -z "${line}" ]; then
    echo "  NUM_VALIDATORS=${n}: no sustained level found -- see ${log}"
    echo "${n},${NUM_SHARDS},,,,,,,,,," >> "${SUMMARY_CSV}"
    continue
  fi
  read -r num_clients requested_bps committed failed achieved_bps achieved_tps p25 p50 p95 _rest <<< "${line}"
  if [ "${ceiling_hit}" -gt 0 ]; then
    echo "  NUM_VALIDATORS=${n}: WARNING -- never saturated below MAX_CLIENTS=${MAX_CLIENTS}; this row is a lower bound" >&2
  fi
  resolution_note=""
  if [ -n "${first_bad}" ]; then
    resolution_note=" [bracket ${num_clients}..${first_bad}, +/-$(( (first_bad - num_clients) * BPS_PER_CLIENT )) bps]"
  fi
  echo "  NUM_VALIDATORS=${n}: max sustained at ${num_clients} client(s) -> ${achieved_tps} tx/s (${achieved_bps} bps), p50=${p50}ms${resolution_note}"
  echo "${n},${NUM_SHARDS},${num_clients},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25},${p50},${p95},${first_bad}" >> "${SUMMARY_CSV}"
done

echo
echo "==> Done. Summary: ${SUMMARY_CSV}"
