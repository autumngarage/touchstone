#!/usr/bin/env bash
#
# tests/test-delivery-evidence.sh — the evidence gate must refuse an
# unrecorded pull request and accept a recorded one.
#
# The tiered review workflow shipped as prose and was skipped for a day by the
# person who wrote it. This test guards the layer that makes it real, so the
# gate cannot quietly stop gating.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-delivery-evidence.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-evidence.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

body() { printf '%s\n' "$1" >"$TMP_DIR/body.md"; }
accepts() { bash "$CHECK" "$TMP_DIR/body.md" >/dev/null 2>&1; }

echo "==> a fully recorded pull request is accepted"
body '## Intent
Bind the branch a PR is opened for.

## Invariants
- The reviewed head is the merged head.

## Validation
- Automated tests: full suite, pass.

## Review tier
serious

## Why this tier
Touches the merge boundary used by every project.'
if accepts; then
  pass "a recorded serious pull request passes"
else
  fail "the gate refused a fully recorded pull request"
fi

echo "==> an unedited template is absence, not evidence"
body '## Intent
<State exactly what behavior this change creates.>

## Invariants
<List the conditions that must remain true.>

## Validation
- Build: <exact command and result>

## Review tier
normal

## Why this tier
<One or two concrete sentences.>'
if accepts; then
  fail "the gate accepted an unedited template"
else
  pass "placeholder text does not satisfy the gate"
fi

echo "==> a missing or invalid tier is refused"
for tier in "" "quick" "SERIOUSLY"; do
  body "## Intent
Real intent.

## Invariants
- Something true.

## Validation
- Tests: pass.

## Review tier
$tier

## Why this tier
Because."
  if accepts; then
    fail "the gate accepted tier '$tier'"
  else
    pass "tier '$tier' is refused"
  fi
done

echo "==> trivial needs less, but still needs its reasoning"
body '## Intent
Fix a typo in a comment.

## Validation
- Lint: pass.

## Review tier
trivial

## Why this tier
Comment-only, no behavior change.'
if accepts; then
  pass "a trivial pull request needs no invariants section"
else
  fail "the gate demanded invariants from a trivial change"
fi

body '## Intent
Fix a typo.

## Validation
- Lint: pass.

## Review tier
trivial

## Why this tier
'
if accepts; then
  fail "the gate accepted a tier with no justification"
else
  pass "an unjustified tier is refused at every level"
fi

echo "==> a normal or serious change must state its invariants"
body '## Intent
Change how merges bind.

## Validation
- Tests: pass.

## Review tier
normal

## Why this tier
Contained logic change.'
if accepts; then
  fail "the gate accepted a normal change with no invariants"
else
  pass "normal requires invariants"
fi

echo "==> evasions that look like content are still absence"
for evasion in "n/a" "TBD" "todo" "-"; do
  body "## Intent
$evasion

## Invariants
- Real invariant.

## Validation
- Tests: pass.

## Review tier
normal

## Why this tier
Contained."
  if accepts; then
    fail "the gate accepted '$evasion' as intent"
  else
    pass "'$evasion' does not satisfy a required section"
  fi
done

echo "==> placeholders inside labeled bullets are still placeholders"
# "- Build: <exact command and result>" is the template, not a record of
# anything that ran.
body '## Intent
Real intent.

## Invariants
- Real invariant.

## Validation
- Build: <exact command and result>
- Automated tests: <exact command and result>

## Review tier
normal

## Why this tier
Contained.'
if accepts; then
  fail "the gate accepted labeled placeholder bullets as validation"
else
  pass "a labeled placeholder bullet does not satisfy validation"
fi

echo "==> n/a with a reason is honest and accepted"
body '## Intent
Fix prose.

## Invariants
- The rendered blocks match canon.

## Validation
- Build: n/a — documentation only, no build step
- Automated tests: full suite, pass

## Review tier
normal

## Why this tier
Contained doc change with deterministic coverage.'
if accepts; then
  pass "n/a with a recorded reason satisfies the section"
else
  fail "the gate refused an honest n/a-with-reason"
fi

echo "==> the shipped template refuses itself"
body "$(cat "$REPO_ROOT/.github/pull_request_template.md")"
if accepts; then
  fail "the unedited PR template satisfies the gate it feeds"
else
  pass "the unedited template is absence"
fi

echo "==> the gate refuses a body it cannot read"
if bash "$CHECK" "$TMP_DIR/absent.md" >/dev/null 2>&1; then
  fail "the gate passed on an unreadable body"
else
  pass "an unreadable body fails closed"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: delivery evidence is recorded, not narrated"
