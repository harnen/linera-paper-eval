#!/usr/bin/env bash
set -euo pipefail

# Runs the eval client against a real, remote validator started by run_validators.sh
# on a *different* machine. No validator binaries needed here, just `linera`
# and `linera-paper-eval`.
#
# Configuration (env vars):
#   FAUCET_URL       (required) e.g. http://<testbed-host>:8080, printed by run_validators.sh.
#                    If the testbed only exposes the faucet locally (see
#                    scripts/open_faucet_tunnel.sh), first open that tunnel, then set
#                    this to http://127.0.0.1:<LOCAL_FAUCET_PORT> instead. Either way,
#                    this only affects the one-time chain-claiming step -- the actual
#                    benchmark traffic goes straight to the validator's public proxy
#                    port (baked into the genesis config), not through FAUCET_URL.
#   BIN_DIR          (default ../bin relative to this script)
#   CLIENT_DIR       (default /var/tmp/linera-client) local wallet/keystore/storage for this client
#   EVAL_OUTPUT_DIR  (default /data_out) where result CSVs get written

FAUCET_URL="${FAUCET_URL:?set FAUCET_URL to the node faucet, e.g. http://<testbed-host>:8080}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
CLIENT_DIR="${CLIENT_DIR:-/var/tmp/linera-client}"
export EVAL_OUTPUT_DIR="${EVAL_OUTPUT_DIR:-/data_out}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v linera >/dev/null || { echo "linera binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v linera-paper-eval >/dev/null || { echo "linera-paper-eval binary not found on PATH (set BIN_DIR)" >&2; exit 1; }

echo "==> Waiting for faucet at ${FAUCET_URL}"
for attempt in $(seq 1 60); do
  if curl --fail --silent "${FAUCET_URL}" >/dev/null 2>&1; then
    break
  fi
  if [ "${attempt}" -eq 60 ]; then
    echo "Faucet did not become ready :(" >&2
    exit 1
  fi
  sleep 1
done

rm -rf "${CLIENT_DIR}"
mkdir -p "${CLIENT_DIR}"
mkdir -p "${EVAL_OUTPUT_DIR}"

export LINERA_WALLET="${CLIENT_DIR}/wallet.json"
export LINERA_KEYSTORE="${CLIENT_DIR}/keystore.json"
export LINERA_STORAGE="rocksdb:${CLIENT_DIR}/wallet-client.db"
export LINERA_TMP_DIR="${CLIENT_DIR}"
export FAUCET_URL

echo "==> Initializing local wallet from the remote faucet"
linera wallet init --faucet "${FAUCET_URL}"

echo "==> Running eval binary"
RUST_LOG="info,linera_paper_eval=info" linera-paper-eval

echo "==> Done. Results in ${EVAL_OUTPUT_DIR}"
