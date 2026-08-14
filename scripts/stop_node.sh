#!/usr/bin/env bash
set -euo pipefail

# Stops everything started by run_validators.sh.
STATE_DIR="${STATE_DIR:-/var/tmp/linera-node}"

if [ ! -f "${STATE_DIR}/pids" ]; then
  echo "No pid file at ${STATE_DIR}/pids, nothing to stop." >&2
  exit 0
fi

pids=()
while read -r pid; do
  [ -n "${pid}" ] || continue
  if kill -0 "${pid}" 2>/dev/null; then
    echo "Stopping pid ${pid}"
    kill "${pid}" 2>/dev/null || true
    pids+=("${pid}")
  fi
done < "${STATE_DIR}/pids"

# Wait for a clean exit (SIGTERM) before returning: a caller that immediately starts a new
# node needs these ports actually released, not just a signal sent. Escalate to SIGKILL for
# any straggler so we never return with something still bound to our ports.
for attempt in $(seq 1 20); do
  still_alive=()
  for pid in "${pids[@]}"; do
    kill -0 "${pid}" 2>/dev/null && still_alive+=("${pid}")
  done
  [ "${#still_alive[@]}" -eq 0 ] && break
  sleep 0.5
done
if [ "${#still_alive[@]}" -gt 0 ]; then
  echo "Force-killing stragglers: ${still_alive[*]}"
  kill -9 "${still_alive[@]}" 2>/dev/null || true
  sleep 1
fi

echo "Done. State/logs left in ${STATE_DIR} for inspection; delete manually when no longer needed."
