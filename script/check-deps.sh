#!/usr/bin/env bash
#
# Supply-chain guard.
#
# The compiled bytecode depends entirely on the pinned dependency revisions, so
# a submodule silently moving is a build-integrity failure, not a nuisance.
# This asserts that every submodule sits at exactly the revision recorded in
# foundry.lock, with no uncommitted or untracked content.
#
# Run locally with: make check-deps
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# Parse in the foreground so missing/malformed locks fail the command.
dependency_rows="$(python3 - <<'LOCK'
import json
import re
from pathlib import Path
lock = json.loads(Path("foundry.lock").read_text())
expected = {"lib/forge-std", "lib/openzeppelin-contracts"}
if not isinstance(lock, dict) or set(lock) != expected:
    raise SystemExit("foundry.lock must contain exactly the two reviewed dependencies")
for path in sorted(expected):
    spec = lock[path]
    tag = spec.get("tag") if isinstance(spec, dict) else None
    rev = tag.get("rev") if isinstance(tag, dict) else None
    if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise SystemExit(f"Invalid pinned revision for {path}")
    print(f"{path}\t{rev}")
LOCK
)"

echo "==> Verifying submodule revisions against foundry.lock"
while IFS=$'\t' read -r path expected; do
  if [ ! -d "$path" ]; then
    echo "  ERROR: $path is missing. Run: git submodule update --init --recursive"
    fail=1
    continue
  fi
  if [ -n "$(git -C "$path" status --porcelain --untracked-files=all)" ]; then
    echo "  ERROR: $path has uncommitted or untracked dependency content"
    fail=1
  fi
  actual="$(git -C "$path" rev-parse HEAD)"
  if [ "$actual" != "$expected" ]; then
    echo "  ERROR: $path"
    echo "         at   $actual"
    echo "         want $expected (foundry.lock)"
    fail=1
  else
    echo "  ok: $path @ ${expected:0:12}"
  fi
done <<< "$dependency_rows"

if [ "$fail" -ne 0 ]; then
  echo "FAIL: dependency verification failed."
  exit 1
fi
echo "PASS: dependencies match foundry.lock."
