#!/usr/bin/env bash
set -euo pipefail

# Provisions chains for linera-lite-benchmark, without ever touching a faucet.
#
# linera-lite-benchmark only works on chains owned by a single *super owner* (so it can use
# the one-round-trip Round::Fast path). Rather than claiming chains from an untrusted faucet
# (which needs its own port/tunnel -- see open_faucet_tunnel.sh), this script uses the node's
# own admin wallet directly: that wallet already owns the genesis/root chain outright (with
# the committee baked into the wallet file), so it can fund children from it. Only the
# validator's public proxy port is ever touched -- the same port the benchmark traffic
# itself uses.
#
# Opening chains one at a time (one block each) is inherently serial: they're all children
# of the same admin chain, whose blocks must be strictly ordered, so a naive loop can't be
# parallelized. Instead this uses `linera benchmark single`, which batches up to 900
# OpenChain operations (each creating a `ChainOwnership::single_super` chain, exactly what
# we need) into a *single* block -- turning "N sequential blocks" into "N/900 sequential
# blocks". `--confirm-before-start` makes it pause right after chain creation and wait for a
# "yes" on stdin before sending any of its own benchmark traffic; piping in anything else
# declines and lets it exit cleanly via its normal wrap-up path, chains left open and ready.
#
# Get the admin wallet and genesis config onto this machine first, e.g.:
#   scp node:$STATE_DIR/admin_wallet.json node:$STATE_DIR/admin_keystore.json \
#       node:$STATE_DIR/genesis.json $CLIENT_DIR/
#
# Configuration (env vars):
#   LINERA_WALLET     (required) path to the copied admin_wallet.json
#   LINERA_KEYSTORE   (required) path to the copied admin_keystore.json
#   GENESIS_PATH      (default: genesis.json next to LINERA_WALLET) path to the copied
#                      genesis.json -- needed to seed this client's own local storage with
#                      the admin chain's ChainDescription before it can open chains from it
#   BIN_DIR           (default ../bin relative to this script)
#   CLIENT_DIR        (default /var/tmp/linera-client) local storage for this client's own
#                      bookkeeping (not shared with the node)
#   NUM_CHAINS        (default 10) how many super-owner chains to open (always from the
#                      wallet's default chain -- linera benchmark doesn't support an
#                      explicit --from, unlike the old one-at-a-time approach)
#   INITIAL_BALANCE   (default 1000) initial balance of each opened chain
#   OUTPUT_FILE       (default ./chain_ids.txt) where the opened chain IDs are written,
#                      one per line, for reuse by run_lite_benchmark.sh / the sweep driver

LINERA_WALLET="${LINERA_WALLET:?set LINERA_WALLET to the copied admin_wallet.json path}"
LINERA_KEYSTORE="${LINERA_KEYSTORE:?set LINERA_KEYSTORE to the copied admin_keystore.json path}"
GENESIS_PATH="${GENESIS_PATH:-$(dirname "${LINERA_WALLET}")/genesis.json}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
CLIENT_DIR="${CLIENT_DIR:-/var/tmp/linera-client}"
NUM_CHAINS="${NUM_CHAINS:-10}"
INITIAL_BALANCE="${INITIAL_BALANCE:-1000}"
OUTPUT_FILE="${OUTPUT_FILE:-./chain_ids.txt}"

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v linera >/dev/null || { echo "linera binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -f "${GENESIS_PATH}" ] || { echo "genesis config not found at ${GENESIS_PATH} (set GENESIS_PATH, or copy genesis.json next to the wallet)" >&2; exit 1; }

rm -rf "${CLIENT_DIR}"
mkdir -p "${CLIENT_DIR}"
export LINERA_WALLET
export LINERA_KEYSTORE
export LINERA_STORAGE="${LINERA_STORAGE:-rocksdb:${CLIENT_DIR}/wallet-client.db}"

# This client's own local storage starts out empty, so it has no ChainDescription for the
# admin chain we're about to open children from -- write it in first (safe to re-run: a
# storage that's already initialized to the same genesis is left untouched).
echo "==> Initializing local client storage from ${GENESIS_PATH}"
linera storage initialize --storage "${LINERA_STORAGE}" --genesis "${GENESIS_PATH}"

# create-genesis-config (see run_validators.sh) always creates one non-admin root chain in
# addition to the admin chain -- needed so the faucet flow (a different workflow, sharing
# the same genesis) doesn't panic. That pre-existing chain is a regular (non-super-owner)
# chain, so it can't use linera-lite-benchmark's Round::Fast path: any client assigned it
# would get "no quorum of validators voted to confirm the proposed block" on every single
# attempt against it, while every other chain works fine. Record it now, before opening our
# own chains, so it can be excluded below rather than silently ending up in the pool.
preexisting_chains_file="$(mktemp)"
jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${LINERA_WALLET}" > "${preexisting_chains_file}"

echo "==> Opening ${NUM_CHAINS} super-owner chains via batched blocks (up to 900/block)"
echo "no" | linera benchmark single \
  --num-chains "${NUM_CHAINS}" \
  --tokens-per-chain "${INITIAL_BALANCE}" \
  --transactions-per-block 1 \
  --bps 1 \
  --confirm-before-start

# `linera benchmark single` writes the new chains straight into the wallet; every chain in
# it other than the default (admin) one and the pre-existing one recorded above is a chain
# we just created.
jq -r '.default as $admin | .chains | keys[] | select(. != $admin)' "${LINERA_WALLET}" \
  | grep -vxFf "${preexisting_chains_file}" > "${OUTPUT_FILE}"
rm -f "${preexisting_chains_file}"

created="$(wc -l < "${OUTPUT_FILE}")"
if [ "${created}" -ne "${NUM_CHAINS}" ]; then
  echo "warning: expected ${NUM_CHAINS} chains, found ${created} in the wallet" >&2
fi

echo "==> Done. ${created} chain IDs written to ${OUTPUT_FILE}"
