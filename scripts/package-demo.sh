#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/builds.py package "$@"
