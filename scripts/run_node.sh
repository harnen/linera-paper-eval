#!/usr/bin/env bash
set -euo pipefail

# Runs a single, real, remotely-reachable Linera validator as plain OS processes
# (no Docker) on this machine: a storage-server (memory backend, shared by all
# shards), NUM_SHARDS shard processes, one proxy, and a faucet.
#
# Unlike `linera net up` (used for the single-machine Docker experiments in
# run_docker_paper_eval.sh), every address here is the real, LAN/public-reachable
# NODE_HOST, so a client on a *different* machine can talk to it.
#
# Only two ports need to leave this machine at all: the proxy's public port (all
# benchmark traffic, so it's pinned to PROXY_PUBLIC_PORT -- the one port your
# firewall opens directly, so this hot path never goes through a tunnel) and the
# faucet port (only used once at startup to claim chains, low intensity, fine to
# reach through an SSH tunnel instead -- see scripts/open_faucet_tunnel.sh). Shards,
# the proxy's internal/metrics ports, and the storage-service never need to be
# reachable from outside this machine.
#
# Requires `jq` and the binaries produced by extract_binaries.sh
# (linera, linera-server, linera-proxy, linera-storage-server) on PATH or in BIN_DIR.
#
# Configuration (env vars):
#   NODE_HOST         (required) this machine's IP/hostname, reachable from the client
#   PROXY_PUBLIC_PORT (default 4001) the one port opened directly for clients (hot path)
#   NUM_SHARDS        (default 1)
#   CORES_PER_SHARD   (default 0 = no pinning) if set, each shard is pinned via `taskset`
#                      to its own block of this many cores, and given a matching
#                      --tokio-threads so it doesn't oversubscribe its own pinned cores
#                      (override with SHARD_TOKIO_THREADS if a shard needs more worker
#                      threads than pinned cores -- most chain-processing work is
#                      lock/IO-bound, not CPU-bound, so oversubscribing threads relative to
#                      cores can relieve head-of-line blocking when a shard owns many
#                      concurrently-active chains).
#                      Cores are assigned after RESERVED_CORES + STORAGE_CORES, sequentially
#                      per shard.
#   RESERVED_CORES    (default 2) cores set aside (and pinned) for the proxy, only used
#                      when CORES_PER_SHARD > 0. It handles every request in or out, so it
#                      needs headroom too -- don't set this to 0 if you're pinning shards to
#                      every remaining core.
#   STORAGE_CORES     (default 0 = same as RESERVED_CORES, i.e. shares the proxy's range,
#                      the old behavior) cores set aside (and pinned) for storage-server,
#                      only used when CORES_PER_SHARD > 0. All shards funnel every read/write
#                      through this one process (in-memory backend, single instance), so
#                      under concurrent load it can be a serialization point worth its own
#                      dedicated cores rather than sharing the proxy's small reservation --
#                      set this explicitly (e.g. close to NUM_SHARDS, one storage core per
#                      shard worker) to test whether storage contention is a bottleneck.
#                      Cores are assigned after RESERVED_CORES and before the shards' range.
#                      Errors out if NUM_SHARDS * CORES_PER_SHARD + RESERVED_CORES +
#                      STORAGE_CORES exceeds the machine's core count (`nproc`).
#   STORAGE_PORT      (default 19100)
#   START_FAUCET      (default true) set to false to skip the faucet entirely -- only the
#                      run_client.sh/linera-paper-eval fat-client flow needs it; the
#                      no-faucet lite-benchmark flow (provision_super_owner_chains.sh) does
#                      not touch it at all
#   FAUCET_PORT       (default 8080) only reachable via SSH tunnel, not opened directly
#   INITIAL_AMOUNT    (default 1000000000) initial balance of the genesis admin chain
#   FAUCET_AMOUNT     (default 1000) tokens the faucet hands out per claimed chain
#   BIN_DIR           (default ../bin relative to this script) where the binaries live
#   STATE_DIR         (default /var/tmp/linera-node) wallets/configs/logs/PIDs
#   STORAGE_TOKIO_THREADS (default 0 = unset, storage-server picks its own default via
#                      `available_parallelism()`) passed as `--tokio-threads` to
#                      linera-storage-server directly -- independent of STORAGE_CORES/
#                      taskset pinning, so thread count can be constrained without also
#                      restricting which cores storage-server may run on.
#   STRACE_STORAGE_SERVER (default false) wrap storage-server's launch in
#                      `strace -f -c`, writing a syscall-time summary to
#                      STATE_DIR/storage-server.strace on exit. Diagnostic only -- adds
#                      ptrace overhead to every syscall, so throughput numbers from a run
#                      with this on are not representative; only the *relative* time
#                      breakdown across syscalls is meaningful. Needs no root (works because
#                      strace launches the process itself as its own child).
#   BASE_SHARDS       (default NUM_SHARDS, i.e. every shard is a base shard, the old
#                      behavior) how many of the NUM_SHARDS configured shard slots are
#                      started as processes and receive default (hash-based) chain
#                      assignments. Shards beyond this prefix are *elastic* slots: they're
#                      only ever started/stopped by the validator manager (see
#                      START_MANAGER) as chains are explicitly migrated onto them, so they
#                      can be added/removed at runtime without orphaning any default-routed
#                      chain. Requires the restored `dynamic_shards` + manager work (see
#                      linera-rpc/src/routing.rs, linera-service/src/manager.rs).
#   START_MANAGER     (default false) start `linera-server manager`, a long-running process
#                      that polls per-chain load from every configured shard and adapts:
#                      spawns the worker for the next elastic slot when a base/active shard
#                      is overloaded and nobody has spare capacity, rebalances hot chains
#                      onto the least-loaded shard, and drains+stops elastic workers that
#                      have been idle for MANAGER_SCALE_DOWN_ROUNDS consecutive polls. Only
#                      meaningful when BASE_SHARDS < NUM_SHARDS (otherwise there are no
#                      elastic slots to spawn into). On shutdown (this script's normal
#                      SIGTERM-based teardown) it drains and stops every elastic worker it
#                      started before exiting.
#   MANAGER_INTERVAL_MS, MANAGER_HIGH_WATERMARK, MANAGER_LOW_WATERMARK,
#   MANAGER_MAX_MIGRATIONS_PER_ROUND, MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                      passed straight through to `linera-server manager`'s matching flags;
#                      unset ones are omitted so the binary's own defaults apply (notably
#                      --low-watermark defaults to high-watermark/4 when omitted).

NODE_HOST="${NODE_HOST:?set NODE_HOST to the IP/hostname of this machine, reachable from the client}"
PROXY_PUBLIC_PORT="${PROXY_PUBLIC_PORT:-4001}"
NUM_SHARDS="${NUM_SHARDS:-1}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
SHARD_TOKIO_THREADS="${SHARD_TOKIO_THREADS:-0}"
RESERVED_CORES="${RESERVED_CORES:-2}"
STORAGE_CORES="${STORAGE_CORES:-0}"
STORAGE_TOKIO_THREADS="${STORAGE_TOKIO_THREADS:-0}"
STRACE_STORAGE_SERVER="${STRACE_STORAGE_SERVER:-false}"
BASE_SHARDS="${BASE_SHARDS:-${NUM_SHARDS:-1}}"
START_MANAGER="${START_MANAGER:-false}"
MANAGER_INTERVAL_MS="${MANAGER_INTERVAL_MS:-}"
MANAGER_HIGH_WATERMARK="${MANAGER_HIGH_WATERMARK:-}"
MANAGER_LOW_WATERMARK="${MANAGER_LOW_WATERMARK:-}"
MANAGER_MAX_MIGRATIONS_PER_ROUND="${MANAGER_MAX_MIGRATIONS_PER_ROUND:-}"
MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS:-}"
MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS:-}"
STORAGE_PORT="${STORAGE_PORT:-19100}"
START_FAUCET="${START_FAUCET:-true}"
FAUCET_PORT="${FAUCET_PORT:-8080}"
INITIAL_AMOUNT="${INITIAL_AMOUNT:-1000000000}"
FAUCET_AMOUNT="${FAUCET_AMOUNT:-1000}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
STATE_DIR="${STATE_DIR:-/var/tmp/linera-node}"
# Resolve to an absolute path up front: the script cd's into STATE_DIR below, and every
# subsequent use of "${STATE_DIR}/..." must stay valid after that -- a relative STATE_DIR
# (e.g. "linera/state") would otherwise get erroneously re-joined against the new cwd
# (already inside STATE_DIR), duplicating the path.
case "${STATE_DIR}" in
  /*) ;;
  *) STATE_DIR="$(pwd)/${STATE_DIR}" ;;
esac

if [ -n "${BIN_DIR}" ]; then
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v linera >/dev/null || { echo "linera binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v linera-server >/dev/null || { echo "linera-server binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v linera-proxy >/dev/null || { echo "linera-proxy binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
command -v linera-storage-server >/dev/null || { echo "linera-storage-server binary not found on PATH (set BIN_DIR)" >&2; exit 1; }

proxy_taskset=()
storage_taskset=()
shard_core_offset=0
if [ "${CORES_PER_SHARD}" -gt 0 ]; then
  command -v taskset >/dev/null || { echo "taskset is required when CORES_PER_SHARD > 0" >&2; exit 1; }
  available_cores="$(nproc)"
  needed_cores=$((RESERVED_CORES + STORAGE_CORES + NUM_SHARDS * CORES_PER_SHARD))
  if [ "${needed_cores}" -gt "${available_cores}" ]; then
    echo "RESERVED_CORES (${RESERVED_CORES}) + STORAGE_CORES (${STORAGE_CORES}) + NUM_SHARDS*CORES_PER_SHARD (${NUM_SHARDS}*${CORES_PER_SHARD}=$((NUM_SHARDS * CORES_PER_SHARD))) = ${needed_cores} exceeds this machine's ${available_cores} cores" >&2
    exit 1
  fi
  if [ "${RESERVED_CORES}" -gt 0 ]; then
    proxy_taskset=(taskset -c "0-$((RESERVED_CORES - 1))")
  fi
  if [ "${STORAGE_CORES}" -gt 0 ]; then
    storage_taskset=(taskset -c "${RESERVED_CORES}-$((RESERVED_CORES + STORAGE_CORES - 1))")
    shard_core_offset=$((RESERVED_CORES + STORAGE_CORES))
  else
    # Old behavior: storage-server shares the proxy's reserved range, shards start right
    # after it -- preserved as the default (STORAGE_CORES=0) for backward compatibility.
    storage_taskset=("${proxy_taskset[@]}")
    shard_core_offset="${RESERVED_CORES}"
  fi
fi

rm -rf "${STATE_DIR}"
mkdir -p "${STATE_DIR}"
cd "${STATE_DIR}"
: > pids

# nohup'ing a process that fails immediately (e.g. a bind conflict) still returns success --
# the failure only shows up in its log file. Verify each process actually stayed up instead
# of silently proceeding to declare the node ready.
require_alive() {
  local pid="$1" label="$2" logfile="$3"
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "==> ${label} (pid ${pid}) died immediately -- last lines of ${logfile}:" >&2
    tail -n 20 "${logfile}" >&2
    exit 1
  fi
}

# If a port we're about to bind is still held (e.g. by a child of the throwaway template
# net below that outlived the `kill` of its parent -- `wait` on the parent does not
# guarantee its children have exited too), reclaim it instead of letting our own process
# fail with AddrInUse and leaving a half-started, orphaned node behind.
ensure_port_free() {
  local port="$1" pid
  # $4 is "Local Address:Port" (e.g. "193.60.241.98:19100"); anchor on ":<port>" at the end
  # so port 100 doesn't match a listener on port 1009 etc.
  # grep exits 1 on "no matches" (the normal case: port already free), which under
  # pipefail would otherwise take the whole script down via set -e.
  pid="$(ss -ltnp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p' | { grep -oP 'pid=\K[0-9]+' || true; } | head -1)"
  if [ -n "${pid}" ]; then
    echo "  port ${port} still held by pid ${pid} (likely a leftover from the throwaway template net below) -- killing it" >&2
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
  fi
}

# Covers the whole script, not just the throwaway net: if anything fails partway through
# startup (including require_alive above calling exit), kill everything recorded in `pids`
# so far instead of leaving a half-started node occupying ports for the next attempt.
# STARTUP_COMPLETE is only set once the node is genuinely up, so a normal successful exit
# leaves the long-running processes alone.
STARTUP_COMPLETE=false
cleanup_on_exit() {
  if [ -n "${NET_UP_PID:-}" ]; then
    kill "${NET_UP_PID}" 2>/dev/null || true
    wait "${NET_UP_PID}" 2>/dev/null || true
  fi
  if [ "${STARTUP_COMPLETE}" != "true" ]; then
    echo "==> Startup did not complete -- cleaning up anything already started" >&2
    while read -r pid; do
      [ -n "${pid}" ] && kill -9 "${pid}" 2>/dev/null || true
    done < "${STATE_DIR}/pids" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

echo "==> Generating a template validator config via a throwaway localhost-only net"
echo "    (only used to steal the exact server_config.json/committee.json shape;"
echo "     it never gets exposed and is torn down immediately after)."
TEMPLATE_DIR="${STATE_DIR}/template"
mkdir -p "${TEMPLATE_DIR}"

source /dev/stdin <<<"$(linera net helper 2>/dev/null)"
RUST_LOG=error linera_spawn \
  linera net up --path "${TEMPLATE_DIR}" --validators 1 --shards "${NUM_SHARDS}" --testing-prng-seed 1 \
  > "${STATE_DIR}/template-net-up.log" 2>&1 &
NET_UP_PID=$!

for _ in $(seq 1 30); do
  [ -f "${TEMPLATE_DIR}/server_0.json" ] && break
  sleep 1
done
[ -f "${TEMPLATE_DIR}/server_0.json" ] || { echo "template server config never appeared, see ${STATE_DIR}/template-net-up.log" >&2; exit 1; }

kill "${NET_UP_PID}" 2>/dev/null || true
wait "${NET_UP_PID}" 2>/dev/null || true
NET_UP_PID=""

echo "==> Patching template config: host -> ${NODE_HOST}, public proxy port -> ${PROXY_PUBLIC_PORT}, base_shards -> ${BASE_SHARDS}"
jq --arg host "${NODE_HOST}" --argjson port "${PROXY_PUBLIC_PORT}" --argjson base_shards "${BASE_SHARDS}" '
    .validator.network.host = $host
  | .validator.network.port = $port
  | .internal_network.shards |= map(.host = $host)
  | .internal_network.proxies |= map(.host = $host | .public_port = $port)
  | .internal_network.base_shards = $base_shards
' "${TEMPLATE_DIR}/server_0.json" > "${STATE_DIR}/server_config.json"

jq '{validators: [.validator]}' "${STATE_DIR}/server_config.json" > "${STATE_DIR}/committee.json"

echo "==> Network layout:"
echo "  proxy public_port:    ${PROXY_PUBLIC_PORT}  <- open this directly, this is the only port clients dial"
jq -r '.internal_network.shards[] | "  shard port (local):  " + (.port|tostring)' "${STATE_DIR}/server_config.json"
jq -r '.internal_network.proxies[] | "  proxy private_port (local): " + (.private_port|tostring) + ", metrics_port: " + (.metrics_port|tostring)' "${STATE_DIR}/server_config.json"
echo "  storage-service port (local): ${STORAGE_PORT}"
echo "  faucet port (local, reach via SSH tunnel only): ${FAUCET_PORT}"
echo "     -> see scripts/open_faucet_tunnel.sh on the client"

echo "==> Reclaiming any of our target ports left over from the throwaway template net"
ensure_port_free "${STORAGE_PORT}"
ensure_port_free "${PROXY_PUBLIC_PORT}"
while read -r port; do
  ensure_port_free "${port}"
done < <(jq -r '.internal_network.shards[].port, .internal_network.shards[].metrics_port, .internal_network.proxies[].private_port, .internal_network.proxies[].metrics_port' "${STATE_DIR}/server_config.json")

# Somehow this doesn't work reliably and some ports are still in use sometimes, so wait a bit.
sleep 3

STORAGE_ENDPOINT="service:tcp:${NODE_HOST}:${STORAGE_PORT}:table_default"

storage_strace=()
if [ "${STRACE_STORAGE_SERVER}" = "true" ]; then
  command -v strace >/dev/null || { echo "strace is required when STRACE_STORAGE_SERVER=true" >&2; exit 1; }
  storage_strace=(strace -f -c -o "${STATE_DIR}/storage-server.strace")
  echo "==> STRACE_STORAGE_SERVER=true: syscall-time summary will be written to ${STATE_DIR}/storage-server.strace on exit"
fi
storage_tokio_threads_args=()
if [ "${STORAGE_TOKIO_THREADS}" -gt 0 ]; then
  storage_tokio_threads_args=(--tokio-threads "${STORAGE_TOKIO_THREADS}")
fi
if [ "${#storage_taskset[@]}" -gt 0 ]; then
  echo "==> Starting storage-server (memory backend) on ${NODE_HOST}:${STORAGE_PORT}, pinned to cores ${storage_taskset[2]}"
else
  echo "==> Starting storage-server (memory backend) on ${NODE_HOST}:${STORAGE_PORT}"
fi
if [ "${STORAGE_TOKIO_THREADS}" -gt 0 ]; then
  echo "  tokio-threads: ${STORAGE_TOKIO_THREADS}"
fi
nohup "${storage_taskset[@]}" "${storage_strace[@]}" linera-storage-server "${storage_tokio_threads_args[@]}" memory --endpoint "${NODE_HOST}:${STORAGE_PORT}" \
  > "${STATE_DIR}/storage-server.log" 2>&1 &
storage_pid=$!
echo "${storage_pid}" >> pids
sleep 2
require_alive "${storage_pid}" "storage-server" "${STATE_DIR}/storage-server.log"

echo "==> Creating genesis config + admin wallet"
# One non-admin root chain, not zero: the faucet (linera-client's first_non_admin_chain())
# panics if the wallet has no non-admin chain to give away tokens from.
linera --wallet "${STATE_DIR}/admin_wallet.json" \
       --keystore "${STATE_DIR}/admin_keystore.json" \
       --storage "${STORAGE_ENDPOINT}" \
  create-genesis-config \
  --committee "${STATE_DIR}/committee.json" \
  --genesis "${STATE_DIR}/genesis.json" \
  --initial-funding "${INITIAL_AMOUNT}" \
  1

echo "==> Initializing shared storage from genesis"
linera storage initialize \
  --storage "${STORAGE_ENDPOINT}" \
  --genesis "${STATE_DIR}/genesis.json"

if [ "${BASE_SHARDS}" -lt "${NUM_SHARDS}" ]; then
  echo "==> Starting ${BASE_SHARDS} base shard(s) (${NUM_SHARDS} total slots configured, $((NUM_SHARDS - BASE_SHARDS)) elastic)"
else
  echo "==> Starting ${BASE_SHARDS} shard(s)"
fi
shard_pids=()
for i in $(seq 0 $((BASE_SHARDS - 1))); do
  shard_taskset=()
  tokio_threads_args=()
  if [ "${CORES_PER_SHARD}" -gt 0 ]; then
    shard_start=$((shard_core_offset + i * CORES_PER_SHARD))
    shard_end=$((shard_start + CORES_PER_SHARD - 1))
    shard_taskset=(taskset -c "${shard_start}-${shard_end}")
    if [ "${SHARD_TOKIO_THREADS}" -gt 0 ]; then
      tokio_threads_args=(--tokio-threads "${SHARD_TOKIO_THREADS}")
    else
      tokio_threads_args=(--tokio-threads "${CORES_PER_SHARD}")
    fi
    echo "  shard ${i}: pinned to cores ${shard_start}-${shard_end}, tokio-threads=${tokio_threads_args[1]}"
  fi
  nohup "${shard_taskset[@]}" linera-server "${tokio_threads_args[@]}" run \
    --server "${STATE_DIR}/server_config.json" \
    --storage "${STORAGE_ENDPOINT}" \
    --shard "${i}" \
    > "${STATE_DIR}/shard_${i}.log" 2>&1 &
  shard_pids[i]=$!
  echo "${shard_pids[i]}" >> pids
done
sleep 2
for i in $(seq 0 $((BASE_SHARDS - 1))); do
  require_alive "${shard_pids[i]}" "shard ${i}" "${STATE_DIR}/shard_${i}.log"
done

if [ "${#proxy_taskset[@]}" -gt 0 ]; then
  echo "==> Starting proxy, pinned to cores 0-$((RESERVED_CORES - 1))"
else
  echo "==> Starting proxy"
fi
nohup "${proxy_taskset[@]}" linera-proxy "${STATE_DIR}/server_config.json" \
  --storage "${STORAGE_ENDPOINT}" \
  > "${STATE_DIR}/proxy.log" 2>&1 &
proxy_pid=$!
echo "${proxy_pid}" >> pids
sleep 2
require_alive "${proxy_pid}" "proxy" "${STATE_DIR}/proxy.log"

if [ "${START_MANAGER}" = "true" ]; then
  echo "==> Starting validator manager (base_shards=${BASE_SHARDS}, total_shards=${NUM_SHARDS})"
  linera_server_bin="$(command -v linera-server)"
  spawn_command="${linera_server_bin} run --server ${STATE_DIR}/server_config.json --storage ${STORAGE_ENDPOINT} --shard {shard}"
  manager_args=(--server "${STATE_DIR}/server_config.json")
  [ -n "${MANAGER_INTERVAL_MS}" ] && manager_args+=(--interval-ms "${MANAGER_INTERVAL_MS}")
  [ -n "${MANAGER_HIGH_WATERMARK}" ] && manager_args+=(--high-watermark "${MANAGER_HIGH_WATERMARK}")
  [ -n "${MANAGER_LOW_WATERMARK}" ] && manager_args+=(--low-watermark "${MANAGER_LOW_WATERMARK}")
  [ -n "${MANAGER_MAX_MIGRATIONS_PER_ROUND}" ] && manager_args+=(--max-migrations-per-round "${MANAGER_MAX_MIGRATIONS_PER_ROUND}")
  [ -n "${MANAGER_SCALE_DOWN_ROUNDS}" ] && manager_args+=(--scale-down-rounds "${MANAGER_SCALE_DOWN_ROUNDS}")
  [ -n "${MANAGER_COOLDOWN_ROUNDS}" ] && manager_args+=(--cooldown-rounds "${MANAGER_COOLDOWN_ROUNDS}")
  manager_args+=(--spawn-command "${spawn_command}")
  nohup linera-server manager "${manager_args[@]}" \
    > "${STATE_DIR}/manager.log" 2>&1 &
  manager_pid=$!
  echo "${manager_pid}" >> pids
  sleep 2
  require_alive "${manager_pid}" "manager" "${STATE_DIR}/manager.log"
else
  echo "==> Skipping validator manager (START_MANAGER=false)"
fi

if [ "${START_FAUCET}" = "true" ]; then
  echo "==> Starting faucet on port ${FAUCET_PORT}"
  nohup linera --wallet "${STATE_DIR}/admin_wallet.json" \
               --keystore "${STATE_DIR}/admin_keystore.json" \
    faucet --port "${FAUCET_PORT}" --amount "${FAUCET_AMOUNT}" \
    --storage-path "${STATE_DIR}/faucet.db" \
    > "${STATE_DIR}/faucet.log" 2>&1 &
  faucet_pid=$!
  echo "${faucet_pid}" >> pids
  sleep 2
  require_alive "${faucet_pid}" "faucet" "${STATE_DIR}/faucet.log"
else
  echo "==> Skipping faucet (START_FAUCET=false)"
fi

STARTUP_COMPLETE=true
echo "==> Node is up. State, logs and PIDs are in ${STATE_DIR}"
echo "==> Proxy is directly reachable at ${NODE_HOST}:${PROXY_PUBLIC_PORT} (make sure this is the open port)"
if [ "${START_FAUCET}" = "true" ]; then
  echo "==> Faucet is only bound locally on ${FAUCET_PORT}; on the client, run:"
  echo "      SSH_HOST=${NODE_HOST} REMOTE_FAUCET_PORT=${FAUCET_PORT} $(dirname "$0")/open_faucet_tunnel.sh"
fi
echo "    then use FAUCET_URL=http://127.0.0.1:<LOCAL_FAUCET_PORT> with run_client.sh"
echo "==> Stop everything with: STATE_DIR=${STATE_DIR} $(dirname "$0")/stop_node.sh"
