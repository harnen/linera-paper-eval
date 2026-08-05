#!/usr/bin/env bash
set -euo pipefail

# Finds the validator's maximum sustained throughput by ramping the number of concurrent
# linera-lite-benchmark client processes on CLIENT_HOST (each a genuinely separate OS
# process, driving its own slice of chains) until latency clearly degrades, matching the
# paper's Section VII.C methodology: latency stays flat and low until an inflection point
# (the saturation throughput), after which it rises sharply.
#
# Builds, deploys, starts the validator (optionally with shards pinned to dedicated CPU
# cores via CORES_PER_SHARD), provisions a chain pool, then for clients = 1..MAX_CLIENTS
# runs a fixed-duration burst and checks: any failures, p95 latency vs. the first level's
# baseline, and achieved vs. requested throughput. Stops at the first level that fails any
# of those checks and reports the previous level as the sustained maximum.
#
# Assumes passwordless SSH to both hosts (see deploy_and_smoke_test.sh, which this mirrors).
#
# Configuration (env vars):
#   SPARTA_ADDRESS         (default 193.60.241.98)
#   SPARTA_HOST            (default sparta)
#   CLIENT_HOST            (default yiannis-testbed)
#   REMOTE_DIR             (default linera)
#   PROXY_PUBLIC_PORT      (default 4001)
#   BUILD_PROFILE          (default debug) debug | release
#   LINERA_SRC             (default ~/work/linera/linera-protocol)
#   NUM_SHARDS             (default 19)
#   CORES_PER_SHARD        (default 2) 0 disables CPU pinning entirely
#   RESERVED_CORES         (default 2) reserved for storage-server + proxy (see run_node.sh)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default) passed straight to
#                          run_node.sh -- caps storage-server's Tokio worker-thread count
#                          independent of CPU pinning; see run_node.sh for why this matters
#                          (oversized default thread count causes excess futex/parking
#                          overhead relative to storage-server's actual per-call work)
#   CHAINS_PER_CLIENT      (default 5)
#   BPS_PER_CLIENT         (default 50)
#   TRANSACTIONS_PER_BLOCK (default 1)
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   MAX_CLIENTS            (default 20) ramp ceiling
#   RUNTIME_SECONDS        (default 20) duration of each level
#   LATENCY_DEGRADATION_FACTOR (default 3.0) stop when p95 exceeds this multiple of the
#                          first level's p95 -- ignored when FAILURES_ONLY=true
#   MIN_ACHIEVED_FRACTION  (default 0.8) stop when achieved throughput falls below this
#                          fraction of requested throughput -- ignored when FAILURES_ONLY=true
#   FAILURES_ONLY          (default false) if true, only stop the ramp when failed > 0;
#                          latency and achieved-throughput are still measured and printed,
#                          just not used to stop early. Useful when latency itself is
#                          unreliable (e.g. contention on a shared client machine) and you
#                          just want to know where things start actually breaking.
#   START_CLIENTS          (default 1) start the ramp at this client count instead of 1 --
#                          lets you re-probe a narrower, higher range quickly without
#                          re-running every lower level (the chain pool is still sized for
#                          MAX_CLIENTS regardless of where you start)
#   CLIENT_STEP            (default 1) increment client count by this much per level, to
#                          cover a wide range in fewer, coarser levels
#   STOP_NODE_AFTER        (default true)
#   SKIP_BUILD             (default false) skip `cargo build` entirely and reuse whatever's
#                          already in target/<profile> -- use when only these scripts
#                          changed, not the Rust source
#   SKIP_BINARY_DEPLOY     (default false) skip rsync'ing the (large, slow-over-this-link)
#                          binaries and reuse whatever's already on both remote hosts;
#                          scripts are still re-copied every time (cheap, and we iterate on
#                          those constantly)

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
BUILD_PROFILE="${BUILD_PROFILE:-debug}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
NUM_SHARDS="${NUM_SHARDS:-19}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-2}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
MAX_CLIENTS="${MAX_CLIENTS:-20}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-20}"
LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR:-3.0}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
FAILURES_ONLY="${FAILURES_ONLY:-false}"
START_CLIENTS="${START_CLIENTS:-1}"
CLIENT_STEP="${CLIENT_STEP:-1}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOCAL_SUMMARY_DIR="$(mktemp -d)"
SUMMARY_CSV="${LOCAL_SUMMARY_DIR}/max_tps_summary.csv"
echo "num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,sparta_reserved_cpu_pct,sparta_shard_cpu_pct,client_cpu_pct" > "${SUMMARY_CSV}"

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
  (
    cd "${LINERA_SRC}"
    cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server
  )
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
  "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/5] Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores + ${RESERVED_CORES} reserved"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} \
   NUM_SHARDS=${NUM_SHARDS} CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} \
   STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} START_FAUCET=false \
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

echo "==> Relaying admin wallet + genesis config: ${SPARTA_HOST} -> here -> ${CLIENT_HOST}"
tmp_wallet_dir="$(mktemp -d)"
scp "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_wallet.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_keystore.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/genesis.json" "${tmp_wallet_dir}/"
scp "${tmp_wallet_dir}/admin_wallet.json" "${tmp_wallet_dir}/admin_keystore.json" \
  "${tmp_wallet_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/"
rm -rf "${tmp_wallet_dir}"

pool_size=$((MAX_CLIENTS * CHAINS_PER_CLIENT))
echo "==> [4/5] Provisioning ${pool_size} super-owner chains on ${CLIENT_HOST} (enough for ${MAX_CLIENTS} clients x ${CHAINS_PER_CLIENT} chains)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${pool_size} OUTPUT_FILE=./chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh"

# Percentile of a newline-separated, ascending-sorted numeric file. Empty file -> empty output.
percentile() {
  local file="$1" pct="$2" n idx
  n="$(wc -l < "${file}")"
  [ "${n}" -eq 0 ] && return
  idx=$(( (pct * n + 99) / 100 ))
  [ "${idx}" -lt 1 ] && idx=1
  [ "${idx}" -gt "${n}" ] && idx="${n}"
  sed -n "${idx}p" "${file}"
}

# Per-core /proc/stat lines (not just the aggregate "cpu " one), so a before/after pair
# lets us tell apart the proxy+storage-server cores (0..RESERVED_CORES-1) from the shard
# cores -- an aggregate-only average can easily hide a single hot pair of cores. Also used
# as a plain aggregate for the client host, where we don't have a core-range breakdown.
read_cpu_stat_all() {
  timeout 5 ssh "$1" "grep '^cpu' /proc/stat" 2>/dev/null
}

cpu_range_utilization_pct() {
  awk -v b="$1" -v a="$2" -v s="$3" -v e="$4" '
    function accumulate(text, tot, idl,    nlines, lines, i, n, fields, nf, core, j) {
      nlines = split(text, lines, "\n")
      for (i = 1; i <= nlines; i++) {
        if (lines[i] == "") continue
        nf = split(lines[i], fields, " ")
        core = fields[1]
        sub(/^cpu/, "", core)
        if (core == "") continue
        n = core + 0
        if (n < s || n > e) continue
        for (j = 2; j <= nf; j++) tot[n] += fields[j]
        idl[n] = fields[5] + fields[6]
      }
    }
    BEGIN {
      if (b == "" || a == "") { print "NaN"; exit }
      accumulate(b, bt, bi)
      accumulate(a, at, ai)
      dt = 0; di = 0
      for (n = s; n <= e; n++) {
        dt += (at[n] - bt[n])
        di += (ai[n] - bi[n])
      }
      if (dt <= 0) { print "0.0"; exit }
      printf "%.1f", 100 * (1 - di / dt)
    }
  '
}

shard_cores_end=$((RESERVED_CORES + NUM_SHARDS * CORES_PER_SHARD - 1))

echo "==> [5/5] Ramping clients (traffic-mode=${TRAFFIC_MODE}, ${RUNTIME_SECONDS}s per level)"
printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-14s %-13s %-12s\n" \
  "clients" "requested_bps" "committed" "failed" "achieved_bps" "achieved_tps" \
  "p25_ms" "p50_ms" "p95_ms" "sparta_rsvd%" "sparta_shard%" "client_cpu%"

baseline_p95=""
max_good_clients=0
declare -A LEVEL_LINE

for n in $(seq "${START_CLIENTS}" "${CLIENT_STEP}" "${MAX_CLIENTS}"); do
  requested_bps=$((n * BPS_PER_CLIENT))
  experiment_name="level_${RUN_ID}_${n}"

  sparta_stat_before="$(read_cpu_stat_all "${SPARTA_HOST}")"
  client_stat_before="$(read_cpu_stat_all "${CLIENT_HOST}")"
  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=${n} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
    BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
    TRAFFIC_MODE=${TRAFFIC_MODE} RUNTIME_SECONDS=${RUNTIME_SECONDS} \
    EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name} \
    ./scripts/run_lite_benchmark_parallel.sh" > /dev/null
  sparta_stat_after="$(read_cpu_stat_all "${SPARTA_HOST}")"
  client_stat_after="$(read_cpu_stat_all "${CLIENT_HOST}")"
  sparta_reserved_pct="$(cpu_range_utilization_pct "${sparta_stat_before}" "${sparta_stat_after}" 0 $((RESERVED_CORES - 1)))"
  sparta_shard_pct="$(cpu_range_utilization_pct "${sparta_stat_before}" "${sparta_stat_after}" "${RESERVED_CORES}" "${shard_cores_end}")"
  client_cpu_pct="$(cpu_range_utilization_pct "${client_stat_before}" "${client_stat_after}" 0 9999)"

  level_dir="$(mktemp -d)"
  scp -r "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/${experiment_name}/client_*" "${level_dir}/" > /dev/null

  durations_file="${level_dir}/durations.txt"
  : > "${durations_file}"
  committed=0
  failed=0
  total_tx=0
  for csv in "${level_dir}"/client_*/transfers.csv; do
    [ -f "${csv}" ] || continue
    committed=$((committed + $(awk -F, 'NR>1 && $4=="committed"' "${csv}" | wc -l)))
    failed=$((failed + $(awk -F, 'NR>1 && $4=="failed"' "${csv}" | wc -l)))
    total_tx=$((total_tx + $(awk -F, 'NR>1 && $4=="committed" {s+=$3} END{print s+0}' "${csv}")))
    awk -F, 'NR>1 && $4=="committed" { print $5 }' "${csv}" >> "${durations_file}"
  done
  sort -n -o "${durations_file}" "${durations_file}"

  p25_us="$(percentile "${durations_file}" 25)"
  p50_us="$(percentile "${durations_file}" 50)"
  p95_us="$(percentile "${durations_file}" 95)"
  p25_ms="$(awk -v v="${p25_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p50_ms="$(awk -v v="${p50_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p95_ms="$(awk -v v="${p95_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  # "achieved_tps" here is transactions/sec (committed blocks x their tx count) -- the
  # figure this feeds wants real TPS, not blocks/sec. achieved_bps (blocks/sec) is kept
  # too since the ramp's own stop conditions below compare against requested_bps.
  achieved_bps="$(awk -v c="${committed}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"
  achieved_tps="$(awk -v c="${total_tx}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"

  row="$(printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-14s %-13s %-12s" \
    "${n}" "${requested_bps}" "${committed}" "${failed}" "${achieved_bps}" "${achieved_tps}" \
    "${p25_ms}" "${p50_ms}" "${p95_ms}" "${sparta_reserved_pct}" "${sparta_shard_pct}" "${client_cpu_pct}")"
  echo "${row}"
  echo "${n},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25_ms},${p50_ms},${p95_ms},${sparta_reserved_pct},${sparta_shard_pct},${client_cpu_pct}" >> "${SUMMARY_CSV}"
  LEVEL_LINE[$n]="${row}"

  rm -rf "${level_dir}"

  if [ "${n}" -eq "${START_CLIENTS}" ]; then
    baseline_p95="${p95_ms}"
  fi

  stop_reason=""
  if [ "${failed}" -gt 0 ]; then
    stop_reason="${failed} failed block(s)"
  elif [ "${FAILURES_ONLY}" != "true" ] && awk -v p="${p95_ms}" -v b="${baseline_p95}" -v f="${LATENCY_DEGRADATION_FACTOR}" 'BEGIN{exit !(b>0 && p>b*f)}'; then
    stop_reason="p95 latency ${p95_ms}ms exceeds ${LATENCY_DEGRADATION_FACTOR}x baseline (${baseline_p95}ms)"
  elif [ "${FAILURES_ONLY}" != "true" ] && awk -v a="${achieved_bps}" -v r="${requested_bps}" -v f="${MIN_ACHIEVED_FRACTION}" 'BEGIN{exit !(a < r*f)}'; then
    stop_reason="achieved ${achieved_bps} BPS is below ${MIN_ACHIEVED_FRACTION}x requested ${requested_bps}"
  fi

  if [ -n "${stop_reason}" ]; then
    echo
    echo "==> Stopping ramp at ${n} client(s): ${stop_reason}"
    break
  fi
  max_good_clients="${n}"
done

echo
if [ "${max_good_clients}" -eq 0 ]; then
  echo "==> Even a single client showed degraded/failed behavior -- see ${SUMMARY_CSV}"
else
  echo "==> Estimated max sustained throughput: ${LEVEL_LINE[${max_good_clients}]}"
fi
echo "==> Full per-level results: ${SUMMARY_CSV}"
