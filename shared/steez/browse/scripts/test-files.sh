#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <test-dir> [<test-dir> ...]" >&2
  exit 2
fi

files=()

for root in "$@"; do
  if [[ "$root" != /* ]]; then
    root="$PROJECT_DIR/$root"
  fi

  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$root" -type f -name '*.test.ts' ! -name '*e2e*' | sort)
done

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No test files matched." >&2
  exit 1
fi

cd "$PROJECT_DIR"

failed=0

for file in "${files[@]}"; do
  if ! bun test "$file"; then
    failed=1
  fi
done

exit "$failed"
