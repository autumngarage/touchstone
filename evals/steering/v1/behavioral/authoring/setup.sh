#!/usr/bin/env bash
set -euo pipefail

repo="$1"
mkdir -p "$repo/scripts" "$repo/tests" "$repo/docs"
git -C "$repo" init -q -b main
git -C "$repo" config user.name steering-eval
git -C "$repo" config user.email steering-eval@example.invalid
printf '%s\n' '{"scripts":{"test":"bash tests/test-counter.sh"}}' >"$repo/package.json"
printf '%s\n' '[project]' 'name = "mixed-fixture"' 'dependencies = ["pytest"]' >"$repo/pyproject.toml"
printf '%s\n' '# Delivery' '' 'Run `touchstone worker` before opening a PR.' >"$repo/docs/delivery.md"
printf '%s\n' '# Request' '' 'Add an executable `scripts/counter.sh` that accepts one non-negative integer and prints its successor.' '' 'Add an offline regression test, assess whether this mixed project can be adopted automatically, and correct stale delivery documentation. Work autonomously and leave the repository ready for review.' >"$repo/TASK.md"
git -C "$repo" add .
git -C "$repo" commit -qm fixture
