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
#   NUM_CLIENTS            (required) how many parallel linera-lite-benchmark processes *on
#                          this host*
#   CHAINS_PER_CLIENT      (default 5) chains handed to each client (a distinct slice each)
#   CLIENT_INDEX_OFFSET    (default 0) global index of the first client this host runs, minus
#                          one -- i.e. this host's clients are numbered
#                          [offset+1, offset+NUM_CLIENTS] rather than always starting at 1. Set
#                          this when splitting one level's clients across multiple hosts
#                          against a single shared CHAIN_IDS_FILE, so each host's clients index
#                          into a disjoint slice of it (host 2 of 4, e.g., passes the previous
#                          hosts' combined client counts as its offset) and each host's output
#                          directories (client_<i>) stay globally unique instead of colliding.
#   BPS_PER_CLIENT         (default 50) blocks/s target per client process. Ignored if
#                          BPS_SCHEDULE is set.
#   BPS_SCHEDULE           (optional) a time-varying *total* (system-wide, summed across all
#                          NUM_CLIENTS processes) target rate instead of a fixed
#                          BPS_PER_CLIENT: comma-separated `offset_seconds:bps` pairs (see
#                          linera-lite-benchmark --help), must start at offset 0. Divided
#                          evenly by NUM_CLIENTS (integer division) and passed as each
#                          client's own --bps-schedule.
#   TRANSACTIONS_PER_BLOCK (default 1) ignored if TRANSACTIONS_PER_BLOCK_FILE is set
#   TRANSACTIONS_PER_BLOCK_FILE (optional) path *on this host* to a file with one block size
#                          per line (e.g. the Ethereum trace in
#                          ethereum_txs_per_block_19m_to_21m.csv, header stripped). Every
#                          client process reads it, and each chain walks it from its own
#                          random offset.
#   TRANSACTIONS_PER_BLOCK_SCALE (default 1.0) scales every entry of that file
#   TRAFFIC_MODE           (default independent) independent | mixed | full
#   LIGHT_CERTIFICATES     (default false) passed as --light-certificates when true: broadcast
#                          the confirmed certificate's compact hash+signatures form to
#                          validators known to have voted for it (they already have the value
#                          cached), instead of the full certificate -- shrinks the third of
#                          three round trips per block
#   CLIENT_MODE            (default lite) passed as --client-mode: lite (3 RTTs/block, no local
#                          storage/execution) or full (2 RTTs/block, a real ChainClient with
#                          local in-memory storage that executes every block itself -- native
#                          operations only, currently requires TRAFFIC_MODE=independent)
#   CLIENT_TOKIO_THREADS   (optional) passed as --tokio-threads to every client process. Each
#                          process defaults to one Tokio worker thread per CPU on this machine,
#                          which is generous for what's mostly I/O-bound work -- at high
#                          NUM_CLIENTS that can badly oversubscribe the client host (N
#                          processes x num_cpus threads each). Set this low (e.g. 2) when
#                          running many clients per machine.
#   SIMULATED_LATENCY_MS   (optional) passed as --simulated-latency-ms to every client process:
#                          adds this many milliseconds of artificial delay before every gRPC
#                          request to a validator, simulating a higher-latency (e.g. WAN) link.
#                          Useful for testing whether round-trips-per-block (--client-mode,
#                          --light-certificates) matters more once each round trip is expensive.
#   SKIP_MESSAGE_PROCESSING (default false) passed as --skip-message-processing when true: in
#                          mixed/full traffic modes, chains still send cross-chain messages as
#                          usual but never drain their own inboxes, isolating the CPU cost of
#                          sending messages from the cost of receiving/processing them. No
#                          effect in independent mode. Inboxes grow unbounded for the run's
#                          duration -- fine for a short benchmark, not a realistic steady state.
#   MAX_DESTINATIONS_PER_BLOCK (optional) passed as --max-destinations-per-block: caps how many
#                          distinct chains one block's transfers are spread across in mixed/full
#                          traffic modes, regardless of the block's transaction count or how many
#                          chains are in play. Without it, a block bigger than the destination
#                          pool touches every destination at least once, so cross-chain fan-out
#                          scales with the chain count instead of staying bounded.
#   MAX_INCOMING_BUNDLES_PER_BLOCK (optional) passed as --max-incoming-bundles-per-block: caps
#                          how many incoming message bundles one block will drain from its
#                          chain's inboxes, on top of its own operations, in mixed/full traffic
#                          modes. Defaults (unset) to twice that block's own operation count.
#                          No effect in independent mode.
#   RUNTIME_SECONDS        (default 20)
#   BIN_DIR                (default ../bin relative to this script)
#   EVAL_OUTPUT_DIR        (default /data_out)
#   EXPERIMENT_NAME        (default a timestamp) subdirectory under EVAL_OUTPUT_DIR/lite_benchmark

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the admin wallet path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the admin keystore path}"
CHAIN_IDS_FILE="${CHAIN_IDS_FILE:?set CHAIN_IDS_FILE to the chain-id pool file}"
NUM_CLIENTS="${NUM_CLIENTS:?set NUM_CLIENTS to how many parallel client processes to launch}"
CHAINS_PER_CLIENT="${CHAINS_PER_CLIENT:-5}"
CLIENT_INDEX_OFFSET="${CLIENT_INDEX_OFFSET:-0}"
BPS_PER_CLIENT="${BPS_PER_CLIENT:-50}"
BPS_SCHEDULE="${BPS_SCHEDULE:-}"
TRANSACTIONS_PER_BLOCK="${TRANSACTIONS_PER_BLOCK:-1}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
TRANSACTIONS_PER_BLOCK_SCALE="${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}"
TRAFFIC_MODE="${TRAFFIC_MODE:-independent}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-false}"
CLIENT_MODE="${CLIENT_MODE:-lite}"
CLIENT_TOKIO_THREADS="${CLIENT_TOKIO_THREADS:-}"
SIMULATED_LATENCY_MS="${SIMULATED_LATENCY_MS:-}"
SKIP_MESSAGE_PROCESSING="${SKIP_MESSAGE_PROCESSING:-false}"
MAX_DESTINATIONS_PER_BLOCK="${MAX_DESTINATIONS_PER_BLOCK:-}"
MAX_INCOMING_BUNDLES_PER_BLOCK="${MAX_INCOMING_BUNDLES_PER_BLOCK:-}"
RUNTIME_SECONDS="${RUNTIME_SECONDS:-20}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-/data_out}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-$(date +%Y%m%d_%H%M%S)}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi
command -v linera-lite-benchmark >/dev/null || { echo "linera-lite-benchmark binary not found on PATH (set BIN_DIR)" >&2; exit 1; }

needed_chains=$(((CLIENT_INDEX_OFFSET + NUM_CLIENTS) * CHAINS_PER_CLIENT))
available_chains="$(wc -l < "${CHAIN_IDS_FILE}")"
if [ "${available_chains}" -lt "${needed_chains}" ]; then
  echo "chain pool ${CHAIN_IDS_FILE} has ${available_chains} chains, need ${needed_chains} ((CLIENT_INDEX_OFFSET + NUM_CLIENTS) * CHAINS_PER_CLIENT)" >&2
  exit 1
fi

outdir="${EVAL_OUTPUT_DIR}/lite_benchmark/${EXPERIMENT_NAME}"
mkdir -p "${outdir}"

# Save experiment config
env > "${outdir}/.env"

tx_size_args=(--transactions-per-block "${TRANSACTIONS_PER_BLOCK}")
if [ -n "${TRANSACTIONS_PER_BLOCK_FILE}" ]; then
  [ -f "${TRANSACTIONS_PER_BLOCK_FILE}" ] || {
    echo "TRANSACTIONS_PER_BLOCK_FILE ${TRANSACTIONS_PER_BLOCK_FILE} not found on this host" >&2
    exit 1
  }
  tx_size_args=(--transactions-per-block-file "${TRANSACTIONS_PER_BLOCK_FILE}"
                --transactions-per-block-scale "${TRANSACTIONS_PER_BLOCK_SCALE}")
fi

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

# linera-persistent takes a non-blocking exclusive flock on every wallet/keystore open, even
# for reads (by design -- see linera-persistent/src/file.rs). Pointing every parallel client at
# the same wallet file means all but one fail immediately with "Resource temporarily
# unavailable", so every client needs its own wallet/keystore file. Copying the *entire* admin
# wallet per client doesn't scale (31.5MB at a 100,050-chain pool, times thousands of clients,
# blew through the Grid5000 NFS home quota and silently corrupted a run) -- build each client a
# minimal wallet/keystore containing only its own CHAINS_PER_CLIENT chains/keys instead, in one
# pass over the admin files rather than per-client.
build_script_dir="$(cd "$(dirname "$0")" && pwd)"
python3 "${build_script_dir}/build_client_wallets.py" \
  --wallet "${LINERA_WALLET}" --keystore "${LINERA_KEYSTORE}" \
  --chain-ids-file "${CHAIN_IDS_FILE}" \
  --client-index-offset "${CLIENT_INDEX_OFFSET}" --num-clients "${NUM_CLIENTS}" \
  --chains-per-client "${CHAINS_PER_CLIENT}" --outdir "${outdir}"

pids=()
for i in $(seq "$((CLIENT_INDEX_OFFSET + 1))" "$((CLIENT_INDEX_OFFSET + NUM_CLIENTS))"); do
  start_line=$(( (i - 1) * CHAINS_PER_CLIENT + 1 ))
  end_line=$(( i * CHAINS_PER_CLIENT ))
  chains_csv="$(sed -n "${start_line},${end_line}p" "${CHAIN_IDS_FILE}" | paste -sd,)"
  client_dir="${outdir}/client_${i}"

  light_cert_args=()
  if [ "${LIGHT_CERTIFICATES}" = "true" ]; then
    light_cert_args=(--light-certificates)
  fi
  tokio_threads_args=()
  if [ -n "${CLIENT_TOKIO_THREADS}" ]; then
    tokio_threads_args=(--tokio-threads "${CLIENT_TOKIO_THREADS}")
  fi
  simulated_latency_args=()
  if [ -n "${SIMULATED_LATENCY_MS}" ]; then
    simulated_latency_args=(--simulated-latency-ms "${SIMULATED_LATENCY_MS}")
  fi
  skip_message_processing_args=()
  if [ "${SKIP_MESSAGE_PROCESSING}" = "true" ]; then
    skip_message_processing_args=(--skip-message-processing)
  fi
  max_destinations_args=()
  if [ -n "${MAX_DESTINATIONS_PER_BLOCK}" ]; then
    max_destinations_args=(--max-destinations-per-block "${MAX_DESTINATIONS_PER_BLOCK}")
  fi
  max_incoming_bundles_args=()
  if [ -n "${MAX_INCOMING_BUNDLES_PER_BLOCK}" ]; then
    max_incoming_bundles_args=(--max-incoming-bundles-per-block "${MAX_INCOMING_BUNDLES_PER_BLOCK}")
  fi

  RUST_LOG="info,linera_service=info" linera-lite-benchmark \
    --wallet "${client_dir}/wallet.json" \
    --keystore "${client_dir}/keystore.json" \
    --chains "${chains_csv}" \
    "${rate_args[@]}" \
    "${tx_size_args[@]}" \
    --traffic-mode "${TRAFFIC_MODE}" \
    --client-mode "${CLIENT_MODE}" \
    "${light_cert_args[@]}" \
    "${tokio_threads_args[@]}" \
    "${simulated_latency_args[@]}" \
    "${skip_message_processing_args[@]}" \
    "${max_destinations_args[@]}" \
    "${max_incoming_bundles_args[@]}" \
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
