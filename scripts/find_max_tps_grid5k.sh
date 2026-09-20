#!/usr/bin/env bash
set -euo pipefail

# The distributed-committee counterpart of find_max_tps.sh: same ramp-until-degraded
# methodology (paper Section VII.C / Fig. 6), but against a committee of NUM_VALIDATORS real
# validators, each on its own physical machine (VALIDATOR_HOSTS), instead of find_max_tps.sh's
# single SPARTA_HOST. Brought up via run_committee_grid5k.sh instead of run_validators.sh.
#
# Intended for a Grid5000 reservation (grid5k_reserve.sh), but only assumes SSH reachability to
# every host via SSH_PROXY_JUMP -- nothing else here is Grid5000-specific.
#
# What changed vs. find_max_tps.sh, concretely:
#   - "Deploy + start validator" is now run_committee_grid5k.sh across N hosts instead of one
#     ssh call to SPARTA_HOST running run_validators.sh.
#   - CPU utilization is sampled on every validator host, not just one; reported per level as
#     min/avg/max across the committee rather than a single reserved%/shard% pair, since with
#     N>1 machines a single number would hide an unbalanced validator.
#   - Everything else -- the coarse-to-fine client ramp, the stop conditions (failures, p95
#     latency degradation, achieved-throughput floor), the per-level CSV, chain provisioning,
#     run_lite_benchmark_parallel.sh invocation -- is unchanged from find_max_tps.sh, since none
#     of it is aware of how many validators or hosts are behind PROXY_PUBLIC_PORT.
#
# Expect lower throughput than find_max_tps.sh's n=1 result, and expect it to fall further as
# NUM_VALIDATORS grows: every block now needs a real quorum of signatures collected over the
# network (ceil((n + ceil(n/3)) / 2) of n), not a single self-certifying validator. Whether the
# committee still matches Fig. 6's peak *aggregate* throughput depends on whether enough
# independent chains are in flight to keep that added per-block latency pipelined/hidden --
# that is what this script measures, not something to assume going in.
#
# Configuration (env vars):
#   VALIDATOR_HOSTS        (required) space-separated hosts, one per validator -- see
#                          grid5k_reserve.sh's VALIDATOR_HOSTS array (join with spaces)
#   SSH_PROXY_JUMP         (default empty) e.g. "grid5k" -- see grid5k_reserve.sh
#   CLIENT_HOST            (required unless CLIENT_HOSTS is set) also reached via
#                          SSH_PROXY_JUMP -- point this at the extra node grid5k_reserve.sh
#                          reserved when WITH_CLIENT=true
#   CLIENT_HOSTS           (optional) space-separated list of client hosts -- see
#                          grid5k_reserve.sh's CLIENT_HOSTS (NUM_CLIENT_HOSTS>1). Each level's
#                          client-process count is split as evenly as possible across these
#                          hosts (remainder going to the first few), each running a disjoint
#                          slice of the same shared chain pool via
#                          run_lite_benchmark_parallel.sh's CLIENT_INDEX_OFFSET. Falls back to
#                          a single host (CLIENT_HOST) when unset -- use this once one client
#                          host's CPU becomes the bottleneck instead of the validators'.
#   REMOTE_DIR             (default linera)
#   BUILD_PROFILE          (default release) debug | release
#   LINERA_SRC             (default ~/work/linera/linera-protocol)
#   NUM_SHARDS             (default 19) shards *per validator*
#   CORES_PER_SHARD        (default 2) 0 disables CPU pinning entirely
#   RESERVED_CORES         (default 2) reserved for storage-server + proxy on each validator host
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default)
#   CHAINS_PER_CLIENT, BPS_PER_CLIENT, TRANSACTIONS_PER_BLOCK[_FILE|_SCALE], TRAFFIC_MODE,
#   LIGHT_CERTIFICATES, CLIENT_MODE, CLIENT_TOKIO_THREADS, SIMULATED_LATENCY_MS,
#   SKIP_MESSAGE_PROCESSING, RUNTIME_SECONDS, MIN_ACHIEVED_FRACTION,
#   START_CLIENTS,
#   CLIENT_STEP, CLIENT_STEP_SCHEDULE, CONFIRM_STOP_RETRIES, SUMMARY_CSV_PATH,
#   CLIENT_ARCHIVE_DIR, CLEAN_LEVEL_ON_CLIENT
#   PROVISION_PARALLELISM  (default 1) when >1, provisions the chain pool via
#                          provision_super_owner_chains_parallel.sh instead of the serial
#                          provision_super_owner_chains.sh -- opens this many independent
#                          "shard" chains first, then provisions the pool concurrently across
#                          them (each shard's block history is independent, so this is
#                          genuinely parallel, unlike batching more into one chain's blocks).
#                          Large pools (tens of thousands of chains) provision roughly
#                          PROVISION_PARALLELISM times faster. Confirmed via a real ~12s/block
#                          measurement on paradoxe: 100,000 chains took ~22 minutes serially.
#   MAX_CLIENTS            (default 200, was 20) ramp ceiling -- raised because
#                          FAILURES_ONLY now defaults to true (see below): a real max-TPS
#                          search needs real headroom to climb into before hitting the
#                          ceiling, and the old MAX_CLIENTS=20 default left almost no room.
#   FAILURES_ONLY          (default true, was false) only stop the ramp on a real failure
#                          (failed > 0), not on MIN_ACHIEVED_FRACTION. Confirmed this session
#                          (both here and on a single-machine testbed) that the
#                          achieved/requested-throughput floor routinely cut ramps off tens of
#                          percent below the committee's real capacity -- e.g. a run that
#                          "ceilinged" at ~415K TPS kept climbing to over 1M once left to run
#                          past that floor. Set FAILURES_ONLY=false to restore the old
#                          behavior (still ignores the p95-latency check, which was removed
#                          entirely, not just gated, for the same reason).
#                          identical meaning to find_max_tps.sh -- see there for the full
#                          rationale of each (especially CLIENT_STEP_SCHEDULE's coarse-to-fine
#                          search and CONFIRM_STOP_RETRIES's anti-downward-bias retry)
#   STOP_COMMITTEE_AFTER   (default true) tear down the committee when done
#   SKIP_BUILD             (default false)
#   SKIP_BINARY_DEPLOY     (default false)

VALIDATOR_HOSTS="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of hosts, one per validator}"
read -ra VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS}"
NUM_VALIDATORS="${#VALIDATOR_HOSTS_ARR[@]}"
SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
CLIENT_HOSTS="${CLIENT_HOSTS:-${CLIENT_HOST:-}}"
[ -n "${CLIENT_HOSTS}" ] || { echo "set CLIENT_HOST or CLIENT_HOSTS" >&2; exit 1; }
read -ra CLIENT_HOSTS_ARR <<< "${CLIENT_HOSTS}"
CLIENT_HOST="${CLIENT_HOSTS_ARR[0]}"
NUM_CLIENT_HOSTS="${#CLIENT_HOSTS_ARR[@]}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
NUM_SHARDS="${NUM_SHARDS:-19}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-2}"
STORAGE_CORES="${STORAGE_CORES:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
PROVISION_PARALLELISM="${PROVISION_PARALLELISM:-1}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
TRANSACTIONS_PER_BLOCK_SCALE="${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-false}"
CLIENT_MODE="${CLIENT_MODE:-lite}"
CLIENT_TOKIO_THREADS="${CLIENT_TOKIO_THREADS:-}"
SIMULATED_LATENCY_MS="${SIMULATED_LATENCY_MS:-}"
SKIP_MESSAGE_PROCESSING="${SKIP_MESSAGE_PROCESSING:-false}"
MAX_DESTINATIONS_PER_BLOCK="${MAX_DESTINATIONS_PER_BLOCK:-}"
MAX_INCOMING_BUNDLES_PER_BLOCK="${MAX_INCOMING_BUNDLES_PER_BLOCK:-}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
MAX_CLIENTS="${MAX_CLIENTS:-200}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-20}"
MIN_ACHIEVED_FRACTION="${MIN_ACHIEVED_FRACTION:-0.8}"
FAILURES_ONLY="${FAILURES_ONLY:-true}"
START_CLIENTS="${START_CLIENTS:-1}"
CLIENT_STEP="${CLIENT_STEP:-1}"
CLIENT_STEP_SCHEDULE="${CLIENT_STEP_SCHEDULE:-${CLIENT_STEP}}"
CONFIRM_STOP_RETRIES="${CONFIRM_STOP_RETRIES:-1}"
CLIENT_ARCHIVE_DIR="${CLIENT_ARCHIVE_DIR:-}"
CLEAN_LEVEL_ON_CLIENT="${CLEAN_LEVEL_ON_CLIENT:-true}"
STOP_COMMITTEE_AFTER="${STOP_COMMITTEE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
SUMMARY_CSV="${SUMMARY_CSV_PATH:-$(mktemp -d)/max_tps_summary.csv}"
mkdir -p "$(dirname "${SUMMARY_CSV}")"
echo "num_clients,requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,validator_reserved_cpu_pct_min_avg_max,validator_storage_cpu_pct_min_avg_max,validator_shard_cpu_pct_min_avg_max,client_cpu_pct_min_avg_max,step,attempt,verdict" > "${SUMMARY_CSV}"

# See run_committee_grid5k.sh for why this is -o User=... rather than user@host (hosts double
# as NODE_HOST) and why ControlMaster/ControlPersist matter (avoids re-tripping the bastion's
# connection-rate limiting across dozens of calls to the same handful of hosts).
ssh_cm_opts=(-o ControlMaster=auto -o "ControlPath=/tmp/g5k-ssh-cm-%r@%h:%p" -o ControlPersist=15m)
ssh_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then ssh -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} -J "${SSH_PROXY_JUMP}" "$@"; else ssh "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"; fi
}
rsync_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then rsync -az -e "ssh -o StrictHostKeyChecking=accept-new ${ssh_cm_opts[*]} -J ${SSH_PROXY_JUMP} ${SSH_USER:+-o User=${SSH_USER}}" "$@"; else rsync -az -e "ssh ${ssh_cm_opts[*]} ${SSH_USER:+-o User=${SSH_USER}}" "$@"; fi
}
scp_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then scp -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" -o "ProxyJump=${SSH_PROXY_JUMP}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"; else scp "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"; fi
}

quorum=$(( (NUM_VALIDATORS + (NUM_VALIDATORS + 2) / 3 + 1) / 2 ))
echo "==> Committee: ${NUM_VALIDATORS} validator(s) (quorum ${quorum}), hosts: ${VALIDATOR_HOSTS_ARR[*]}"

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
  (
    cd "${LINERA_SRC}"
    cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server
  )
fi

echo "==> [2/6] Bringing up committee across ${NUM_VALIDATORS} host(s)"
committee_state_dir="$(mktemp -d)"
VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
  BIN_SRC_DIR="${bin_src}" STATE_DIR="${committee_state_dir}" \
  SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY}" \
  NUM_SHARDS="${NUM_SHARDS}" CORES_PER_SHARD="${CORES_PER_SHARD}" RESERVED_CORES="${RESERVED_CORES}" \
  STORAGE_CORES="${STORAGE_CORES}" STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS}" ACTION=start \
  "${LOCAL_DIR}/scripts/run_committee_grid5k.sh"

cleanup_committee() {
  if [ "${STOP_COMMITTEE_AFTER}" = "true" ]; then
    echo "==> Stopping committee"
    VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
      ACTION=stop "${LOCAL_DIR}/scripts/run_committee_grid5k.sh" || true
  else
    echo "==> Leaving committee running (STOP_COMMITTEE_AFTER=false)"
  fi
}
trap cleanup_committee EXIT

echo "==> [3/6] Deploying to ${NUM_CLIENT_HOSTS} client host(s): ${CLIENT_HOSTS_ARR[*]}"
for ch in "${CLIENT_HOSTS_ARR[@]}"; do
  ssh_j "${ch}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
  if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
    echo "  skipping binary transfer to ${ch} (SKIP_BINARY_DEPLOY=true)"
  else
    rsync_j "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${ch}:${REMOTE_DIR}/bin/"
  fi
  scp_j "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" \
    "${LOCAL_DIR}/scripts/provision_super_owner_chains_parallel.sh" \
    "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
    "${ch}:${REMOTE_DIR}/scripts/"
  ssh_j "${ch}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

  echo "==> Relaying admin wallet + genesis config: committee -> here -> ${ch}"
  scp_j "${committee_state_dir}/admin_wallet.json" "${committee_state_dir}/admin_keystore.json" \
    "${committee_state_dir}/genesis.json" "${ch}:${REMOTE_DIR}/"
done

pool_size=$((MAX_CLIENTS * CHAINS_PER_CLIENT))
if [ "${PROVISION_PARALLELISM}" -gt 1 ]; then
  echo "==> [4/6] Provisioning ${pool_size} super-owner chains on ${CLIENT_HOST} (${PROVISION_PARALLELISM}-way parallel)"
  ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    NUM_CHAINS=${pool_size} OUTPUT_FILE=./chain_pool.txt PARALLELISM=${PROVISION_PARALLELISM} \
    ./scripts/provision_super_owner_chains_parallel.sh"
else
  echo "==> [4/6] Provisioning ${pool_size} super-owner chains on ${CLIENT_HOST}"
  ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    NUM_CHAINS=${pool_size} OUTPUT_FILE=./chain_pool.txt \
    ./scripts/provision_super_owner_chains.sh"
fi

if [ "${NUM_CLIENT_HOSTS}" -gt 1 ]; then
  # All hosts run clients against the same global chain pool (disjoint index ranges via
  # CLIENT_INDEX_OFFSET), so every host needs its own copy of the file provisioning just wrote
  # on CLIENT_HOST -- relayed the same way the wallet/genesis were (through here, not
  # host-to-host, since client hosts aren't necessarily reachable from each other).
  chain_pool_tmp="$(mktemp)"
  scp_j "${CLIENT_HOST}:${REMOTE_DIR}/chain_pool.txt" "${chain_pool_tmp}"
  for ch in "${CLIENT_HOSTS_ARR[@]:1}"; do
    echo "==> Relaying chain pool: ${CLIENT_HOST} -> here -> ${ch}"
    scp_j "${chain_pool_tmp}" "${ch}:${REMOTE_DIR}/chain_pool.txt"
  done
  rm -f "${chain_pool_tmp}"
fi

percentile() {
  local file="$1" pct="$2" n idx
  n="$(wc -l < "${file}")"
  [ "${n}" -eq 0 ] && return
  idx=$(( (pct * n + 99) / 100 ))
  [ "${idx}" -lt 1 ] && idx=1
  [ "${idx}" -gt "${n}" ] && idx="${n}"
  sed -n "${idx}p" "${file}"
}

# `timeout <n> ssh_j ...` does NOT work: ssh_j is a bash function, not an external binary, and
# `timeout` can only exec real commands -- it fails with "command not found" (exit 127). Use
# ssh's own -o ConnectTimeout instead.
read_cpu_stat_all() {
  ssh_j -o ConnectTimeout=5 "$1" "grep '^cpu' /proc/stat" 2>/dev/null
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

# min/avg/max of a space-separated list of numbers, formatted "min/avg/max" -- used to collapse
# each level's per-host CPU utilization into one CSV field instead of NUM_VALIDATORS columns.
min_avg_max() {
  awk -v vals="$1" 'BEGIN{
    n=split(vals,a," ");
    if (n==0) { print "NaN/NaN/NaN"; exit }
    mn=a[1]; mx=a[1]; sum=0
    for (i=1;i<=n;i++) { if (a[i]<mn) mn=a[i]; if (a[i]>mx) mx=a[i]; sum+=a[i] }
    printf "%.1f/%.1f/%.1f", mn, sum/n, mx
  }'
}

# Storage shares the reserved range when STORAGE_CORES=0 (matches run_committee_grid5k.sh's
# own default), so shards start right after RESERVED_CORES in that case; otherwise storage gets
# its own dedicated range between the proxy and the shards.
shard_cores_start=$((RESERVED_CORES + STORAGE_CORES))
shard_cores_end=$((shard_cores_start + NUM_SHARDS * CORES_PER_SHARD - 1))

echo "==> [5/6] Ramping clients (traffic-mode=${TRAFFIC_MODE}, ${RUNTIME_SECONDS}s per level)"
echo "    step schedule: ${CLIENT_STEP_SCHEDULE} (coarse -> fine), ceiling ${MAX_CLIENTS} clients"
printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-22s %-22s %-19s %-19s\n" \
  "clients" "requested_bps" "committed" "failed" "achieved_bps" "achieved_tps" \
  "p25_ms" "p50_ms" "p95_ms" "validator_rsvd%(min/avg/max)" "validator_storage%(m/a/M)" "validator_shard%(m/a/M)" "client_cpu%(m/a/M)"

declare -A LEVEL_LINE
declare -A LEVEL_VERDICT

measure_level() {
  local n="$1" attempt="$2" step="$3"
  local requested_bps=$((n * BPS_PER_CLIENT))
  local experiment_name="level_${RUN_ID}_${n}_a${attempt}"

  # Split this level's n clients as evenly as possible across the client hosts (remainder to
  # the first few), so each host runs a disjoint index range against the shared chain pool.
  # A host with 0 clients this level (n < NUM_CLIENT_HOSTS) is skipped entirely below.
  local -a host_counts=() host_offsets=()
  local base=$((n / NUM_CLIENT_HOSTS)) rem=$((n % NUM_CLIENT_HOSTS)) idx offset=0
  for ((idx = 0; idx < NUM_CLIENT_HOSTS; idx++)); do
    local c="${base}"
    [ "${idx}" -lt "${rem}" ] && c=$((c + 1))
    host_counts+=("${c}")
    host_offsets+=("${offset}")
    offset=$((offset + c))
  done

  local validator_stats_before=() validator_stats_after=()
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    validator_stats_before+=("$(read_cpu_stat_all "${host}")")
  done
  local -A client_stats_before=()
  for ((idx = 0; idx < NUM_CLIENT_HOSTS; idx++)); do
    [ "${host_counts[$idx]}" -gt 0 ] || continue
    client_stats_before["${CLIENT_HOSTS_ARR[$idx]}"]="$(read_cpu_stat_all "${CLIENT_HOSTS_ARR[$idx]}")"
  done

  local pids=()
  for ((idx = 0; idx < NUM_CLIENT_HOSTS; idx++)); do
    [ "${host_counts[$idx]}" -gt 0 ] || continue
    local ch="${CLIENT_HOSTS_ARR[$idx]}"
    ssh_j "${ch}" "cd ${REMOTE_DIR} && \
      LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
      CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=${host_counts[$idx]} \
      CLIENT_INDEX_OFFSET=${host_offsets[$idx]} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
      BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
      TRANSACTIONS_PER_BLOCK_FILE=${TRANSACTIONS_PER_BLOCK_FILE} \
      TRANSACTIONS_PER_BLOCK_SCALE=${TRANSACTIONS_PER_BLOCK_SCALE} \
      TRAFFIC_MODE=${TRAFFIC_MODE} LIGHT_CERTIFICATES=${LIGHT_CERTIFICATES} \
      CLIENT_MODE=${CLIENT_MODE} \
      CLIENT_TOKIO_THREADS=${CLIENT_TOKIO_THREADS} \
      SIMULATED_LATENCY_MS=${SIMULATED_LATENCY_MS} \
      SKIP_MESSAGE_PROCESSING=${SKIP_MESSAGE_PROCESSING} \
      MAX_DESTINATIONS_PER_BLOCK=${MAX_DESTINATIONS_PER_BLOCK} \
      MAX_INCOMING_BUNDLES_PER_BLOCK=${MAX_INCOMING_BUNDLES_PER_BLOCK} \
      RUNTIME_SECONDS=${RUNTIME_SECONDS} \
      EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name}_h${idx} \
      ./scripts/run_lite_benchmark_parallel.sh" > /dev/null &
    pids+=("$!")
  done
  local fail=0
  for pid in "${pids[@]}"; do
    wait "${pid}" || fail=1
  done
  [ "${fail}" -eq 0 ] || echo "  warning: at least one client host's run_lite_benchmark_parallel.sh exited non-zero for level ${n} (attempt ${attempt})" >&2

  local i=0
  local reserved_vals="" storage_vals="" shard_vals=""
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    local after
    after="$(read_cpu_stat_all "${host}")"
    reserved_vals="${reserved_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" 0 $((RESERVED_CORES - 1)))"
    if [ "${STORAGE_CORES}" -gt 0 ]; then
      storage_vals="${storage_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" "${RESERVED_CORES}" $((shard_cores_start - 1)))"
    fi
    shard_vals="${shard_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" "${shard_cores_start}" "${shard_cores_end}")"
    i=$((i + 1))
  done
  local client_vals=""
  for ((idx = 0; idx < NUM_CLIENT_HOSTS; idx++)); do
    [ "${host_counts[$idx]}" -gt 0 ] || continue
    local ch="${CLIENT_HOSTS_ARR[$idx]}" after
    after="$(read_cpu_stat_all "${ch}")"
    client_vals="${client_vals} $(cpu_range_utilization_pct "${client_stats_before[${ch}]}" "${after}" 0 9999)"
  done
  local validator_reserved_summary validator_storage_summary validator_shard_summary client_cpu_pct
  validator_reserved_summary="$(min_avg_max "${reserved_vals}")"
  validator_storage_summary="$([ "${STORAGE_CORES}" -gt 0 ] && min_avg_max "${storage_vals}" || echo "n/a")"
  validator_shard_summary="$(min_avg_max "${shard_vals}")"
  client_cpu_pct="$(min_avg_max "${client_vals}")"

  local level_dir keep_level_dir=false
  if [ -n "${CLIENT_ARCHIVE_DIR}" ]; then
    level_dir="${CLIENT_ARCHIVE_DIR}/${experiment_name}"
    keep_level_dir=true
    mkdir -p "${level_dir}"
  else
    level_dir="$(mktemp -d)"
  fi
  for ((idx = 0; idx < NUM_CLIENT_HOSTS; idx++)); do
    [ "${host_counts[$idx]}" -gt 0 ] || continue
    local ch="${CLIENT_HOSTS_ARR[$idx]}"
    # Per-host remote dir (EXPERIMENT_NAME=${experiment_name}_h${idx} above): Grid5000 shares
    # $HOME via NFS across every host at a site, so a *shared* remote path here would let one
    # host's cleanup (rm -rf below) delete a directory another host is still rsync-fetching
    # from -- confirmed the hard way as "Stale file handle" errors on 3 of 4 client hosts
    # every level once NUM_CLIENT_HOSTS>1 was exercised for real.
    local remote_level_dir="${REMOTE_DIR}/results/lite_benchmark/${experiment_name}_h${idx}"
    rsync_j --exclude='wallet.json' --exclude='keystore.json' \
      "${ch}:${remote_level_dir}/" "${level_dir}/" || \
      echo "  warning: failed to fetch level ${n} (attempt ${attempt}) from ${ch}" >&2
    if [ "${CLEAN_LEVEL_ON_CLIENT}" = "true" ]; then
      ssh_j "${ch}" "rm -rf ${remote_level_dir}" || \
        echo "  warning: failed to clean up ${remote_level_dir} on ${ch}" >&2
    fi
  done

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

  # A client whose process died before ever writing transfers.csv (e.g. it couldn't establish
  # a TCP connection to the validator in time -- a real signal at very high concurrent-client
  # counts) contributes nothing to the committed/failed counts above, so without this a level
  # where a growing fraction of clients silently fail to connect would keep reporting "good"
  # all the way to MAX_CLIENTS instead of ever tripping FAILURES_ONLY's stop condition.
  # run_lite_benchmark_parallel.sh marks each such client with a PROCESS_FAILED sentinel file.
  local process_failed
  process_failed="$(find "${level_dir}" -maxdepth 2 -name PROCESS_FAILED 2>/dev/null | wc -l)"
  failed=$((failed + process_failed))

  local p25_us p50_us p95_us p25_ms p50_ms p95_ms achieved_bps achieved_tps
  p25_us="$(percentile "${durations_file}" 25)"
  p50_us="$(percentile "${durations_file}" 50)"
  p95_us="$(percentile "${durations_file}" 95)"
  p25_ms="$(awk -v v="${p25_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p50_ms="$(awk -v v="${p50_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p95_ms="$(awk -v v="${p95_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  achieved_bps="$(awk -v c="${committed}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"
  achieved_tps="$(awk -v c="${total_tx}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"

  local row
  row="$(printf "%-8s %-14s %-10s %-8s %-14s %-14s %-10s %-10s %-10s %-22s %-22s %-19s %-19s" \
    "${n}" "${requested_bps}" "${committed}" "${failed}" "${achieved_bps}" "${achieved_tps}" \
    "${p25_ms}" "${p50_ms}" "${p95_ms}" "${validator_reserved_summary}" "${validator_storage_summary}" "${validator_shard_summary}" "${client_cpu_pct}")"

  LEVEL_STOP_REASON=""
  if [ "${failed}" -gt 0 ]; then
    LEVEL_STOP_REASON="${failed} failed block(s)/client(s) (incl. ${process_failed} that never connected)"
  elif [ "${FAILURES_ONLY}" != "true" ] && awk -v a="${achieved_bps}" -v r="${requested_bps}" -v f="${MIN_ACHIEVED_FRACTION}" 'BEGIN{exit !(a < r*f)}'; then
    LEVEL_STOP_REASON="achieved ${achieved_bps} BPS is below ${MIN_ACHIEVED_FRACTION}x requested ${requested_bps}"
  fi

  local verdict="good"
  [ -n "${LEVEL_STOP_REASON}" ] && verdict="bad"
  printf "%s %-6s %s\n" "${row}" "${verdict}" "${LEVEL_STOP_REASON}"
  echo "${n},${requested_bps},${committed},${failed},${achieved_bps},${achieved_tps},${p25_ms},${p50_ms},${p95_ms},${validator_reserved_summary},${validator_storage_summary},${validator_shard_summary},${client_cpu_pct},${step},${attempt},${verdict}" >> "${SUMMARY_CSV}"
  MEASURED_ROW="${row}"

  rm -f "${durations_file}"
  [ "${keep_level_dir}" = true ] || rm -rf "${level_dir}"
}

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
    n=$((lower_good + step))
    if [ $((lower_good + 1)) -ge "${upper_bad}" ]; then
      break
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
echo "==> [6/6] Done"
if [ "${lower_good}" -eq 0 ]; then
  echo "==> Even the first level (${START_CLIENTS} client(s)) showed degraded/failed behavior -- see ${SUMMARY_CSV}"
else
  if [ "${upper_bad}" -gt "${MAX_CLIENTS}" ]; then
    echo "==> WARNING: no level failed up to the MAX_CLIENTS=${MAX_CLIENTS} ceiling -- the"
    echo "    reported maximum is bounded by the ceiling, not by the committee. Raise MAX_CLIENTS."
  else
    echo "==> Limit bracketed to (${lower_good}, ${upper_bad}) clients: resolution is $((BPS_PER_CLIENT * (upper_bad - lower_good))) blocks/s"
  fi
  echo "==> Estimated max sustained throughput: ${LEVEL_LINE[${lower_good}]}"
fi
echo "==> Full per-level results: ${SUMMARY_CSV}"
