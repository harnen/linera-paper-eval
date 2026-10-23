#!/usr/bin/env bash
set -euo pipefail

# Grid5000, multi-validator counterpart to run_elasticity_experiment.sh (paper Fig. 6): a real
# N-validator committee (one validator per physical host, via run_committee_grid5k.sh), each
# running its own `linera-server manager` watching its own load and adapting its own worker
# count independently -- no scripted scaling, we only vary traffic and let every validator's
# manager react on its own. Written to support the committee sizes (5v, 10v) the single-host
# run_elasticity_experiment.sh was never built for.
#
# Why a new script instead of extending run_elasticity_experiment.sh in place: that script's
# SPARTA_HOST/SPARTA_ADDRESS are singular throughout (one `ssh "${SPARTA_HOST}" ...` per step),
# and its log collection pulls exactly one manager.log. The actual committee bring-up/teardown,
# deploy, and per-host manager launch are NOT the part that needed rewriting -- run_committee_
# grid5k.sh and run_single_validator_grid5k.sh already start one full validator (shards, proxy,
# storage, and -- with START_MANAGER=true -- its own manager) per host in VALIDATOR_HOSTS, and
# already relay a committee-wide genesis/admin wallet that provision_super_owner_chains.sh /
# run_lite_benchmark_parallel.sh already consume unchanged regardless of committee size (see
# run_committee_grid5k.sh's own closing message). This script is the thin orchestration layer on
# top of those three existing pieces, mirroring run_elasticity_experiment.sh's shape (schedule
# building, provisioning, one continuous --bps-schedule run, result collection) but driving a
# real distributed committee instead of one host.
#
# Each validator's manager makes its own independent scaling decision from its own local load --
# every validator is sent the same blocks (ordinary BFT broadcast), so in practice every
# validator's manager should track the offered schedule in near lock-step (same load in, same
# decision out), modulo real per-host timing jitter. combined_manager_events.py / plot_elasticity.py
# --manager-logs-dir sums every validator's own worker-count timeline into one committee-wide
# "total active workers" curve (and base_shards into a committee-wide floor) for panels (a)/(d) --
# per-validator jitter shows up as the curve not being a perfectly clean multiple of one
# validator's own timeline, which is itself a real, worth-reporting signal, not noise to hide.
#
# Configuration (env vars):
#   VALIDATOR_HOSTS, CLIENT_HOST, SSH_PROXY_JUMP, SSH_USER, REMOTE_DIR, LINERA_SRC, BUILD_PROFILE,
#     SKIP_BUILD, SKIP_BINARY_DEPLOY -- as in run_committee_grid5k.sh / find_max_tps_grid5k.sh.
#     VALIDATOR_HOSTS must name at least one host per validator (same convention as
#     run_committee_grid5k.sh); CLIENT_HOST is a single host (this experiment's load levels
#     don't need multiple client hosts -- see find_max_tps_grid5k.sh's CLIENT_HOSTS if that ever
#     changes).
#   BASE_SHARDS, NUM_SHARDS, START_MANAGER, CORES_PER_SHARD, RESERVED_CORES, STORAGE_CORES,
#   SHARD_TOKIO_THREADS, STORAGE_TOKIO_THREADS, MANAGER_INTERVAL_MS, MANAGER_HIGH_WATERMARK,
#   MANAGER_LOW_WATERMARK, MANAGER_MAX_MIGRATIONS_PER_ROUND, MANAGER_MAX_DRAINS_PER_ROUND,
#   MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                          applied identically to every validator -- passed straight through to
#                          run_committee_grid5k.sh / run_single_validator_grid5k.sh, same
#                          semantics and defaults as run_elasticity_experiment.sh. Per-validator
#                          shard counts, not committee-wide -- committee-wide capacity is
#                          NUM_VALIDATORS * NUM_SHARDS (quorum-weighted; see required_workers()
#                          in plot_elasticity.py for how the plot accounts for this).
#   NUM_CLIENTS            (default 3) parallel lite-benchmark client processes on CLIENT_HOST
#   CHAINS_PER_CLIENT      (default 10)
#   TRANSACTIONS_PER_BLOCK (default 10) ignored if TRANSACTIONS_PER_BLOCK_FILE is set
#   TRANSACTIONS_PER_BLOCK_FILE, TRANSACTIONS_PER_BLOCK_SCALE
#                          optional real Ethereum-trace block sizing, as in
#                          find_max_tps_grid5k.sh -- unset (fixed TRANSACTIONS_PER_BLOCK) by
#                          default, matching run_elasticity_experiment.sh's prior behavior.
#   TRAFFIC_MODE           (default independent)
#   LIGHT_CERTIFICATES     (default true, unlike run_elasticity_experiment.sh's implicit false --
#                          see feedback_linera_use_optimized_build.md; override to false for a
#                          direct one-to-one comparison against an older single-host run)
#   CLIENT_MODE            (default lite)
#   BPS_SCHEDULE           (optional) explicit total (committee-wide) schedule, comma-separated
#                          offset:bps pairs. If unset, one is built from LOW_BPS/PEAK_BPS/the
#                          segment durations below -- identical construction to
#                          run_elasticity_experiment.sh.
#   LOW_BPS, PEAK_BPS, MED1_FRACTION, MED2_FRACTION, SEG_LOW1, SEG_MED1, SEG_DIP, SEG_PEAK1,
#   SEG_MED2, SEG_PEAK2, SEG_MED1B, SEG_TAIL
#                          same defaults and meaning as run_elasticity_experiment.sh. PEAK_BPS
#                          should be calibrated against this committee size's own ceiling (see
#                          find_max_tps_grid5k.sh / run_validator_traffic_sweep_grid5k.sh for
#                          this committee size), not reused from a different committee size or
#                          the old single-host run.
#   STOP_COMMITTEE_AFTER   (default true)
#   OUT_DIR                (default ./results/elasticity/<validator-count>v_<timestamp>)

VALIDATOR_HOSTS="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of hosts, one per validator}"
read -ra VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS}"
NUM_VALIDATORS="${#VALIDATOR_HOSTS_ARR[@]}"
[ "${NUM_VALIDATORS}" -ge 1 ] || { echo "VALIDATOR_HOSTS must name at least one host" >&2; exit 1; }
CLIENT_HOST="${CLIENT_HOST:?set CLIENT_HOST}"

SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
SKIP_BUILD="${SKIP_BUILD:-true}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-true}"

BASE_SHARDS="${BASE_SHARDS:-2}"
NUM_SHARDS="${NUM_SHARDS:-6}"
START_MANAGER="${START_MANAGER:-true}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
RESERVED_CORES="${RESERVED_CORES:-0}"
STORAGE_CORES="${STORAGE_CORES:-0}"
SHARD_TOKIO_THREADS="${SHARD_TOKIO_THREADS:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-8}"
MANAGER_INTERVAL_MS="${MANAGER_INTERVAL_MS:-2000}"
MANAGER_HIGH_WATERMARK="${MANAGER_HIGH_WATERMARK:-300}"
MANAGER_LOW_WATERMARK="${MANAGER_LOW_WATERMARK:-}"
MANAGER_MAX_MIGRATIONS_PER_ROUND="${MANAGER_MAX_MIGRATIONS_PER_ROUND:-8}"
MANAGER_MAX_DRAINS_PER_ROUND="${MANAGER_MAX_DRAINS_PER_ROUND:-8}"
MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS:-3}"
MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS:-3}"

NUM_CLIENTS="${NUM_CLIENTS:-3}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-10}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
TRANSACTIONS_PER_BLOCK_SCALE="${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-true}"
CLIENT_MODE="${CLIENT_MODE:-lite}"
CLIENT_TOKIO_THREADS="${CLIENT_TOKIO_THREADS:-}"

LOW_BPS="${LOW_BPS:-120}"
PEAK_BPS="${PEAK_BPS:-}"
MED1_FRACTION="${MED1_FRACTION:-0.35}"
MED2_FRACTION="${MED2_FRACTION:-0.6}"
SEG_LOW1="${SEG_LOW1:-50}"
SEG_MED1="${SEG_MED1:-40}"
SEG_DIP="${SEG_DIP:-20}"
SEG_PEAK1="${SEG_PEAK1:-90}"
SEG_MED2="${SEG_MED2:-30}"
SEG_PEAK2="${SEG_PEAK2:-20}"
SEG_MED1B="${SEG_MED1B:-40}"
SEG_TAIL="${SEG_TAIL:-130}"
STOP_COMMITTEE_AFTER="${STOP_COMMITTEE_AFTER:-true}"

BPS_SCHEDULE="${BPS_SCHEDULE:-}"
if [ -z "${BPS_SCHEDULE}" ]; then
  [ -n "${PEAK_BPS}" ] || { echo "set PEAK_BPS (or BPS_SCHEDULE directly) -- calibrate against THIS committee size's own ceiling, see find_max_tps_grid5k.sh" >&2; exit 1; }
  med1_bps="$(awk -v p="${PEAK_BPS}" -v f="${MED1_FRACTION}" 'BEGIN{printf "%d", p*f}')"
  med2_bps="$(awk -v p="${PEAK_BPS}" -v f="${MED2_FRACTION}" 'BEGIN{printf "%d", p*f}')"
  t1=${SEG_LOW1}
  t2=$((t1 + SEG_MED1))
  t3=$((t2 + SEG_DIP))
  t4=$((t3 + SEG_PEAK1))
  t5=$((t4 + SEG_MED2))
  t6=$((t5 + SEG_PEAK2))
  t7=$((t6 + SEG_MED1B))
  total_duration=$((t7 + SEG_TAIL))
  BPS_SCHEDULE="0:${LOW_BPS},${t1}:${med1_bps},${t2}:${LOW_BPS},${t3}:${PEAK_BPS},${t4}:${med2_bps},${t5}:${PEAK_BPS},${t6}:${med1_bps},${t7}:${LOW_BPS}"
else
  total_duration="${RUNTIME_SECONDS:?set RUNTIME_SECONDS when providing BPS_SCHEDULE directly}"
fi
echo "==> Committee-wide workload schedule (total bps): ${BPS_SCHEDULE}"
echo "==> Total duration: ${total_duration}s"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/elasticity/${NUM_VALIDATORS}v_${RUN_ID}}"
mkdir -p "${OUT_DIR}/manager_logs"
echo "==> Output: ${OUT_DIR}"
{
  echo "num_validators=${NUM_VALIDATORS}"
  echo "base_shards=${BASE_SHARDS}"
  echo "num_shards=${NUM_SHARDS}"
  echo "start_manager=${START_MANAGER}"
  echo "bps_schedule=${BPS_SCHEDULE}"
} > "${OUT_DIR}/metadata.txt"

cargo_flags=()
target_dir="debug"
case "${BUILD_PROFILE}" in
  release) cargo_flags=(--release --config profile.release.debug=false); target_dir="release" ;;
  debug) ;;
  *) echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2; exit 1 ;;
esac
bin_src="${LINERA_SRC}/target/${target_dir}"

if [ "${SKIP_BUILD}" = "true" ]; then
  echo "==> [1/7] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/7] Building validator + client binaries natively (${BUILD_PROFILE})"
  ( cd "${LINERA_SRC}" && cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server )
fi

ssh_cm_opts=(-o ControlMaster=auto -o "ControlPath=/tmp/g5k-ssh-cm-%r@%h:%p" -o ControlPersist=15m)
ssh_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then
    ssh -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} -J "${SSH_PROXY_JUMP}" "$@"
  else
    ssh "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  fi
}
scp_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then
    scp -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" -o "ProxyJump=${SSH_PROXY_JUMP}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  else
    scp "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  fi
}
# Same sanitization as run_committee_grid5k.sh's state_dir_for -- must match exactly, since
# we read back from the same per-host state directories it creates.
state_dir_for() { echo "${REMOTE_DIR}/state-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

committee_state_dir="$(mktemp -d)"
echo "==> [2/7] Starting ${NUM_VALIDATORS}-validator committee (${BASE_SHARDS} base / ${NUM_SHARDS} total shards each, manager watching high=${MANAGER_HIGH_WATERMARK} req/s)"
VALIDATOR_HOSTS="${VALIDATOR_HOSTS}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" REMOTE_DIR="${REMOTE_DIR}" \
  BIN_SRC_DIR="${bin_src}" STATE_DIR="${committee_state_dir}" \
  SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY}" \
  NUM_SHARDS="${NUM_SHARDS}" BASE_SHARDS="${BASE_SHARDS}" CORES_PER_SHARD="${CORES_PER_SHARD}" \
  RESERVED_CORES="${RESERVED_CORES}" STORAGE_CORES="${STORAGE_CORES}" \
  SHARD_TOKIO_THREADS="${SHARD_TOKIO_THREADS}" STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS}" \
  START_MANAGER="${START_MANAGER}" \
  MANAGER_INTERVAL_MS="${MANAGER_INTERVAL_MS}" MANAGER_HIGH_WATERMARK="${MANAGER_HIGH_WATERMARK}" \
  MANAGER_LOW_WATERMARK="${MANAGER_LOW_WATERMARK}" \
  MANAGER_MAX_MIGRATIONS_PER_ROUND="${MANAGER_MAX_MIGRATIONS_PER_ROUND}" \
  MANAGER_MAX_DRAINS_PER_ROUND="${MANAGER_MAX_DRAINS_PER_ROUND}" \
  MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS}" MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS}" \
  ACTION=start \
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

# Clock-offset correction: manager.log timestamps are in each validator's own clock. Grid5000
# nodes at one site are NTP-synced to the same source, so host0's offset is used for every
# validator's log rather than resolving each one separately -- if that assumption ever looks
# wrong (manager events from different hosts landing suspiciously out of order relative to the
# schedule), resolve per-host offsets instead.
host0="${VALIDATOR_HOSTS_ARR[0]}"
host0_epoch="$(ssh_j "${host0}" 'date +%s')"
local_epoch="$(date +%s)"
clock_offset=$((host0_epoch - local_epoch))
echo "${clock_offset}" > "${OUT_DIR}/sparta_clock_offset_seconds.txt"

echo "==> [3/7] Deploying client to ${CLIENT_HOST}, relaying committee-wide genesis + admin wallet"
ssh_j "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" != "true" ]; then
  scp_j "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp_j "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh_j "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"
scp_j "${committee_state_dir}/admin_wallet.json" "${committee_state_dir}/admin_keystore.json" \
  "${committee_state_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/"

if [ -n "${TRANSACTIONS_PER_BLOCK_FILE}" ]; then
  tx_block_basename="$(basename "${TRANSACTIONS_PER_BLOCK_FILE}")"
  echo "==> Deploying block-size trace (${tx_block_basename}) to ${CLIENT_HOST}"
  scp_j "${TRANSACTIONS_PER_BLOCK_FILE}" "${CLIENT_HOST}:${REMOTE_DIR}/${tx_block_basename}"
  TRANSACTIONS_PER_BLOCK_FILE_REMOTE="${tx_block_basename}"
else
  TRANSACTIONS_PER_BLOCK_FILE_REMOTE=""
fi

pool_size=$((NUM_CLIENTS * CHAINS_PER_CLIENT))
echo "==> [4/7] Provisioning ${pool_size} super-owner chains on ${CLIENT_HOST}"
ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${pool_size} OUTPUT_FILE=./elasticity_chains.txt \
  ./scripts/provision_super_owner_chains.sh" > "${OUT_DIR}/provision.log" 2>&1

echo "==> [5/7] Running ${total_duration}s continuous workload against the ${NUM_VALIDATORS}-validator committee"
experiment_start_epoch="$(date +%s)"
echo "${experiment_start_epoch}" > "${OUT_DIR}/experiment_start_epoch.txt"

tx_block_args=""
if [ -n "${TRANSACTIONS_PER_BLOCK_FILE_REMOTE}" ]; then
  tx_block_args="TRANSACTIONS_PER_BLOCK_FILE=${TRANSACTIONS_PER_BLOCK_FILE_REMOTE} TRANSACTIONS_PER_BLOCK_SCALE=${TRANSACTIONS_PER_BLOCK_SCALE}"
fi
client_tokio_args=""
[ -n "${CLIENT_TOKIO_THREADS}" ] && client_tokio_args="CLIENT_TOKIO_THREADS=${CLIENT_TOKIO_THREADS}"

ssh_j "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  CHAIN_IDS_FILE=./elasticity_chains.txt NUM_CLIENTS=${NUM_CLIENTS} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
  BPS_SCHEDULE=${BPS_SCHEDULE} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} ${tx_block_args} \
  TRAFFIC_MODE=${TRAFFIC_MODE} LIGHT_CERTIFICATES=${LIGHT_CERTIFICATES} CLIENT_MODE=${CLIENT_MODE} \
  ${client_tokio_args} \
  RUNTIME_SECONDS=${total_duration} EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=elasticity_${RUN_ID} \
  ./scripts/run_lite_benchmark_parallel.sh" > "${OUT_DIR}/run.log" 2>&1

echo "==> [6/7] Pulling client results"
scp_j -r "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/elasticity_${RUN_ID}/client_*" "${OUT_DIR}/"

COMBINED_CSV="${OUT_DIR}/combined_transfers.csv"
echo "chain_id,ts_within_experiment,num_tx,result,duration_micros" > "${COMBINED_CSV}"
for csv in "${OUT_DIR}"/client_*/transfers.csv; do
  [ -f "${csv}" ] || continue
  tail -n +2 "${csv}" >> "${COMBINED_CSV}"
done

echo "==> [7/7] Pulling every validator's manager.log"
if [ "${START_MANAGER}" = "true" ]; then
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    safe_host="$(printf '%s' "${host}" | tr -c 'A-Za-z0-9' '_')"
    scp_j "${host}:$(state_dir_for "${host}")/manager.log" "${OUT_DIR}/manager_logs/${safe_host}.log" \
      || echo "  warning: could not pull manager.log from ${host}" >&2
  done
fi

echo "==> Done."
echo "    Combined transfers: ${COMBINED_CSV} ($(($(wc -l < "${COMBINED_CSV}") - 1)) rows)"
echo "    Manager logs:       ${OUT_DIR}/manager_logs/ ($(ls "${OUT_DIR}/manager_logs" | wc -l) of ${NUM_VALIDATORS} validators)"
echo "    Clock offset (host0 - local, seconds): $(cat "${OUT_DIR}/sparta_clock_offset_seconds.txt")"
echo "    Plot with: scripts/plot_elasticity.py ${OUT_DIR} --manager-logs-dir ${OUT_DIR}/manager_logs"
