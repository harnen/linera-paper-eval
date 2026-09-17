#!/usr/bin/env bash
set -euo pipefail

# Reserves NUM_VALIDATORS + (WITH_CLIENT?1:0) whole physical machines on Grid5000 -- one node
# per validator, plus one for the benchmark client -- as a single passive OAR job, then writes
# out the assigned hostnames so run_committee_grid5k.sh / find_max_tps_grid5k.sh can drive them.
#
# This does *not* deploy any OS image (no `-t deploy`, no kadeploy): it takes the site's
# standard production environment, which is enough to run prebuilt Linera binaries -- see
# run_committee_grid5k.sh's header for why we cross-deploy prebuilt binaries (mirroring how
# find_max_tps.sh already deploys to sparta/yiannis-testbed) instead of bootstrapping a Rust
# toolchain on Grid5000.
#
# Prerequisites (verified interactively before writing this script, not assumed):
#   - `ssh grid5k` reaches a bastion (hostname resolved to "access-north" when checked).
#   - `ssh -J grid5k <site>` reaches that site's frontend directly (e.g. `ssh -J grid5k nancy`
#     landed on "fnancy" with oarsub/oarstat/oardel on PATH). Two-hop nested `ssh grid5k ssh
#     <site> ...` does NOT work the way you'd expect for multi-statement remote commands --
#     the shell metacharacters get re-split by the intermediate hop's shell. Always use
#     ProxyJump (`-J`), never nested ssh invocations, for anything beyond a single command.
#   - Site frontends have no cargo/rustc; do NOT try to build there. curl/git/gcc are present
#     but unused by this pipeline (see run_committee_grid5k.sh).
#   - Home directories are NFS-shared per site (~24GB soft quota observed at Nancy) -- useful
#     to know for staging genesis/config files, but this script and run_committee_grid5k.sh do
#     not rely on that sharing (they scp explicitly), so the same scripts would still work
#     across a topology that spans multiple sites (no shared home) with VALIDATOR_HOSTS drawn
#     from different reservations, at the cost of real WAN latency between validators -- which
#     may be a deliberate, more realistic choice for the paper. See the hardware survey: grdix
#     (Nancy, 16 nodes, 128c/256t EPYC, 1TB RAM, 25GbE) is the largest single-site option for a
#     `1 machine = 1 validator` setup up to n=10 with headroom to spare; paradoxe (Rennes, 64
#     nodes, 26c/52t Xeon, 384GB RAM, 25GbE) is the closer-to-sparta-class alternative if you'd
#     rather the comparison to Fig. 6 not be confounded by suddenly having ~6x sparta's cores
#     per validator.
#
# Configuration (env vars):
#   G5K_SITE          (required) e.g. nancy, rennes
#   G5K_CLUSTER       (optional) e.g. grdix, paradoxe -- unset lets OAR pick any node at the site
#   CLIENT_CLUSTER    (optional) reserve the client node from a *different* cluster than
#                      G5K_CLUSTER (e.g. a smaller/cheaper one), still within the same site --
#                      OAR jobs can't span sites. Requires G5K_CLUSTER to also be set and
#                      WITH_CLIENT=true. Builds a composite `-l` request
#                      ({cluster='G5K_CLUSTER'}/nodes=N+{cluster='CLIENT_CLUSTER'}/nodes=1)
#                      instead of the single-cluster `-p` filter, and identifies each host's
#                      role by matching its hostname prefix against the two cluster names
#                      (not by request order, which OAR does not guarantee to preserve).
#   G5K_GATEWAY       (default grid5k) local ssh alias/host for the Grid5000 bastion
#   NUM_VALIDATORS    (default 1)
#   WITH_CLIENT       (default true) reserve extra node(s) for the lite-benchmark client
#   NUM_CLIENT_HOSTS  (default 1) how many client nodes to reserve when WITH_CLIENT=true --
#                      set >1 to split client-process load across several machines (e.g. once a
#                      single client host's CPU becomes the bottleneck, not the validators).
#   WALLTIME          (default 04:00:00) HH:MM:SS, enforced by OAR itself
#   JOB_NAME          (default linera-mv)
#   EXTRA_OARSUB_ARGS (optional) appended verbatim to the oarsub command, e.g. "-t besteffort"
#   OUT_ENV_FILE      (default ./grid5k_job_<site>.env) where the reservation's details are
#                      written -- source this file in later scripts/shells:
#                        source ./grid5k_job_nancy.env
#                        echo "${VALIDATOR_HOSTS[@]}" "${CLIENT_HOST}"
#
# Writes to OUT_ENV_FILE: G5K_SITE, G5K_GATEWAY, SSH_PROXY_JUMP (whichever hop pattern actually
# worked -- see the connectivity probe below), JOB_ID, VALIDATOR_HOSTS (bash array), CLIENT_HOSTS
# (space-separated, empty string if WITH_CLIENT=false), and CLIENT_HOST (the first of
# CLIENT_HOSTS, for scripts that only know about a single client host).
#
# Release the reservation with grid5k_release.sh once done -- OAR will also reclaim it
# automatically at WALLTIME regardless, but jobs left idle waste shared quota in the meantime.

G5K_SITE="${G5K_SITE:?set G5K_SITE, e.g. nancy}"
G5K_CLUSTER="${G5K_CLUSTER:-}"
CLIENT_CLUSTER="${CLIENT_CLUSTER:-}"
G5K_GATEWAY="${G5K_GATEWAY:-grid5k}"
NUM_VALIDATORS="${NUM_VALIDATORS:-1}"
WITH_CLIENT="${WITH_CLIENT:-true}"
NUM_CLIENT_HOSTS="${NUM_CLIENT_HOSTS:-1}"
WALLTIME="${WALLTIME:-04:00:00}"
JOB_NAME="${JOB_NAME:-linera-mv}"
EXTRA_OARSUB_ARGS="${EXTRA_OARSUB_ARGS:-}"
OUT_ENV_FILE="${OUT_ENV_FILE:-./grid5k_job_${G5K_SITE}.env}"

[ "${NUM_VALIDATORS}" -ge 1 ] || { echo "NUM_VALIDATORS must be >= 1" >&2; exit 1; }
[ "${NUM_CLIENT_HOSTS}" -ge 1 ] || { echo "NUM_CLIENT_HOSTS must be >= 1" >&2; exit 1; }

if [ -n "${CLIENT_CLUSTER}" ]; then
  [ -n "${G5K_CLUSTER}" ] || { echo "CLIENT_CLUSTER requires G5K_CLUSTER to also be set" >&2; exit 1; }
  [ "${WITH_CLIENT}" = "true" ] || { echo "CLIENT_CLUSTER requires WITH_CLIENT=true" >&2; exit 1; }
fi

total_nodes="${NUM_VALIDATORS}"
if [ "${WITH_CLIENT}" = "true" ]; then
  total_nodes=$((total_nodes + NUM_CLIENT_HOSTS))
fi

prop_arg=""
if [ -n "${G5K_CLUSTER}" ] && [ -z "${CLIENT_CLUSTER}" ]; then
  # OAR's -p takes a SQL WHERE clause, where a string comparison needs the value itself
  # single-quoted (cluster='gros', confirmed against the real frontend). The double quotes
  # here are for the remote bash's benefit -- they group the argument so its literal single
  # quotes survive into oarsub's argv unchanged, rather than being stripped as shell syntax.
  prop_arg="-p \"cluster='${G5K_CLUSTER}'\""
fi

l_arg="nodes=${total_nodes},walltime=${WALLTIME}"
if [ -n "${CLIENT_CLUSTER}" ]; then
  # Composite request: NUM_VALIDATORS nodes from G5K_CLUSTER, NUM_CLIENT_HOSTS from
  # CLIENT_CLUSTER, both within the same OAR job so they share a walltime/JOB_ID and get
  # released together.
  l_arg="\"{cluster='${G5K_CLUSTER}'}/nodes=${NUM_VALIDATORS}+{cluster='${CLIENT_CLUSTER}'}/nodes=${NUM_CLIENT_HOSTS},walltime=${WALLTIME}\""
fi

echo "==> Submitting OAR job: ${total_nodes} node(s) at ${G5K_SITE}${G5K_CLUSTER:+ (cluster=${G5K_CLUSTER})}, walltime ${WALLTIME}"
# Passive job: hold ${total_nodes} whole nodes idle (sleep effectively forever; OAR enforces
# WALLTIME itself and kills the job then, so this never actually needs to wake up on its own)
# so we can ssh into each one individually and orchestrate from here, instead of running
# inside a single `oarsub -I` foreground shell or a `-t deploy` custom image.
#
# Built as ONE pre-composed remote command string, not separate ssh argv words: ssh flattens
# multiple trailing arguments into a single space-joined string before the remote shell parses
# it, which silently destroys any argument that itself contains a space (e.g. "sleep
# 2147483647" arrives back as two separate, unquoted words, and oarsub chokes on the stray
# extra positional argument). A single already-quoted string sent as one argument sidesteps
# that entirely -- confirmed the hard way against the real frontend before trusting this.
remote_cmd="oarsub -l ${l_arg} ${prop_arg} -n ${JOB_NAME} ${EXTRA_OARSUB_ARGS} 'sleep 2147483647'"
oarsub_output="$(ssh -J "${G5K_GATEWAY}" "${G5K_SITE}" "${remote_cmd}" 2>&1)"
echo "${oarsub_output}"

job_id="$(printf '%s\n' "${oarsub_output}" | grep -oE 'OAR_JOB_ID=[0-9]+' | head -1 | cut -d= -f2)"
if [ -z "${job_id}" ]; then
  echo "==> Could not parse OAR_JOB_ID from oarsub output above -- submission likely failed" >&2
  exit 1
fi
echo "==> Job ${job_id} submitted -- waiting for it to start running"

state=""
empty_streak=0
for _ in $(seq 1 120); do
  # `|| true` on the ssh call itself: a transient connection blip here (confirmed happens in
  # practice) must not kill the whole reservation via set -e over one bad poll -- only a
  # *genuinely* empty state repeated several times in a row (the job actually gone) should.
  state="$(ssh -J "${G5K_GATEWAY}" "${G5K_SITE}" oarstat -s -j "${job_id}" 2>/dev/null | awk -F': ' '{print $2}')" || true
  case "${state}" in
    Running) break ;;
    Error|Terminated) echo "==> Job ${job_id} entered state '${state}' while waiting -- see 'oarstat -f -j ${job_id}' at ${G5K_SITE}" >&2; exit 1 ;;
    "")
      empty_streak=$((empty_streak + 1))
      if [ "${empty_streak}" -ge 5 ]; then
        echo "==> Got no state for job ${job_id} ${empty_streak} times in a row -- see 'oarstat -f -j ${job_id}' at ${G5K_SITE}" >&2
        exit 1
      fi
      sleep 5
      ;;
    *) empty_streak=0; sleep 5 ;;
  esac
done
[ "${state}" = "Running" ] || { echo "==> Timed out waiting for job ${job_id} to start (last state: ${state})" >&2; exit 1; }
echo "==> Job ${job_id} is Running"

# oarprint needs $OAR_RESOURCE_PROPERTIES_FILE, which only exists *inside* a running job's own
# environment -- it has no "-j <id>" mode from the plain frontend shell we're in (confirmed
# against the real frontend: "Unknown option: j"). oarstat -f's own "assigned_hostnames" field,
# "+"-joined, is what actually works from here without being inside the job.
hosts_raw="$(ssh -J "${G5K_GATEWAY}" "${G5K_SITE}" oarstat -f -j "${job_id}" 2>/dev/null \
  | awk -F'= ' '/assigned_hostnames/ {print $2}' | tr '+' '\n' | sort -u)"
if [ -z "${hosts_raw}" ]; then
  echo "==> Could not parse assigned_hostnames for job ${job_id} from oarstat -f" >&2
  exit 1
fi
mapfile -t all_hosts <<< "${hosts_raw}"
if [ "${#all_hosts[@]}" -ne "${total_nodes}" ]; then
  echo "==> WARNING: expected ${total_nodes} hosts, oarprint returned ${#all_hosts[@]}: ${all_hosts[*]}" >&2
fi

client_hosts=()
if [ -n "${CLIENT_CLUSTER}" ]; then
  # Composite request: don't trust host ordering to reflect request order -- match each
  # host's role by its hostname's cluster prefix instead (hostnames look like
  # "<cluster>-<n>.<site>.grid5000.fr").
  validator_hosts=()
  for h in "${all_hosts[@]}"; do
    case "${h}" in
      "${G5K_CLUSTER}"-*) validator_hosts+=("${h}") ;;
      "${CLIENT_CLUSTER}"-*) client_hosts+=("${h}") ;;
      *) echo "==> WARNING: host ${h} matches neither cluster '${G5K_CLUSTER}' nor '${CLIENT_CLUSTER}'" >&2 ;;
    esac
  done
  [ "${#client_hosts[@]}" -gt 0 ] || echo "==> WARNING: WITH_CLIENT=true but no ${CLIENT_CLUSTER} host was assigned" >&2
else
  validator_hosts=("${all_hosts[@]:0:${NUM_VALIDATORS}}")
  if [ "${WITH_CLIENT}" = "true" ]; then
    client_hosts=("${all_hosts[@]:${NUM_VALIDATORS}:${NUM_CLIENT_HOSTS}}")
    [ "${#client_hosts[@]}" -gt 0 ] || echo "==> WARNING: WITH_CLIENT=true but no extra host was assigned" >&2
  fi
fi
client_host="${client_hosts[0]:-}"

echo "==> Validator hosts: ${validator_hosts[*]}"
[ "${#client_hosts[@]}" -gt 0 ] && echo "==> Client host(s): ${client_hosts[*]}"

# The site frontend hop (ssh -J grid5k <site>) authenticates fine with no explicit user --
# confirmed the frontend's own ~/.ssh/config-equivalent already resolves it. Compute nodes
# (gros-122.nancy.grid5000.fr etc.) do NOT: they only accept the real Grid5000 account
# ("Permission denied (publickey,password)" for the local username, confirmed against a real
# reserved node), which is the *same* account every site frontend already runs as. Grab it once
# here via `whoami` on the frontend rather than hardcoding it, and record it as SSH_USER so
# every later script's ssh/scp/rsync calls can pass -o User=... to compute nodes without
# needing to bake it into VALIDATOR_HOSTS/CLIENT_HOST themselves (those stay plain hostnames,
# since they're also used as NODE_HOST -- a real network address, not an SSH target).
g5k_user="$(ssh -J "${G5K_GATEWAY}" "${G5K_SITE}" whoami 2>/dev/null)"
echo "==> Grid5000 account for compute-node SSH: ${g5k_user:-<could not determine>}"

# Probe both hop patterns against the first validator host: some Grid5000 deployments let the
# bastion jump straight to any node with a running job on it; others require a second hop
# through the site frontend. Recorded once here so every later script just sources
# SSH_PROXY_JUMP instead of re-probing.
echo "==> Probing SSH reachability of ${validator_hosts[0]} from here"
ssh_proxy_jump=""
user_opt=()
[ -n "${g5k_user}" ] && user_opt=(-o "User=${g5k_user}")
if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "${user_opt[@]}" -J "${G5K_GATEWAY}" "${validator_hosts[0]}" true 2>/dev/null; then
  ssh_proxy_jump="${G5K_GATEWAY}"
  echo "  direct hop works: ssh -J ${G5K_GATEWAY} -o User=${g5k_user} ${validator_hosts[0]}"
elif ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "${user_opt[@]}" -J "${G5K_GATEWAY},${G5K_SITE}" "${validator_hosts[0]}" true 2>/dev/null; then
  ssh_proxy_jump="${G5K_GATEWAY},${G5K_SITE}"
  echo "  two-hop works: ssh -J ${G5K_GATEWAY},${G5K_SITE} -o User=${g5k_user} ${validator_hosts[0]}"
else
  echo "==> WARNING: neither hop pattern could reach ${validator_hosts[0]} as user '${g5k_user}'." >&2
  echo "    Writing SSH_PROXY_JUMP=${G5K_GATEWAY} as a guess -- fix it by hand in ${OUT_ENV_FILE}" >&2
  echo "    before running anything else." >&2
  ssh_proxy_jump="${G5K_GATEWAY}"
fi

{
  echo "G5K_SITE=${G5K_SITE}"
  echo "G5K_GATEWAY=${G5K_GATEWAY}"
  echo "SSH_PROXY_JUMP=${ssh_proxy_jump}"
  echo "SSH_USER=${g5k_user}"
  echo "JOB_ID=${job_id}"
  printf 'VALIDATOR_HOSTS="%s"\n' "${validator_hosts[*]}"
  printf 'CLIENT_HOSTS="%s"\n' "${client_hosts[*]}"
  echo "CLIENT_HOST=${client_host}"
} > "${OUT_ENV_FILE}"

echo "==> Wrote ${OUT_ENV_FILE}"
echo "==> Release with: JOB_ID=${job_id} G5K_SITE=${G5K_SITE} scripts/grid5k_release.sh"
echo "    (or just let it expire at WALLTIME=${WALLTIME} -- OAR reclaims it either way)"
