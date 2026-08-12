#!/usr/bin/env bash
set -euo pipefail

# Launches NUM_CLIENTS separate linera-lite-benchmark processes concurrently, each driving
# its own slice of CHAINS_PER_CLIENT chains from a shared chain-ID pool, and waits for all
# of them to finish. This is the "ramp the number of clients" building block used by
# find_max_tps.sh -- running genuinely separate OS processes (rather than one process with
# more --bps) means we're stressing the validator's ability to handle many concurrent
# connections, not just one client's internal concurrency.
#
# Configuration (env vars):
#   LINERA_WALLET          (required) admin wallet path (same one used to provision chains)
#   LINERA_KEYSTORE        (required) matching admin keystore path
#   CHAIN_IDS_FILE         (required) pool of chain IDs, one per line (from
#                          provision_super_owner_chains.sh); must have at least
#                          NUM_CLIENTS * CHAINS_PER_CLIENT lines
#   NUM_CLIENTS            (required) how many parallel linera-lite-benchmark processes
#   CHAINS_PER_CLIENT      (default 5) chains handed to each client (a distinct slice each)
#   BPS_PER_CLIENT         (default 50) blocks/s target per client process. Ignored if
#                          BPS_SCHEDULE is set.
#   BPS_SCHEDULE           (optional) a time-varying *total* (system-wide, summed across all
#                          NUM_CLIENTS processes) target rate instead of a fixed
#                          BPS_PER_CLIENT: comma-separated `offset_seconds:bps` pairs (see
#                          linera-lite-benchmark --help), must start at offset 0. Divided
#                          evenly by NUM_CLIENTS (integer division) and passed as each
#                          client's own --bps-schedule.
#   TRANSACTIONS_PER_BLOCK (default 1)
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   RUNTIME_SECONDS        (default 20)
#   BIN_DIR                (default ../bin relative to this script)
#   EVAL_OUTPUT_DIR        (default /data_out)
#   EXPERIMENT_NAME        (default a timestamp) subdirectory under EVAL_OUTPUT_DIR/lite_benchmark

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the admin wallet path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the admin keystore path}"
CHAIN_IDS_FILE="${CHAIN_IDS_FILE:?set CHAIN_IDS_FILE to the chain-id pool file}"
NUM_CLIENTS="${NUM_CLIENTS:?set NUM_CLIENTS to how many parallel client processes to launch}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
BPS_SCHEDULE="${BPS_SCHEDULE:-}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-20}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-/data_out}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-$(date +%Y%m%d_%H%M%S)}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi
command -v linera-lite-benchmark >/dev/null || { echo "linera-lite-benchmark binary not found on PATH (set BIN_DIR)" >&2; exit 1; }

needed_chains=$((NUM_CLIENTS * CHAINS_PER_CLIENT))
available_chains="$(wc -l < "${CHAIN_IDS_FILE}")"
if [ "${available_chains}" -lt "${needed_chains}" ]; then
  echo "chain pool ${CHAIN_IDS_FILE} has ${available_chains} chains, need ${needed_chains} (NUM_CLIENTS * CHAINS_PER_CLIENT)" >&2
  exit 1
fi

outdir="${EVAL_OUTPUT_DIR}/lite_benchmark/${EXPERIMENT_NAME}"
mkdir -p "${outdir}"

# Save experiment config
env > "${outdir}/.env"

rate_args=()
if [ -n "${BPS_SCHEDULE}" ]; then
  # Divide every breakpoint's bps by NUM_CLIENTS so the *system-wide* schedule is what's
  # actually achieved in aggregate (each client only knows its own even share). Rounds up
  # (not truncates) so a small-but-nonzero total never divides down to exactly 0 per
  # client -- --bps-schedule's wire format is integer bps, so unlike the per-chain split
  # inside linera-lite-benchmark itself (which uses f64 and can't hit this), a client-side
  # rate of exactly 0 would silently go completely idle instead of just ticking slowly.
  client_bps_schedule="$(awk -F'[:,]' -v n="${NUM_CLIENTS}" '
    { out = ""
      for (i = 1; i <= NF; i += 2) {
        if (out != "") out = out ","
        v = $(i+1)
        share = (v > 0) ? int((v + n - 1) / n) : 0
        out = out $i ":" share
      }
      print out
    }' <<< "${BPS_SCHEDULE}")"
  rate_args=(--bps-schedule "${client_bps_schedule}")
else
  rate_args=(--bps "${BPS_PER_CLIENT}")
fi

pids=()
for i in $(seq 1 "${NUM_CLIENTS}"); do
  start_line=$(( (i - 1) * CHAINS_PER_CLIENT + 1 ))
  end_line=$(( i * CHAINS_PER_CLIENT ))
  chains_csv="$(sed -n "${start_line},${end_line}p" "${CHAIN_IDS_FILE}" | paste -sd,)"
  client_dir="${outdir}/client_${i}"
  mkdir -p "${client_dir}"

  # linera-persistent takes a non-blocking exclusive flock on every wallet/keystore open,
  # even for reads (by design -- see linera-persistent/src/file.rs). Pointing every parallel
  # client at the same wallet file means all but one fail immediately with "Resource
  # temporarily unavailable", so give each client its own copy (read-only content, safe to
  # duplicate -- linera-lite-benchmark never writes back to it).
  cp "${LINERA_WALLET}" "${client_dir}/wallet.json"
  cp "${LINERA_KEYSTORE}" "${client_dir}/keystore.json"

  RUST_LOG="info,linera_service=info" linera-lite-benchmark \
    --wallet "${client_dir}/wallet.json" \
    --keystore "${client_dir}/keystore.json" \
    --chains "${chains_csv}" \
    "${rate_args[@]}" \
    --transactions-per-block "${TRANSACTIONS_PER_BLOCK}" \
    --traffic-mode "${TRAFFIC_MODE}" \
    --output-csv "${client_dir}/transfers.csv" \
    --runtime-in-seconds "${RUNTIME_SECONDS}" \
    > "${client_dir}/lite_benchmark.log" 2>&1 &
  pids+=($!)
done

if [ -n "${BPS_SCHEDULE}" ]; then
  echo "==> ${NUM_CLIENTS} client(s) running (bps schedule: ${BPS_SCHEDULE}), waiting ~${RUNTIME_SECONDS}s..."
else
  echo "==> ${NUM_CLIENTS} client(s) running (requested total: $((NUM_CLIENTS * BPS_PER_CLIENT)) bps), waiting ~${RUNTIME_SECONDS}s..."
fi
failed=0
for pid in "${pids[@]}"; do
  wait "${pid}" || failed=$((failed + 1))
done

if [ "${failed}" -gt 0 ]; then
  echo "==> ${failed}/${NUM_CLIENTS} client process(es) exited with an error -- check ${outdir}/client_*/lite_benchmark.log" >&2
fi

echo "==> Done. Results in ${outdir}"
