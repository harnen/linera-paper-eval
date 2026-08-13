#!/usr/bin/env bash
set -euo pipefail

# Runs run_shard_count_sweep.sh ITERATIONS times over the same shard-count range, so each
# shard count ends up with a *distribution* of max-sustained-throughput measurements rather
# than the single sample a one-shot sweep gives you. Produces the mean/stddev/CI table and
# the long-format CSV behind it.
#
# Why repeat the whole sweep rather than repeat each shard count back-to-back: consecutive
# runs of the same shard count share whatever the machine happened to be doing at that
# moment (a cron job, page-cache state, another tenant, thermal state). Repeating at the
# *sweep* level puts hours between a shard count's repeats, so those effects show up as
# spread across iterations -- which the error bars then honestly report -- instead of as a
# suspiciously tight cluster that hides a systematic offset.
#
# By default the shard order within each iteration is shuffled (SHUFFLE_SHARD_ORDER), for
# the same reason: swept in a fixed 1..20 order every time, any drift over the ~3h an
# iteration takes is perfectly confounded with shard count, and would masquerade as a
# scaling effect (e.g. a machine that slows down over time makes scaling look sublinear).
# Shuffling converts that confound into noise the error bars capture.
#
# Resumable: each iteration writes to its own OUT_DIR/iter_NN/ and is marked complete only
# when its sweep returns. Re-running with the same OUT_DIR skips completed iterations, so a
# multi-day run survives an interrupted session -- point OUT_DIR at the existing directory.
# Aggregates are recomputed after every iteration, so partial results are always usable.
#
# Configuration (env vars):
#   ITERATIONS            (default 10) how many full sweeps to run
#   OUT_DIR               (default ./results/tps_vs_shards_repeated/<timestamp>) set this to
#                          an existing run's directory to resume it
#   SHUFFLE_SHARD_ORDER   (default true) shuffle each iteration's shard-count order
#   SHARD_LIST            (default: seq MIN_SHARDS..MAX_SHARDS) explicit shard counts
#   MIN_SHARDS, MAX_SHARDS, CORES_PER_SHARD, RESERVED_CORES, CHAINS_PER_CLIENT,
#   TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, BPS_PER_CLIENT, START_CLIENTS, MAX_CLIENTS,
#   CLIENT_STEP_SCHEDULE, CONFIRM_STOP_RETRIES, RUNTIME_SECONDS, LATENCY_DEGRADATION_FACTOR,
#   MIN_ACHIEVED_FRACTION, FAILURES_ONLY, BUILD_PROFILE, CLIENT_HOST, REMOTE_DIR
#                         -- all passed straight through to run_shard_count_sweep.sh
#   SKIP_BUILD, SKIP_BINARY_DEPLOY
#                         -- honored for the first iteration only; every later iteration
#                            forces both true, since nothing about the binary changes
#                            between iterations
#
# Outputs, all under OUT_DIR:
#   iter_NN/              a full run_shard_count_sweep.sh output tree per iteration
#   all_iterations.csv    every iteration's summary rows in tidy long format, one row per
#                          (iteration, num_shards), iteration-tagged -- the file to load for
#                          analysis. No statistics are computed here on purpose: the
#                          per-observation rows are what the analysis wants, and aggregating
#                          in the measurement harness would only throw them away.
#   iter_NN/shards_<n>_levels.csv
#                         every individual load level probed for that shard count (the full
#                          load-vs-latency curve, not just the winning level)

ITERATIONS="${ITERATIONS:-10}"
SHUFFLE_SHARD_ORDER="${SHUFFLE_SHARD_ORDER:-true}"
MIN_SHARDS="${MIN_SHARDS:-1}"
MAX_SHARDS="${MAX_SHARDS:-19}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/tps_vs_shards_repeated/${RUN_ID}}"
mkdir -p "${OUT_DIR}"

ALL_CSV="${OUT_DIR}/all_iterations.csv"

base_shard_list="${SHARD_LIST:-$(seq "${MIN_SHARDS}" "${MAX_SHARDS}")}"

echo "==> Repeated shard sweep: ${ITERATIONS} iteration(s) over shards [${base_shard_list//$'\n'/ }]"
echo "==> Output: ${OUT_DIR}"
env | sort > "${OUT_DIR}/.env"

# Rebuilt from scratch on every (re)start so that resuming never double-counts an iteration
# that was already folded in, and so a re-run picks up iterations added since.
rebuild_all_csv() {
  echo "iteration,num_shards,num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,first_bad_clients" > "${ALL_CSV}"
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

  iter_shard_list="${base_shard_list}"
  if [ "${SHUFFLE_SHARD_ORDER}" = "true" ]; then
    iter_shard_list="$(printf '%s\n' ${base_shard_list} | shuf | tr '\n' ' ')"
  fi

  # Only the very first iteration can need a build/deploy; the binary is identical across
  # iterations, and re-rsync'ing it over a slow link 10 times is pure overhead.
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
  echo "# shard order: ${iter_shard_list}"
  echo "############################################################"

  iter_start="$(date +%s)"
  set +e
  OUT_DIR="${iter_dir}" SHARD_LIST="${iter_shard_list}" \
  SKIP_BUILD="${iter_skip_build}" SKIP_BINARY_DEPLOY="${iter_skip_deploy}" \
    "${LOCAL_DIR}/scripts/run_shard_count_sweep.sh"
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

  # Rebuilt after every iteration, so an interrupted run still leaves a complete,
  # analysis-ready CSV of whatever finished.
  rebuild_all_csv
done

echo
echo "==> Done. ${ITERATIONS} iteration(s)."
echo "    Tidy long-format rows for analysis: ${ALL_CSV}"
echo "    $(( $(wc -l < "${ALL_CSV}") - 1 )) observation(s) from $(find "${OUT_DIR}" -maxdepth 2 -name .complete | wc -l) completed iteration(s)"
