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
#   NUM_SHARDS             (default 19) shards *per validator*
#   NUM_VALIDATORS         (default 1) committee size. The validator(s) are always started by
#                          run_validators.sh, for every count including 1 -- so an n=1 baseline
#                          and the n>1 points of a validator sweep come from the same code
#                          path, rather than from two different launchers.
#   CORES_PER_SHARD        (default 2) 0 disables CPU pinning entirely. Each validator gets its
#                          own non-overlapping block of NUM_SHARDS*CORES_PER_SHARD cores, so
#                          per-validator CPU is constant as the committee grows.
#   RESERVED_CORES         (default 2) reserved for storage-server + proxy (see run_validators.sh)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default) passed straight to
#                          run_validators.sh -- caps storage-server's Tokio worker-thread count
#                          independent of CPU pinning; see run_validators.sh for why this matters
#                          (oversized default thread count causes excess futex/parking
#                          overhead relative to storage-server's actual per-call work)
#   CHAINS_PER_CLIENT      (default 5)
#   BPS_PER_CLIENT         (default 50)
#   TRANSACTIONS_PER_BLOCK (default 1) ignored if TRANSACTIONS_PER_BLOCK_FILE is set
#   TRANSACTIONS_PER_BLOCK_FILE (optional) path *on CLIENT_HOST* to a file with one block size
#                          per line (e.g. the Ethereum trace in
#                          ethereum_txs_per_block_19m_to_21m.csv, header stripped), passed
#                          through to run_lite_benchmark_parallel.sh
#   TRANSACTIONS_PER_BLOCK_SCALE (default 1.0) scales every entry of that file
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   LIGHT_CERTIFICATES     (default false) passed through to run_lite_benchmark_parallel.sh --
#                          broadcast the confirmed certificate's compact hash+signatures form
#                          to validators known to have voted for it, instead of the full
#                          certificate
#   CLIENT_MODE            (default lite) passed through to run_lite_benchmark_parallel.sh --
#                          lite (3 RTTs/block) or full (2 RTTs/block, real local execution,
#                          currently requires TRAFFIC_MODE=independent)
#   CLIENT_TOKIO_THREADS   (optional) passed through to run_lite_benchmark_parallel.sh -- caps
#                          each client process's Tokio worker threads (default: one per CPU on
#                          the client host, which oversubscribes badly at high client counts)
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
#                          cover a wide range in fewer, coarser levels. Ignored when
#                          CLIENT_STEP_SCHEDULE is set.
#   CLIENT_STEP_SCHEDULE   (default: just "${CLIENT_STEP}", i.e. the old single-pass ramp)
#                          space-separated, descending list of client steps for a
#                          coarse-to-fine search, e.g. "25 5 1". The reported maximum is
#                          only ever as precise as the *last* step, so a single coarse step
#                          quantizes the answer to a multiple of that step x BPS_PER_CLIENT
#                          -- which is exactly what makes a shard sweep's TPS curve look
#                          artificially staircased. Instead:
#                            phase 1 walks up by the first (coarse) step until a level fails,
#                                    bracketing the limit between last-good and first-bad;
#                            each later phase re-walks that bracket at the next, finer step,
#                                    tightening it.
#                          This is strictly cheaper *and* more precise than one fine pass:
#                          reaching ~100 clients at step 1 costs ~100 levels, while
#                          "25 5 1" costs ~6 coarse + <=4 + <=4 ~= 14 levels for the same
#                          final resolution of 1 client (= BPS_PER_CLIENT blocks/s).
#                          Levels are memoized, so overlapping phases never re-run a level.
#                          Resolution below one client is not reachable this way: total load
#                          is NUM_CLIENTS x BPS_PER_CLIENT, so lower BPS_PER_CLIENT if you
#                          need a finer grid than one client's worth of load.
#   CONFIRM_STOP_RETRIES   (default 1) when a level is judged bad, re-run it this many times
#                          before accepting it as the ceiling; the first passing retry wins.
#                          A single spuriously-bad coarse level would otherwise cap the whole
#                          search far below the true limit (refinement only ever searches
#                          *below* first-bad), which biases the result downward -- and unlike
#                          random noise, that bias does not average out over repeated runs.
#                          Set to 0 for the old stop-at-first-bad behavior.
#   SUMMARY_CSV_PATH       (default a throwaway mktemp path) where to write the per-level
#                          CSV. Set it to keep the full load-vs-latency curve for every
#                          level probed, not just the single winning level -- that curve is
#                          the raw data behind the reported maximum.
#   CLIENT_ARCHIVE_DIR     (default empty) if set, each level's client output (transfers.csv
#                          + logs) is rsync'd here *as the level finishes*, rather than being
#                          left to pile up on CLIENT_HOST. Per-client wallet/keystore copies
#                          are excluded -- they are byte-identical copies of the one admin
#                          wallet, and at a large chain pool they are by far the biggest
#                          thing on disk (a 20k-chain wallet+keystore is ~12MB *per client
#                          process*, so a 130-client level writes ~1.6GB of pure redundancy).
#   CLEAN_LEVEL_ON_CLIENT  (default true) delete each level's output on CLIENT_HOST once it
#                          has been harvested, bounding that host's disk use to a single
#                          level instead of a whole ramp. CLIENT_HOST's results dir is
#                          typically a ramdisk, and a ramp that fills it does not fail
#                          cleanly -- it fails as an unrelated-looking `cp: No space left on
#                          device` mid-level, taking out every remaining shard count.
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
NUM_VALIDATORS="${NUM_VALIDATORS:-1}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-2}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
TRANSACTIONS_PER_BLOCK_SCALE="${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-false}"
CLIENT_MODE="${CLIENT_MODE:-lite}"
CLIENT_TOKIO_THREADS="${CLIENT_TOKIO_THREADS:-}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
MAX_CLIENTS="${MAX_CLIENTS:-20}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-20}"
LATENCY_DEGRADATION_FACTOR="${LATENCY_DEGRADATION_FACTOR:-3.0}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
FAILURES_ONLY="${FAILURES_ONLY:-false}"
START_CLIENTS="${START_CLIENTS:-1}"
CLIENT_STEP="${CLIENT_STEP:-1}"
CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE:-${CLIENT_STEP}}"
CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES:-1}"
CLIENT_ARCHIVE_DIR="${CLIENT_ARCHIVE_DIR:-}"
CLEAN_LEVEL_ON_CLIENT="${CLEAN_LEVEL_ON_CLIENT:-true}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
SUMMARY_CSV="${SUMMARY_CSV_PATH:-$(mktemp -d)/max_tps_summary.csv}"
mkdir -p "$(dirname "${SUMMARY_CSV}")"
echo "num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,sparta_reserved_cpu_pct,sparta_shard_cpu_pct,client_cpu_pct,step,attempt,verdict" > "${SUMMARY_CSV}"

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
scp "${LOCAL_DIR}/scripts/run_validators.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
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

echo "==> [3/5] Starting ${NUM_VALIDATORS} validator(s) on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores each + ${RESERVED_CORES} reserved"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT_BASE=${PROXY_PUBLIC_PORT} \
   NUM_VALIDATORS=${NUM_VALIDATORS} \
   NUM_SHARDS=${NUM_SHARDS} CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} \
   STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} START_FAUCET=false \
   ${REMOTE_DIR}/scripts/run_validators.sh"
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

# Spans every validator's shard block, not just the first: run_validators.sh lays the
# committee out as NUM_VALIDATORS contiguous blocks of NUM_SHARDS*CORES_PER_SHARD cores
# starting at RESERVED_CORES, so the whole committee's shard CPU is one range.
shard_cores_end=$((RESERVED_CORES + NUM_VALIDATORS * NUM_SHARDS * CORES_PER_SHARD - 1))

echo "==> [5/5] Ramping clients (traffic-mode=${TRAFFIC_MODE}, ${RUNTIME_SECONDS}s per level)"
echo "    step schedule: ${CLIENT_STEP_SCHEDULE} (coarse -> fine), ceiling ${MAX_CLIENTS} clients"
printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-14s %-13s %-12s\n" \
  "clients" "requested_bps" "committed" "failed" "achieved_bps" "achieved_tps" \
  "p25_ms" "p50_ms" "p95_ms" "sparta_rsvd%" "sparta_shard%" "client_cpu%"

baseline_p95=""
declare -A LEVEL_LINE     # n -> the printf'd row of the level's *accepted* measurement
declare -A LEVEL_VERDICT  # n -> "good" | "bad", memoizing levels across search phases

# Runs one load level at ${1} clients (attempt ${2}, probed at step ${3}), prints its row and
# appends it to the per-level CSV. Sets LEVEL_STOP_REASON to "" when the level sustained the
# load, or to a human-readable reason when it did not.
measure_level() {
  local n="$1" attempt="$2" step="$3"
  local requested_bps=$((n * BPS_PER_CLIENT))
  local experiment_name="level_${RUN_ID}_${n}_a${attempt}"
  local remote_level_dir="${REMOTE_DIR}/results/lite_benchmark/${experiment_name}"

  local sparta_stat_before client_stat_before sparta_stat_after client_stat_after
  sparta_stat_before="$(read_cpu_stat_all "${SPARTA_HOST}")"
  client_stat_before="$(read_cpu_stat_all "${CLIENT_HOST}")"
  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=${n} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
    BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
    TRANSACTIONS_PER_BLOCK_FILE=${TRANSACTIONS_PER_BLOCK_FILE} \
    TRANSACTIONS_PER_BLOCK_SCALE=${TRANSACTIONS_PER_BLOCK_SCALE} \
    TRAFFIC_MODE=${TRAFFIC_MODE} LIGHT_CERTIFICATES=${LIGHT_CERTIFICATES} \
    CLIENT_MODE=${CLIENT_MODE} \
    CLIENT_TOKIO_THREADS=${CLIENT_TOKIO_THREADS} \
    RUNTIME_SECONDS=${RUNTIME_SECONDS} \
    EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name} \
    ./scripts/run_lite_benchmark_parallel.sh" > /dev/null
  sparta_stat_after="$(read_cpu_stat_all "${SPARTA_HOST}")"
  client_stat_after="$(read_cpu_stat_all "${CLIENT_HOST}")"
  local sparta_reserved_pct sparta_shard_pct client_cpu_pct
  sparta_reserved_pct="$(cpu_range_utilization_pct "${sparta_stat_before}" "${sparta_stat_after}" 0 $((RESERVED_CORES - 1)))"
  sparta_shard_pct="$(cpu_range_utilization_pct "${sparta_stat_before}" "${sparta_stat_after}" "${RESERVED_CORES}" "${shard_cores_end}")"
  client_cpu_pct="$(cpu_range_utilization_pct "${client_stat_before}" "${client_stat_after}" 0 9999)"

  # Harvest this level and free it on CLIENT_HOST right away -- see CLIENT_ARCHIVE_DIR /
  # CLEAN_LEVEL_ON_CLIENT above for why per-level (not per-sweep) cleanup matters. The
  # wallet/keystore excludes are what make this cheap: they are per-client copies of one
  # file and carry no per-level information.
  local level_dir keep_level_dir=false
  if [ -n "${CLIENT_ARCHIVE_DIR}" ]; then
    level_dir="${CLIENT_ARCHIVE_DIR}/${experiment_name}"
    keep_level_dir=true
    mkdir -p "${level_dir}"
  else
    level_dir="$(mktemp -d)"
  fi
  rsync -az --exclude='wallet.json' --exclude='keystore.json' \
    "${CLIENT_HOST}:${remote_level_dir}/" "${level_dir}/" || \
    echo "  warning: failed to fetch level ${n} (attempt ${attempt}) from ${CLIENT_HOST}" >&2
  if [ "${CLEAN_LEVEL_ON_CLIENT}" = "true" ]; then
    ssh "${CLIENT_HOST}" "rm -rf ${remote_level_dir}" || \
      echo "  warning: failed to clean up ${remote_level_dir} on ${CLIENT_HOST}" >&2
  fi

  # Derived from transfers.csv, so it is deliberately kept out of level_dir -- level_dir may
  # be the permanent archive, and re-deriving this is far cheaper than storing it per level.
  local durations_file
  durations_file="$(mktemp)"
  local committed=0 failed=0 total_tx=0 csv
  for csv in "${level_dir}"/client_*/transfers.csv; do
    [ -f "${csv}" ] || continue
    committed=$((committed + $(awk -F, 'NR>1 && $5=="committed"' "${csv}" | wc -l)))
    failed=$((failed + $(awk -F, 'NR>1 && $5=="failed"' "${csv}" | wc -l)))
    total_tx=$((total_tx + $(awk -F, 'NR>1 && $5=="committed" {s+=$3} END{print s+0}' "${csv}")))
    awk -F, 'NR>1 && $5=="committed" { print $6 }' "${csv}" >> "${durations_file}"
  done
  sort -n -o "${durations_file}" "${durations_file}"

  local p25_us p50_us p95_us p25_ms p50_ms p95_ms achieved_bps achieved_tps
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

  local row
  row="$(printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-14s %-13s %-12s" \
    "${n}" "${requested_bps}" "${committed}" "${failed}" "${achieved_bps}" "${achieved_tps}" \
    "${p25_ms}" "${p50_ms}" "${p95_ms}" "${sparta_reserved_pct}" "${sparta_shard_pct}" "${client_cpu_pct}")"

  # The baseline p95 every later level is compared against is the *first level measured in
  # this run*, whatever the search happens to probe first -- not a fixed client count.
  if [ -z "${baseline_p95}" ]; then
    baseline_p95="${p95_ms}"
  fi

  LEVEL_STOP_REASON=""
  if [ "${failed}" -gt 0 ]; then
    LEVEL_STOP_REASON="${failed} failed block(s)"
  elif [ "${FAILURES_ONLY}" != "true" ] && awk -v p="${p95_ms}" -v b="${baseline_p95}" -v f="${LATENCY_DEGRADATION_FACTOR}" 'BEGIN{exit !(b>0 && p>b*f)}'; then
    LEVEL_STOP_REASON="p95 latency ${p95_ms}ms exceeds ${LATENCY_DEGRADATION_FACTOR}x baseline (${baseline_p95}ms)"
  elif [ "${FAILURES_ONLY}" != "true" ] && awk -v a="${achieved_bps}" -v r="${requested_bps}" -v f="${MIN_ACHIEVED_FRACTION}" 'BEGIN{exit !(a < r*f)}'; then
    LEVEL_STOP_REASON="achieved ${achieved_bps} BPS is below ${MIN_ACHIEVED_FRACTION}x requested ${requested_bps}"
  fi

  local verdict="good"
  [ -n "${LEVEL_STOP_REASON}" ] && verdict="bad"
  printf "%s %-6s %s\n" "${row}" "${verdict}" "${LEVEL_STOP_REASON}"
  echo "${n},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25_ms},${p50_ms},${p95_ms},${sparta_reserved_pct},${sparta_shard_pct},${client_cpu_pct},${step},${attempt},${verdict}" >> "${SUMMARY_CSV}"
  MEASURED_ROW="${row}"

  rm -f "${durations_file}"
  [ "${keep_level_dir}" = true ] || rm -rf "${level_dir}"
}

# Memoized "does ${1} clients sustain the load?" -- returns 0 for good, 1 for bad. A bad
# verdict is re-tested up to CONFIRM_STOP_RETRIES times before it is believed (see above).
level_is_good() {
  local n="$1" step="$2" attempt=0
  if [ -n "${LEVEL_VERDICT[$n]:-}" ]; then
    [ "${LEVEL_VERDICT[$n]}" = "good" ]
    return
  fi
  while :; do
    measure_level "${n}" "${attempt}" "${step}"
    if [ -z "${LEVEL_STOP_REASON}" ]; then
      LEVEL_VERDICT[$n]="good"
      LEVEL_LINE[$n]="${MEASURED_ROW}"
      return 0
    fi
    if [ "${attempt}" -ge "${CONFIRM_STOP_RETRIES}" ]; then
      LEVEL_VERDICT[$n]="bad"
      return 1
    fi
    attempt=$((attempt + 1))
    echo "  level ${n} failed (${LEVEL_STOP_REASON}) -- re-testing (${attempt}/${CONFIRM_STOP_RETRIES}) before accepting it as the ceiling"
  done
}

# Coarse-to-fine search: keep a bracket [lower_good, upper_bad) around the limit and tighten
# it one step size at a time. lower_good=0 means "nothing has passed yet"; upper_bad is kept
# one past MAX_CLIENTS while nothing has failed yet, so the ceiling is treated as an
# unexplored bound rather than a known-bad level.
lower_good=0
upper_bad=$((MAX_CLIENTS + 1))
first_phase=true

for step in ${CLIENT_STEP_SCHEDULE}; do
  if [ "${step}" -lt 1 ]; then
    echo "CLIENT_STEP_SCHEDULE entries must be >= 1, got '${step}'" >&2
    exit 1
  fi
  if [ "${first_phase}" = true ]; then
    n="${START_CLIENTS}"
    first_phase=false
  else
    # Everything at or below lower_good already passed, and upper_bad already failed, so
    # only the strict interior of the bracket is worth probing.
    n=$((lower_good + step))
    if [ $((lower_good + 1)) -ge "${upper_bad}" ]; then
      break  # bracket is tight to a single client; no finer step can say anything new
    fi
    echo "==> Refining at step ${step} within (${lower_good}, ${upper_bad}) clients"
  fi
  while [ "${n}" -le "${MAX_CLIENTS}" ] && [ "${n}" -lt "${upper_bad}" ]; do
    if level_is_good "${n}" "${step}"; then
      lower_good="${n}"
    else
      upper_bad="${n}"
      break
    fi
    n=$((n + step))
  done
done

echo
if [ "${lower_good}" -eq 0 ]; then
  echo "==> Even the first level (${START_CLIENTS} client(s)) showed degraded/failed behavior -- see ${SUMMARY_CSV}"
else
  if [ "${upper_bad}" -gt "${MAX_CLIENTS}" ]; then
    echo "==> WARNING: no level failed up to the MAX_CLIENTS=${MAX_CLIENTS} ceiling -- the"
    echo "    reported maximum is bounded by the ceiling, not by the validator. Raise MAX_CLIENTS."
  else
    echo "==> Limit bracketed to (${lower_good}, ${upper_bad}) clients: resolution is $((BPS_PER_CLIENT * (upper_bad - lower_good))) blocks/s"
  fi
  echo "==> Estimated max sustained throughput: ${LEVEL_LINE[${lower_good}]}"
fi
echo "==> Full per-level results: ${SUMMARY_CSV}"
