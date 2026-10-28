#!/usr/bin/env bash
set -euo pipefail

# The genuinely-distributed counterpart of run_validators.sh: brings up a committee of
# NUM_VALIDATORS validators with one validator per *physical machine* (VALIDATOR_HOSTS),
# instead of run_validators.sh's NUM_VALIDATORS>1 mode, which co-locates every validator as
# separate processes on a single host. Designed for a Grid5000 reservation made by
# grid5k_reserve.sh, but only assumes SSH reachability (via SSH_PROXY_JUMP) to each host --
# nothing here depends on Grid5000 specifically, so the same VALIDATOR_HOSTS could equally be
# any set of real machines reachable over plain SSH.
#
# Why not just reuse run_validators.sh remotely once per host? It conflates three things that
# must happen exactly once for the *whole* committee (generating the committee config, creating
# genesis, seeding it into every validator's storage) with the part that's genuinely per-host
# (starting that host's own storage-server/shards/proxy/manager). Calling it independently on
# each host would make each one invent its own, different, single-node genesis -- not a shared
# committee at all. This script does the once-for-the-committee steps itself (locally, plus one
# remote host acting as the point of contact for genesis creation) and delegates only the
# per-host steps to run_single_validator_grid5k.sh, deployed to every host.
#
# Binaries are cross-deployed as prebuilt artifacts (rsync from BIN_SRC_DIR), the same way
# find_max_tps.sh already deploys to sparta/yiannis-testbed -- no Rust toolchain is bootstrapped
# on the remote hosts. This assumes BIN_SRC_DIR's binaries run on the target hosts (same
# architecture/glibc generation); if that assumption breaks on some Grid5000 cluster, build
# there directly instead (rustup + cargo build with LINERA_SRC rsync'd or git-cloned onto that
# site's shared home) and point BIN_SRC_DIR at the result -- everything past that point in this
# script is unaffected either way.
#
# Ports: every validator here is alone on its own machine, so unlike run_validators.sh there is
# no need for a per-validator port offset -- every host uses the same plain
# PROXY_PUBLIC_PORT/SHARD_PORT_BASE/etc.
#
# Configuration (env vars):
#   VALIDATOR_HOSTS      (required) space-separated list of SSH-reachable hosts, one per
#                         validator, e.g. "grdix-1.nancy.grid5000.fr grdix-2.nancy.grid5000.fr"
#   SSH_PROXY_JUMP        (default empty = no -J) e.g. "grid5k" or "grid5k,nancy" -- see
#                         grid5k_reserve.sh, which probes and writes the working value
#   REMOTE_DIR            (default linera) path on every validator host
#   BIN_SRC_DIR           (required) local directory with linera, linera-server, linera-proxy,
#                         linera-storage-server already built (e.g. LINERA_SRC/target/release)
#   STATE_DIR             (default ./grid5k_state) local directory for committee.json,
#                         genesis.json, admin_wallet.json, admin_keystore.json, per-host logs
#   SKIP_BINARY_DEPLOY    (default false) reuse whatever's already deployed on every host
#   NUM_SHARDS, CORES_PER_SHARD, RESERVED_CORES, STORAGE_CORES, SHARD_TOKIO_THREADS,
#   STORAGE_TOKIO_THREADS, BASE_SHARDS, START_MANAGER, MANAGER_INTERVAL_MS,
#   MANAGER_HIGH_WATERMARK, MANAGER_LOW_WATERMARK, MANAGER_MAX_MIGRATIONS_PER_ROUND,
#   MANAGER_MAX_DRAINS_PER_ROUND, MANAGER_SCALE_DOWN_ROUNDS, MANAGER_COOLDOWN_ROUNDS
#                         applied identically to every validator -- see run_validators.sh
#   PROXY_PUBLIC_PORT, PROXY_PRIVATE_PORT, PROXY_METRICS_PORT, SHARD_PORT_BASE,
#   SHARD_METRICS_PORT_BASE, STORAGE_PORT
#                         (defaults match run_validators.sh's *_BASE defaults)
#   INITIAL_AMOUNT        (default 1000000000)
#   ACTION                (default start) start | stop
#
# On success (ACTION=start), writes to STATE_DIR: committee.json, genesis.json,
# admin_wallet.json, admin_keystore.json -- relay these to your CLIENT_HOST exactly as
# find_max_tps.sh already relays sparta's, then run provision_super_owner_chains.sh /
# run_lite_benchmark_parallel.sh unchanged.
#
# A quorum is not one validator: with equal voting weights the threshold is
# ceil((n + ceil(n/3)) / 2). Every validator's PROXY_PUBLIC_PORT must be reachable from
# CLIENT_HOST, not just the first -- clients broadcast to the whole committee and wait for
# quorum.

VALIDATOR_HOSTS_STR="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of hosts, one per validator}"
read -ra VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS_STR}"
NUM_VALIDATORS="${#VALIDATOR_HOSTS_ARR[@]}"
[ "${NUM_VALIDATORS}" -ge 1 ] || { echo "VALIDATOR_HOSTS must name at least one host" >&2; exit 1; }

SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
BIN_SRC_DIR="${BIN_SRC_DIR:-}"
STATE_DIR="${STATE_DIR:-./grid5k_state}"
SKIP_BINARY_DEPLOY="${SKIP_BINARY_DEPLOY:-false}"
NUM_SHARDS="${NUM_SHARDS:-1}"
CORES_PER_SHARD="${CORES_PER_SHARD:-0}"
RESERVED_CORES="${RESERVED_CORES:-0}"
STORAGE_CORES="${STORAGE_CORES:-0}"
PIN_RESERVED_STORAGE="${PIN_RESERVED_STORAGE:-false}"
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
INITIAL_AMOUNT="${INITIAL_AMOUNT:-1000000000}"
ACTION="${ACTION:-start}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
case "${STATE_DIR}" in
  /*) ;;
  *) STATE_DIR="$(pwd)/${STATE_DIR}" ;;
esac
mkdir -p "${STATE_DIR}"

# Compute nodes (unlike the site frontend hop) don't accept the local username -- see
# grid5k_reserve.sh, which determines SSH_USER via `whoami` on the frontend and writes it into
# the sourced env file. -o User=... rather than rewriting hostnames to user@host, since
# VALIDATOR_HOSTS entries double as NODE_HOST (a real network address baked into genesis/config,
# not an SSH target) and must stay plain hostnames.
#
# ControlMaster/ControlPersist: a committee bring-up makes dozens of separate ssh/scp/rsync
# calls to the same handful of hosts. Without multiplexing, every single one re-opens a fresh
# TCP connection through the single external bastion (-J) -- which is what tripped the
# bastion's own connection-rate limiting ("kex_exchange_identification: Connection reset by
# peer" on *every* host, including the bastion itself) partway through this script's first real
# runs. Reusing one authenticated connection per host, kept alive for 15m of idle time, cuts
# that to one bastion connection per host for the whole sweep.
ssh_cm_opts=(-o ControlMaster=auto -o "ControlPath=/tmp/g5k-ssh-cm-%r@%h:%p" -o ControlPersist=15m)
ssh_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then
    ssh -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} -J "${SSH_PROXY_JUMP}" "$@"
  else
    ssh "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  fi
}
scp_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then
    scp -o StrictHostKeyChecking=accept-new "${ssh_cm_opts[@]}" -o "ProxyJump=${SSH_PROXY_JUMP}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  else
    scp "${ssh_cm_opts[@]}" ${SSH_USER:+-o "User=${SSH_USER}"} "$@"
  fi
}
rsync_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then
    rsync -az -e "ssh -o StrictHostKeyChecking=accept-new ${ssh_cm_opts[*]} -J ${SSH_PROXY_JUMP} ${SSH_USER:+-o User=${SSH_USER}}" "$@"
  else
    rsync -az -e "ssh ${ssh_cm_opts[*]} ${SSH_USER:+-o User=${SSH_USER}}" "$@"
  fi
}

# Per-validator state (its own signing key, pids, logs) must never collide between hosts --
# but REMOTE_DIR is a path under $HOME, and Grid5000 (confirmed the hard way) shares $HOME via
# NFS across every node at a site. Two validator hosts both writing/reading
# "${REMOTE_DIR}/state/server_0.json" were, on Grid5000, the exact same underlying file:
# whichever host's config got distributed last silently became BOTH validators' identity, so
# every response one of them signed used the wrong key relative to what committee.json told
# clients to expect for its address -- surfacing as a deterministic, genuine-looking signature
# verification failure with no protocol bug involved at all. Namespacing state by (a sanitized
# form of) the hostname fixes this under a shared filesystem and is a no-op on a topology where
# every host already has its own separate disk (e.g. sparta/yiannis-testbed).
state_dir_for() { echo "${REMOTE_DIR}/state-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

# Every per-host loop below runs each host's work in its own backgrounded subshell and waits
# for all of them, instead of one host at a time -- confirmed the hard way (2026-10-24, 30v
# weekend run): even with ControlMaster reuse, a purely sequential 30-host loop with several
# ssh/scp/rsync calls per host took >20min to get through just ONE of the ~7 per-host loops in
# this script, which would have made a single committee bring-up take hours -- and this script
# runs up to ~18 times across one sweep (once per calibration combo + once per ramp, per traffic
# mode). Each host's own steps stay in their original order (same subshell); only different
# hosts' work is now concurrent, since each host's state/process is independent of the others.
PAR_DIR="$(mktemp -d)"
trap 'rm -rf "${PAR_DIR}"' EXIT

# Calls FN_NAME once per host in VALIDATOR_HOSTS_ARR (as `FN_NAME "$host"`), all in parallel,
# then waits for all of them. FN_NAME's stdout/stderr land in ${PAR_DIR}/<host>.out; on failure
# that file is printed. Exits the script if any host's call failed.
run_per_validator_parallel() {
  local fn_name="$1" host
  declare -A pids
  for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
    ( "${fn_name}" "${host}" > "${PAR_DIR}/${host//\//_}.out" 2>&1 ) &
    pids[$host]=$!
  done
  local failed=0
  for host in "${!pids[@]}"; do
    if ! wait "${pids[$host]}"; then
      echo "  FAILED: ${host}" >&2
      cat "${PAR_DIR}/${host//\//_}.out" >&2
      failed=1
    fi
  done
  [ "${failed}" -eq 0 ] || exit 1
}

stop_one_host() { local host="$1"; ssh_j "${host}" "STATE_DIR=$(state_dir_for "${host}") ${REMOTE_DIR}/scripts/stop_node.sh"; }

if [ "${ACTION}" = "stop" ]; then
  echo "==> Stopping committee on ${NUM_VALIDATORS} host(s) (parallel)"
  run_per_validator_parallel stop_one_host
  echo "==> Done"
  exit 0
fi

if [ "${ACTION}" != "start" ]; then
  echo "Unknown ACTION: ${ACTION} (expected start or stop)" >&2
  exit 1
fi

[ -n "${BIN_SRC_DIR}" ] || { echo "set BIN_SRC_DIR to a local directory with the built binaries" >&2; exit 1; }
for b in linera linera-server linera-proxy linera-storage-server; do
  [ -x "${BIN_SRC_DIR}/${b}" ] || { echo "${BIN_SRC_DIR}/${b} not found or not executable" >&2; exit 1; }
done
command -v jq >/dev/null || { echo "jq is required locally" >&2; exit 1; }

echo "==> Committee: ${NUM_VALIDATORS} validator(s), one per host: ${VALIDATOR_HOSTS_ARR[*]}"
host0="${VALIDATOR_HOSTS_ARR[0]}"

# linera-storage-server's --endpoint parses a literal SocketAddr (confirmed the hard way:
# AddrParseError(Socket) when given a DNS hostname -- it does not resolve). NODE_HOST needs to
# be an IP for every component, not just storage-server, so resolve once here and use the IP
# everywhere a network address is needed (TOML host fields, NODE_HOST, storage_endpoint) while
# still using the hostname for every ssh/scp/rsync target (SSH resolves Grid5000 hostnames fine
# through the jump chain; only the validators' own gRPC/TCP layer cannot).
declare -A HOST_IP
resolve_ip_one_host() { local host="$1"; ssh_j "${host}" "hostname -I" | awk '{print $1}'; }
run_per_validator_parallel resolve_ip_one_host
for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
  ip="$(cat "${PAR_DIR}/${host//\//_}.out")"
  [ -n "${ip}" ] || { echo "Could not resolve an IP for ${host}" >&2; exit 1; }
  HOST_IP["${host}"]="${ip}"
  echo "  ${host} -> ${ip}"
done

echo "==> [1/6] Deploying to ${NUM_VALIDATORS} host(s) (parallel)"
deploy_one_host() {
  local host="$1"
  ssh_j "${host}" "mkdir -p ${REMOTE_DIR}/bin ${REMOTE_DIR}/scripts $(state_dir_for "${host}")"
  if [ "${SKIP_BINARY_DEPLOY}" != "true" ]; then
    rsync_j "${BIN_SRC_DIR}/linera" "${BIN_SRC_DIR}/linera-server" "${BIN_SRC_DIR}/linera-proxy" \
      "${BIN_SRC_DIR}/linera-storage-server" "${host}:${REMOTE_DIR}/bin/"
  fi
  scp_j "${LOCAL_DIR}/scripts/run_single_validator_grid5k.sh" "${LOCAL_DIR}/scripts/stop_node.sh" \
    "${host}:${REMOTE_DIR}/scripts/"
  ssh_j "${host}" "chmod +x ${REMOTE_DIR}/bin/* ${REMOTE_DIR}/scripts/*.sh"
  ssh_j "${host}" "STATE_DIR=$(state_dir_for "${host}") ${REMOTE_DIR}/scripts/stop_node.sh" 2>/dev/null || true
  # Wipe state fresh every start, mirroring run_validators.sh's own `rm -rf STATE_DIR`. Without
  # this, a second bring-up on the same reservation reuses the previous run's admin_wallet.json
  # / admin_keystore.json / genesis.json -- create-genesis-config refuses to overwrite an
  # existing keystore ("Keystore already exists"), so every combo after the first one in a
  # sweep would fail here.
  ssh_j "${host}" "rm -rf $(state_dir_for "${host}") && mkdir -p $(state_dir_for "${host}")"
}
export -f deploy_one_host ssh_j scp_j rsync_j state_dir_for
run_per_validator_parallel deploy_one_host
for host in "${VALIDATOR_HOSTS_ARR[@]}"; do echo "  ${host} ready"; done

echo "==> [2/6] Generating committee config locally (${NUM_VALIDATORS} validator(s))"
rm -f "${STATE_DIR}"/validator_*.toml "${STATE_DIR}"/server_*.json "${STATE_DIR}/committee.json"
validator_tomls=()
for v in "${!VALIDATOR_HOSTS_ARR[@]}"; do
  host="${VALIDATOR_HOSTS_ARR[$v]}"
  ip="${HOST_IP[$host]}"
  toml="${STATE_DIR}/validator_${v}.toml"
  {
    echo "server_config_path = \"${STATE_DIR}/server_${v}.json\""
    echo "host = \"${ip}\""
    echo "port = ${PROXY_PUBLIC_PORT}"
    echo 'external_protocol = { Grpc = "ClearText" }'
    echo 'internal_protocol = { Grpc = "ClearText" }'
    echo "num_base_shards = ${BASE_SHARDS}"
    echo
    echo "[[proxies]]"
    echo "host = \"${ip}\""
    echo "public_port = ${PROXY_PUBLIC_PORT}"
    echo "private_port = ${PROXY_PRIVATE_PORT}"
    echo "metrics_port = ${PROXY_METRICS_PORT}"
    for s in $(seq 0 $((NUM_SHARDS - 1))); do
      echo
      echo "[[shards]]"
      echo "host = \"${ip}\""
      echo "port = $((SHARD_PORT_BASE + s))"
      echo "metrics_port = $((SHARD_METRICS_PORT_BASE + s))"
    done
  } > "${toml}"
  validator_tomls+=("${toml}")
done
"${BIN_SRC_DIR}/linera-server" generate --validators "${validator_tomls[@]}" \
  --committee "${STATE_DIR}/committee.json" > "${STATE_DIR}/generate.log" 2>&1
for v in "${!VALIDATOR_HOSTS_ARR[@]}"; do
  [ -f "${STATE_DIR}/server_${v}.json" ] || {
    echo "linera-server generate did not produce server_${v}.json -- see ${STATE_DIR}/generate.log" >&2
    exit 1
  }
done
echo "  committee: $(jq '.validators | length' "${STATE_DIR}/committee.json") validator(s)"

echo "==> [3/6] Distributing per-validator config (parallel)"
declare -A VALIDATOR_IDX
for v in "${!VALIDATOR_HOSTS_ARR[@]}"; do VALIDATOR_IDX["${VALIDATOR_HOSTS_ARR[$v]}"]="${v}"; done
distribute_config_one_host() {
  local host="$1" v="${VALIDATOR_IDX[$1]}"
  scp_j "${STATE_DIR}/server_${v}.json" "${host}:$(state_dir_for "${host}")/server_0.json"
}
export -f distribute_config_one_host
run_per_validator_parallel distribute_config_one_host
scp_j "${STATE_DIR}/committee.json" "${host0}:$(state_dir_for "${host0}")/committee.json"

echo "==> [4/6] Starting ${NUM_VALIDATORS} storage-server(s) (one per host, memory backend, parallel)"
start_storage_one_host() {
  local host="$1"
  ssh_j "${host}" \
    "STATE_DIR=$(state_dir_for "${host}") NODE_HOST=${HOST_IP[$host]} STORAGE_PORT=${STORAGE_PORT} \
     STORAGE_TOKIO_THREADS=${STORAGE_TOKIO_THREADS} \
     RESERVED_CORES=${RESERVED_CORES} STORAGE_CORES=${STORAGE_CORES} CORES_PER_SHARD=${CORES_PER_SHARD} \
     PIN_RESERVED_STORAGE=${PIN_RESERVED_STORAGE} \
     NUM_SHARDS=${NUM_SHARDS} MODE=storage ${REMOTE_DIR}/scripts/run_single_validator_grid5k.sh"
}
export -f start_storage_one_host
run_per_validator_parallel start_storage_one_host

echo "==> [5/6] Creating genesis config + admin wallet on ${host0}, initializing every validator's storage"
storage_endpoint() { echo "service:tcp:$1:${STORAGE_PORT}:table_default"; }
export -f storage_endpoint
host0_state="$(state_dir_for "${host0}")"
ssh_j "${host0}" \
  "${REMOTE_DIR}/bin/linera --wallet ${host0_state}/admin_wallet.json --keystore ${host0_state}/admin_keystore.json \
   --storage $(storage_endpoint "${HOST_IP[$host0]}") \
   create-genesis-config --committee ${host0_state}/committee.json --genesis ${host0_state}/genesis.json \
   --initial-funding ${INITIAL_AMOUNT} 1"
# All of these target host0 (the only place genesis.json lives) but each initializes a
# DIFFERENT remote validator's storage endpoint -- independent operations, safe to run
# concurrently over host0's multiplexed SSH connection (parallel is the whole point here: this
# loop is NUM_VALIDATORS calls, all funneled through one host, which is exactly where the old
# sequential version bottlenecked worst).
init_storage_one_host() {
  local host="$1"
  ssh_j "${host0}" \
    "${REMOTE_DIR}/bin/linera storage initialize --storage $(storage_endpoint "${HOST_IP[$host]}") --genesis ${host0_state}/genesis.json"
}
export -f init_storage_one_host
run_per_validator_parallel init_storage_one_host
scp_j "${host0}:${host0_state}/genesis.json" "${host0}:${host0_state}/admin_wallet.json" \
  "${host0}:${host0_state}/admin_keystore.json" "${STATE_DIR}/"
echo "  genesis + admin wallet relayed to ${STATE_DIR}/"

echo "==> [6/6] Starting shard(s) + proxy (+ manager) on every host (parallel)"
start_workers_one_host() {
  local host="$1"
  ssh_j "${host}" \
    "STATE_DIR=$(state_dir_for "${host}") NODE_HOST=${HOST_IP[$host]} \
     NUM_SHARDS=${NUM_SHARDS} BASE_SHARDS=${BASE_SHARDS} \
     CORES_PER_SHARD=${CORES_PER_SHARD} RESERVED_CORES=${RESERVED_CORES} STORAGE_CORES=${STORAGE_CORES} \
     PIN_RESERVED_STORAGE=${PIN_RESERVED_STORAGE} \
     SHARD_TOKIO_THREADS=${SHARD_TOKIO_THREADS} \
     PROXY_PUBLIC_PORT=${PROXY_PUBLIC_PORT} PROXY_PRIVATE_PORT=${PROXY_PRIVATE_PORT} \
     PROXY_METRICS_PORT=${PROXY_METRICS_PORT} SHARD_PORT_BASE=${SHARD_PORT_BASE} \
     SHARD_METRICS_PORT_BASE=${SHARD_METRICS_PORT_BASE} \
     START_MANAGER=${START_MANAGER} \
     MANAGER_INTERVAL_MS=${MANAGER_INTERVAL_MS} MANAGER_HIGH_WATERMARK=${MANAGER_HIGH_WATERMARK} \
     MANAGER_LOW_WATERMARK=${MANAGER_LOW_WATERMARK} \
     MANAGER_MAX_MIGRATIONS_PER_ROUND=${MANAGER_MAX_MIGRATIONS_PER_ROUND} \
     MANAGER_MAX_DRAINS_PER_ROUND=${MANAGER_MAX_DRAINS_PER_ROUND} \
     MANAGER_SCALE_DOWN_ROUNDS=${MANAGER_SCALE_DOWN_ROUNDS} MANAGER_COOLDOWN_ROUNDS=${MANAGER_COOLDOWN_ROUNDS} \
     MODE=workers ${REMOTE_DIR}/scripts/run_single_validator_grid5k.sh"
}
export -f start_workers_one_host
run_per_validator_parallel start_workers_one_host

quorum=$(( (NUM_VALIDATORS + (NUM_VALIDATORS + 2) / 3 + 1) / 2 ))
echo "==> Committee of ${NUM_VALIDATORS} is up (quorum: ${quorum} of ${NUM_VALIDATORS})"
echo "==> Client-reachable proxy endpoints:"
for host in "${VALIDATOR_HOSTS_ARR[@]}"; do
  echo "    ${HOST_IP[$host]}:${PROXY_PUBLIC_PORT} (${host})"
done
echo "==> Genesis/wallet in ${STATE_DIR}/ -- relay to your client host, then run"
echo "    provision_super_owner_chains.sh / run_lite_benchmark_parallel.sh unchanged"
echo "==> Stop everything with: ACTION=stop VALIDATOR_HOSTS=\"${VALIDATOR_HOSTS_STR}\" SSH_PROXY_JUMP=${SSH_PROXY_JUMP} REMOTE_DIR=${REMOTE_DIR} $(dirname "$0")/run_committee_grid5k.sh"
