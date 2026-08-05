#!/usr/bin/env bash
set -euo pipefail

# CPU/hotspot profiling without perf/root: the validator already exposes Prometheus
# /metrics on every shard + the proxy (linera-metrics crate), including Tokio runtime
# stats (per-worker busy-seconds -- real CPU time spent in async tasks) and per-RPC-method
# latency/count histograms (server_request_latency, labeled by method_name). This script
# starts a fresh validator, snapshots /metrics from the proxy and every shard before and
# after a load-generating run, and diffs the counters/histograms to produce a breakdown of
# where time (and thus CPU) is going -- exactly the kind of report to hand to devs, with no
# code changes, no perf, no root.
#
# Assumes run_node.sh's usual layout: STATE_DIR/server_config.json has proxy+shard ports.
# Metrics endpoints are internal (localhost-only from sparta's perspective) so this is run
# entirely over SSH into the node host -- the client's single open port is untouched.
#
# Configuration (env vars):
#   NODE_HOST          (default sparta) ssh alias for the validator machine
#   CLIENT_HOST         (default yiannis-testbed) ssh alias for the load-generating client
#   NODE_ADDRESS        (default 193.60.241.98) public IP passed to run_node.sh
#   REMOTE_DIR           (default linera) remote checkout dir on both hosts
#   NUM_SHARDS           (default 19)
#   CORES_PER_SHARD      (default 0 = unpinned) passed through to run_node.sh -- set >0 to
#                          test pinned configurations (see RESERVED_CORES/STORAGE_CORES below)
#   RESERVED_CORES       (default 2) passed through to run_node.sh (proxy's cores, only
#                          used when CORES_PER_SHARD > 0)
#   STORAGE_CORES        (default 0 = shares RESERVED_CORES, old behavior) passed through to
#                          run_node.sh -- dedicated storage-server cores, only used when
#                          CORES_PER_SHARD > 0; set close to NUM_SHARDS to test whether
#                          storage (a single shared in-memory backend) is contended
#   SHARD_TOKIO_THREADS  (default 0 = same as CORES_PER_SHARD, old behavior) passed through
#                          to run_node.sh -- lets a shard have more async worker threads
#                          than pinned cores, to test whether the 1:1 thread/core cap is
#                          starving shards that own many concurrently-active chains
#   RUNTIME_SECONDS      (default 30) duration of the load-generating run
#   NUM_CLIENTS          (default 8) parallel lite-benchmark client processes
#   CHAINS_PER_CLIENT    (default 5)
#   BPS_PER_CLIENT       (default 100)
#   TRANSACTIONS_PER_BLOCK (default 1) transactions packed per block, passed through to
#                          run_lite_benchmark_parallel.sh
#   OUT_DIR              (default ./profile_out/<timestamp>) where raw snapshots + report go

NODE_HOST="${NODE_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
NODE_ADDRESS="${NODE_ADDRESS:-193.60.241.98}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
NUM_SHARDS="${NUM_SHARDS:-19}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
RESERVED_CORES="${RESERVED_CORES:-2}"
STORAGE_CORES="${STORAGE_CORES:-0}"
SHARD_TOKIO_THREADS="${SHARD_TOKIO_THREADS:-0}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-30}"
NUM_CLIENTS="${NUM_CLIENTS:-8}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-100}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
OUT_DIR="${OUT_DIR:-./profile_out/$(date +%Y%m%d_%H%M%S)}"

mkdir -p "${OUT_DIR}"
echo "==> Output: ${OUT_DIR}"

echo "==> Stopping any previous node on ${NODE_HOST}"
ssh "${NODE_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true

echo "==> Starting validator on ${NODE_HOST} (${NUM_SHARDS} shards, CORES_PER_SHARD=${CORES_PER_SHARD}, RESERVED_CORES=${RESERVED_CORES}, STORAGE_CORES=${STORAGE_CORES})"
ssh "${NODE_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${NODE_ADDRESS} NUM_SHARDS=${NUM_SHARDS} \
   CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} STORAGE_CORES=${STORAGE_CORES} \
   SHARD_TOKIO_THREADS=${SHARD_TOKIO_THREADS} \
   START_FAUCET=false ${REMOTE_DIR}/scripts/run_node.sh" \
  > "${OUT_DIR}/node_start.log" 2>&1
cleanup() {
  echo "==> Stopping validator"
  ssh "${NODE_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" || true
}
trap cleanup EXIT

echo "==> Discovering metrics ports"
mapfile -t METRICS_PORTS < <(ssh "${NODE_HOST}" \
  "jq -r '.internal_network.proxies[].metrics_port, .internal_network.shards[].metrics_port' ${REMOTE_DIR}/state/server_config.json")
echo "    ${#METRICS_PORTS[@]} endpoints: ${METRICS_PORTS[*]}"

snapshot() {
  local label="$1"
  local dir="${OUT_DIR}/${label}"
  mkdir -p "${dir}"
  for port in "${METRICS_PORTS[@]}"; do
    ssh "${NODE_HOST}" "curl -s 127.0.0.1:${port}/metrics" > "${dir}/${port}.txt" 2>/dev/null || true
  done
}

echo "==> Taking 'before' snapshot"
snapshot before

echo "==> Relaying fresh wallet + genesis to ${CLIENT_HOST}"
tmp_wallet_dir="$(mktemp -d)"
scp "${NODE_HOST}:${REMOTE_DIR}/state/admin_wallet.json" \
  "${NODE_HOST}:${REMOTE_DIR}/state/admin_keystore.json" \
  "${NODE_HOST}:${REMOTE_DIR}/state/genesis.json" "${tmp_wallet_dir}/" > /dev/null
scp "${tmp_wallet_dir}/admin_wallet.json" "${tmp_wallet_dir}/admin_keystore.json" \
  "${tmp_wallet_dir}/genesis.json" "${CLIENT_HOST}:${REMOTE_DIR}/" > /dev/null
rm -rf "${tmp_wallet_dir}"

echo "==> Provisioning chains on ${CLIENT_HOST}"
chains_needed=$((NUM_CLIENTS * CHAINS_PER_CLIENT))
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${chains_needed} OUTPUT_FILE=./profile_chains.txt \
  ./scripts/provision_super_owner_chains.sh" > "${OUT_DIR}/provision.log" 2>&1

echo "==> Running ${RUNTIME_SECONDS}s load (NUM_CLIENTS=${NUM_CLIENTS}, BPS_PER_CLIENT=${BPS_PER_CLIENT})"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  CHAIN_IDS_FILE=./profile_chains.txt NUM_CLIENTS=${NUM_CLIENTS} CHAINS_PER_CLIENT=${CHAINS_PER_CLIENT} \
  BPS_PER_CLIENT=${BPS_PER_CLIENT} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} TRAFFIC_MODE=independent \
  RUNTIME_SECONDS=${RUNTIME_SECONDS} EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=profile_run \
  ./scripts/run_lite_benchmark_parallel.sh" > "${OUT_DIR}/load_run.log" 2>&1

echo "==> Taking 'after' snapshot"
snapshot after

echo "==> Generating report"
python3 "$(dirname "$0")/analyze_metrics_snapshot.py" "${OUT_DIR}/before" "${OUT_DIR}/after" "${RUNTIME_SECONDS}" \
  | tee "${OUT_DIR}/report.txt"

echo "==> Done. Raw snapshots and report in ${OUT_DIR}"
