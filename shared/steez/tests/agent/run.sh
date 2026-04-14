#!/usr/bin/env bash
# Run all agent subsystem tests. Exits non-zero if any test file fails.
set -uo pipefail

cd "$(dirname "$0")"

files_run=0
failed_names=()

for test_file in test-*.sh; do
  [[ -f "$test_file" ]] || continue
  echo ""
  echo "=== $test_file ==="
  rc=0
  bash "$test_file" || rc=$?
  files_run=$((files_run + 1))
  [[ $rc -ne 0 ]] && failed_names+=("$test_file")
done

echo ""
if [[ ${#failed_names[@]} -eq 0 ]]; then
  echo "=== $files_run test files executed, all passed ==="
  exit 0
fi

echo "=== $files_run test files executed, ${#failed_names[@]} failed ==="
for name in "${failed_names[@]}"; do
  echo "  - $name"
done
exit 1
