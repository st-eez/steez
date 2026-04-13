#!/usr/bin/env bash
# Run all agent subsystem tests
set -euo pipefail

cd "$(dirname "$0")"

total_pass=0
total_fail=0
files_run=0

for test_file in test-*.sh; do
  [[ -f "$test_file" ]] || continue
  echo ""
  echo "=== $test_file ==="
  if bash "$test_file"; then
    : # test prints its own summary
  fi
  files_run=$((files_run + 1))
done

echo ""
echo "=== $files_run test files executed ==="
