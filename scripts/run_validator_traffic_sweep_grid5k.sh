#!/usr/bin/env bash
set -euo pipefail

# Sweeps VALIDATOR_COUNTS x TRAFFIC_MODES on a single Grid5000 reservation: for each
# combination, first calibrates the proxy/storage/shard core split with
# profile_core_split_grid5k.sh (a fixed moderate load, several RESERVED_CORES:STORAGE_CORES:
# CORES_PER_SHARD combos), picks the combo with the highest achieved_bps, then runs the real
# ramp-to-failure with find_max_tps_grid5k.sh using that calibrated split -- archiving every
# level's per-client transfers.csv (CLIENT_ARCHIVE_DIR) for later plotting.
#
# Assumes binaries and (if TRANSACTIONS_PER_BLOCK_FILE is set) the trace file are already
# deployed to every host in VALIDATOR_HOSTS and to CLIENT_HOST -- this script always passes
# SKIP_BUILD=true SKIP_BINARY_DEPLOY=true to both sub-scripts, on the assumption the caller
# did that deploy once up front (deploying separately per combination would repeat it
# VALIDATOR_COUNTS x TRAFFIC_MODES times for no benefit, since the binaries don't change).
#
# Configuration (env vars):
#   VALIDATOR_HOSTS      (required) space-separated hosts, at least max(VALIDATOR_COUNTS) of
#                         them -- each validator count N uses the first N of this list, so
#                         results across N stay on a consistent, comparable set of machines.
#   CLIENT_HOST           (required) used for calibration (profile_core_split_grid5k.sh only
#                         supports a single client host)
#   RAMP_CLIENT_HOSTS     (optional, space-separated) client hosts for the full ramp
#                         (find_max_tps_grid5k.sh, which does support multiple) -- defaults to
#                         just CLIENT_HOST if unset. Set this to several hosts once a single
#                         client host's CPU becomes the bottleneck (see find_max_tps_grid5k.sh's
#                         per-level client_cpu_pct column).
#   SSH_PROXY_JUMP, SSH_USER, REMOTE_DIR, LINERA_SRC
#   VALIDATOR_COUNTS      (default "1 5 10")
#   TRAFFIC_MODES         (default "independent mixed full")
#   TRANSACTIONS_PER_BLOCK_FILE (optional) path *on CLIENT_HOST*, header already stripped
#   LIGHT_CERTIFICATES    (default true)
#   CALIBRATION_COMBOS    (default "2:0:2 4:0:2 6:0:2 2:2:2 4:2:2") RESERVED_CORES:
#                         STORAGE_CORES:CORES_PER_SHARD triples passed to
#                         profile_core_split_grid5k.sh's COMBOS
#   CALIBRATION_NUM_CLIENTS, CALIBRATION_BPS_PER_CLIENT, CALIBRATION_CHAINS_PER_CLIENT,
#   CALIBRATION_RUNTIME_SECONDS  (defaults 20, 50, 5, 15) the fixed load applied to every combo
#   RAMP_MAX_CLIENTS, RAMP_CLIENT_STEP_SCHEDULE, RAMP_RUNTIME_SECONDS, RAMP_CHAINS_PER_CLIENT,
#   RAMP_BPS_PER_CLIENT  (defaults 4000, "x2 1000", 10, 5, 50) passed to find_max_tps_grid5k.sh.
#                         The schedule doubles to find the rough neighborhood fast, then
#                         brackets it with a single 1000-client additive pass -- 1000 clients
#                         (50000 bps) is as fine a resolution as this project needs, so finer
#                         additive steps just buy unneeded levels. See
#                         feedback_grid5k_linera_benchmark_methodology memory point 7
#                         (multiplicative-first, never pure-additive) for why.
#   PROVISION_PARALLELISM (default 16) passed to find_max_tps_grid5k.sh -- see there for
#                         rationale; matches RAMP_MAX_CLIENTS's bigger default so the larger
#                         chain pool doesn't cost minutes of serial provisioning per combo. Set
#                         to 1 only if RAMP_MAX_CLIENTS x RAMP_CHAINS_PER_CLIENT is small enough
#                         that parallel shard setup isn't worth its own overhead.
#   CLUSTER_LABEL         (default: inferred from VALIDATOR_HOSTS[0], the part before its first
#                         "-", e.g. "gros-109.nancy..." -> "gros") prefixes every output path
#                         (summary CSVs, calibration dirs, archive dirs) so two sweeps against
#                         different clusters/reservations never collide on the same filename --
#                         confirmed the hard way running a gros sweep and a grvingt sweep at the
#                         same time: both defaulted to identical "gros_<label>.csv" paths
#                         (leftover from when this script only ever targeted gros) and started
#                         overwriting each other's calibration/archive directories mid-run.
#   OUT_ROOT              (default ./results) calibration summaries + ramp summary CSVs land
#                         under here
#   CLIENT_ARCHIVE_ROOT   (default ./results/graphs_data) every ramp's per-level, per-client
#                         transfers.csv is archived under
#                         ${CLIENT_ARCHIVE_ROOT}/${CLUSTER_LABEL}_${N}val_${mode}_raw/
#   STOP_COMMITTEE_AFTER  (default true) passed through to both sub-scripts

VALIDATOR_HOSTS="${VALIDATOR_HOSTS:?set VALIDATOR_HOSTS to a space-separated list of hosts}"
read -ra ALL_VALIDATOR_HOSTS_ARR <<< "${VALIDATOR_HOSTS}"
CLUSTER_LABEL="${CLUSTER_LABEL:-${ALL_VALIDATOR_HOSTS_ARR[0]%%-*}}"
CLIENT_HOST="${CLIENT_HOST:?set CLIENT_HOST}"
RAMP_CLIENT_HOSTS="${RAMP_CLIENT_HOSTS:-${CLIENT_HOST}}"
SSH_PROXY_JUMP="${SSH_PROXY_JUMP:-}"
SSH_USER="${SSH_USER:-}"
REMOTE_DIR="${REMOTE_DIR:-linera}"
LINERA_SRC="${LINERA_SRC:-$HOME/work/linera/linera-protocol}"
VALIDATOR_COUNTS="${VALIDATOR_COUNTS:-1 5 10}"
TRAFFIC_MODES="${TRAFFIC_MODES:-independent mixed full}"
TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE:-}"
LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES:-true}"
QUORUM_ONLY="${QUORUM_ONLY:-false}"
CALIBRATION_COMBOS="${CALIBRATION_COMBOS:-2:0:2 4:0:2 6:0:2 2:2:2 4:2:2}"
CALIBRATION_NUM_CLIENTS="${CALIBRATION_NUM_CLIENTS:-20}"
CALIBRATION_BPS_PER_CLIENT="${CALIBRATION_BPS_PER_CLIENT:-50}"
CALIBRATION_CHAINS_PER_CLIENT="${CALIBRATION_CHAINS_PER_CLIENT:-5}"
CALIBRATION_RUNTIME_SECONDS="${CALIBRATION_RUNTIME_SECONDS:-15}"
RAMP_MAX_CLIENTS="${RAMP_MAX_CLIENTS:-4000}"
RAMP_CLIENT_STEP_SCHEDULE="${RAMP_CLIENT_STEP_SCHEDULE:-x2 1000}"
RAMP_RUNTIME_SECONDS="${RAMP_RUNTIME_SECONDS:-10}"
RAMP_CHAINS_PER_CLIENT="${RAMP_CHAINS_PER_CLIENT:-5}"
RAMP_BPS_PER_CLIENT="${RAMP_BPS_PER_CLIENT:-50}"
PROVISION_PARALLELISM="${PROVISION_PARALLELISM:-16}"
OUT_ROOT="${OUT_ROOT:-./results}"
CLIENT_ARCHIVE_ROOT="${CLIENT_ARCHIVE_ROOT:-./results/graphs_data}"
STOP_COMMITTEE_AFTER="${STOP_COMMITTEE_AFTER:-true}"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${OUT_ROOT}"

pick_best_combo() {
  # Reads a profile_core_split_grid5k.sh summary.csv on stdin, prints
  # "reserved storage cps shards" for the row with the highest achieved_bps among rows whose
  # status is "ok" (skips "skipped: ..." / "failed: ..." rows). A combo with a handful of
  # transient failures still reads "ok; N failed block(s)" (see profile_core_split_grid5k.sh),
  # not the bare string "ok" -- notably with --quorum-only, where a few expected transient
  # failures under load are normal, not a sign the combo itself is broken. An exact-match
  # comparison here rejected every otherwise-healthy combo and starved the full ramp entirely
  # (confirmed 2026-10-28: all 5 quorum-only combos read "ok; N failed block(s)" with achieved_bps
  # close to the target and <0.2% failure rate, yet "no combo succeeded" fired every time).
  python3 -c '
import csv, sys
best = None
best_bps = -1.0
for row in csv.reader(sys.stdin):
    if len(row) < 15 or row[0] == "reserved_cores":
        continue
    status = row[14]
    if not (status == "ok" or status.startswith("ok;")):
        continue
    try:
        bps = float(row[7])
    except ValueError:
        continue
    if bps > best_bps:
        best_bps = bps
        best = (row[0], row[1], row[2], row[3])
if best is None:
    sys.exit(1)
print(" ".join(best))
'
}

for n in ${VALIDATOR_COUNTS}; do
  if [ "${n}" -gt "${#ALL_VALIDATOR_HOSTS_ARR[@]}" ]; then
    echo "==> Skipping N=${n}: only ${#ALL_VALIDATOR_HOSTS_ARR[@]} validator host(s) available" >&2
    continue
  fi
  hosts_n="${ALL_VALIDATOR_HOSTS_ARR[*]:0:${n}}"

  for mode in ${TRAFFIC_MODES}; do
    label="${CLUSTER_LABEL}_${n}val_${mode}"
    echo ""
    echo "########## ${label}: calibrating proxy/storage/shard core split ##########"
    calib_out="${OUT_ROOT}/core_split_grid5k/${label}"
    VALIDATOR_HOSTS="${hosts_n}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" \
      CLIENT_HOST="${CLIENT_HOST}" REMOTE_DIR="${REMOTE_DIR}" LINERA_SRC="${LINERA_SRC}" \
      SKIP_BUILD=true SKIP_BINARY_DEPLOY=true \
      COMBOS="${CALIBRATION_COMBOS}" \
      NUM_CLIENTS="${CALIBRATION_NUM_CLIENTS}" BPS_PER_CLIENT="${CALIBRATION_BPS_PER_CLIENT}" \
      CHAINS_PER_CLIENT="${CALIBRATION_CHAINS_PER_CLIENT}" RUNTIME_SECONDS="${CALIBRATION_RUNTIME_SECONDS}" \
      TRAFFIC_MODE="${mode}" LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES}" QUORUM_ONLY="${QUORUM_ONLY}" \
      TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE}" \
      PERF_PROFILE=false OUT_DIR="${calib_out}" \
      "${LOCAL_DIR}/scripts/profile_core_split_grid5k.sh"

    best="$(pick_best_combo < "${calib_out}/summary.csv")" || {
      echo "==> ${label}: no combo succeeded, skipping full ramp" >&2
      continue
    }
    read -r best_reserved best_storage best_cps best_shards <<< "${best}"
    echo "==> ${label}: best split reserved=${best_reserved} storage=${best_storage} cores_per_shard=${best_cps} shards=${best_shards}"

    echo ""
    echo "########## ${label}: full ramp with calibrated split ##########"
    archive_dir="${CLIENT_ARCHIVE_ROOT}/${label}_raw"
    mkdir -p "${archive_dir}"
    VALIDATOR_HOSTS="${hosts_n}" SSH_PROXY_JUMP="${SSH_PROXY_JUMP}" SSH_USER="${SSH_USER}" \
      CLIENT_HOSTS="${RAMP_CLIENT_HOSTS}" REMOTE_DIR="${REMOTE_DIR}" LINERA_SRC="${LINERA_SRC}" \
      SKIP_BUILD=true SKIP_BINARY_DEPLOY=true \
      RESERVED_CORES="${best_reserved}" STORAGE_CORES="${best_storage}" \
      CORES_PER_SHARD="${best_cps}" NUM_SHARDS="${best_shards}" \
      TRAFFIC_MODE="${mode}" LIGHT_CERTIFICATES="${LIGHT_CERTIFICATES}" QUORUM_ONLY="${QUORUM_ONLY}" \
      TRANSACTIONS_PER_BLOCK_FILE="${TRANSACTIONS_PER_BLOCK_FILE}" \
      CHAINS_PER_CLIENT="${RAMP_CHAINS_PER_CLIENT}" BPS_PER_CLIENT="${RAMP_BPS_PER_CLIENT}" \
      MAX_CLIENTS="${RAMP_MAX_CLIENTS}" CLIENT_STEP_SCHEDULE="${RAMP_CLIENT_STEP_SCHEDULE}" \
      RUNTIME_SECONDS="${RAMP_RUNTIME_SECONDS}" PROVISION_PARALLELISM="${PROVISION_PARALLELISM}" \
      CLIENT_ARCHIVE_DIR="${archive_dir}" \
      SUMMARY_CSV_PATH="${OUT_ROOT}/${label}.csv" \
      STOP_COMMITTEE_AFTER="${STOP_COMMITTEE_AFTER}" \
      "${LOCAL_DIR}/scripts/find_max_tps_grid5k.sh"

    echo "==> ${label}: done. Summary: ${OUT_ROOT}/${label}.csv, archived data: ${archive_dir}"
  done
done

echo ""
echo "==> Sweep complete."
