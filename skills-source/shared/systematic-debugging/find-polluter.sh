#!/usr/bin/env bash
# Find the first npm test file that creates the given path.
set -e

if [[ $# -ne 2 ]]; then
  echo "Usage: bash $0 <path-that-should-not-exist> '<test-file-glob>'" >&2
  exit 2
fi

target=$1
pattern=$2
if [[ -e $target || -L $target ]]; then
  echo "Cannot attribute pollution: $target already exists before testing." >&2
  exit 2
fi

shopt -s globstar nullglob
# Expand the user's glob without splitting paths that contain whitespace.
IFS=
tests=()
for file in $pattern; do
  if [[ -f $file ]]; then tests+=("$file"); fi
done

if (( ${#tests[@]} == 0 )); then
  echo "No test files matched: $pattern" >&2
  exit 2
fi

echo "Found ${#tests[@]} test files"
for file in "${tests[@]}"; do
  echo "Testing: $file"
  status=0
  npm test -- "$file" || status=$?
  if [[ -e $target || -L $target ]]; then
    echo "Found polluter: $file created $target"
    exit 1
  fi
  if (( status != 0 )); then
    echo "Inconclusive: npm test failed for $file (exit $status)." >&2
    exit 2
  fi
done

echo "All ${#tests[@]} test files passed without creating $target."
