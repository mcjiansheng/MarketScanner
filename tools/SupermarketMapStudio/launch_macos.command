#!/bin/sh
set -eu

LAUNCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export RTABMAP_REPROCESS="$LAUNCH_DIR/bin/rtabmap-reprocess"
export MARKETSCANNER_FACTOR_GRAPH_BIN="$LAUNCH_DIR/bin/rtabmap-prior-map-factor-graph"
PYTHON_COMMAND=${PYTHON:-python3}

if ! "$PYTHON_COMMAND" "$LAUNCH_DIR/tools/SupermarketMapStudio/server.py" --selfcheck; then
  echo "Supermarket Map Studio startup self-check failed." >&2
  echo "Keep this window open and export the output for support." >&2
  exit 1
fi

exec "$PYTHON_COMMAND" "$LAUNCH_DIR/tools/SupermarketMapStudio/server.py" "$@"
