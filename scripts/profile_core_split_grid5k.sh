#!/usr/bin/env bash
set -euo pipefail

# Profiles how a validator's CPU budget should be split between the proxy (RESERVED_CORES),
# the storage-server (STORAGE_CORES), and the shard workers (NUM_SHARDS * CORES_PER_SHARD) --
# a lighter sibling of find_max_tps_grid5k.sh: no ramp-to-failure search, just one fixed,
# moderate load level per combo, since the point is comparing CPU/latency *across splits* at
# constant offered load, not finding each split's own ceiling.
#
# Every combo in COMBOS uses the same total per-validator core budget (TOTAL_CORES) -- only how
# that budget is divided changes -- so the comparison is apples to apples.
#
# Brought up/torn down via run_committee_grid5k.sh exactly like find_max_tps_grid5k.sh, and
# driven the same way (Grid5000 or any SSH-reachable hosts, via SSH_PROXY_JUMP).
#
# Configuration (env vars):
#   VALIDATOR_HOSTS      (required) space-separated hosts, one per validator
#   SSH_PROXY_JUMP       (default empty)
#   CLIENT_HOST          (required)
#   REMOTE_DIR           (default linera)
#   LINERA_SRC           (default ~/work/linera/linera-protocol)
#   BUILD_PROFILE        (default release)
#   SKIP_BUILD           (default false) honored only for the build step, which happens once
#   SKIP_BINARY_DEPLOY   (default false) honored only for the *first* combo's deploy -- binaries
#                         don't change between combos, so every later combo forces this true,
#                         same pattern as run_validator_count_sweep.sh
#   TOTAL_CORES          (default: `nproc` probed on VALIDATOR_HOSTS[0]) fixed per-validator
#                         core budget every combo must sum to
#   COMBOS               (default "1:1:1 1:2:1 1:4:1 1:1:2 2:2:2 2:4:2") space-separated
#                         RESERVED_CORES:STORAGE_CORES:CORES_PER_SHARD triples. NUM_SHARDS is
#                         derived per combo as floor((TOTAL_CORES - RESERVED_CORES -
#                         STORAGE_CORES) / CORES_PER_SHARD); a combo that derives to 0 shards is
#                         skipped with a warning.
#   NUM_CLIENTS, CHAINS_PER_CLIENT, BPS_PER_CLIENT, RUNTIME_SECONDS
#                         (defaults 4, 5, 20, 15) the one fixed load level applied to every
#                         combo. Deliberately modest -- this is about a clean per-range CPU
#                         read, not saturation. Worth eyeballing after the first combo: if the
#                         busiest range's CPU% is near 0, raise the load; if some range is
#                         already pegged near 100%, that combo is capacity-bound and not a fair
#                         comparison point at this load.
#   TRANSACTIONS_PER_BLOCK, TRAFFIC_MODE, CLIENT_MODE, LIGHT_CERTIFICATES
#                         passed through to run_lite_benchmark_parallel.sh (defaults 1,
#                         independent, lite, false)
#   TRANSACTIONS_PER_BLOCK_FILE (optional) path *on CLIENT_HOST* to a file with one block size
#                         per line (e.g. ethereum_txs_per_block_19m_to_21m.csv, header
#                         stripped) -- overrides TRANSACTIONS_PER_BLOCK when set; see
#                         run_lite_benchmark_parallel.sh
#   TRANSACTIONS_PER_BLOCK_SCALE (default 1.0) scales every entry of that file
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default)
#   INITIAL_AMOUNT        (default 1000000000)
#   PERF_PROFILE          (default true) sample each core range with `perf record -C <range> -g`
#                         for the duration of every combo's burst, then save a `perf report
#                         --stdio` text summary (top functions by CPU share) per range per host.
#                         Profiles by CPU range rather than by PID -- matches the proxy/storage/
#                         shard split this script already measures, and sidesteps tracking
#                         dozens of individual shard-worker PIDs. Requires `perf` and Grid5000's
#                         `sudo-g5k` (root on your own reserved node) on every validator host;
#                         auto-disables with a warning if either is missing. Raw perf.data stays
#                         on the remote host (overwritten each combo); only the text report is
#                         pulled back, to avoid perf.data format/version mismatches between the
#                         remote kernel and whatever reads it back locally.
#   PERF_FREQ             (default 99) sampling frequency in Hz (odd number, avoids lockstep
#                         with periodic kernel/timer activity)
#   OUT_DIR               (default ./results/core_split_grid5k/<timestamp>)

VALIDATOR_HOSTS="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of hosts, one per validator}"
read -ra VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS}"
NUM_VALIDATORS="${#VALIDATOR_HOSTS_ARR[@]}"
SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
CLIENT_HOST="${CLIENT_HOST:?set CLIENT_HOST}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"
TOTAL_CORES="${TOTAL_CORES:-}"
COMBOS="${COMBOS:-1:1:1 1:2:1 1:4:1 1:1:2 2:2:2 2:4:2}"
NUM_CLIENTS="${NUM_CLIENTS:-4}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-20}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-15}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
TRANSACTIONS_PER_BLOCK_SCALE="${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
CLIENT_MODE="${CLIENT_MODE:-lite}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-false}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
INITIAL_AMOUNT="${INITIAL_AMOUNT:-1000000000}"
PERF_PROFILE="${PERF_PROFILE:-true}"
PERF_FREQ="${PERF_FREQ:-99}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-./results/core_split_grid5k/${RUN_ID}}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${OUT_DIR}"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "reserved_cores,storage_cores,cores_per_shard,num_shards,requested_bps,committed,failed,achieved_bps,p50_ms,p95_ms,proxy_cpu_pct_min_avg_max,storage_cpu_pct_min_avg_max,shard_cpu_pct_min_avg_max,client_cpu_pct,status" > "${SUMMARY_CSV}"

# See run_committee_grid5k.sh for why this is -o User=... rather than user@host (hosts double
# as NODE_HOST) and why ControlMaster/ControlPersist matter (avoids re-tripping the bastion's
# connection-rate limiting across dozens of calls to the same handful of hosts per combo).
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
# Must match run_committee_grid5k.sh's own state_dir_for() exactly -- that's the directory each
# host's per-validator state (and, here, where we cd to run perf) actually lives in, namespaced
# per host because Grid5000 shares $HOME via NFS across a site (see run_committee_grid5k.sh).
state_dir_for() { echo "${REMOTE_DIR}/state-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

cargo_flags=()
target_dir="debug"
case "${BUILD_PROFILE}" in
  release) cargo_flags=(--release --config profile.release.debug=false); target_dir="release" ;;
  debug) ;;
  *) echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2; exit 1 ;;
esac
bin_src="${LINERA_SRC}/target/${target_dir}"

if [ "${SKIP_BUILD}" = "true" ]; then
  echo "==> [1/4] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/4] Building validator + client binaries natively (${BUILD_PROFILE})"
  (
    cd "${LINERA_SRC}"
    cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server
  )
fi

if [ -z "${TOTAL_CORES}" ]; then
  TOTAL_CORES="$(ssh_j "${VALIDATOR_HOSTS_ARR[0]}" nproc)"
  echo "==> Probed TOTAL_CORES=${TOTAL_CORES} on ${VALIDATOR_HOSTS_ARR[0]}"
fi

if [ "${PERF_PROFILE}" = "true" ]; then
  echo "==> Enabling per-core perf sampling on every validator host (requires perf + sudo-g5k)"
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    if ! ssh_j "${host}" "command -v perf >/dev/null && command -v sudo-g5k >/dev/null" 2>/dev/null; then
      echo "  ${host}: perf or sudo-g5k not found -- disabling PERF_PROFILE for this run" >&2
      PERF_PROFILE=false
      break
    fi
    # Debian's default perf_event_paranoid=3 blocks unprivileged perf entirely; -1 removes all
    # restriction. sudo-g5k is Grid5000's own root-on-your-own-reserved-node helper (backed by
    # a NOPASSWD sudoers entry for g5k-backend-sudo) -- confirmed working interactively before
    # relying on it here.
    ssh_j "${host}" "sudo-g5k sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'" >/dev/null 2>&1 || {
      echo "  ${host}: could not set perf_event_paranoid via sudo-g5k -- disabling PERF_PROFILE" >&2
      PERF_PROFILE=false
      break
    }
  done
  [ "${PERF_PROFILE}" = "true" ] && echo "  perf sampling ready on: ${VALIDATOR_HOSTS_ARR[*]}"
fi

echo "==> [2/4] Deploying client to ${CLIENT_HOST}:${REMOTE_DIR}/ (once, reused across every combo)"
ssh_j "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync_j "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp_j "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh_j "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

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
read_cpu_stat_all() { ssh_j -o ConnectTimeout=5 "$1" "grep '^cpu' /proc/stat" 2>/dev/null; }
cpu_range_utilization_pct() {
  awk -v b="$1" -v a="$2" -v s="$3" -v e="$4" '
    function accumulate(text, tot, idl,    nlines, lines, i, n, fields, nf, core, j) {
      nlines = split(text, lines, "\n")
      for (i = 1; i <= nlines; i++) {
        if (lines[i] == "") continue
        nf = split(lines[i], fields, " ")
        core = fields[1]; sub(/^cpu/, "", core)
        if (core == "") continue
        n = core + 0
        if (n < s || n > e) continue
        for (j = 2; j <= nf; j++) tot[n] += fields[j]
        idl[n] = fields[5] + fields[6]
      }
    }
    BEGIN {
      if (b == "" || a == "") { print "NaN"; exit }
      accumulate(b, bt, bi); accumulate(a, at, ai)
      dt = 0; di = 0
      for (n = s; n <= e; n++) { dt += (at[n] - bt[n]); di += (ai[n] - bi[n]) }
      if (dt <= 0) { print "0.0"; exit }
      printf "%.1f", 100 * (1 - di / dt)
    }'
}
min_avg_max() {
  awk -v vals="$1" 'BEGIN{
    n=split(vals,a," ");
    if (n==0) { print "NaN/NaN/NaN"; exit }
    mn=a[1]; mx=a[1]; sum=0
    for (i=1;i<=n;i++) { if (a[i]<mn) mn=a[i]; if (a[i]>mx) mx=a[i]; sum+=a[i] }
    printf "%.1f/%.1f/%.1f", mn, sum/n, mx
  }'
}

first_combo=true
combo_num=0
for combo in ${COMBOS}; do
  combo_num=$((combo_num + 1))
  reserved="${combo%%:*}"
  rest="${combo#*:}"
  storage="${rest%%:*}"
  cps="${rest#*:}"
  budget_left=$((TOTAL_CORES - reserved - storage))
  if [ "${budget_left}" -lt "${cps}" ] || [ "${cps}" -le 0 ]; then
    echo "==================== combo ${combo_num} (${combo}): SKIPPED -- budget ${budget_left} < cores_per_shard ${cps} ===================="
    echo "${reserved},${storage},${cps},,,,,,,,,,,,skipped: budget ${budget_left} < cores_per_shard ${cps}" >> "${SUMMARY_CSV}"
    continue
  fi
  num_shards=$((budget_left / cps))
  echo "==================== combo ${combo_num}: reserved=${reserved} storage=${storage} cores_per_shard=${cps} -> num_shards=${num_shards} (budget ${TOTAL_CORES}) $(date +%H:%M:%S) ===================="

  combo_log="${OUT_DIR}/combo_${combo_num}_${reserved}_${storage}_${cps}.log"
  combo_state_dir="$(mktemp -d)"
  skip_deploy="${SKIP_BINARY_DEPLOY}"
  [ "${first_combo}" = true ] || skip_deploy=true

  set +e
  {
    VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
      BIN_SRC_DIR="${bin_src}" STATE_DIR="${combo_state_dir}" SKIP_BINARY_DEPLOY="${skip_deploy}" \
      NUM_SHARDS="${num_shards}" CORES_PER_SHARD="${cps}" RESERVED_CORES="${reserved}" \
      STORAGE_CORES="${storage}" STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS}" \
      INITIAL_AMOUNT="${INITIAL_AMOUNT}" ACTION=start \
      "${LOCAL_DIR}/scripts/run_committee_grid5k.sh"
  } > "${combo_log}" 2>&1
  start_status=$?
  set -e
  first_combo=false

  if [ "${start_status}" -ne 0 ]; then
    echo "  combo ${combo_num} FAILED to start committee -- see ${combo_log}" >&2
    echo "${reserved},${storage},${cps},${num_shards},,,,,,,,,,,failed: committee start (exit ${start_status})" >> "${SUMMARY_CSV}"
    VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
      ACTION=stop "${LOCAL_DIR}/scripts/run_committee_grid5k.sh" >> "${combo_log}" 2>&1 || true
    rm -rf "${combo_state_dir}"
    continue
  fi

  scp_j "${combo_state_dir}/admin_wallet.json" "${combo_state_dir}/admin_keystore.json" \
    "${combo_state_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/" >> "${combo_log}" 2>&1

  pool_size=$((NUM_CLIENTS * CHAINS_PER_CLIENT))
  set +e
  ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    NUM_CHAINS=${pool_size} OUTPUT_FILE=./chain_pool.txt \
    ./scripts/provision_super_owner_chains.sh" >> "${combo_log}" 2>&1
  provision_status=$?
  set -e
  if [ "${provision_status}" -ne 0 ]; then
    echo "  combo ${combo_num} FAILED to provision chains -- see ${combo_log}" >&2
    echo "${reserved},${storage},${cps},${num_shards},,,,,,,,,,,failed: chain provisioning" >> "${SUMMARY_CSV}"
    VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
      ACTION=stop "${LOCAL_DIR}/scripts/run_committee_grid5k.sh" >> "${combo_log}" 2>&1 || true
    rm -rf "${combo_state_dir}"
    continue
  fi

  reserved_end=$((reserved - 1))
  storage_start="${reserved}"
  storage_end=$((reserved + storage - 1))
  shard_start=$((reserved + storage))
  shard_end=$((reserved + storage + num_shards * cps - 1))

  requested_bps=$((NUM_CLIENTS * BPS_PER_CLIENT))
  validator_stats_before=()
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    validator_stats_before+=("$(read_cpu_stat_all "${host}")")
  done
  # Also sample the client host: with enough concurrent lite-benchmark client processes, the
  # driver machine itself can become the bottleneck, which would silently cap achieved_bps and
  # make a validator-side combo look artificially load-limited when it isn't.
  client_stat_before="$(read_cpu_stat_all "${CLIENT_HOST}")"

  # Sample each core range with perf for the same window as the burst below, so "what's the
  # hottest function" is answered for the load this combo actually saw, not an idle machine.
  # -C (CPU range) rather than -p (PID): captures every process pinned to that range at once
  # (the whole point for the shard range, which can be a few dozen worker processes), and
  # avoids the driver needing to know each host's worker PIDs at all.
  perf_pids=()
  if [ "${PERF_PROFILE}" = "true" ]; then
    for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
      if [ "${reserved}" -gt 0 ]; then
        ssh_j "${host}" "cd $(state_dir_for "${host}") && perf record -C 0-${reserved_end} -g -F ${PERF_FREQ} -o perf_proxy.data -- sleep ${RUNTIME_SECONDS}" >> "${combo_log}" 2>&1 &
        perf_pids+=($!)
      fi
      if [ "${storage}" -gt 0 ]; then
        ssh_j "${host}" "cd $(state_dir_for "${host}") && perf record -C ${storage_start}-${storage_end} -g -F ${PERF_FREQ} -o perf_storage.data -- sleep ${RUNTIME_SECONDS}" >> "${combo_log}" 2>&1 &
        perf_pids+=($!)
      fi
      ssh_j "${host}" "cd $(state_dir_for "${host}") && perf record -C ${shard_start}-${shard_end} -g -F ${PERF_FREQ} -o perf_shard.data -- sleep ${RUNTIME_SECONDS}" >> "${combo_log}" 2>&1 &
      perf_pids+=($!)
    done
  fi

  experiment_name="combo_${RUN_ID}_${combo_num}"
  set +e
  ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=${NUM_CLIENTS} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
    BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
    TRANSACTIONS_PER_BLOCK_FILE=${TRANSACTIONS_PER_BLOCK_FILE} TRANSACTIONS_PER_BLOCK_SCALE=${TRANSACTIONS_PER_BLOCK_SCALE} \
    TRAFFIC_MODE=${TRAFFIC_MODE} LIGHT_CERTIFICATES=${LIGHT_CERTIFICATES} CLIENT_MODE=${CLIENT_MODE} \
    RUNTIME_SECONDS=${RUNTIME_SECONDS} \
    EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name} \
    ./scripts/run_lite_benchmark_parallel.sh" >> "${combo_log}" 2>&1
  burst_status=$?
  set -e

  if [ "${#perf_pids[@]}" -gt 0 ]; then
    wait "${perf_pids[@]}" 2>/dev/null || true
    i=0
    for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
      for role in proxy storage shard; do
        case "${role}" in
          proxy) [ "${reserved}" -gt 0 ] || continue ;;
          storage) [ "${storage}" -gt 0 ] || continue ;;
        esac
        report_file="${OUT_DIR}/combo_${combo_num}_${role}_host${i}.perf.txt"
        ssh_j "${host}" "cd $(state_dir_for "${host}") && perf report --stdio -i perf_${role}.data --sort=overhead,symbol -g none 2>&1" > "${report_file}" 2>&1 || \
          echo "  warning: perf report failed for combo ${combo_num} ${role} on ${host}" >&2
      done
      i=$((i + 1))
    done
    echo "  --- top functions by CPU share (host0, combo ${combo_num}) ---"
    for role in proxy storage shard; do
      f="${OUT_DIR}/combo_${combo_num}_${role}_host0.perf.txt"
      [ -f "${f}" ] || continue
      echo "  [${role}]"
      grep -E '^\s+[0-9]+\.[0-9]+%' "${f}" | head -5 | sed 's/^/    /' || echo "    (no samples / perf report failed -- see ${f})"
    done
  fi

  reserved_vals="" storage_vals="" shard_vals=""
  i=0
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    after="$(read_cpu_stat_all "${host}")"
    if [ "${reserved}" -gt 0 ]; then
      reserved_vals="${reserved_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" 0 "${reserved_end}")"
    fi
    if [ "${storage}" -gt 0 ]; then
      storage_vals="${storage_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" "${storage_start}" "${storage_end}")"
    fi
    shard_vals="${shard_vals} $(cpu_range_utilization_pct "${validator_stats_before[$i]}" "${after}" "${shard_start}" "${shard_end}")"
    i=$((i + 1))
  done
  proxy_summary="$(min_avg_max "${reserved_vals}")"
  storage_summary="$(min_avg_max "${storage_vals}")"
  shard_summary="$(min_avg_max "${shard_vals}")"
  client_stat_after="$(read_cpu_stat_all "${CLIENT_HOST}")"
  client_cpu_pct="$(cpu_range_utilization_pct "${client_stat_before}" "${client_stat_after}" 0 9999)"

  level_dir="$(mktemp -d)"
  rsync_j --exclude='wallet.json' --exclude='keystore.json' \
    "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/${experiment_name}/" "${level_dir}/" >> "${combo_log}" 2>&1 || \
    echo "  warning: failed to fetch combo ${combo_num} results from ${CLIENT_HOST}" >&2
  ssh_j "${CLIENT_HOST}" "rm -rf ${REMOTE_DIR}/results/lite_benchmark/${experiment_name}" >> "${combo_log}" 2>&1 || true

  durations_file="$(mktemp)"
  committed=0 failed=0
  for csv in "${level_dir}"/client_*/transfers.csv; do
    [ -f "${csv}" ] || continue
    committed=$((committed + $(awk -F, 'NR>1 && $5=="committed"' "${csv}" | wc -l)))
    failed=$((failed + $(awk -F, 'NR>1 && $5=="failed"' "${csv}" | wc -l)))
    awk -F, 'NR>1 && $5=="committed" { print $6 }' "${csv}" >> "${durations_file}"
  done
  sort -n -o "${durations_file}" "${durations_file}"
  p50_us="$(percentile "${durations_file}" 50)"
  p95_us="$(percentile "${durations_file}" 95)"
  p50_ms="$(awk -v v="${p50_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p95_ms="$(awk -v v="${p95_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  achieved_bps="$(awk -v c="${committed}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"

  status="ok"
  [ "${burst_status}" -ne 0 ] && status="burst exited ${burst_status}"
  [ "${failed}" -gt 0 ] && status="${status}; ${failed} failed block(s)"

  printf "  reserved=%s storage=%s cores_per_shard=%s shards=%s | achieved=%sbps (req %sbps) p50=%sms p95=%sms | proxy=%s%% storage=%s%% shard=%s%% client=%s%% | %s\n" \
    "${reserved}" "${storage}" "${cps}" "${num_shards}" "${achieved_bps}" "${requested_bps}" \
    "${p50_ms}" "${p95_ms}" "${proxy_summary}" "${storage_summary}" "${shard_summary}" "${client_cpu_pct}" "${status}"
  if awk -v c="${client_cpu_pct}" 'BEGIN{exit !(c+0 >= 85)}' 2>/dev/null; then
    echo "  WARNING: client host CPU at ${client_cpu_pct}% during this burst -- achieved_bps may be" >&2
    echo "    limited by the client driver, not the validators. Add more client processes/hosts" >&2
    echo "    or lower per-process load before trusting this combo's throughput number." >&2
  fi
  echo "${reserved},${storage},${cps},${num_shards},${requested_bps},${committed},${failed},${achieved_bps},${p50_ms},${p95_ms},${proxy_summary},${storage_summary},${shard_summary},${client_cpu_pct},${status}" >> "${SUMMARY_CSV}"

  rm -f "${durations_file}"
  rm -rf "${level_dir}" "${combo_state_dir}"

  echo "==> [3/4] Tearing down combo ${combo_num}"
  VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
    ACTION=stop "${LOCAL_DIR}/scripts/run_committee_grid5k.sh" >> "${combo_log}" 2>&1 || \
    echo "  warning: teardown reported an error for combo ${combo_num} -- see ${combo_log}" >&2
done

echo
echo "==> [4/4] Done. Summary: ${SUMMARY_CSV}"
