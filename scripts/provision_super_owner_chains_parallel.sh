#!/usr/bin/env bash
set -euo pipefail

# Parallel variant of provision_super_owner_chains.sh for large chain counts.
#
# `linera benchmark single` opens chains as children of one wallet's default chain, batched
# up to 900 OpenChain operations per block -- but those blocks are still strictly ordered (one
# admin chain, one linear history), so N chains costs ceil(N/900) *sequential* block
# round-trips no matter what. Measured at ~12s/block on paradoxe, that's ~22 minutes for
# 100,000 chains from a single stream.
#
# This script instead opens PARALLELISM independent "shard" chains from the true admin first
# (one cheap batched block, since PARALLELISM << 900), then runs PARALLELISM concurrent
# `linera benchmark single` processes, each opening its own slice of the total from its own
# shard chain -- genuinely parallel, since each shard's block history is independent of the
# others. Wall-clock cost becomes ceil((NUM_CHAINS/PARALLELISM)/900) sequential blocks, i.e.
# roughly NUM_CHAINS/(900*PARALLELISM) instead of NUM_CHAINS/900.
#
# Configuration (env vars): same as provision_super_owner_chains.sh, plus:
#   PARALLELISM   (default 16) number of independent shard chains / concurrent streams

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the copied admin_wallet.json path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the copied admin_keystore.json path}"
GENESIS_PATH="${GENESIS_PATH:-$(dirname "${LINERA_WALLET}")/genesis.json}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
CLIENT_DIR="${CLIENT_DIR:-/var/tmp/linera-client}"
NUM_CHAINS="${NUM_CHAINS:-10}"
INITIAL_BALANCE="${INITIAL_BALANCE:-1000}"
OUTPUT_FILE="${OUTPUT_FILE:-./chain_ids.txt}"
PARALLELISM="${PARALLELISM:-16}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v linera >/dev/null || { echo "linera binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -f "${GENESIS_PATH}" ] || { echo "genesis config not found at ${GENESIS_PATH}" >&2; exit 1; }

rm -rf "${CLIENT_DIR}"
mkdir -p "${CLIENT_DIR}"
export LINERA_WALLET
export LINERA_KEYSTORE
export LINERA_STORAGE="${LINERA_STORAGE:-rocksdb:${CLIENT_DIR}/wallet-client.db}"

echo "==> Initializing local client storage from ${GENESIS_PATH}"
linera storage initialize --storage "${LINERA_STORAGE}" --genesis "${GENESIS_PATH}"

preexisting_chains_file="$(mktemp)"
jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${LINERA_WALLET}" > "${preexisting_chains_file}"

per_shard=$(( (NUM_CHAINS + PARALLELISM - 1) / PARALLELISM ))
shard_balance=$(awk -v n="${per_shard}" -v b="${INITIAL_BALANCE}" 'BEGIN{printf "%.1f", (n+10)*b}')

echo "==> [1/3] Opening ${PARALLELISM} independent shard chains (single batched block)"
echo "no" | linera benchmark single \
  --num-chains "${PARALLELISM}" \
  --tokens-per-chain "${shard_balance}" \
  --transactions-per-block 1 \
  --bps 1 \
  --confirm-before-start

shard_chains_file="$(mktemp)"
jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${LINERA_WALLET}" \
  | grep -vxFf "${preexisting_chains_file}" > "${shard_chains_file}"
num_shards_opened="$(wc -l < "${shard_chains_file}")"
[ "${num_shards_opened}" -eq "${PARALLELISM}" ] || {
  echo "error: expected ${PARALLELISM} shard chains, found ${num_shards_opened}" >&2
  exit 1
}
echo "  opened ${num_shards_opened} shard chains"

true_admin_id="$(jq -r '.default' "${LINERA_WALLET}")"
known_before_children_file="$(mktemp)"
{ cat "${preexisting_chains_file}" "${shard_chains_file}"; echo "${true_admin_id}"; } | sort -u > "${known_before_children_file}"

# Every worker's wallet is a full copy of the admin wallet made *before* any shard opens its
# children, so each one already "knows" about every other shard chain plus the true admin --
# --num-chains N counts a worker's whole wallet (minus its own default chain), not just chains
# it created itself, so passing N=per_shard would only ever open (per_shard - (PARALLELISM))
# new chains: short by exactly the shard count, every single retry. See the per-attempt
# `current_total`/`target` computation below, which derives the correct absolute target from
# the wallet's live state rather than a precomputed constant.

work_dir="$(mktemp -d)"
echo "==> [2/3] Provisioning ${NUM_CHAINS} chains across ${PARALLELISM} parallel streams (~${per_shard}/stream)"
i=0
pids=()
while IFS= read -r shard_chain_id; do
  worker_wallet="${work_dir}/wallet_${i}.json"
  worker_keystore="${work_dir}/keystore_${i}.json"
  worker_client_dir="${CLIENT_DIR}_shard${i}"
  cp "${LINERA_WALLET}" "${worker_wallet}"
  cp "${LINERA_KEYSTORE}" "${worker_keystore}"
  jq --arg d "${shard_chain_id}" '.default = $d' "${worker_wallet}" > "${worker_wallet}.tmp"
  mv "${worker_wallet}.tmp" "${worker_wallet}"

  (
    rm -rf "${worker_client_dir}"
    mkdir -p "${worker_client_dir}"
    export LINERA_WALLET="${worker_wallet}"
    export LINERA_KEYSTORE="${worker_keystore}"
    export LINERA_STORAGE="rocksdb:${worker_client_dir}/wallet-client.db"
    linera storage initialize --storage "${LINERA_STORAGE}" --genesis "${GENESIS_PATH}"
    # `linera benchmark single --confirm-before-start` has been observed to sometimes read
    # the piped "no" and wind down before every requested chain's creation has locally
    # settled in the wallet file (more likely under concurrent load on the validator, as here
    # with PARALLELISM streams running at once) -- self-heal by checking the actual count
    # and retrying if short. --num-chains is a *target total* for the whole wallet (it checks
    # how many chains the wallet already knows about -- including sibling shard chains and the
    # true admin, since each worker's wallet is a full copy -- and only opens the delta), so
    # every retry must pass a fresh absolute target, not the outstanding shortfall on its own:
    # passing a shrinking shortfall made a wallet that already had more chains than that skip
    # straight past chain-opening to the benchmark-confirm prompt, opening nothing further.
    # Re-derive the target from the wallet's *actual current* chain count on every attempt
    # (rather than a precomputed constant) so this self-corrects regardless of exactly how the
    # CLI accounts for the default chain in its own "already have" baseline.
    remaining="${per_shard}"
    attempt=0
    while [ "${remaining}" -gt 0 ] && [ "${attempt}" -lt 5 ]; do
      attempt=$((attempt + 1))
      current_total="$(jq '.chains | keys | length' "${worker_wallet}")"
      target=$((current_total - 1 + remaining))
      echo "no" | linera benchmark single \
        --num-chains "${target}" \
        --tokens-per-chain "${INITIAL_BALANCE}" \
        --transactions-per-block 1 \
        --bps 1 \
        --confirm-before-start \
        >> "${work_dir}/worker_${i}.log" 2>&1
      have="$(jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${worker_wallet}" \
        | grep -vxFf "${known_before_children_file}" | wc -l)"
      remaining=$((per_shard - have))
      echo "  worker ${i} attempt ${attempt}: ${have}/${per_shard} chains (${remaining} remaining)" >> "${work_dir}/worker_${i}.log"
    done
    [ "${remaining}" -le 0 ] || { echo "worker ${i}: still ${remaining} short after ${attempt} attempts" >> "${work_dir}/worker_${i}.log"; exit 1; }
  ) &
  pids+=("$!")
  i=$((i + 1))
done < "${shard_chains_file}"

fail=0
for pid in "${pids[@]}"; do
  wait "${pid}" || fail=1
done
[ "${fail}" -eq 0 ] || { echo "error: at least one parallel provisioning stream failed -- see ${work_dir}/worker_*.log" >&2; exit 1; }

echo "==> [3/3] Merging results"
: > "${OUTPUT_FILE}"
new_chains_file="${work_dir}/new_chains.json"
new_keys_file="${work_dir}/new_keys.json"
echo '{}' > "${new_chains_file}"
echo '[]' > "${new_keys_file}"

for ((j = 0; j < PARALLELISM; j++)); do
  worker_wallet="${work_dir}/wallet_${j}.json"
  worker_keystore="${work_dir}/keystore_${j}.json"

  # Chain IDs this worker created (not present before any of the parallel streams forked).
  worker_new_ids="$(jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${worker_wallet}" \
    | grep -vxFf "${known_before_children_file}")"
  printf '%s\n' "${worker_new_ids}" >> "${OUTPUT_FILE}"

  # `linera benchmark single` writes new chains straight into *this worker's own* wallet
  # copy and their owner keys into *this worker's own* keystore copy -- neither is ever
  # seen by the real admin wallet/keystore the benchmark clients will actually use, so both
  # need pulling back out and merging in, or every chain here fails with "no owner in the
  # wallet" the first time a client tries to use it.
  worker_new_ids_json="$(printf '%s\n' "${worker_new_ids}" | jq -R -s 'split("\n") | map(select(length > 0))')"
  worker_new_chains_json="${work_dir}/wallet_chains_${j}.json"
  jq --argjson ids "${worker_new_ids_json}" \
    '.chains | to_entries | map(select(.key as $k | $ids | index($k) != null)) | from_entries' \
    "${worker_wallet}" > "${worker_new_chains_json}"
  jq -s '.[0] * .[1]' "${new_chains_file}" "${worker_new_chains_json}" > "${new_chains_file}.tmp"
  mv "${new_chains_file}.tmp" "${new_chains_file}"

  worker_owners_json="$(jq '[.[].owner]' "${worker_new_chains_json}")"
  worker_new_keys_json="${work_dir}/keystore_keys_${j}.json"
  jq --argjson owners "${worker_owners_json}" \
    '.keys | map(select(.[0] as $o | $owners | index($o) != null))' \
    "${worker_keystore}" > "${worker_new_keys_json}"
  jq -s '.[0] + .[1]' "${new_keys_file}" "${worker_new_keys_json}" > "${new_keys_file}.tmp"
  mv "${new_keys_file}.tmp" "${new_keys_file}"
done

echo "==> Merging new chains + owner keys back into ${LINERA_WALLET} / ${LINERA_KEYSTORE}"
jq --slurpfile new "${new_chains_file}" '.chains += $new[0]' "${LINERA_WALLET}" > "${LINERA_WALLET}.tmp"
mv "${LINERA_WALLET}.tmp" "${LINERA_WALLET}"
jq --slurpfile new "${new_keys_file}" '.keys += $new[0]' "${LINERA_KEYSTORE}" > "${LINERA_KEYSTORE}.tmp"
mv "${LINERA_KEYSTORE}.tmp" "${LINERA_KEYSTORE}"

created="$(wc -l < "${OUTPUT_FILE}")"
if [ "${created}" -lt "${NUM_CHAINS}" ]; then
  echo "warning: expected at least ${NUM_CHAINS} chains, found only ${created} in ${OUTPUT_FILE} -- per-worker counts:" >&2
  for ((j = 0; j < PARALLELISM; j++)); do
    n="$(jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${work_dir}/wallet_${j}.json" 2>/dev/null \
      | grep -vxFf "${known_before_children_file}" | wc -l)"
    echo "  worker ${j}: ${n} chains (expected ${per_shard}) -- tail of ${work_dir}/worker_${j}.log:" >&2
    tail -5 "${work_dir}/worker_${j}.log" >&2 2>/dev/null || true
  done
elif [ "${created}" -gt "${NUM_CHAINS}" ]; then
  # Harmless: each attempt's --num-chains target is re-derived from the worker wallet's live
  # chain count (see the per-attempt loop above), and the CLI's own "already have" accounting
  # for that target has been observed to land a small, consistent number of chains over rather
  # than under -- typically one extra per shard. Every downstream consumer of this pool
  # (run_lite_benchmark_parallel.sh) only requires *at least* NUM_CHAINS available and reads a
  # fixed line-range slice per client, so a few unused trailing chains are never touched.
  echo "note: created ${created} chains, $((created - NUM_CHAINS)) more than the ${NUM_CHAINS} requested (harmless over-provisioning, see comment above)"
fi
rm -rf "${work_dir}" "${preexisting_chains_file}" "${shard_chains_file}" "${known_before_children_file}"
echo "==> Done. ${created} chain IDs written to ${OUTPUT_FILE}"
