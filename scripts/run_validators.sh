#!/usr/bin/env bash
set -euo pipefail

# Runs NUM_VALIDATORS real, remotely-reachable Linera validators as plain OS processes on this
# machine. Each validator gets its own storage-server, its own NUM_SHARDS shard processes, and
# its own proxy; they share nothing but the machine and the genesis config that names them all.
#
# Replaces the old run_node.sh, which could only ever start a single validator: it produced its
# config by spinning up a throwaway `linera net up`, stealing its server_0.json, killing it, and
# then reclaiming the ports that net leaked (hence its `sleep 3` and its "somehow this doesn't
# work reliably" comment).
#
# This calls `linera-server generate --validators <toml>... --committee committee.json` directly
# -- the same primitive `net up` uses internally -- which emits every server_<v>.json *and* the
# single committee.json naming all of them, in one shot. No throwaway net, no port leak, and n
# validators fall out for free.
#
# The committee ends up baked into genesis.json and the admin wallet by create-genesis-config,
# so clients need no configuration at all beyond the wallet/genesis they already copy: they
# learn the whole validator set from it. Two things this does imply, though:
#
#   * Every validator's proxy port must be reachable from the client, not just the first.
#     Clients broadcast proposals to all validators and wait for a quorum, so a firewall that
#     only opens PROXY_PUBLIC_PORT_BASE will leave n>1 unable to reach quorum.
#   * A quorum is not one validator. With equal voting weights the threshold is
#     ceil((n + ceil(n/3)) / 2): n=1 -> 1, n=2 -> 2 of 2, n=3 -> 2 of 3, n=4 -> 3 of 4. At
#     n=2 every request waits on both validators, so the slower one sets the latency.
#
# Requires `jq` and the binaries from extract_binaries.sh on PATH or in BIN_DIR.
#
# Configuration (env vars):
#   NODE_HOST         (required) this machine's IP/hostname, reachable from the client
#   NUM_VALIDATORS    (default 1) size of the committee
#   NUM_SHARDS        (default 1) shards *per validator*
#   CORES_PER_SHARD   (default 0 = no pinning) each shard is pinned via `taskset` to its own
#                      block of this many cores, with a matching --tokio-threads. Blocks are
#                      laid out per validator and never overlap: validator v's shards occupy
#                      [RESERVED_CORES + v*NUM_SHARDS*CORES_PER_SHARD, ... + NUM_SHARDS*CORES_PER_SHARD - 1].
#                      So each validator gets identical dedicated CPU regardless of how many
#                      validators are running -- the replication factor is then the only thing
#                      that varies across a validator-count sweep, and a slowdown cannot be
#                      blamed on validators having been squeezed onto fewer cores each.
#                      Errors out if the total exceeds `nproc`.
#   RESERVED_CORES    (default 0) proxies and storage-servers are ALWAYS left unpinned (free
#                      to float across every core, including idle shard cores) regardless of
#                      this value -- see the no-taskset-for-proxy/storage rationale where
#                      reserved_taskset/storage_taskset are computed, below. This only shifts
#                      where the shard blocks start (shard_core_offset = RESERVED_CORES +
#                      STORAGE_CORES), i.e. it holds that many cores out of the shard budget
#                      rather than confining proxies to them.
#   STORAGE_CORES     (default 0) same as RESERVED_CORES above -- storage-servers are always
#                      unpinned; this only adds to shard_core_offset.
#   SHARD_TOKIO_THREADS (default 0 = CORES_PER_SHARD)
#   STORAGE_TOKIO_THREADS (default 0 = storage-server's own default)
#   BASE_SHARDS       (default NUM_SHARDS) how many of each validator's NUM_SHARDS configured
#                      shard slots are started as processes and receive default (hash-based)
#                      chain assignments. Slots beyond this prefix are *elastic*: only the
#                      manager starts/stops them, as chains are explicitly migrated onto them,
#                      so they can come and go at runtime without orphaning a default-routed
#                      chain.
#   START_MANAGER     (default false) start one `linera-server manager` per validator: a
#                      long-running process that polls per-chain load from every shard and
#                      adapts -- spawning the next elastic slot's worker when an active shard
#                      is overloaded, rebalancing hot chains onto the least-loaded shard, and
#                      draining/stopping elastic workers idle for MANAGER_SCALE_DOWN_ROUNDS
#                      polls. Only meaningful when BASE_SHARDS < NUM_SHARDS.
#   MANAGER_INTERVAL_MS, MANAGER_HIGH_WATERMARK, MANAGER_LOW_WATERMARK,
#   MANAGER_MAX_MIGRATIONS_PER_ROUND, MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                      passed through to `linera-server manager`'s matching flags; unset ones
#                      are omitted so the binary's own defaults apply.
#   PROXY_PUBLIC_PORT_BASE   (default 4001)  validator v listens on BASE + v  <- open these
#   PROXY_PRIVATE_PORT_BASE  (default 10001) BASE + v
#   PROXY_METRICS_PORT_BASE  (default 12001) BASE + v
#   SHARD_PORT_BASE          (default 9001)  BASE + v*NUM_SHARDS + s
#   SHARD_METRICS_PORT_BASE  (default 11001) BASE + v*NUM_SHARDS + s
#   STORAGE_PORT_BASE        (default 19100) BASE + v
#                      (these mirror the layout `linera net up` uses internally, so a config
#                      produced here is directly comparable to one produced by net up)
#   INITIAL_AMOUNT    (default 1000000000) initial balance of the genesis admin chain
#   START_FAUCET      (default false) the lite-benchmark flow does not use a faucet at all;
#                      when true, one faucet is started against the admin wallet
#   FAUCET_PORT       (default 8080)
#   FAUCET_AMOUNT     (default 1000)
#   BIN_DIR           (default ../bin relative to this script)
#   STATE_DIR         (default /var/tmp/linera-node) wallets/configs/logs/PIDs
#
# All PIDs land in a single ${STATE_DIR}/pids, so scripts/stop_node.sh tears down the whole
# committee unchanged.

NODE_HOST="${NODE_HOST:?set NODE_HOST to the IP/hostname of this machine, reachable from the client}"
NUM_VALIDATORS="${NUM_VALIDATORS:-1}"
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
MANAGER_SCALE_DOWN_ROUNDS="${MANAGER_SCALE_DOWN_ROUNDS:-}"
MANAGER_COOLDOWN_ROUNDS="${MANAGER_COOLDOWN_ROUNDS:-}"
PROXY_PUBLIC_PORT_BASE="${PROXY_PUBLIC_PORT_BASE:-4001}"
PROXY_PRIVATE_PORT_BASE="${PROXY_PRIVATE_PORT_BASE:-10001}"
PROXY_METRICS_PORT_BASE="${PROXY_METRICS_PORT_BASE:-12001}"
SHARD_PORT_BASE="${SHARD_PORT_BASE:-9001}"
SHARD_METRICS_PORT_BASE="${SHARD_METRICS_PORT_BASE:-11001}"
STORAGE_PORT_BASE="${STORAGE_PORT_BASE:-19100}"
INITIAL_AMOUNT="${INITIAL_AMOUNT:-1000000000}"
START_FAUCET="${START_FAUCET:-false}"
FAUCET_PORT="${FAUCET_PORT:-8080}"
FAUCET_AMOUNT="${FAUCET_AMOUNT:-1000}"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd || echo "")}"
STATE_DIR="${STATE_DIR:-/var/tmp/linera-node}"
# Absolute up front: this script cd's into STATE_DIR, after which a relative path would get
# re-joined against the new cwd and silently duplicate itself.
case "${STATE_DIR}" in
  /*) ;;
  *) STATE_DIR="$(pwd)/${STATE_DIR}" ;;
esac

if [ -n "${BIN_DIR}" ]; then
  # Absolute, for the same reason STATE_DIR is: this script cd's into STATE_DIR below, and a
  # relative BIN_DIR on PATH would stop resolving the moment it does.
  case "${BIN_DIR}" in
    /*) ;;
    *) BIN_DIR="$(cd "${BIN_DIR}" && pwd)" ;;
  esac
  export PATH="${BIN_DIR}:${PATH}"
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
for b in linera linera-server linera-proxy linera-storage-server; do
  command -v "${b}" >/dev/null || { echo "${b} binary not found on PATH (set BIN_DIR)" >&2; exit 1; }
done
[ "${NUM_VALIDATORS}" -ge 1 ] || { echo "NUM_VALIDATORS must be >= 1" >&2; exit 1; }
[ "${BASE_SHARDS}" -le "${NUM_SHARDS}" ] || { echo "BASE_SHARDS (${BASE_SHARDS}) must be <= NUM_SHARDS (${NUM_SHARDS})" >&2; exit 1; }

# proxies and storage-servers are deliberately left unpinned (reserved_taskset/storage_taskset
# stay empty -- no `taskset -c` at all, regardless of RESERVED_CORES/STORAGE_CORES) so they
# inherit the full machine's default affinity and the kernel scheduler can spread/grow them onto
# however many cores they actually need, including idle shard-pinned cores, instead of being
# hard-walled into a small guessed slice. Found 2026-10-27/28 (see
# project_weekend_byzantine_experiments memory): a RESERVED_CORES=2 pin left those 2 cores
# pegged at 86-97% busy (mostly `user` time -- the proxy's own routing/signing work, not
# softirq) while every shard core sat at only 15-25% busy -- plenty of idle shard-core capacity
# sitting right there unused. RESERVED_CORES/STORAGE_CORES still matter here only as a budget
# subtracted from shard placement (shard_core_offset below), not as an affinity mask.
shard_core_offset=$((RESERVED_CORES + STORAGE_CORES))
reserved_taskset=()
storage_taskset=()
if [ "${CORES_PER_SHARD}" -gt 0 ]; then
  command -v taskset >/dev/null || { echo "taskset is required when CORES_PER_SHARD > 0" >&2; exit 1; }
  available_cores="$(nproc)"
  needed_cores=$((RESERVED_CORES + STORAGE_CORES + NUM_VALIDATORS * NUM_SHARDS * CORES_PER_SHARD))
  if [ "${needed_cores}" -gt "${available_cores}" ]; then
    echo "RESERVED_CORES (${RESERVED_CORES}) + STORAGE_CORES (${STORAGE_CORES}) + NUM_VALIDATORS*NUM_SHARDS*CORES_PER_SHARD (${NUM_VALIDATORS}*${NUM_SHARDS}*${CORES_PER_SHARD}=$((NUM_VALIDATORS * NUM_SHARDS * CORES_PER_SHARD))) = ${needed_cores} exceeds this machine's ${available_cores} cores" >&2
    exit 1
  fi
fi

rm -rf "${STATE_DIR}"
mkdir -p "${STATE_DIR}"
cd "${STATE_DIR}"
: > pids

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
    echo "  port ${port} still held by pid ${pid} (leftover from a previous run) -- killing it" >&2
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
  fi
}

STARTUP_COMPLETE=false
cleanup_on_exit() {
  if [ "${STARTUP_COMPLETE}" != "true" ]; then
    echo "==> Startup did not complete -- cleaning up anything already started" >&2
    while read -r pid; do
      [ -n "${pid}" ] && kill -9 "${pid}" 2>/dev/null || true
    done < "${STATE_DIR}/pids" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

proxy_public_port() { echo $((PROXY_PUBLIC_PORT_BASE + $1)); }
storage_port()      { echo $((STORAGE_PORT_BASE + $1)); }
storage_endpoint()  { echo "service:tcp:${NODE_HOST}:$(storage_port "$1"):table_default"; }

echo "==> Generating config for ${NUM_VALIDATORS} validator(s) x ${NUM_SHARDS} shard(s)"
validator_tomls=()
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  toml="${STATE_DIR}/validator_${v}.toml"
  {
    echo "server_config_path = \"server_${v}.json\""
    echo "host = \"${NODE_HOST}\""
    echo "port = $(proxy_public_port "${v}")"
    echo 'external_protocol = { Grpc = "ClearText" }'
    echo 'internal_protocol = { Grpc = "ClearText" }'
    echo "num_base_shards = ${BASE_SHARDS}"
    echo
    echo "[[proxies]]"
    echo "host = \"${NODE_HOST}\""
    echo "public_port = $(proxy_public_port "${v}")"
    echo "private_port = $((PROXY_PRIVATE_PORT_BASE + v))"
    echo "metrics_port = $((PROXY_METRICS_PORT_BASE + v))"
    for s in $(seq 0 $((NUM_SHARDS - 1))); do
      echo
      echo "[[shards]]"
      echo "host = \"${NODE_HOST}\""
      echo "port = $((SHARD_PORT_BASE + v * NUM_SHARDS + s))"
      echo "metrics_port = $((SHARD_METRICS_PORT_BASE + v * NUM_SHARDS + s))"
    done
  } > "${toml}"
  validator_tomls+=("${toml}")
done

# One call, one committee: every server_<v>.json plus the committee.json naming all of them.
linera-server generate --validators "${validator_tomls[@]}" --committee "${STATE_DIR}/committee.json" \
  > "${STATE_DIR}/generate.log" 2>&1
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  [ -f "${STATE_DIR}/server_${v}.json" ] || {
    echo "linera-server generate did not produce server_${v}.json -- see ${STATE_DIR}/generate.log" >&2
    exit 1
  }
done
echo "  committee: $(jq '.validators | length' "${STATE_DIR}/committee.json") validator(s)"

echo "==> Network layout:"
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  echo "  validator ${v}: proxy public_port $(proxy_public_port "${v}")  <- must be reachable from the client"
  echo "               storage port $(storage_port "${v}") (local), shard ports $((SHARD_PORT_BASE + v * NUM_SHARDS))-$((SHARD_PORT_BASE + v * NUM_SHARDS + NUM_SHARDS - 1)) (local)"
done

echo "==> Reclaiming any target ports left over from a previous run"
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  ensure_port_free "$(proxy_public_port "${v}")"
  ensure_port_free "$(storage_port "${v}")"
  while read -r port; do
    ensure_port_free "${port}"
  done < <(jq -r '.internal_network.shards[].port, .internal_network.shards[].metrics_port, .internal_network.proxies[].private_port, .internal_network.proxies[].metrics_port' "${STATE_DIR}/server_${v}.json")
done

storage_tokio_threads_args=()
if [ "${STORAGE_TOKIO_THREADS}" -gt 0 ]; then
  storage_tokio_threads_args=(--tokio-threads "${STORAGE_TOKIO_THREADS}")
fi

# One storage-server per validator. Validators are independent replicas -- sharing a storage
# backend between them would let each read the others' state, so the committee would not be
# measuring replication at all.
echo "==> Starting ${NUM_VALIDATORS} storage-server(s) (memory backend)"
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  nohup "${storage_taskset[@]}" linera-storage-server "${storage_tokio_threads_args[@]}" \
    memory --endpoint "${NODE_HOST}:$(storage_port "${v}")" \
    > "${STATE_DIR}/storage-server_${v}.log" 2>&1 &
  pid=$!
  echo "${pid}" >> pids
  sleep 1
  require_alive "${pid}" "storage-server ${v}" "${STATE_DIR}/storage-server_${v}.log"
done

# The genesis config names the whole committee, so it is created once and every validator's
# storage is then seeded from that same genesis.
echo "==> Creating genesis config + admin wallet (committee of ${NUM_VALIDATORS})"
linera --wallet "${STATE_DIR}/admin_wallet.json" \
       --keystore "${STATE_DIR}/admin_keystore.json" \
       --storage "$(storage_endpoint 0)" \
  create-genesis-config \
  --committee "${STATE_DIR}/committee.json" \
  --genesis "${STATE_DIR}/genesis.json" \
  --initial-funding "${INITIAL_AMOUNT}" \
  1

echo "==> Initializing each validator's storage from the shared genesis"
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  linera storage initialize \
    --storage "$(storage_endpoint "${v}")" \
    --genesis "${STATE_DIR}/genesis.json"
done

echo "==> Starting ${BASE_SHARDS} shard(s) per validator"
declare -A SHARD_PID
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  for s in $(seq 0 $((BASE_SHARDS - 1))); do
    shard_taskset=()
    tokio_threads_args=()
    if [ "${CORES_PER_SHARD}" -gt 0 ]; then
      shard_start=$((shard_core_offset + (v * NUM_SHARDS + s) * CORES_PER_SHARD))
      shard_end=$((shard_start + CORES_PER_SHARD - 1))
      shard_taskset=(taskset -c "${shard_start}-${shard_end}")
      if [ "${SHARD_TOKIO_THREADS}" -gt 0 ]; then
        tokio_threads_args=(--tokio-threads "${SHARD_TOKIO_THREADS}")
      else
        tokio_threads_args=(--tokio-threads "${CORES_PER_SHARD}")
      fi
      echo "  validator ${v} shard ${s}: cores ${shard_start}-${shard_end}, tokio-threads=${tokio_threads_args[1]}"
    fi
    nohup "${shard_taskset[@]}" linera-server "${tokio_threads_args[@]}" run \
      --server "${STATE_DIR}/server_${v}.json" \
      --storage "$(storage_endpoint "${v}")" \
      --shard "${s}" \
      > "${STATE_DIR}/shard_${v}_${s}.log" 2>&1 &
    SHARD_PID[${v}_${s}]=$!
    echo "${SHARD_PID[${v}_${s}]}" >> pids
  done
done
sleep 2
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  for s in $(seq 0 $((BASE_SHARDS - 1))); do
    require_alive "${SHARD_PID[${v}_${s}]}" "validator ${v} shard ${s}" "${STATE_DIR}/shard_${v}_${s}.log"
  done
done

echo "==> Starting ${NUM_VALIDATORS} proxy/proxies"
declare -A PROXY_PID
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  nohup "${reserved_taskset[@]}" linera-proxy "${STATE_DIR}/server_${v}.json" \
    --storage "$(storage_endpoint "${v}")" \
    > "${STATE_DIR}/proxy_${v}.log" 2>&1 &
  PROXY_PID[${v}]=$!
  echo "${PROXY_PID[${v}]}" >> pids
done
sleep 2
for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
  require_alive "${PROXY_PID[${v}]}" "proxy ${v}" "${STATE_DIR}/proxy_${v}.log"
done

if [ "${START_MANAGER}" = "true" ]; then
  echo "==> Starting validator manager(s) (base_shards=${BASE_SHARDS}, total_shards=${NUM_SHARDS})"
  linera_server_bin="$(command -v linera-server)"
  for v in $(seq 0 $((NUM_VALIDATORS - 1))); do
    spawn_command="${linera_server_bin} run --server ${STATE_DIR}/server_${v}.json --storage $(storage_endpoint "${v}") --shard {shard}"
    manager_args=(--server "${STATE_DIR}/server_${v}.json")
    [ -n "${MANAGER_INTERVAL_MS}" ] && manager_args+=(--interval-ms "${MANAGER_INTERVAL_MS}")
    [ -n "${MANAGER_HIGH_WATERMARK}" ] && manager_args+=(--high-watermark "${MANAGER_HIGH_WATERMARK}")
    [ -n "${MANAGER_LOW_WATERMARK}" ] && manager_args+=(--low-watermark "${MANAGER_LOW_WATERMARK}")
    [ -n "${MANAGER_MAX_MIGRATIONS_PER_ROUND}" ] && manager_args+=(--max-migrations-per-round "${MANAGER_MAX_MIGRATIONS_PER_ROUND}")
    [ -n "${MANAGER_SCALE_DOWN_ROUNDS}" ] && manager_args+=(--scale-down-rounds "${MANAGER_SCALE_DOWN_ROUNDS}")
    [ -n "${MANAGER_COOLDOWN_ROUNDS}" ] && manager_args+=(--cooldown-rounds "${MANAGER_COOLDOWN_ROUNDS}")
    manager_args+=(--spawn-command "${spawn_command}")
    nohup linera-server manager "${manager_args[@]}" \
      > "${STATE_DIR}/manager_${v}.log" 2>&1 &
    manager_pid=$!
    echo "${manager_pid}" >> pids
    sleep 2
    require_alive "${manager_pid}" "manager ${v}" "${STATE_DIR}/manager_${v}.log"
  done
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
fi

STARTUP_COMPLETE=true
quorum=$(( (NUM_VALIDATORS + (NUM_VALIDATORS + 2) / 3 + 1) / 2 ))
echo "==> Committee of ${NUM_VALIDATORS} is up (quorum: ${quorum} of ${NUM_VALIDATORS}). State/logs/PIDs in ${STATE_DIR}"
echo "==> Client-reachable proxy ports: $(for v in $(seq 0 $((NUM_VALIDATORS - 1))); do printf "%s " "$(proxy_public_port "${v}")"; done)"
echo "==> Stop everything with: STATE_DIR=${STATE_DIR} $(dirname "$0")/stop_node.sh"
