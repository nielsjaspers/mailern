#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
simulator_id=${1:?Usage: scripts/check-ui.sh DISPOSABLE_SIMULATOR_ID [WORKERS|--stop]}
workers=${2:-5}
if [ "$workers" = --stop ]; then
  exec python3 scripts/run-ui-workers.py "$simulator_id" --stop
fi
case "$workers" in 1|2|3|4|5|6|7|8|9|10) ;; *) echo 'WORKERS must be between 1 and 10' >&2; exit 2 ;; esac
started=$(date +%s)
derived_data=build/ui-tests
run_id=$(date +%Y%m%d-%H%M%S)-$$
python3 scripts/run-ui-workers.py "$simulator_id" "$workers" "$derived_data" "$run_id"
echo "Full UI suite completed in $(($(date +%s) - started))s"
