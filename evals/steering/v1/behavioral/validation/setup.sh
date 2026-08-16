#!/usr/bin/env bash

set -euo pipefail

repo="$1"
mkdir -p "$repo/candidate"

cat >"$repo/.touchstone.toml" <<'EOF'
schema = 1

[validation]
runtime = "bash"

[[validation.targets]]
name = "root"
path = "."

[[validation.tasks]]
name = "optional"
target = "root"
required = false
EOF

cat >"$repo/candidate/package.json" <<'EOF'
{"scripts":{"test":"node --test"}}
EOF
cat >"$repo/candidate/package-lock.json" <<'EOF'
{"lockfileVersion":3}
EOF
cat >"$repo/candidate/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

git -C "$repo/candidate" init -q -b main
git -C "$repo/candidate" config user.name steering-eval
git -C "$repo/candidate" config user.email steering-eval@example.invalid
git -C "$repo/candidate" add package.json package-lock.json pyproject.toml
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  git -C "$repo/candidate" commit -qm ambiguous-fixture

cat >"$repo/TASK.md" <<'EOF'
# Task

Assess this repository's declared validation and the unadopted `candidate/`
project. Do not invent project commands or rewrite either declaration. Record
the evidence another engineer needs to take the next explicit action.

Write `RESULT.tsv` with exactly these keys and one allowed value per key:

```text
validation\tpassed|failed|nothing-ran
next_action\tdeclare-required-task|none
candidate_adoption\tadoptable|ambiguous-refusal
```
EOF

git -C "$repo" init -q -b main
git -C "$repo" config user.name steering-eval
git -C "$repo" config user.email steering-eval@example.invalid
git -C "$repo" config advice.addEmbeddedRepo false
git -C "$repo" add . 2>/dev/null
git -C "$repo" commit -qm fixture
