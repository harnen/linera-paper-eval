#!/usr/bin/env bash
set -euo pipefail

# Drives a small set of chains continuously at a high per-chain block rate and migrates all
# of them, repeatedly, to a rotating target shard every MIGRATION_INTERVAL_SECONDS -- turning
# a handful of anecdotal migrations into hundreds of aligned samples for an event-aligned
# per-block-latency plot (block index relative to the migration trigger, median + p95 across
# every migration observed, not five individual lines against wall-clock time).
#
# Block index 0 is defined as *the first block committed at or after the migration trigger*,
# not the moment the target worker's log reports having acquired the chain -- acquiring
# happens on the order of single-digit milliseconds (see run_state_size_experiment.sh), so at
# any block rate coarser than that (this script defaults to ~50ms spacing) the first
# post-trigger block is already almost certainly post-acquire. This is an approximation,
# stated here rather than overclaimed in the plot.
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT, BUILD_PROFILE,
#     LINERA_SRC -- as in find_max_tps.sh
#   NUM_SHARDS             (default 4)
#   CORES_PER_SHARD        (default 2)
#   RESERVED_CORES         (default 4)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default)
#   REPEAT_CHAINS          (default 12) chains driven and repeatedly migrated
#   BPS_PER_CHAIN          (default 20) blocks/s per chain -- dense enough to plausibly land
#                          a block during the handover window
#   TRANSACTIONS_PER_BLOCK (default 1)
#   MIGRATION_INTERVAL_SECONDS (default 3) time between migration rounds
#   ROUND_DISPATCH_DELAY_SECONDS (default 1.8) artificial per-chain delay inside a round,
#                          before each migrate-chain ssh call fires. Originally added to chase
#                          a routing-failure storm ("refusing to forward an already-forwarded
#                          request" on 50-85% of blocks once ssh round-trips got fast enough
#                          for many chains to be mid-migration at once). Staggering only ever
#                          delayed the onset, not the root cause: worker/proxy routing tables
#                          can go briefly stale after a migration, and nothing retried a
#                          rejected double-forward with fresh routing, despite that being the
#                          documented behavior (see route()'s doc comment in
#                          linera-rpc/src/grpc/server.rs). Fixed at the protocol level: a
#                          rejected double-forward now carries the authoritative shard ID as
#                          gRPC status metadata, and both the worker forwarder and the proxy
#                          retry once directly against it (server.rs's forward_with_retry!
#                          macro, mirrored in linera-service/src/proxy/grpc.rs). Verified: the
#                          same 12-chain/15s-interval config that showed ~80% failure at
#                          BPS_PER_CHAIN=67 now shows a flat ~15-16% failure rate uncorrelated
#                          with migration timing (i.e. ordinary contention from driving blocks
#                          that fast from one client, not a routing bug), and BPS_PER_CHAIN=20
#                          (this script's default) drops to <1%. Staggering is kept as a minor
#                          belt-and-braces knob, not a load-bearing workaround -- 0 disables it.
#   SETTLE_SECONDS         (default 5) delay before the first migration round, so every chain
#                          has an established baseline first
#   RUNTIME_SECONDS        (default 150) total benchmark duration
#   OUT_DIR                (default ./results/repeated_migration/<timestamp>)
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
REPEAT_CHAINS="${REPEAT_CHAINS:-12}"
BPS_PER_CHAIN="${BPS_PER_CHAIN:-20}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
MIGRATION_INTERVAL_SECONDS="${MIGRATION_INTERVAL_SECONDS:-3}"
ROUND_DISPATCH_DELAY_SECONDS="${ROUND_DISPATCH_DELAY_SECONDS:-1.8}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-150}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/repeated_migration/${RUN_ID}}"
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
  echo "==> [1/7] Skipping build (SKIP_BUILD=true), reusing ${bin_src}"
else
  echo "==> [1/7] Building validator + client binaries natively (${BUILD_PROFILE})"
  ( cd "${LINERA_SRC}" && cargo build "${cargo_flags[@]}" \
      --features opentelemetry,metrics \
      -p linera-service \
      --bin linera --bin linera-server --bin linera-proxy --bin linera-lite-benchmark \
      -p linera-storage-service --bin linera-storage-server )
fi

echo "==> [2/7] Deploying binaries"
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
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/7] Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores + ${RESERVED_CORES} reserved"
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

echo "==> [4/7] Provisioning ${REPEAT_CHAINS} chains on ${CLIENT_HOST}"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${REPEAT_CHAINS} OUTPUT_FILE=./repeat_chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh"
pool_file="${OUT_DIR}/repeat_chains.txt"
scp "${CLIENT_HOST}:${REMOTE_DIR}/repeat_chain_pool.txt" "${pool_file}"
chains_csv="$(paste -sd, "${pool_file}")"

echo "==> Computing sparta<->client clock offset (SSH connection setup alone was measured at
    1.6-2.2s -- far more than either block rate this experiment tests -- so trigger timestamps
    must come from the clock actually driving the ssh call, corrected into the other host's
    frame, never from 'local time right before dispatch')"
sparta_epoch="$(ssh -n "${SPARTA_HOST}" 'date +%s.%N')"
client_epoch="$(ssh -n "${CLIENT_HOST}" 'date +%s.%N')"
client_clock_offset="$(awk -v s="${sparta_epoch}" -v c="${client_epoch}" 'BEGIN{printf "%.3f", s-c}')"
echo "  sparta - client = ${client_clock_offset}s"

echo "==> [5/7] Launching ${RUNTIME_SECONDS}s benchmark against ${REPEAT_CHAINS} chains (background)"
# `nohup cmd </dev/null >log 2>&1 &` alone does NOT detach cleanly here -- measured directly:
# even with every fd redirected, the ssh session still blocked until the backgrounded process
# exited (a plain `sleep 3 &` held the whole ssh call open for the full 3s). Wrapping the
# background job in its own subshell `( cmd & )` does detach it, confirmed the same way (ssh
# returned in <1s regardless of the child's runtime). The client's own `date` is captured by
# this same ssh invocation right after that subshell exits -- not a separate, later ssh call,
# which would itself cost another 1.6-2.2s and misdate the reference point exactly like the
# bug being fixed here.
launch_output="$(ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json && \
  ( nohup env RUST_LOG=error ./bin/linera-lite-benchmark \
      --wallet ./admin_wallet.json --keystore ./admin_keystore.json \
      --chains ${chains_csv} \
      --bps $(( BPS_PER_CHAIN * REPEAT_CHAINS )) \
      --transactions-per-block ${TRANSACTIONS_PER_BLOCK} \
      --traffic-mode independent --client-mode lite \
      --output-csv ./repeat_transfers.csv \
      --runtime-in-seconds ${RUNTIME_SECONDS} \
      < /dev/null > ./repeat_bench.log 2>&1 & \
    echo \$! > ./repeat_bench.pid ) ; \
  date -u +%s.%6N")"
# benchmark_start_epoch (client's clock) is for *data alignment* only, precise to a few ms.
# local_start_epoch (this machine's clock, captured right around the same moment) is a
# separate reference used only to decide when to stop looping -- mixing the two clocks in one
# comparison is exactly the bug being fixed elsewhere in this script, so the loop-control timer
# must not touch benchmark_start_epoch at all.
benchmark_start_epoch="$(echo "${launch_output}" | grep -oP '^\d+\.\d+$' | tail -1)"
local_start_epoch="$(date +%s.%N)"
echo "==> Benchmark launched; settling for ${SETTLE_SECONDS}s before the first migration round"
sleep "${SETTLE_SECONDS}"

echo "==> [6/7] Migration rounds every ${MIGRATION_INTERVAL_SECONDS}s until ~${RUNTIME_SECONDS}s"
echo "chain_id,round,elapsed_seconds,h_star_elapsed_seconds,from_shard,to_shard" > "${OUT_DIR}/migrations.csv"
round=0
shard_cursor=0
end_at=$(awk -v r="${RUNTIME_SECONDS}" -v s="${SETTLE_SECONDS}" 'BEGIN{print r - s - 2}')
while true; do
  now_epoch="$(date +%s.%N)"
  elapsed="$(awk -v s="${local_start_epoch}" -v n="${now_epoch}" 'BEGIN{printf "%.3f", n-s}')"
  awk -v e="${elapsed}" -v end="${end_at}" 'BEGIN{exit !(e>=end)}' && break

  round=$((round + 1))
  round_tmp_dir="$(mktemp -d)"
  i=0
  while read -r chain_id; do
    [ -n "${chain_id}" ] || continue
    i=$((i + 1))
    # Stagger, don't just delay: firing all REPEAT_CHAINS migrate-chain calls in one
    # simultaneous burst is what triggers "refusing to forward an already-forwarded
    # request" (see the note on ROUND_DISPATCH_DELAY_SECONDS above) -- spreading them across
    # the same total window, one chain at a time, is what the old tc-latency-slowed runs did
    # by accident.
    stagger_delay="$(awk -v i="${i}" -v n="${REPEAT_CHAINS}" -v d="${ROUND_DISPATCH_DELAY_SECONDS}" 'BEGIN{printf "%.3f", (i-1)*d/n}')"
    (
      sleep "${stagger_delay}"
      for attempt in $(seq 0 $((NUM_SHARDS - 1))); do
        target_shard=$(( (shard_cursor + attempt) % NUM_SHARDS ))
        # date is piggybacked on the same ssh call as migrate-chain (sparta's own clock, no
        # extra round trip) -- capturing "now" beforehand on this machine would be off by
        # this call's own 1.6-2.2s connection setup, dwarfing both block rates tested here.
        output="$(ssh -n "${SPARTA_HOST}" \
          "date -u +%s.%6N && \
           linera/bin/linera-server migrate-chain --server linera/state/server_0.json --chain-id ${chain_id} --to-shard ${target_shard}" 2>&1)" && {
            from_shard="$(echo "${output}" | grep -oP 'from shard \K[0-9]+' | head -1)"
            sparta_trigger_epoch="$(echo "${output}" | grep -oP '^\d+\.\d+$' | head -1)"
            elapsed="$(awk -v se="${sparta_trigger_epoch}" -v off="${client_clock_offset}" -v bs="${benchmark_start_epoch}" \
              'BEGIN{printf "%.3f", (se-off)-bs}')"
            # h* -- the actual write-lock handover completing -- comes from the "acquired
            # chain" tracing line's own timestamp (sparta's clock, same as sparta_trigger_epoch
            # above), NOT the "migrated to shard" line, which only prints after migrate_chain's
            # steps 3/4 (sequentially notifying every other shard and proxy) and can be
            # inflated by an unrelated slow-connect tail. Falls back to the dispatch elapsed
            # time if the line can't be parsed (e.g. malformed output), so downstream tooling
            # never sees an empty field.
            acquired_iso="$(echo "${output}" | grep -oP '^\S+(?=.*acquired chain)' | head -1)"
            if [ -n "${acquired_iso}" ]; then
              acquired_epoch="$(python3 -c "
from datetime import datetime
print(datetime.fromisoformat('${acquired_iso}'.replace('Z','+00:00')).timestamp())
")"
              h_star_elapsed="$(awk -v ae="${acquired_epoch}" -v off="${client_clock_offset}" -v bs="${benchmark_start_epoch}" \
                'BEGIN{printf "%.3f", (ae-off)-bs}')"
            else
              h_star_elapsed="${elapsed}"
            fi
            echo "${chain_id},${round},${elapsed},${h_star_elapsed},${from_shard:-unknown},${target_shard}" > "${round_tmp_dir}/${i}.csv"
            exit 0
          }
      done
      exit 1
    ) &
  done < "${pool_file}"
  wait
  succeeded=0
  for f in "${round_tmp_dir}"/*.csv; do
    [ -f "${f}" ] || continue
    cat "${f}" >> "${OUT_DIR}/migrations.csv"
    succeeded=$((succeeded + 1))
  done
  rm -rf "${round_tmp_dir}"
  shard_cursor=$(( (shard_cursor + 1) % NUM_SHARDS ))
  echo "  round ${round} done at t=${elapsed}s (${succeeded}/${i} succeeded)"
  sleep "${MIGRATION_INTERVAL_SECONDS}"
done

echo "==> [7/7] Waiting for benchmark to finish"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  pid=\$(cat ./repeat_bench.pid 2>/dev/null); \
  if [ -n \"\${pid}\" ]; then \
    for i in \$(seq 1 120); do \
      kill -0 \"\${pid}\" 2>/dev/null || break; \
      sleep 1; \
    done; \
  fi"

scp "${CLIENT_HOST}:${REMOTE_DIR}/repeat_transfers.csv" "${OUT_DIR}/transfers.csv"
scp "${CLIENT_HOST}:${REMOTE_DIR}/repeat_bench.log" "${OUT_DIR}/bench.log" || true

echo "==> Done. $(( round )) migration round(s) x ${REPEAT_CHAINS} chains = $(( round * REPEAT_CHAINS )) events"
echo "    Transfers: ${OUT_DIR}/transfers.csv"
echo "    Migrations: ${OUT_DIR}/migrations.csv"
