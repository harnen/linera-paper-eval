#!/usr/bin/env bash
set -euo pipefail

# Opens an SSH tunnel from this (client) machine to the testbed's faucet, which
# run_validators.sh only binds locally (it's not one of the directly-opened ports --
# only the proxy's public port is). The faucet is only hit once at startup to
# claim chains, so tunneling it is fine even though it adds latency; the actual
# benchmark traffic goes straight to the proxy's public port instead, untouched
# by this tunnel.
#
# Runs in the foreground (ssh -N); leave it running in its own terminal/tmux pane
# (or run this script with `&`) for as long as run_client.sh needs the faucet.
#
# Configuration (env vars):
#   SSH_HOST           (required) the testbed's hostname/IP
#   SSH_USER           (default: current user)
#   SSH_PORT           (default 22)
#   REMOTE_FAUCET_PORT (required) the FAUCET_PORT run_validators.sh printed
#   LOCAL_FAUCET_PORT  (default: same as REMOTE_FAUCET_PORT)

SSH_HOST="${SSH_HOST:?set SSH_HOST to the testbed hostname/IP}"
SSH_USER="${SSH_USER:-$USER}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_FAUCET_PORT="${REMOTE_FAUCET_PORT:?set REMOTE_FAUCET_PORT to the faucet port run_validators.sh printed}"
LOCAL_FAUCET_PORT="${LOCAL_FAUCET_PORT:-${REMOTE_FAUCET_PORT}}"

echo "==> Tunneling 127.0.0.1:${LOCAL_FAUCET_PORT} (here) -> 127.0.0.1:${REMOTE_FAUCET_PORT} (on ${SSH_HOST}, via ssh -p ${SSH_PORT})"
echo "==> Once connected, use: FAUCET_URL=http://127.0.0.1:${LOCAL_FAUCET_PORT} ./scripts/run_client.sh"
exec ssh -N \
  -p "${SSH_PORT}" \
  -L "${LOCAL_FAUCET_PORT}:127.0.0.1:${REMOTE_FAUCET_PORT}" \
  "${SSH_USER}@${SSH_HOST}"
