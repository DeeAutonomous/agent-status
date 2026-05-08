#!/usr/bin/env bash
# Reproducible perf gate. Runs PerfBenchmarks, extracts the elapsed-time line,
# and compares against scripts/perf-baseline.txt.
#
# Usage:
#   scripts/perf-check.sh
#
# Exit 0 when within 2x baseline. Prints both numbers.
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT=$(xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerfBenchmarks 2>&1)

ELAPSED=$(echo "$OUTPUT" | grep -E '^PERF: lines=10000 elapsed=' \
  | tail -1 | sed -E 's/.*elapsed=//')

if [[ -z "$ELAPSED" ]]; then
  echo "perf-check: could not extract elapsed time from xcodebuild output" >&2
  echo "$OUTPUT" | tail -30 >&2
  exit 1
fi

BASELINE=$(cat scripts/perf-baseline.txt 2>/dev/null || echo "0.5")

echo "perf-check: elapsed=${ELAPSED}s  baseline=${BASELINE}s"

# Threshold: 2x baseline → flag regression.
awk -v e="$ELAPSED" -v b="$BASELINE" 'BEGIN {
  if (b > 0 && e > b * 2.0) {
    printf "perf-check: REGRESSION (%.3fs > 2x baseline %.3fs)\n", e, b
    exit 1
  }
  printf "perf-check: OK\n"
  exit 0
}'
