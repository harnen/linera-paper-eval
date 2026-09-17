#!/usr/bin/env bash
set -euo pipefail

# Releases a Grid5000 reservation made by grid5k_reserve.sh. OAR reclaims the job automatically
# at its WALLTIME regardless, but releasing explicitly once you're done frees the nodes for
# other users immediately instead of leaving them idle for the rest of the reservation window.
#
# Usage:
#   scripts/grid5k_release.sh ./grid5k_job_nancy.env
# or:
#   JOB_ID=1234567 G5K_SITE=nancy scripts/grid5k_release.sh

ENV_FILE="${1:-}"
if [ -n "${ENV_FILE}" ]; then
  [ -f "${ENV_FILE}" ] || { echo "No such env file: ${ENV_FILE}" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

G5K_SITE="${G5K_SITE:?set G5K_SITE or pass a grid5k_reserve.sh env file}"
G5K_GATEWAY="${G5K_GATEWAY:-grid5k}"
JOB_ID="${JOB_ID:?set JOB_ID or pass a grid5k_reserve.sh env file}"

echo "==> Deleting OAR job ${JOB_ID} at ${G5K_SITE}"
ssh -J "${G5K_GATEWAY}" "${G5K_SITE}" oardel "${JOB_ID}"
echo "==> Done"
