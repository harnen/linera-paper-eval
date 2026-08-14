#!/usr/bin/env bash
set -euo pipefail

# Runs run_validator_count_sweep.sh ITERATIONS times, so each validator count ends up with a
# distribution of max-sustained-throughput measurements rather than a single sample. The
# validator-count counterpart of run_repeated_shard_sweep.sh; see that script for the
# reasoning behind repeating at the *sweep* level and shuffling the order within each
# iteration (both apply here unchanged).
#
# Resumable: each iteration writes to OUT_DIR/iter_NN/ and is marked complete only when its
# sweep returns. Re-running with the same OUT_DIR skips completed iterations.
#
# Configuration (env vars):
#   ITERATIONS            (default 10)
#   OUT_DIR               (default ./results/tps_vs_validators_repeated/<timestamp>) set to an
#                          existing run's directory to resume it
#   SHUFFLE_VALIDATOR_ORDER (default true) shuffle each iteration's validator-count order, so
#                          drift over the hours an iteration takes shows up as spread rather
#                          than masquerading as an effect of committee size
#   VALIDATOR_LIST        (default: seq MIN_VALIDATORS..MAX_VALIDATORS)
#   MIN_VALIDATORS, MAX_VALIDATORS, NUM_SHARDS, CORES_PER_SHARD, RESERVED_CORES,
#   CHAINS_PER_CLIENT, TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, BPS_PER_CLIENT, START_CLIENTS,
#   MAX_CLIENTS, CLIENT_STEP_SCHEDULE, CONFIRM_STOP_RETRIES, RUNTIME_SECONDS, BUILD_PROFILE,
#   CLIENT_HOST, REMOTE_DIR -- passed through to run_validator_count_sweep.sh
#   SKIP_BUILD, SKIP_BINARY_DEPLOY -- honored for the first iteration only
#
# Outputs, all under OUT_DIR:
#   iter_NN/              a full run_validator_count_sweep.sh output tree per iteration
#   all_iterations.csv    every iteration's summary rows in tidy long format, one row per
#                          (iteration, num_validators) -- the file to load for analysis. No
#                          statistics are computed here on purpose.

ITERATIONS="${ITERATIONS:-10}"
SHUFFLE_VALIDATOR_ORDER="${SHUFFLE_VALIDATOR_ORDER:-true}"
MIN_VALIDATORS="${MIN_VALIDATORS:-1}"
MAX_VALIDATORS="${MAX_VALIDATORS:-4}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/tps_vs_validators_repeated/${RUN_ID}}"
mkdir -p "${OUT_DIR}"

ALL_CSV="${OUT_DIR}/all_iterations.csv"
base_validator_list="${VALIDATOR_LIST:-$(seq "${MIN_VALIDATORS}" "${MAX_VALIDATORS}")}"

echo "==> Repeated validator sweep: ${ITERATIONS} iteration(s) over committees [${base_validator_list//$'\n'/ }]"
echo "==> Output: ${OUT_DIR}"
env | sort > "${OUT_DIR}/.env"

rebuild_all_csv() {
  echo "iteration,num_validators,num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,first_bad_clients" > "${ALL_CSV}"
  local d iter
  for d in "${OUT_DIR}"/iter_*/; do
    [ -f "${d}/summary.csv" ] || continue
    [ -f "${d}/.complete" ] || continue
    iter="$(basename "${d}" | sed 's/^iter_//')"
    tail -n +2 "${d}/summary.csv" | sed "s/^/${iter},/" >> "${ALL_CSV}"
  done
}

for i in $(seq 1 "${ITERATIONS}"); do
  iter_dir="$(printf "%s/iter_%02d" "${OUT_DIR}" "${i}")"
  if [ -f "${iter_dir}/.complete" ]; then
    echo "==> Iteration ${i}/${ITERATIONS} already complete -- skipping (resume)"
    continue
  fi
  rm -rf "${iter_dir}"

  iter_validator_list="${base_validator_list}"
  if [ "${SHUFFLE_VALIDATOR_ORDER}" = "true" ]; then
    iter_validator_list="$(printf '%s\n' ${base_validator_list} | shuf | tr '\n' ' ')"
  fi

  if [ "${i}" -eq 1 ]; then
    iter_skip_build="${SKIP_BUILD}"
    iter_skip_deploy="${SKIP_BINARY_DEPLOY}"
  else
    iter_skip_build=true
    iter_skip_deploy=true
  fi

  echo
  echo "############################################################"
  echo "# Iteration ${i}/${ITERATIONS}  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "# validator order: ${iter_validator_list}"
  echo "############################################################"

  iter_start="$(date +%s)"
  set +e
  OUT_DIR="${iter_dir}" VALIDATOR_LIST="${iter_validator_list}" \
  SKIP_BUILD="${iter_skip_build}" SKIP_BINARY_DEPLOY="${iter_skip_deploy}" \
    "${LOCAL_DIR}/scripts/run_validator_count_sweep.sh"
  status=$?
  set -e
  iter_seconds=$(( $(date +%s) - iter_start ))

  if [ "${status}" -ne 0 ]; then
    echo "==> Iteration ${i} exited ${status} after ${iter_seconds}s -- NOT marking complete" >&2
    echo "    (re-run with OUT_DIR=${OUT_DIR} to retry just this iteration)" >&2
  else
    touch "${iter_dir}/.complete"
    echo "==> Iteration ${i}/${ITERATIONS} done in $((iter_seconds / 60))m$((iter_seconds % 60))s"
  fi

  rebuild_all_csv
done

echo
echo "==> Done. ${ITERATIONS} iteration(s)."
echo "    Tidy long-format rows for analysis: ${ALL_CSV}"
echo "    $(( $(wc -l < "${ALL_CSV}") - 1 )) observation(s) from $(find "${OUT_DIR}" -maxdepth 2 -name .complete | wc -l) completed iteration(s)"
