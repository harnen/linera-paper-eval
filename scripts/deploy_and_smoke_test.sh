#!/usr/bin/env bash
set -euo pipefail

# End-to-end check: builds the binaries natively on this machine, deploys validator
# binaries+scripts to sparta and client binaries+scripts to yiannis-testbed, starts the
# validator, provisions super-owner chains (no faucet), runs a short lite-benchmark check
# across all three traffic modes, and reports whether everything committed cleanly.
#
# Assumes passwordless SSH (key-based, ssh-config aliases "sparta" / "yiannis-testbed" or
# override SPARTA_HOST/CLIENT_HOST) to both hosts.
#
# Configuration (env vars):
#   SPARTA_ADDRESS         (default 193.60.241.98) address yiannis-testbed can actually
#                          reach sparta's proxy at -- may differ from SPARTA_HOST if that's
#                          only an ssh-config alias/hostname not resolvable from
#                          yiannis-testbed.
#   SPARTA_HOST            (default sparta) ssh alias/host for the validator
#   CLIENT_HOST            (default yiannis-testbed) ssh alias/host for the client
#   REMOTE_DIR             (default linera) remote directory (relative to $HOME) on both
#                          hosts to deploy into
#   PROXY_PUBLIC_PORT      (default 4001)
#   BUILD_PROFILE          (default debug) debug | release
#   LINERA_SRC             (default ~/work/linera/linera-protocol) local fork checkout
#   NUM_CHAINS             (default 3)
#   BPS                    (default 10) small on purpose -- this is a correctness check
#   TRANSACTIONS_PER_BLOCK (default 1)
#   RUNTIME_SECONDS        (default 15) per traffic mode
#   STOP_NODE_AFTER        (default true) stop the validator on sparta once done
#   SKIP_BUILD             (default false) skip `cargo build`, reuse target/<profile> as-is
#   SKIP_BINARY_DEPLOY     (default false) skip rsync'ing the (large, slow) binaries, reuse
#                          whatever's already on both remote hosts; scripts still re-copied

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
BUILD_PROFILE="${BUILD_PROFILE:-debug}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
NUM_CHAINS="${NUM_CHAINS:-3}"
BPS="${BPS:-10}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-15}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cargo_flags=()
target_dir="debug"
case "${BUILD_PROFILE}" in
  release)
    cargo_flags=(--release --config profile.release.debug=false)
    target_dir="release"
    ;;
  debug) ;;
  *)
    echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2
    exit 1
    ;;
esac

# --- 1. Build locally -------------------------------------------------------------------
bin_src="${LINERA_SRC}/target/${target_dir}"
if [ "${SKIP_BUILD}" = "true" ]; then
  echo "==> [1/3] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/3] Building validator + client binaries natively (${BUILD_PROFILE})"
  (
    cd "${LINERA_SRC}"
    cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera \
      --bin linera-server \
      --bin linera-proxy \
      --bin linera-lite-benchmark \
      -p linera-storage-service \
      --bin linera-storage-server
  )
fi

# --- 2. Deploy ---------------------------------------------------------------------------
echo "==> [2/3] Deploying to ${SPARTA_HOST}:${REMOTE_DIR}/ (validator)"
ssh "${SPARTA_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  # rsync for the binaries only (they're 1GB+; delta-transfer skips them if unchanged).
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-server" "${bin_src}/linera-proxy" \
    "${bin_src}/linera-storage-server" "${SPARTA_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/run_node.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
  "${SPARTA_HOST}:${REMOTE_DIR}/scripts/"
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [2/3] Deploying to ${CLIENT_HOST}:${REMOTE_DIR}/ (client)"
ssh "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az --progress "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark.sh" \
  "${LOCAL_DIR}/scripts/run_lite_benchmark_sweep.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

# --- 3. Run the test -----------------------------------------------------------------------
echo "==> [3/3] Starting validator on ${SPARTA_HOST} (public address ${SPARTA_ADDRESS}:${PROXY_PUBLIC_PORT})"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} \
   START_FAUCET=false ${REMOTE_DIR}/scripts/run_node.sh"
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

echo "==> Provisioning ${NUM_CHAINS} super-owner chains on ${CLIENT_HOST}"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${NUM_CHAINS} OUTPUT_FILE=./chain_ids.txt \
  ./scripts/provision_super_owner_chains.sh"

traffic_modes="independent"
if [ "${NUM_CHAINS}" -ge 2 ]; then
  traffic_modes="independent mixed full"
fi

for mode in ${traffic_modes}; do
  echo "==> Smoke-testing traffic-mode=${mode} on ${CLIENT_HOST}"
  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    CHAIN_IDS_FILE=./chain_ids.txt BPS=${BPS} TRANSACTIONS_PER_BLOCK=${TRANSACTIONS_PER_BLOCK} \
    TRAFFIC_MODE=${mode} RUNTIME_SECONDS=${RUNTIME_SECONDS} \
    EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=smoke_${mode} \
    ./scripts/run_lite_benchmark.sh"
done

echo "==> Fetching results from ${CLIENT_HOST}"
local_results_dir="$(mktemp -d)"
scp -r "${CLIENT_HOST}:${REMOTE_DIR}/results/lite_benchmark/smoke_*" "${local_results_dir}/"

echo "==> Checking results"
overall_pass=true
for mode in ${traffic_modes}; do
  csv="${local_results_dir}/smoke_${mode}/transfers.csv"
  if [ ! -f "${csv}" ]; then
    echo "  [FAIL] ${mode}: no CSV found at ${csv}"
    overall_pass=false
    continue
  fi
  total="$(tail -n +2 "${csv}" | wc -l)"
  committed="$(awk -F, 'NR>1 && $4=="committed"' "${csv}" | wc -l)"
  failed="$(awk -F, 'NR>1 && $4=="failed"' "${csv}" | wc -l)"
  echo "  ${mode}: ${committed}/${total} committed, ${failed} failed (${csv})"
  if [ "${total}" -eq 0 ] || [ "${failed}" -gt 0 ]; then
    overall_pass=false
  fi
done

echo
if [ "${overall_pass}" = "true" ]; then
  echo "==> PASS: all traffic modes committed cleanly. Results kept at ${local_results_dir}"
else
  echo "==> FAIL: see above. Raw logs at ${local_results_dir}, and remotely under ${REMOTE_DIR}/results/ on ${CLIENT_HOST}"
  exit 1
fi
