#!/usr/bin/env bash
set -euo pipefail

# Runs the lite client sweep script and a given validator setup.
#
# Builds, deploys, starts the validator (optionally with shards pinned to dedicated CPU
# cores via CORES_PER_SHARD), provisions a chain pool, then runs run_lite_benchmark_sweep.sh.
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
#   RESERVED_CORES         (default 2) reserved for storage-server + proxy (see run_validators.sh)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default) passed straight to
#                          run_validators.sh -- caps storage-server's Tokio worker-thread count
#                          independent of CPU pinning; see run_validators.sh for why this matters
#                          (oversized default thread count causes excess futex/parking
#                          overhead relative to storage-server's actual per-call work)
#   STOP_NODE_AFTER        (default true)
#   SKIP_BUILD             (default false) skip `cargo build` entirely and reuse whatever's
#                          already in target/<profile> -- use when only these scripts
#                          changed, not the Rust source
#   SKIP_BINARY_DEPLOY     (default false) skip rsync'ing the (large, slow-over-this-link)
#                          binaries and reuse whatever's already on both remote hosts;
#                          scripts are still re-copied every time (cheap, and we iterate on
#                          those constantly)
#
# Config for the light sweep (passed through):
#   LINERA_WALLET, LINERA_KEYSTORE  (required) same admin wallet used for provisioning
#   BIN_DIR                        (default ../bin relative to this script)
#   NUM_CHAINS_LIST                (default "2 5 10 20 50 100 200")
#   TRAFFIC_MODES                  (default "independent mixed full")
#   TX_PER_BLOCK_LIST              (default "1 10 100")
#   BPS_LIST                       (default "10 100 1000")
#   RUNTIME_SECONDS                (default 60) duration of each individual run
#   INITIAL_BALANCE                (default 1000) passed to provisioning
#   EVAL_OUTPUT_DIR                (default ./data_out)

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
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

NUM_CHAINS_LIST="${NUM_CHAINS_LIST:-2 5 10 20 50 100 200}"
TRAFFIC_MODES="${TRAFFIC_MODES:-independent mixed full}"
TX_PER_BLOCK_LIST="${TX_PER_BLOCK_LIST:-1 10 100}"
BPS_LIST="${BPS_LIST:-10 100 1000}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INITIAL_BALANCE="${INITIAL_BALANCE:-1000}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-./data_out}"

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
  "${LOCAL_DIR}/scripts/run_lite_benchmark_sweep.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/5] Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores + ${RESERVED_CORES} reserved"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT_BASE=${PROXY_PUBLIC_PORT} \
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

# TODO create output dir here

# TODO save experiment config here

echo "Starting sweep..."
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS_LIST=\"${NUM_CHAINS_LIST}\" \
  TRAFFIC_MODES=\"${TRAFFIC_MODES}\" \
  TX_PER_BLOCK_LIST=\"${TX_PER_BLOCK_LIST}\" \
  BPS_LIST=\"${BPS_LIST}\" \
  RUNTIME_SECONDS=${RUNTIME_SECONDS} \
  INITIAL_BALANCE=${INITIAL_BALANCE} \
  ./scripts/run_lite_benchmark_sweep.sh"


# TODO Get results

