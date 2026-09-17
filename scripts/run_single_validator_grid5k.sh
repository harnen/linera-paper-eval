#!/usr/bin/env bash
set -euo pipefail

# One validator's storage-server / shards / proxy / manager, running as OS processes on this
# machine -- deployed and invoked remotely by run_committee_grid5k.sh, once per validator host.
#
# Unlike run_validators.sh, this never generates config or creates genesis itself: it expects
# server_0.json to already be sitting in STATE_DIR, placed there by the driver ahead of time.
# This two-mode split exists because genesis creation must happen exactly once for the whole
# committee (not once per host), and needs every validator's storage-server already listening
# first -- so the driver runs this script in two passes across every host: MODE=storage first,
# then (after it creates+initializes genesis using each host's now-reachable storage-server)
# MODE=workers.
#
# Configuration (env vars): mirrors run_validators.sh's per-validator options exactly, since
# every validator here is the single "v=0" case of that script's own arithmetic -- see there
# for the full rationale behind CORES_PER_SHARD/RESERVED_CORES/STORAGE_CORES/manager options.
#   MODE               storage | workers  (required)
#   NODE_HOST          (required) this machine's address, as named in server_0.json
#   NUM_SHARDS, CORES_PER_SHARD, RESERVED_CORES, STORAGE_CORES, SHARD_TOKIO_THREADS,
#   STORAGE_TOKIO_THREADS, BASE_SHARDS, START_MANAGER, MANAGER_INTERVAL_MS,
#   MANAGER_HIGH_WATERMARK, MANAGER_LOW_WATERMARK, MANAGER_MAX_MIGRATIONS_PER_ROUND,
#   MANAGER_MAX_DRAINS_PER_ROUND, MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                      identical meaning to run_validators.sh, just for one validator.
#   PROXY_PUBLIC_PORT, PROXY_PRIVATE_PORT, PROXY_METRICS_PORT, SHARD_PORT_BASE,
#   SHARD_METRICS_PORT_BASE, STORAGE_PORT
#                      plain ports, not *_BASE-plus-offset -- every validator here is alone on
#                      its own machine, so there is no need for run_validators.sh's
#                      multi-validator-per-host port layout.
#   BIN_DIR            (default ../bin relative to this script)
#   STATE_DIR          (default /var/tmp/linera-node)
#
# PIDs are appended (not overwritten) to ${STATE_DIR}/pids across the two MODE passes, so
# stop_node.sh, run unchanged, tears down everything this script started on this host.

MODE="${MODE:?set MODE=storage or MODE=workers}"
NODE_HOST="${NODE_HOST:?set NODE_HOST to this machine address, as named in server_0.json}"
NUM_SHARDS="${NUM_SHARDS:-1}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
RESERVED_CORES="${RESERVED_CORES:-0}"
STORAGE_CORES="${STORAGE_CORES:-0}"
SHARD_TOKIO_THREADS="${SHARD_TOKIO_THREADS:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
BASE_SHARDS="${BASE_SHARDS:-${NUM_SHARDS}}"
START_MANAGER="${START_MANAGER:-false}"
MANAGER_INTERVAL_MS="${MANAGER_INTERVAL_MS:-}"
MANAGER_HIGH_WATERMARK="${MANAGER_HIGH_WATERMARK:-}"
MANAGER_LOW_WATERMARK="${MANAGER_LOW_WATERMARK:-}"
MANAGER_MAX_MIGRATIONS_PER_ROUND="${MANAGER_MAX_MIGRATIONS_PER_ROUND:-}"
MANAGER_MAX_DRAINS_PER_ROUND="${MANAGER_MAX_DRAINS_PER_ROUND:-}"
MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS:-}"
MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS:-}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
PROXY_PRIVATE_PORT="${PROXY_PRIVATE_PORT:-10001}"
PROXY_METRICS_PORT="${PROXY_METRICS_PORT:-12001}"
SHARD_PORT_BASE="${SHARD_PORT_BASE:-9001}"
SHARD_METRICS_PORT_BASE="${SHARD_METRICS_PORT_BASE:-11001}"
STORAGE_PORT="${STORAGE_PORT:-19100}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
STATE_DIR="${STATE_DIR:-/var/tmp/linera-node}"

case "${STATE_DIR}" in
  /*) ;;
  *) STATE_DIR="$(pwd)/${STATE_DIR}" ;;
esac
if [ -n "${BIN_DIR}" ]; then
  case "${BIN_DIR}" in
    /*) ;;
    *) BIN_DIR="$(cd "${BIN_DIR}" && pwd)" ;;
  esac
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
mkdir -p "${STATE_DIR}"
cd "${STATE_DIR}"
touch pids

require_alive() {
  local pid="$1" label="$2" logfile="$3"
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "==> ${label} (pid ${pid}) died immediately -- last lines of ${logfile}:" >&2
    tail -n 20 "${logfile}" >&2
    exit 1
  fi
}

ensure_port_free() {
  local port="$1" pid
  pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p' | { grep -oP 'pid=\K[0-9]+' || true; } | head -1)"
  if [ -n "${pid}" ]; then
    echo "  port ${port} still held by pid ${pid} (leftover) -- killing it" >&2
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
  fi
}

storage_endpoint() { echo "service:tcp:${NODE_HOST}:${STORAGE_PORT}:table_default"; }

shard_core_offset=$((RESERVED_CORES + STORAGE_CORES))
reserved_taskset=()
storage_taskset=()
if [ "${CORES_PER_SHARD}" -gt 0 ]; then
  command -v taskset >/dev/null || { echo "taskset is required when CORES_PER_SHARD > 0" >&2; exit 1; }
  available_cores="$(nproc)"
  needed_cores=$((RESERVED_CORES + STORAGE_CORES + NUM_SHARDS * CORES_PER_SHARD))
  if [ "${needed_cores}" -gt "${available_cores}" ]; then
    echo "RESERVED_CORES+STORAGE_CORES+NUM_SHARDS*CORES_PER_SHARD=${needed_cores} exceeds this machine's ${available_cores} cores" >&2
    exit 1
  fi
  if [ "${RESERVED_CORES}" -gt 0 ]; then
    reserved_taskset=(taskset -c "0-$((RESERVED_CORES - 1))")
  fi
  if [ "${STORAGE_CORES}" -gt 0 ]; then
    storage_taskset=(taskset -c "${RESERVED_CORES}-$((RESERVED_CORES + STORAGE_CORES - 1))")
  else
    storage_taskset=("${reserved_taskset[@]}")
  fi
fi

if [ "${MODE}" = "storage" ]; then
  echo "==> [${NODE_HOST}] Starting storage-server on port ${STORAGE_PORT}"
  ensure_port_free "${STORAGE_PORT}"
  storage_tokio_threads_args=()
  if [ "${STORAGE_TOKIO_THREADS}" -gt 0 ]; then
    storage_tokio_threads_args=(--tokio-threads "${STORAGE_TOKIO_THREADS}")
  fi
  nohup "${storage_taskset[@]}" linera-storage-server "${storage_tokio_threads_args[@]}" \
    memory --endpoint "${NODE_HOST}:${STORAGE_PORT}" \
    > "${STATE_DIR}/storage-server.log" 2>&1 &
  pid=$!
  echo "${pid}" >> pids
  sleep 1
  require_alive "${pid}" "storage-server" "${STATE_DIR}/storage-server.log"
  echo "==> [${NODE_HOST}] storage-server up (pid ${pid})"
  exit 0
fi

if [ "${MODE}" != "workers" ]; then
  echo "Unknown MODE: ${MODE} (expected storage or workers)" >&2
  exit 1
fi

[ -f "${STATE_DIR}/server_0.json" ] || { echo "${STATE_DIR}/server_0.json not found -- driver must scp it before MODE=workers" >&2; exit 1; }

echo "==> [${NODE_HOST}] Reclaiming any leftover worker ports"
ensure_port_free "${PROXY_PUBLIC_PORT}"
while read -r port; do
  ensure_port_free "${port}"
done < <(jq -r '.internal_network.shards[].port, .internal_network.shards[].metrics_port, .internal_network.proxies[].private_port, .internal_network.proxies[].metrics_port' "${STATE_DIR}/server_0.json")

echo "==> [${NODE_HOST}] Starting ${BASE_SHARDS} shard(s)"
declare -A SHARD_PID
for s in $(seq 0 $((BASE_SHARDS - 1))); do
  shard_taskset=()
  tokio_threads_args=()
  if [ "${CORES_PER_SHARD}" -gt 0 ]; then
    shard_start=$((shard_core_offset + s * CORES_PER_SHARD))
    shard_end=$((shard_start + CORES_PER_SHARD - 1))
    shard_taskset=(taskset -c "${shard_start}-${shard_end}")
    if [ "${SHARD_TOKIO_THREADS}" -gt 0 ]; then
      tokio_threads_args=(--tokio-threads "${SHARD_TOKIO_THREADS}")
    else
      tokio_threads_args=(--tokio-threads "${CORES_PER_SHARD}")
    fi
    echo "  shard ${s}: cores ${shard_start}-${shard_end}, tokio-threads=${tokio_threads_args[1]}"
  fi
  nohup "${shard_taskset[@]}" linera-server "${tokio_threads_args[@]}" run \
    --server "${STATE_DIR}/server_0.json" \
    --storage "$(storage_endpoint)" \
    --shard "${s}" \
    > "${STATE_DIR}/shard_${s}.log" 2>&1 &
  SHARD_PID[${s}]=$!
  echo "${SHARD_PID[${s}]}" >> pids
done
sleep 2
for s in $(seq 0 $((BASE_SHARDS - 1))); do
  require_alive "${SHARD_PID[${s}]}" "shard ${s}" "${STATE_DIR}/shard_${s}.log"
done

echo "==> [${NODE_HOST}] Starting proxy"
nohup "${reserved_taskset[@]}" linera-proxy "${STATE_DIR}/server_0.json" \
  --storage "$(storage_endpoint)" \
  > "${STATE_DIR}/proxy.log" 2>&1 &
proxy_pid=$!
echo "${proxy_pid}" >> pids
sleep 2
require_alive "${proxy_pid}" "proxy" "${STATE_DIR}/proxy.log"

if [ "${START_MANAGER}" = "true" ]; then
  echo "==> [${NODE_HOST}] Starting manager (base_shards=${BASE_SHARDS}, total_shards=${NUM_SHARDS})"
  linera_server_bin="$(command -v linera-server)"
  spawn_command="${linera_server_bin} run --server ${STATE_DIR}/server_0.json --storage $(storage_endpoint) --shard {shard}"
  manager_args=(--server "${STATE_DIR}/server_0.json")
  [ -n "${MANAGER_INTERVAL_MS}" ] && manager_args+=(--interval-ms "${MANAGER_INTERVAL_MS}")
  [ -n "${MANAGER_HIGH_WATERMARK}" ] && manager_args+=(--high-watermark "${MANAGER_HIGH_WATERMARK}")
  [ -n "${MANAGER_LOW_WATERMARK}" ] && manager_args+=(--low-watermark "${MANAGER_LOW_WATERMARK}")
  [ -n "${MANAGER_MAX_MIGRATIONS_PER_ROUND}" ] && manager_args+=(--max-migrations-per-round "${MANAGER_MAX_MIGRATIONS_PER_ROUND}")
  [ -n "${MANAGER_MAX_DRAINS_PER_ROUND}" ] && manager_args+=(--max-drains-per-round "${MANAGER_MAX_DRAINS_PER_ROUND}")
  [ -n "${MANAGER_SCALE_DOWN_ROUNDS}" ] && manager_args+=(--scale-down-rounds "${MANAGER_SCALE_DOWN_ROUNDS}")
  [ -n "${MANAGER_COOLDOWN_ROUNDS}" ] && manager_args+=(--cooldown-rounds "${MANAGER_COOLDOWN_ROUNDS}")
  manager_args+=(--spawn-command "${spawn_command}")
  nohup linera-server manager "${manager_args[@]}" \
    > "${STATE_DIR}/manager.log" 2>&1 &
  manager_pid=$!
  echo "${manager_pid}" >> pids
  sleep 2
  require_alive "${manager_pid}" "manager" "${STATE_DIR}/manager.log"
fi

echo "==> [${NODE_HOST}] Worker(s) up: proxy public_port ${PROXY_PUBLIC_PORT}"
