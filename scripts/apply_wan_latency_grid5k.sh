#!/usr/bin/env bash
set -euo pipefail

# Injects a realistic, per-pair WAN latency mesh between every host (client<->validator AND
# validator<->validator) using `tc netem` (real kernel-level packet delay), instead of the
# client-side-only SIMULATED_LATENCY_MS flag (a single flat delay applied uniformly everywhere).
# Validator<->validator delay matters as much as client<->validator: committee members exchange
# votes/certificates over what should be the same simulated WAN. Each host is round-robin
# assigned to one of 6 AWS regions, using the exact same region-to-region RTT matrix Mysticeti's
# own orchestrator ships (measured 2026-09-18, see mysticeti/crates/simulator/examples/geography.yaml)
# -- so results are comparable apples-to-apples between the two systems' benchmarks. For a pair
# with target RTT R, each side gets R/2 ms of netem delay on its egress toward the other, so the
# two one-way delays sum to the real measured round-trip.
#
# Grid5000 nodes don't have passwordless `sudo`, but do have `sudo-g5k` (a Grid5000-specific
# root escalation that works passwordlessly on your own OAR-reserved nodes) -- confirmed this
# session. All tc commands run through that.
#
# Performance note (2026-10-24): the original version issued one SSH connection per (host,
# pair) tc command -- ~1,350 connections for a 30-validator/8-client mesh. Measured on
# paradoxe/Rennes: SSH+ProxyJump connection setup alone costs ~15-20s per call (confirmed via
# direct timing: a bare `ssh ... true` through `-J grid5k` took 16-21s; the actual tc/sudo-g5k
# commands are fast once connected). At that rate the mesh took >11h to apply -- longer than
# the entire reservation window. Fixed by (a) building ALL of a host's tc commands into one
# shell command string first (pure local bash, no network calls), then (b) opening exactly ONE
# SSH connection per host to run that whole batch, with (c) all hosts' connections launched in
# parallel (`&` + `wait`) since each host's own tc/qdisc tree is independent. This cuts total
# SSH connections from ~1,350 to exactly NUM_HOSTS, and wall-clock time to roughly one
# connection's worth of latency instead of 1,350 of them. The same fix applies to the
# IP/interface-resolution pass, which was also one sequential SSH call per host.
#
# Configuration (env vars):
#   VALIDATOR_HOSTS  (required) space-separated validator hostnames
#   CLIENT_HOSTS     (required) space-separated client hostnames
#   SSH_PROXY_JUMP   (default empty) e.g. "grid5k"
#   SSH_USER         (default empty)
#   ACTION           (default apply) apply | clear -- clear removes the root qdisc (and hence
#                    all injected delay) from every host's primary interface, restoring normal
#                    same-site LAN behavior
#
# Usage:
#   VALIDATOR_HOSTS="..." CLIENT_HOSTS="..." SSH_PROXY_JUMP=grid5k SSH_USER=mapigaglio \
#     ./apply_wan_latency_grid5k.sh
#   ACTION=clear VALIDATOR_HOSTS="..." CLIENT_HOSTS="..." SSH_PROXY_JUMP=grid5k SSH_USER=mapigaglio \
#     ./apply_wan_latency_grid5k.sh

VALIDATOR_HOSTS="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of validator hosts}"
CLIENT_HOSTS="${CLIENT_HOSTS:?set CLIENT_HOSTS to a space-separated list of client hosts}"
SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
ACTION="${ACTION:-apply}"
# netem's own packet-queue limit, applied per (client,validator)/(validator,validator) classid.
# Explicit because netem's kernel default is only 1000 packets -- found 2026-10-28 (see
# project_weekend_byzantine_experiments memory) that at high concurrent-client counts every
# client host's traffic toward a given validator funnels through ONE shared netem queue
# (filtered by destination IP only, not per-connection), so thousands of client processes all
# talking to the same 30 validators can overflow that 1000-packet limit, causing netem to DROP
# packets -- which triggers TCP retransmission timeouts whose exponential backoff (1s, 2s, 4s,
# 8s, 16s, 32s...) matches the previously-unexplained tail latency almost exactly (p95 15-90s),
# while leaving validator CPU looking idle (the bottleneck is packets stuck behind a drop-prone
# queue/TCP timers, not real processing). Confirmed via a live A/B: clearing tc entirely at
# 19384 clients raised reserved-core CPU from ~55% to ~88% (genuinely near-saturated) and cut
# p95 latency from 53.6s to 15.8s -- NETEM_QUEUE_LIMIT restores the simulated delay without
# that queue-overflow artifact.
NETEM_QUEUE_LIMIT="${NETEM_QUEUE_LIMIT:-100000}"

read -ra VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS}"
read -ra CLIENT_HOSTS_ARR <<< "${CLIENT_HOSTS}"

ssh_j() {
  if [ -n "${SSH_PROXY_JUMP}" ]; then ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 ${SSH_USER:+-o "User=${SSH_USER}"} -J "${SSH_PROXY_JUMP}" "$@"; else ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 ${SSH_USER:+-o "User=${SSH_USER}"} "$@"; fi
}

# Mysticeti's own AWS 6-region RTT matrix (crates/simulator/examples/geography.yaml,
# measured 2026-09-18). One direction per pair; the reverse direction is looked up by
# swapping the two region names in `rtt_ms`.
REGIONS=(us-east-1 us-east-2 eu-central-1 eu-west-2 eu-west-3 ap-northeast-1)
declare -A RTT_MS=(
  ["us-east-1,us-east-1"]=0.2 ["us-east-1,us-east-2"]=11.4 ["us-east-1,eu-central-1"]=90.6
  ["us-east-1,eu-west-2"]=75.3 ["us-east-1,eu-west-3"]=82.2 ["us-east-1,ap-northeast-1"]=146.4
  ["us-east-2,us-east-2"]=0.6 ["us-east-2,eu-central-1"]=95.6 ["us-east-2,eu-west-2"]=86.1
  ["us-east-2,eu-west-3"]=90.7 ["us-east-2,ap-northeast-1"]=134.8
  ["eu-central-1,eu-central-1"]=0.4 ["eu-central-1,eu-west-2"]=12.0 ["eu-central-1,eu-west-3"]=8.2
  ["eu-central-1,ap-northeast-1"]=238.3
  ["eu-west-2,eu-west-2"]=0.2 ["eu-west-2,eu-west-3"]=7.4 ["eu-west-2,ap-northeast-1"]=212.2
  ["eu-west-3,eu-west-3"]=0.1 ["eu-west-3,ap-northeast-1"]=219.2
  ["ap-northeast-1,ap-northeast-1"]=0.3
)

rtt_between() {
  local a b key rkey
  a="$1"
  b="$2"
  key="${a},${b}"
  rkey="${b},${a}"
  if [ -n "${RTT_MS[${key}]+x}" ]; then echo "${RTT_MS[${key}]}"; return; fi
  if [ -n "${RTT_MS[${rkey}]+x}" ]; then echo "${RTT_MS[${rkey}]}"; return; fi
  echo "error: no RTT entry for ${a} <-> ${b}" >&2; exit 1
}

ALL_HOSTS=("${VALIDATOR_HOSTS_ARR[@]}" "${CLIENT_HOSTS_ARR[@]}")
PAR_DIR="$(mktemp -d)"
trap 'rm -rf "${PAR_DIR}"' EXIT

# Runs one command per host, all in parallel (each host is an independent machine/qdisc tree),
# and waits for all of them. Command text comes from the HOST_CMD[$h] associative array (the
# caller fills it in before calling this). Retries any host that failed up to 2 more times
# (short backoff) before giving up -- opening ~38 simultaneous SSH connections through the same
# ProxyJump gateway occasionally hits a transient "Connection timed out during banner exchange"
# on a couple of hosts (confirmed: different host each run, never the same one twice, and a bare
# retry always succeeds), not a real per-host config problem. Exits non-zero, printing which
# hosts still failed after retries, only if that actually happens.
run_per_host_parallel() {
  local -n cmds="$1"
  local h pid attempt
  declare -A pending
  for h in "${ALL_HOSTS[@]}"; do
    [ -n "${cmds[$h]+x}" ] && pending[$h]=1
  done
  for attempt in 1 2 3; do
    [ "${#pending[@]}" -eq 0 ] && break
    [ "${attempt}" -gt 1 ] && { echo "  retrying ${#pending[@]} host(s) (attempt ${attempt}): ${!pending[*]}" >&2; sleep 3; }
    declare -A pids
    for h in "${!pending[@]}"; do
      ( ssh_j "${h}" "${cmds[$h]}" > "${PAR_DIR}/${h}.out" 2>&1 ) &
      pids[$h]=$!
    done
    for h in "${!pids[@]}"; do
      if wait "${pids[$h]}"; then
        unset 'pending[$h]'
      fi
    done
    unset pids
    declare -A pids
  done
  if [ "${#pending[@]}" -gt 0 ]; then
    for h in "${!pending[@]}"; do
      echo "  FAILED (after retries): ${h}" >&2
      cat "${PAR_DIR}/${h}.out" >&2
    done
    return 1
  fi
  return 0
}

echo "==> Resolving internal IPs and primary interfaces (parallel, one SSH per host)"
declare -A HOST_IP HOST_IFACE HOST_REGION RESOLVE_CMD
for h in "${ALL_HOSTS[@]}"; do
  RESOLVE_CMD[$h]="ip route | awk '/default/{print \$5; exit}'; hostname -I | awk '{print \$1}'"
done
run_per_host_parallel RESOLVE_CMD || { echo "==> ERROR: IP/interface resolution failed on at least one host" >&2; exit 1; }
all_idx=0
for h in "${ALL_HOSTS[@]}"; do
  iface="$(sed -n '1p' "${PAR_DIR}/${h}.out")"
  ip="$(sed -n '2p' "${PAR_DIR}/${h}.out")"
  HOST_IP[$h]="${ip}"
  HOST_IFACE[$h]="${iface}"
  HOST_REGION[$h]="${REGIONS[$((all_idx % ${#REGIONS[@]}))]}"
  echo "  ${h}: ip=${ip} iface=${iface} region=${HOST_REGION[$h]}"
  all_idx=$((all_idx + 1))
done

if [ "${ACTION}" = "clear" ]; then
  echo "==> Clearing tc root qdisc on every host (removing all injected delay, parallel)"
  declare -A CLEAR_CMD
  for h in "${ALL_HOSTS[@]}"; do
    CLEAR_CMD[$h]="sudo-g5k tc qdisc del dev ${HOST_IFACE[$h]} root 2>/dev/null || true"
  done
  run_per_host_parallel CLEAR_CMD || { echo "==> ERROR: clear failed on at least one host" >&2; exit 1; }
  echo "==> Done (cleared ${#ALL_HOSTS[@]} hosts)"
  exit 0
fi

echo "==> Building per-host tc command batches (pure local computation, no network calls yet)"
# The default/fallback class uses 9999, well outside the 100-1570 range classid/vclassid/
# vvclassid can reach below -- 999 was used originally and silently collided with vvclassid's
# global counter (700 + up to 870) passing through exactly 999 on whichever validator happened
# to own that pair, failing with "RTNETLINK answers: File exists" (confirmed hitting this on
# paradoxe-33 in the 30v weekend run, 2026-10-24).
declare -A HOST_CMD
for h in "${ALL_HOSTS[@]}"; do
  HOST_CMD[$h]="sudo-g5k tc qdisc del dev ${HOST_IFACE[$h]} root 2>/dev/null || true; \
    sudo-g5k tc qdisc add dev ${HOST_IFACE[$h]} root handle 1: htb default 9999 && \
    sudo-g5k tc class add dev ${HOST_IFACE[$h]} parent 1: classid 1:9999 htb rate 10gbit"
done

echo "  client <-> validator (half the target RTT on each side)"
for ch in "${CLIENT_HOSTS_ARR[@]}"; do
  classid=100
  for vh in "${VALIDATOR_HOSTS_ARR[@]}"; do
    rtt="$(rtt_between "${HOST_REGION[$ch]}" "${HOST_REGION[$vh]}")"
    half="$(awk -v r="${rtt}" 'BEGIN{printf "%.2f", r/2}')"
    classid=$((classid + 1))
    echo "    ${ch} (${HOST_REGION[$ch]}) -> ${vh} (${HOST_REGION[$vh]}): RTT=${rtt}ms, delay=${half}ms each side"
    # Client's egress toward this validator.
    HOST_CMD[$ch]="${HOST_CMD[$ch]} && \
      sudo-g5k tc class add dev ${HOST_IFACE[$ch]} parent 1: classid 1:${classid} htb rate 10gbit && \
      sudo-g5k tc qdisc add dev ${HOST_IFACE[$ch]} parent 1:${classid} handle ${classid}: netem delay ${half}ms limit ${NETEM_QUEUE_LIMIT} && \
      sudo-g5k tc filter add dev ${HOST_IFACE[$ch]} protocol ip parent 1:0 prio 1 u32 match ip dst ${HOST_IP[$vh]}/32 flowid 1:${classid}"
  done
done

vclassid=100
for vh in "${VALIDATOR_HOSTS_ARR[@]}"; do
  for ch in "${CLIENT_HOSTS_ARR[@]}"; do
    rtt="$(rtt_between "${HOST_REGION[$ch]}" "${HOST_REGION[$vh]}")"
    half="$(awk -v r="${rtt}" 'BEGIN{printf "%.2f", r/2}')"
    vclassid=$((vclassid + 1))
    # Validator's egress back toward this client (symmetric split).
    HOST_CMD[$vh]="${HOST_CMD[$vh]} && \
      sudo-g5k tc class add dev ${HOST_IFACE[$vh]} parent 1: classid 1:${vclassid} htb rate 10gbit && \
      sudo-g5k tc qdisc add dev ${HOST_IFACE[$vh]} parent 1:${vclassid} handle ${vclassid}: netem delay ${half}ms limit ${NETEM_QUEUE_LIMIT} && \
      sudo-g5k tc filter add dev ${HOST_IFACE[$vh]} protocol ip parent 1:0 prio 1 u32 match ip dst ${HOST_IP[$ch]}/32 flowid 1:${vclassid}"
  done
done

echo "  validator <-> validator (committee consensus traffic)"
vvclassid=700
for vh1 in "${VALIDATOR_HOSTS_ARR[@]}"; do
  for vh2 in "${VALIDATOR_HOSTS_ARR[@]}"; do
    [ "${vh1}" = "${vh2}" ] && continue
    rtt="$(rtt_between "${HOST_REGION[$vh1]}" "${HOST_REGION[$vh2]}")"
    half="$(awk -v r="${rtt}" 'BEGIN{printf "%.2f", r/2}')"
    vvclassid=$((vvclassid + 1))
    HOST_CMD[$vh1]="${HOST_CMD[$vh1]} && \
      sudo-g5k tc class add dev ${HOST_IFACE[$vh1]} parent 1: classid 1:${vvclassid} htb rate 10gbit && \
      sudo-g5k tc qdisc add dev ${HOST_IFACE[$vh1]} parent 1:${vvclassid} handle ${vvclassid}: netem delay ${half}ms limit ${NETEM_QUEUE_LIMIT} && \
      sudo-g5k tc filter add dev ${HOST_IFACE[$vh1]} protocol ip parent 1:0 prio 1 u32 match ip dst ${HOST_IP[$vh2]}/32 flowid 1:${vvclassid}"
  done
done

echo "==> Dispatching one batched SSH call per host (${#ALL_HOSTS[@]} hosts, all in parallel)"
run_per_host_parallel HOST_CMD || { echo "==> ERROR: tc setup failed on at least one host" >&2; exit 1; }
echo "==> All ${#ALL_HOSTS[@]} hosts configured successfully"

echo "==> Done. Verify with: ssh <host> sudo-g5k tc qdisc show dev <iface>"
echo "    Clear with: ACTION=clear (same env vars) $0"
