#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper around linera-lite-benchmark, the storage-free light client. Run
# scripts/provision_super_owner_chains.sh first to get chains it can use.
#
# Configuration (env vars):
#   LINERA_WALLET          (required) path to the admin_wallet.json used to provision chains
#   LINERA_KEYSTORE        (required) path to the matching admin_keystore.json
#   BIN_DIR                (default ../bin relative to this script)
#   CHAIN_IDS_FILE         (default ./chain_ids.txt) one chain ID per line; if unset/empty,
#                          linera-lite-benchmark defaults to every owned chain in the wallet
#   DESTINATION_CHAIN_IDS_FILE (optional) one chain ID per line -- extra chains passed as
#                          --destination-chains: valid mixed/full traffic targets that never
#                          get their own active task, so they don't consume any of
#                          CHAIN_IDS_FILE's chains' shard capacity. Must already exist.
#   BPS                    (default 100) total blocks/s target, summed across chains
#   TRANSACTIONS_PER_BLOCK (default 1)
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   RUNTIME_SECONDS        (optional) stop after this many seconds; omit to run until killed
#   EVAL_OUTPUT_DIR        (default /data_out) base directory for this run's log + CSV
#   EXPERIMENT_NAME        (default a timestamp) subdirectory name under EVAL_OUTPUT_DIR

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the admin wallet path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the admin keystore path}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
CHAIN_IDS_FILE="${CHAIN_IDS_FILE:-./chain_ids.txt}"
BPS="${BPS:-100}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-/data_out}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-$(date +%Y%m%d_%H%M%S)}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v linera-lite-benchmark >/dev/null || { echo "linera-lite-benchmark binary not found on PATH (set BIN_DIR)" >&2; exit 1; }

outdir="${EVAL_OUTPUT_DIR}/lite_benchmark/${EXPERIMENT_NAME}"
mkdir -p "${outdir}"

chains_arg=()
if [ -s "${CHAIN_IDS_FILE}" ]; then
  chains_csv="$(paste -sd, "${CHAIN_IDS_FILE}")"
  chains_arg=(--chains "${chains_csv}")
fi

destination_chains_arg=()
if [ -n "${DESTINATION_CHAIN_IDS_FILE:-}" ] && [ -s "${DESTINATION_CHAIN_IDS_FILE}" ]; then
  destination_chains_csv="$(paste -sd, "${DESTINATION_CHAIN_IDS_FILE}")"
  destination_chains_arg=(--destination-chains "${destination_chains_csv}")
fi

runtime_arg=()
if [ -n "${RUNTIME_SECONDS:-}" ]; then
  runtime_arg=(--runtime-in-seconds "${RUNTIME_SECONDS}")
fi

echo "==> Running linera-lite-benchmark (bps=${BPS}, tx/block=${TRANSACTIONS_PER_BLOCK}, traffic-mode=${TRAFFIC_MODE})"
echo "    log: ${outdir}/lite_benchmark.log"
echo "    csv: ${outdir}/transfers.csv"

RUST_LOG="info,linera_service=info" linera-lite-benchmark \
  --wallet "${LINERA_WALLET}" \
  --keystore "${LINERA_KEYSTORE}" \
  "${chains_arg[@]}" \
  "${destination_chains_arg[@]}" \
  --bps "${BPS}" \
  --transactions-per-block "${TRANSACTIONS_PER_BLOCK}" \
  --traffic-mode "${TRAFFIC_MODE}" \
  --output-csv "${outdir}/transfers.csv" \
  "${runtime_arg[@]}" \
  2>&1 | tee "${outdir}/lite_benchmark.log"

echo "==> Done. Results in ${outdir}"
