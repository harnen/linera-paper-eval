#!/usr/bin/env bash
set -euo pipefail

# Measures whether migration handover duration depends on a chain's accumulated state size --
# the experiment that turns "reassignment requires only a routing update" from a design claim
# into a measured one. Two disjoint chain groups differ *only* in how many blocks they've
# committed before their single migration (a proxy for accumulated state/history size, since
# each confirmed block adds a stored block+certificate): SMALL_STATE_WARMUP_BLOCKS vs
# LARGE_STATE_WARMUP_BLOCKS, three orders of magnitude apart by default. If handover duration
# doesn't move between groups, no state crossed the network at migration time -- only the
# routing table did.
#
# Duration is measured precisely from server-side log timestamps, not from client-observed
# block spacing: for each chain, wall-clock from issuing `migrate-chain` (the "decision") to
# the moment the target worker's own log reports having acquired the chain -- this avoids
# conflating the true handover cost with whatever client pacing happens to be in effect,
# which per-block sampling can't resolve for a handover this fast (see
# run_migration_cost_experiment.sh's pilot: a single migration completed in ~4ms end to end).
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT, BUILD_PROFILE,
#     LINERA_SRC -- as in find_max_tps.sh
#   NUM_SHARDS             (default 4)
#   CORES_PER_SHARD        (default 2)
#   RESERVED_CORES         (default 4)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default)
#   CHAINS_PER_GROUP       (default 20) chains in each of the small/large groups
#   SMALL_STATE_WARMUP_BLOCKS (default 10)
#   LARGE_STATE_WARMUP_BLOCKS (default 10000)
#   WARMUP_BPS_PER_CHAIN   (default 50) blocks/s per chain during warmup (only the large
#                          group's warmup duration is sensitive to this: at the default,
#                          10000 blocks takes ~200s)
#   TRANSACTIONS_PER_BLOCK (default 1)
#   OUT_DIR                (default ./results/state_size_cost/<timestamp>)
#   STOP_NODE_AFTER        (default true)
#   SKIP_BUILD             (default false)
#   SKIP_BINARY_DEPLOY     (default false)

SPARTA_ADDRESS="${SPARTA_ADDRESS:-193.60.241.98}"
SPARTA_HOST="${SPARTA_HOST:-sparta}"
CLIENT_HOST="${CLIENT_HOST:-yiannis-testbed}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
NUM_SHARDS="${NUM_SHARDS:-4}"
CORES_PER_SHARD="${CORES_PER_SHARD:-2}"
RESERVED_CORES="${RESERVED_CORES:-4}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
CHAINS_PER_GROUP="${CHAINS_PER_GROUP:-20}"
SMALL_STATE_WARMUP_BLOCKS="${SMALL_STATE_WARMUP_BLOCKS:-10}"
LARGE_STATE_WARMUP_BLOCKS="${LARGE_STATE_WARMUP_BLOCKS:-10000}"
WARMUP_BPS_PER_CHAIN="${WARMUP_BPS_PER_CHAIN:-50}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/state_size_cost/${RUN_ID}}"
mkdir -p "${OUT_DIR}"
env | sort > "${OUT_DIR}/.env"

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
  ( cd "${LINERA_SRC}" && cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server )
fi

echo "==> [2/6] Deploying binaries"
ssh "${SPARTA_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
ssh "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az "${bin_src}/linera" "${bin_src}/linera-server" "${bin_src}/linera-proxy" \
    "${bin_src}/linera-storage-server" "${SPARTA_HOST}:${REMOTE_DIR}/bin/"
  rsync -az "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/run_validators.sh" "${LOCAL_DIR}/scripts/stop_node.sh" "${SPARTA_HOST}:${REMOTE_DIR}/scripts/"
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" "${LOCAL_DIR}/scripts/run_lite_benchmark_parallel.sh" \
  "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/6] Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores + ${RESERVED_CORES} reserved"
ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
ssh "${SPARTA_HOST}" "rm -rf ${REMOTE_DIR}/state"
ssh "${SPARTA_HOST}" \
  "STATE_DIR=${REMOTE_DIR}/state NODE_HOST=${SPARTA_ADDRESS} PROXY_PUBLIC_PORT_BASE=${PROXY_PUBLIC_PORT} \
   NUM_VALIDATORS=1 NUM_SHARDS=${NUM_SHARDS} CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} \
   STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} START_FAUCET=false \
   ${REMOTE_DIR}/scripts/run_validators.sh"
sleep 3

cleanup_node() {
  if [ "${STOP_NODE_AFTER}" = "true" ]; then
    echo "==> Stopping validator on ${SPARTA_HOST}"
    ssh "${SPARTA_HOST}" "STATE_DIR=${REMOTE_DIR}/state ${REMOTE_DIR}/scripts/stop_node.sh" || true
  else
    echo "==> Leaving validator running (STOP_NODE_AFTER=false)"
  fi
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

total_chains=$(( CHAINS_PER_GROUP * 2 ))
echo "==> [4/6] Provisioning ${total_chains} chains (${CHAINS_PER_GROUP} small-state, ${CHAINS_PER_GROUP} large-state)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${total_chains} OUTPUT_FILE=./state_size_pool.txt \
  ./scripts/provision_super_owner_chains.sh"
pool_file="$(mktemp)"
scp "${CLIENT_HOST}:${REMOTE_DIR}/state_size_pool.txt" "${pool_file}"
small_file="${OUT_DIR}/small_state_chains.txt"
large_file="${OUT_DIR}/large_state_chains.txt"
head -n "${CHAINS_PER_GROUP}" "${pool_file}" > "${small_file}"
tail -n "${CHAINS_PER_GROUP}" "${pool_file}" > "${large_file}"
rm -f "${pool_file}"

warmup_group() {
  local label="$1" chains_file="$2" target_blocks="$3"
  [ "${target_blocks}" -gt 0 ] || { echo "  ${label}: no warmup requested"; return; }
  local chains_csv runtime_seconds bps
  chains_csv="$(paste -sd, "${chains_file}")"
  bps=$(( WARMUP_BPS_PER_CHAIN * CHAINS_PER_GROUP ))
  runtime_seconds=$(( (target_blocks + WARMUP_BPS_PER_CHAIN - 1) / WARMUP_BPS_PER_CHAIN + 5 ))
  echo "==> Warming up ${label} to ~${target_blocks} blocks/chain (${runtime_seconds}s at ${bps} total bps)"
  ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
    LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
    RUST_LOG=error ./bin/linera-lite-benchmark \
      --wallet ./admin_wallet.json --keystore ./admin_keystore.json \
      --chains ${chains_csv} --bps ${bps} \
      --transactions-per-block ${TRANSACTIONS_PER_BLOCK} \
      --traffic-mode independent --client-mode lite \
      --runtime-in-seconds ${runtime_seconds} \
      > ./warmup_${label}.log 2>&1"
}

echo "==> [5/6] Warming up both groups (large group first -- it takes longer)"
warmup_group "large" "${large_file}" "${LARGE_STATE_WARMUP_BLOCKS}"
warmup_group "small" "${small_file}" "${SMALL_STATE_WARMUP_BLOCKS}"

# Migrates a single chain, recording precise decision->acquired duration from server-log
# timestamps (ISO8601 with microseconds, parsed directly -- not from client-observed block
# spacing, which can't resolve a handover this fast) into <label>_durations.csv.
migrate_one_chain() {
  local label="$1" chain_id="$2" shard_cursor="$3"
  local migrated=false
  for attempt in $(seq 0 $((NUM_SHARDS - 1))); do
    local target_shard=$(( (shard_cursor + attempt) % NUM_SHARDS ))
    local output
    # trigger_iso and the migrate-chain log lines must come from the SAME clock (sparta's),
    # not the orchestrating machine's -- any clock skew between hosts would otherwise leak
    # straight into the duration measurement. One remote command, one clock.
    output="$(ssh -n "${SPARTA_HOST}" \
      "date -u +%Y-%m-%dT%H:%M:%S.%6NZ && \
       linera/bin/linera-server migrate-chain --server linera/state/server_0.json --chain-id ${chain_id} --to-shard ${target_shard}" 2>&1)" && {
        local trigger_iso acquired_iso from_shard duration_ms
        # Not `head -1`: the SSH login banner (printed to stderr, merged in via 2>&1) can
        # land before the remote command's own output, so grab the date line by its
        # distinctive format instead of by position.
        trigger_iso="$(echo "${output}" | grep -oP '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$' | head -1)"
        # "acquired chain" (not "migrated to shard") is the write-lock handover completing --
        # printed right after step 2 (target worker takes ownership). "migrated to shard" is
        # the LAST line of migrate_chain, printed only after steps 3/4 (sequentially notifying
        # every other shard and proxy, each a fresh gRPC connection) -- unrelated bookkeeping
        # that inflated this measurement with an occasional slow-connect tail unrelated to
        # state size (confirmed: n=100/arm showed an identical tail on both arms).
        acquired_iso="$(echo "${output}" | grep -oP '^\S+(?=.*acquired chain)' | head -1)"
        from_shard="$(echo "${output}" | grep -oP 'from shard \K[0-9]+' | head -1)"
        if [ -n "${acquired_iso}" ] && [ -n "${trigger_iso}" ]; then
          duration_ms="$(python3 -c "
from datetime import datetime
t1 = datetime.fromisoformat('${trigger_iso}'.replace('Z','+00:00'))
t2 = datetime.fromisoformat('${acquired_iso}'.replace('Z','+00:00'))
print(f'{(t2-t1).total_seconds()*1000:.3f}')
")"
        else
          duration_ms=""
        fi
        echo "${chain_id},${trigger_iso},${acquired_iso},${duration_ms},${from_shard:-unknown},${target_shard}" >> "${OUT_DIR}/${label}_durations.csv"
        migrated=true
        break
      }
  done
  [ "${migrated}" = true ] || echo "  warning: failed to migrate ${chain_id} (${label})" >&2
}

echo "==> [6/6] Migrating both groups, interleaved one-small-one-large -- doing all of one
    group before the other would confound state size with temporal ordering (SSH connection
    warm-up, CPU/thermal state settling after the large group's warmup burst, background load
    on a shared machine), which is exactly what produced the spurious 'large is faster' signal
    on the previous, non-interleaved run."
echo "chain_id,trigger_iso,acquired_iso,duration_ms,from_shard,to_shard" > "${OUT_DIR}/small_durations.csv"
echo "chain_id,trigger_iso,acquired_iso,duration_ms,from_shard,to_shard" > "${OUT_DIR}/large_durations.csv"
shard_cursor=0
while IFS=$'\t' read -r small_chain large_chain; do
  # Both chains in a pair are dispatched concurrently (each writes to its own file, so no
  # contention) -- this keeps the interleaving property (neither group is ever migrated in a
  # block of its own) while running at roughly one round-trip per pair instead of two.
  if [ -n "${small_chain}" ]; then
    migrate_one_chain "small" "${small_chain}" "${shard_cursor}" &
    shard_cursor=$(( (shard_cursor + 1) % NUM_SHARDS ))
  fi
  if [ -n "${large_chain}" ]; then
    migrate_one_chain "large" "${large_chain}" "${shard_cursor}" &
    shard_cursor=$(( (shard_cursor + 1) % NUM_SHARDS ))
  fi
  wait
done < <(paste "${small_file}" "${large_file}")

echo "==> Done."
echo "    Small-state durations: ${OUT_DIR}/small_durations.csv"
echo "    Large-state durations: ${OUT_DIR}/large_durations.csv"
