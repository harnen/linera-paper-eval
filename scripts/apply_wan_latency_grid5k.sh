#!/usr/bin/env bash
set -euo pipefail

# Injects a realistic, per-pair WAN latency mesh between client hosts and validator hosts
# using `tc netem` (real kernel-level packet delay), instead of the client-side-only
# SIMULATED_LATENCY_MS flag (a single flat delay applied uniformly everywhere). Each
# client/validator host is round-robin assigned to one of 6 AWS regions, using the exact
# same region-to-region RTT matrix Mysticeti's own orchestrator ships (measured 2026-09-18,
# see mysticeti/crates/simulator/examples/geography.yaml) -- so results are comparable
# apples-to-apples between the two systems' benchmarks. For a pair with target RTT R, each
# side gets R/2 ms of netem delay on its egress toward the other, so the two one-way delays
# sum to the real measured round-trip.
#
# Grid5000 nodes don't have passwordless `sudo`, but do have `sudo-g5k` (a Grid5000-specific
# root escalation that works passwordlessly on your own OAR-reserved nodes) -- confirmed this
# session. All tc commands run through that.
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
  local a="$1" b="$2" key="${a},${b}" rkey="${b},${a}"
  if [ -n "${RTT_MS[${key}]+x}" ]; then echo "${RTT_MS[${key}]}"; return; fi
  if [ -n "${RTT_MS[${rkey}]+x}" ]; then echo "${RTT_MS[${rkey}]}"; return; fi
  echo "error: no RTT entry for ${a} <-> ${b}" >&2; exit 1
}

echo "==> Resolving internal IPs and primary interfaces"
declare -A HOST_IP HOST_IFACE HOST_REGION
all_idx=0
for h in "${VALIDATOR_HOSTS_ARR[@]}" "${CLIENT_HOSTS_ARR[@]}"; do
  [ -n "${HOST_IP[$h]+x}" ] && continue
  ip_iface="$(ssh_j "${h}" "ip route | awk '/default/{print \$5; exit}'; hostname -I | awk '{print \$1}'")"
  iface="$(echo "${ip_iface}" | sed -n '1p')"
  ip="$(echo "${ip_iface}" | sed -n '2p')"
  HOST_IP[$h]="${ip}"
  HOST_IFACE[$h]="${iface}"
  HOST_REGION[$h]="${REGIONS[$((all_idx % ${#REGIONS[@]}))]}"
  echo "  ${h}: ip=${ip} iface=${iface} region=${HOST_REGION[$h]}"
  all_idx=$((all_idx + 1))
done

if [ "${ACTION}" = "clear" ]; then
  echo "==> Clearing tc root qdisc on every host (removing all injected delay)"
  for h in "${VALIDATOR_HOSTS_ARR[@]}" "${CLIENT_HOSTS_ARR[@]}"; do
    ssh_j "${h}" "sudo-g5k tc qdisc del dev ${HOST_IFACE[$h]} root 2>/dev/null || true"
    echo "  ${h}: cleared"
  done
  echo "==> Done"
  exit 0
fi

echo "==> Applying per-pair netem delay (client <-> validator only, half the target RTT on each side)"
for h in "${VALIDATOR_HOSTS_ARR[@]}" "${CLIENT_HOSTS_ARR[@]}"; do
  ssh_j "${h}" "sudo-g5k tc qdisc del dev ${HOST_IFACE[$h]} root 2>/dev/null || true; \
    sudo-g5k tc qdisc add dev ${HOST_IFACE[$h]} root handle 1: htb default 999 && \
    sudo-g5k tc class add dev ${HOST_IFACE[$h]} parent 1: classid 1:999 htb rate 10gbit"
done

for ch in "${CLIENT_HOSTS_ARR[@]}"; do
  classid=100
  for vh in "${VALIDATOR_HOSTS_ARR[@]}"; do
    rtt="$(rtt_between "${HOST_REGION[$ch]}" "${HOST_REGION[$vh]}")"
    half="$(awk -v r="${rtt}" 'BEGIN{printf "%.2f", r/2}')"
    classid=$((classid + 1))
    echo "  ${ch} (${HOST_REGION[$ch]}) -> ${vh} (${HOST_REGION[$vh]}): RTT=${rtt}ms, delay=${half}ms each side"
    # Client's egress toward this validator.
    ssh_j "${ch}" "sudo-g5k tc class add dev ${HOST_IFACE[$ch]} parent 1: classid 1:${classid} htb rate 10gbit && \
      sudo-g5k tc qdisc add dev ${HOST_IFACE[$ch]} parent 1:${classid} handle ${classid}: netem delay ${half}ms && \
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
    ssh_j "${vh}" "sudo-g5k tc class add dev ${HOST_IFACE[$vh]} parent 1: classid 1:${vclassid} htb rate 10gbit && \
      sudo-g5k tc qdisc add dev ${HOST_IFACE[$vh]} parent 1:${vclassid} handle ${vclassid}: netem delay ${half}ms && \
      sudo-g5k tc filter add dev ${HOST_IFACE[$vh]} protocol ip parent 1:0 prio 1 u32 match ip dst ${HOST_IP[$ch]}/32 flowid 1:${vclassid}"
  done
done

echo "==> Done. Verify with: ssh <host> sudo-g5k tc qdisc show dev <iface>"
echo "    Clear with: ACTION=clear (same env vars) $0"
