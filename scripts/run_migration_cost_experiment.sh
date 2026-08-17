#!/usr/bin/env bash
set -euo pipefail

# Measures the cost of migrating a chain to a different shard (worker) of the same
# validator at runtime, via `linera-server migrate-chain`. Drives a fixed set of chains
# continuously with linera-lite-benchmark, splits them into a "migrate" group and a
# "control" group, and partway through the run migrates every chain in the migrate group
# to a different shard -- all while the benchmark keeps sending blocks to every chain
# throughout. Produces one CSV (a superset of lite-benchmark's own transfers.csv, tagged
# with which group each chain belongs to and the wall-clock migration trigger time) meant
# to drive two figures:
#   (a) Handover timeline: per-block latency (duration_micros) vs. elapsed time
#       (ts_within_experiment) for the migrate group only, with the migration trigger time
#       marked -- shows the unavailability window as a latency spike/gap right at handover.
#   (b) CDF of per-block confirmation latency, migrate group vs. control group -- shows the
#       aggregate cost (or lack thereof) once amortized over the whole run.
#
# The validator runs with BASE_SHARDS = NUM_SHARDS (every shard already running, no elastic
# slots) -- this measures the cost of the routing handover itself (drain in-flight work on
# the source worker, release, target worker acquires and persists the new assignment,
# notify other workers/proxies), independent of the auto-scaling policy in
# run_dormant_chains_experiment.sh's sibling, `linera-server manager` (not used here).
#
# Configuration (env vars):
#   SPARTA_ADDRESS, SPARTA_HOST, CLIENT_HOST, REMOTE_DIR, PROXY_PUBLIC_PORT, BUILD_PROFILE,
#     LINERA_SRC -- as in find_max_tps.sh
#   NUM_SHARDS             (default 4) shards for the single validator -- kept small so a
#                          migration target is easy to reason about and every shard carries
#                          a meaningful share of the chain pool
#   CORES_PER_SHARD        (default 2)
#   RESERVED_CORES         (default 4)
#   STORAGE_TOKIO_THREADS  (default 0 = storage-server's own default)
#   MIGRATE_CHAINS         (default 5) how many chains get migrated mid-run
#   CONTROL_CHAINS         (default 15) how many chains never migrate (the comparison group)
#   BPS_PER_CHAIN          (default 2) blocks/s requested per chain (both groups)
#   TRANSACTIONS_PER_BLOCK (default 1)
#   RUNTIME_SECONDS        (default 90) total benchmark duration
#   MIGRATION_AT_SECONDS   (default RUNTIME_SECONDS * 0.4) elapsed time at which migration
#                          is triggered for every migrate-group chain (fired as a single
#                          batch of migrate-chain calls, not staggered)
#   OUT_DIR                (default ./results/migration_cost/<timestamp>)
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
MIGRATE_CHAINS="${MIGRATE_CHAINS:-5}"
CONTROL_CHAINS="${CONTROL_CHAINS:-15}"
BPS_PER_CHAIN="${BPS_PER_CHAIN:-2}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-90}"
MIGRATION_AT_SECONDS="${MIGRATION_AT_SECONDS:-$(awk -v r="${RUNTIME_SECONDS}" 'BEGIN{printf "%.0f", r*0.4}')}"
STOP_NODE_AFTER="${STOP_NODE_AFTER:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${LOCAL_DIR}/results/migration_cost/${RUN_ID}}"
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

echo "==> [2/7] Deploying to ${SPARTA_HOST}:${REMOTE_DIR}/ (validator)"
ssh "${SPARTA_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az "${bin_src}/linera" "${bin_src}/linera-server" "${bin_src}/linera-proxy" \
    "${bin_src}/linera-storage-server" "${SPARTA_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/run_validators.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
  "${SPARTA_HOST}:${REMOTE_DIR}/scripts/"
ssh "${SPARTA_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [2/7] Deploying to ${CLIENT_HOST}:${REMOTE_DIR}/ (client)"
ssh "${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts"
if [ "${SKIP_BINARY_DEPLOY}" = "true" ]; then
  echo "  skipping binary transfer (SKIP_BINARY_DEPLOY=true)"
else
  rsync -az "${bin_src}/linera" "${bin_src}/linera-lite-benchmark" "${CLIENT_HOST}:${REMOTE_DIR}/bin/"
fi
scp "${LOCAL_DIR}/scripts/provision_super_owner_chains.sh" "${CLIENT_HOST}:${REMOTE_DIR}/scripts/"
ssh "${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"

echo "==> [3/7] Starting validator on ${SPARTA_HOST}: ${NUM_SHARDS} shards x ${CORES_PER_SHARD} cores + ${RESERVED_CORES} reserved (all base, no elastic slots)"
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

total_chains=$(( MIGRATE_CHAINS + CONTROL_CHAINS ))
echo "==> [4/7] Provisioning ${total_chains} chains on ${CLIENT_HOST} (${MIGRATE_CHAINS} to migrate, ${CONTROL_CHAINS} control)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=${total_chains} OUTPUT_FILE=./migration_chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh"
pool_file="$(mktemp)"
scp "${CLIENT_HOST}:${REMOTE_DIR}/migration_chain_pool.txt" "${pool_file}"
migrate_group_file="${OUT_DIR}/migrate_group.txt"
control_group_file="${OUT_DIR}/control_group.txt"
head -n "${MIGRATE_CHAINS}" "${pool_file}" > "${migrate_group_file}"
tail -n "${CONTROL_CHAINS}" "${pool_file}" > "${control_group_file}"
rm -f "${pool_file}"
all_chains_csv="$(cat "${migrate_group_file}" "${control_group_file}" | paste -sd,)"

echo "==> [5/7] Launching ${RUNTIME_SECONDS}s benchmark against all ${total_chains} chains (background)"
# `nohup ... < /dev/null &` is required, not just a trailing `&`: without it, the benchmark
# process gets SIGHUP'd and dies the moment this ssh session closes (which it does
# immediately after launching, since we don't want to hold the connection open).
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  nohup env RUST_LOG=info,linera_service=info ./bin/linera-lite-benchmark \
    --wallet ./admin_wallet.json --keystore ./admin_keystore.json \
    --chains ${all_chains_csv} \
    --bps $(( BPS_PER_CHAIN * total_chains )) \
    --transactions-per-block ${TRANSACTIONS_PER_BLOCK} \
    --traffic-mode independent --client-mode lite \
    --output-csv ./migration_transfers.csv \
    --runtime-in-seconds ${RUNTIME_SECONDS} \
    < /dev/null > ./migration_bench.log 2>&1 & \
  echo \$! > ./migration_bench.pid"

benchmark_start_epoch="$(date +%s.%N)"
echo "==> Benchmark launched at $(date -d @${benchmark_start_epoch%.*} '+%H:%M:%S' 2>/dev/null || date)"

echo "==> [6/7] Waiting ${MIGRATION_AT_SECONDS}s before triggering migration"
sleep "${MIGRATION_AT_SECONDS}"

migration_trigger_epoch="$(date +%s.%N)"
migration_elapsed="$(awk -v s="${benchmark_start_epoch}" -v t="${migration_trigger_epoch}" 'BEGIN{printf "%.3f", t-s}')"
echo "==> Triggering migration for ${MIGRATE_CHAINS} chain(s) at t=${migration_elapsed}s"

echo "chain_id,from_shard,to_shard" > "${OUT_DIR}/migrations.csv"
shard_cursor=0
while read -r chain_id; do
  [ -n "${chain_id}" ] || continue
  migrated=false
  for attempt in $(seq 0 $((NUM_SHARDS - 1))); do
    target_shard=$(( (shard_cursor + attempt) % NUM_SHARDS ))
    output="$(ssh -n "${SPARTA_HOST}" \
      "linera/bin/linera-server migrate-chain --server linera/state/server_0.json --chain-id ${chain_id} --to-shard ${target_shard}" 2>&1)" && {
        from_shard="$(echo "${output}" | grep -oP 'from shard \K[0-9]+' | head -1)"
        echo "${chain_id},${from_shard:-unknown},${target_shard}" >> "${OUT_DIR}/migrations.csv"
        migrated=true
        break
      }
  done
  [ "${migrated}" = true ] || echo "  warning: failed to migrate ${chain_id} to any shard" >&2
  shard_cursor=$(( (shard_cursor + 1) % NUM_SHARDS ))
done < "${migrate_group_file}"

echo "migration_trigger_elapsed_seconds" > "${OUT_DIR}/migration_trigger.csv"
echo "${migration_elapsed}" >> "${OUT_DIR}/migration_trigger.csv"

echo "==> [7/7] Waiting for benchmark to finish (up to $(( RUNTIME_SECONDS - MIGRATION_AT_SECONDS + 30 ))s more)"
ssh "${CLIENT_HOST}" "cd ${REMOTE_DIR} && \
  pid=\$(cat ./migration_bench.pid 2>/dev/null); \
  if [ -n \"\${pid}\" ]; then \
    for i in \$(seq 1 $(( RUNTIME_SECONDS - MIGRATION_AT_SECONDS + 60 ))); do \
      kill -0 \"\${pid}\" 2>/dev/null || break; \
      sleep 1; \
    done; \
  fi"

scp "${CLIENT_HOST}:${REMOTE_DIR}/migration_transfers.csv" "${OUT_DIR}/transfers.csv"
scp "${CLIENT_HOST}:${REMOTE_DIR}/migration_bench.log" "${OUT_DIR}/bench.log" || true

echo "==> Tagging transfers by group (migrate vs control)"
python3 - "${OUT_DIR}" <<'PYEOF'
import csv
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
migrate_ids = set(x.strip() for x in (out_dir / "migrate_group.txt").read_text().splitlines() if x.strip())

with open(out_dir / "transfers.csv", newline="") as f:
    rows = list(csv.DictReader(f))

with open(out_dir / "tagged_transfers.csv", "w", newline="") as f:
    fieldnames = list(rows[0].keys()) + ["group"] if rows else \
        ["chain_id", "ts_within_experiment", "num_tx", "num_bundles", "result", "duration_micros", "group"]
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        row["group"] = "migrate" if row["chain_id"] in migrate_ids else "control"
        writer.writerow(row)

print(f"Tagged {len(rows)} rows -> {out_dir / 'tagged_transfers.csv'}")
PYEOF

echo "==> Done."
echo "    Tagged transfers: ${OUT_DIR}/tagged_transfers.csv"
echo "    Migration trigger time: ${OUT_DIR}/migration_trigger.csv (${migration_elapsed}s)"
echo "    Migrations performed: ${OUT_DIR}/migrations.csv"
