#!/usr/bin/env bash
set -euo pipefail

# Linera isn't optimized for single-chain throughput (each chain's blocks are strictly
# sequential), so for a fixed total requested bps per client, spreading it across more
# chains (lower bps/chain) may sustain higher aggregate throughput than fewer chains at
# higher bps/chain. This starts the node once (fixed, best-known config), provisions the
# largest chain pool needed once, then runs run_lite_benchmark_parallel.sh once per
# CHAINS_PER_CLIENT value in CHAINS_PER_CLIENT_VALUES at a fixed NUM_CLIENTS and
# BPS_PER_CLIENT (so bps/chain = BPS_PER_CLIENT / chains_per_client varies), reporting
# achieved throughput/failures/latency for each so they can be compared directly.
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT -- as in
#     find_max_tps.sh
#   NUM_SHARDS, CORES_PER_SHARD, STORAGE_TOKIO_THREADS -- validator config (defaults match
#     the best-known setup: 19 shards, unpinned, storage-server capped at 8 threads)
#   NUM_CLIENTS            (default 10) fixed client count for every level in the sweep
#   BPS_PER_CLIENT         (default 150) fixed total bps requested per client; each level
#                          divides this across its own CHAINS_PER_CLIENT_VALUES entry
#   CHAINS_PER_CLIENT_VALUES (default "5 15 30") space-separated list of chains/client to
#                          try, largest value sizes the provisioned chain pool
#   TRANSACTIONS_PER_BLOCK (default 10)
#   TRAFFIC_MODE           (default independent)
#   RUNTIME_SECONDS        (default 15)
#   BUILD_PROFILE          (default release) -- assumes SKIP_BUILD-style reuse; this script
#                          never builds, only deploys+runs (build separately if needed)
#   LINERA_SRC             (default ~/work/linera/linera-protocol)

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
NUM_SHARDS="${NUM_SHARDS:-19}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-8}"
NUM_CLIENTS="${NUM_CLIENTS:-10}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-150}"
CHAINS_PER_CLIENT_VALUES="${CHAINS_PER_CLIENT_VALUES:-5 15 30}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-10}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-15}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"

max_chains_per_client=0
for c in ${CHAINS_PER_CLIENT_VALUES}; do
  [ "${c}" -gt "${max_chains_per_client}" ] && max_chains_per_client="${c}"
done
pool_size=$((NUM_CLIENTS * max_chains_per_client))

echo "==> Deploying scripts (binaries assumed already current on both hosts)"
scp "${LOCAL_DIR}/scripts/run_node.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
  "${SPARTA_HOST}:${REMOTE_DIR}/scripts/" > /dev/null
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/" > /dev/null
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/scripts/*.sh"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/scripts/*.sh"

echo "==> Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards, CORES_PER_SHARD=${CORES_PER_SHARD}, STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS}"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} \
   NUM_SHARDS=${NUM_SHARDS} CORES_PER_SHARD=${CORES_PER_SHARD} STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} \
   START_FAUCET=false ${REMOTE_DIR}/scripts/run_node.sh"
sleep 3

cleanup_node() {
  echo "==> Stopping validator on ${SPARTA_HOST}"
  ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" || true
}
trap cleanup_node EXIT

echo "==> Relaying admin wallet + genesis config"
tmp_wallet_dir="$(mktemp -d)"
scp "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_wallet.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/admin_keystore.json" \
  "${SPARTA_HOST}:${REMOTE_DIR}/state/genesis.json" "${tmp_wallet_dir}/"
scp "${tmp_wallet_dir}/admin_wallet.json" "${tmp_wallet_dir}/admin_keystore.json" \
  "${tmp_wallet_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/"
rm -rf "${tmp_wallet_dir}"

echo "==> Provisioning ${pool_size} super-owner chains (largest CHAINS_PER_CLIENT_VALUES x NUM_CLIENTS)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${pool_size} OUTPUT_FILE=./chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh"

percentile() {
  local file="$1" pct="$2" n idx
  n="$(wc -l < "${file}")"
  [ "${n}" -eq 0 ] && return
  idx=$(( (pct * n + 99) / 100 ))
  [ "${idx}" -lt 1 ] && idx=1
  [ "${idx}" -gt "${n}" ] && idx="${n}"
  sed -n "${idx}p" "${file}"
}

echo "==> Sweeping CHAINS_PER_CLIENT in [${CHAINS_PER_CLIENT_VALUES}] at fixed NUM_CLIENTS=${NUM_CLIENTS}, BPS_PER_CLIENT=${BPS_PER_CLIENT}"
printf "%-16s %-12s %-10s %-8s %-12s %-10s %-10s\n" \
  "chains/client" "bps/chain" "committed" "failed" "achieved_tps" "p50_ms" "p95_ms"

for chains_per_client in ${CHAINS_PER_CLIENT_VALUES}; do
  bps_per_chain="$(awk -v b="${BPS_PER_CLIENT}" -v c="${chains_per_client}" 'BEGIN{printf "%.1f", b/c}')"
  experiment_name="sweep_${RUN_ID}_cpc${chains_per_client}"

  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=${NUM_CLIENTS} CHAINS_PER_CLIENT=${chains_per_client} \
    BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
    TRAFFIC_MODE=${TRAFFIC_MODE} RUNTIME_SECONDS=${RUNTIME_SECONDS} \
    EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=${experiment_name} \
    ./scripts/run_lite_benchmark_parallel.sh" > /dev/null

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

  p50_us="$(percentile "${durations_file}" 50)"
  p95_us="$(percentile "${durations_file}" 95)"
  p50_ms="$(awk -v v="${p50_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  p95_ms="$(awk -v v="${p95_us:-0}" 'BEGIN{printf "%.1f", v/1000}')"
  achieved_tps="$(awk -v c="${total_tx}" -v t="${RUNTIME_SECONDS}" 'BEGIN{printf "%.1f", c/t}')"

  printf "%-16s %-12s %-10s %-8s %-12s %-10s %-10s\n" \
    "${chains_per_client}" "${bps_per_chain}" "${committed}" "${failed}" "${achieved_tps}" "${p50_ms}" "${p95_ms}"

  rm -rf "${level_dir}"
done
