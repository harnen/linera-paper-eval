#!/usr/bin/env bash
set -euo pipefail

# Sweep driver for linera-lite-benchmark, mirroring the nested-loop structure of the
# linera-paper-eval sweep in src/main.rs (num_chains x traffic_mode x tx_per_block x bps),
# but against the lighter, storage-free client. Provisions enough super-owner chains once
# up front (no faucet -- see provision_super_owner_chains.sh), then reuses subsets of them
# across the sweep.
#
# Configuration (env vars):
#   LINERA_WALLET, LINERA_KEYSTORE  (required) same admin wallet used for provisioning
#   BIN_DIR                        (default ../bin relative to this script)
#   NUM_CHAINS_LIST                (default "2 5 10 20 50 100 200")
#   TRAFFIC_MODES                  (default "independent mixed full")
#   TX_PER_BLOCK_LIST              (default "1 10 100")
#   BPS_LIST                       (default "10 100 1000")
#   RUNTIME_SECONDS                (default 60) duration of each individual run
#   INITIAL_BALANCE                (default 1000) passed to provisioning
#   EVAL_OUTPUT_DIR                (default /data_out)

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the admin wallet path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the admin keystore path}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
NUM_CHAINS_LIST="${NUM_CHAINS_LIST:-2 5 10 20 50 100 200}"
TRAFFIC_MODES="${TRAFFIC_MODES:-independent mixed full}"
TX_PER_BLOCK_LIST="${TX_PER_BLOCK_LIST:-1 10 100}"
BPS_LIST="${BPS_LIST:-10 100 1000}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-60}"
INITIAL_BALANCE="${INITIAL_BALANCE:-1000}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-/data_out}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export LINERA_WALLET LINERA_KEYSTORE BIN_DIR EVAL_OUTPUT_DIR

# Provision enough chains for the largest num_chains value up front.
max_chains=0
for n in ${NUM_CHAINS_LIST}; do
  if [ "${n}" -gt "${max_chains}" ]; then
    max_chains="${n}"
  fi
done

all_chains_file="${EVAL_OUTPUT_DIR}/lite_benchmark/all_chain_ids.txt"
mkdir -p "$(dirname "${all_chains_file}")"
echo "==> Provisioning ${max_chains} super-owner chains (reused across the whole sweep)"
NUM_CHAINS="${max_chains}" INITIAL_BALANCE="${INITIAL_BALANCE}" OUTPUT_FILE="${all_chains_file}" \
  "${SCRIPT_DIR}/provision_super_owner_chains.sh"

for num_chains in ${NUM_CHAINS_LIST}; do
  subset_file="${EVAL_OUTPUT_DIR}/lite_benchmark/subset_${num_chains}.txt"
  head -n "${num_chains}" "${all_chains_file}" > "${subset_file}"

  for traffic_mode in ${TRAFFIC_MODES}; do
    if [ "${num_chains}" -lt 2 ] && [ "${traffic_mode}" != "independent" ]; then
      echo "==> Skipping ${traffic_mode} with ${num_chains} chain(s): needs at least 2"
      continue
    fi
    for tx_per_block in ${TX_PER_BLOCK_LIST}; do
      for bps in ${BPS_LIST}; do
        experiment_name="${num_chains}chains_${traffic_mode}_${tx_per_block}tx_${bps}bps"
        echo "==> ${experiment_name}"
        CHAIN_IDS_FILE="${subset_file}" \
          BPS="${bps}" \
          TRANSACTIONS_PER_BLOCK="${tx_per_block}" \
          TRAFFIC_MODE="${traffic_mode}" \
          RUNTIME_SECONDS="${RUNTIME_SECONDS}" \
          EXPERIMENT_NAME="${experiment_name}" \
          "${SCRIPT_DIR}/run_lite_benchmark.sh"
      done
    done
  done
done

echo "==> Sweep done. Results under ${EVAL_OUTPUT_DIR}/lite_benchmark/"
