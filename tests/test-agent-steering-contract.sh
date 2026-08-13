#!/usr/bin/env bash
#
# tests/test-agent-steering-contract.sh — guard the interpretability contract
# that lets Claude, Codex, and Gemini act as interchangeable driving CLIs.

set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-agent-steering.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

ERRORS=0
fail() {
  echo "FAIL: $*" >&2
  ERRORS=$((ERRORS + 1))
}

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    fail "expected $file to contain '$needle'"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -qF -- "$needle" "$file"; then
    fail "expected $file to NOT contain '$needle'"
  fi
}

echo "==> TOUCHSTONE.md and managed AGENTS blocks expose the driver/reviewer contract"
# TOUCHSTONE.md is the single source of truth. AGENTS.md and templates/AGENTS.md
# inline its content as a hand-maintained copy of the same block.
for file in \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "Required Delivery Workflow"
  assert_contains "$file" "Before the first edit"
  assert_contains "$file" "principles/ai-delivery-architecture.md"
  # The mechanics must be stated as raw commands, not delegated to a wrapper.
  # A steering doc that names only a script leaves an agent stranded the moment
  # the script is absent — which is exactly what the strip made true.
  assert_contains "$file" "gh pr create"
  assert_contains "$file" "--match-head-commit"
  # The silent-failure trap: a closing trailer in a commit body does nothing on
  # a squash merge, because GitHub reads the PR body. Nothing warns you.
  assert_contains "$file" "PR body"
  assert_contains "$file" "Answer every piece of PR feedback before merging"
  assert_contains "$file" "scripts/respond-review.sh"
  assert_not_contains "$file" "touchstone worker"
  assert_contains "$file" "Claim issues before implementation"
  assert_contains "$file" "bash scripts/claim-issue.sh <n>"
  assert_contains "$file" "Reconcile issues"
  assert_contains "$file" "Do not leave fixed issues open silently"
done

echo "==> Claude entry files import the TOUCHSTONE.md steering router"
# CLAUDE.md uses @TOUCHSTONE.md (Claude Code resolves @-imports transitively),
# so the contract phrases are inlined into agent context via TOUCHSTONE.md
# rather than literally appearing in CLAUDE.md. Asserting the import is the
# verification contract.
for file in \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/templates/CLAUDE.md"; do
  assert_contains "$file" "@TOUCHSTONE.md"
done

echo "==> Gemini entry files name the driving CLI role inline"
# GEMINI.md (and templates/GEMINI.md) carry the managed steering block inlined
# as a hand-maintained copy, so the contract phrases must appear directly.
for file in \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_contains "$file" "Agent Roles And Fallbacks"
  assert_contains "$file" "Driving CLI"
  assert_contains "$file" "PR-visible reviewer"
  assert_contains "$file" "review runs asynchronously against the exact pushed head"
done

echo "==> canonical git workflow describes the PR-visible review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Agentic PR Review Loop"
# The canonical doc must carry the whole mechanism in raw commands: how to open
# the PR, how to bind the review to the head being merged, and how to resolve a
# thread. These are the four gaps that made the prose unusable without a wrapper.
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "gh pr create"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "@codex review"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "--match-head-commit"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "resolveReviewThread"
# #801 review: this doc promised the gate emits `review_requested` and
# `review_result` events and that review latency is measurable from them.
# lib/events.sh and every emit call were deleted in #737, so the promise became
# false in a doc that ships to every project. A shipped principle may not
# describe a mechanism no shipped code provides — assert the absence, because
# nothing else notices when a capability is cut and its documentation is not.
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "review_requested"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "review_result"
if grep -rn "review_requested\|review_result" "$TOUCHSTONE_ROOT/principles/" >/dev/null 2>&1; then
  echo "FAIL: principles/ still promises review telemetry events that no shipped code emits" >&2
  grep -rn "review_requested\|review_result" "$TOUCHSTONE_ROOT/principles/" >&2
  ERRORS=$((ERRORS + 1))
fi
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "Codex merge review"
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" "codex exec --full-auto"

echo "==> branch guard does not feed grep -q from a pipe under pipefail"
# A producer that receives SIGPIPE after grep finds an early match can make a
# successful match report 141 under pipefail. In a branch guard that wrong
# boolean fails open. Keep every guarded predicate on an already-materialized
# value so grep alone owns the status.
pipefail_grep_hits="$(
  grep -nE '\|[[:space:]]*grep[[:space:]]+-[^|]*q' \
    "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" || true
)"
if [ -n "$pipefail_grep_hits" ]; then
  printf '%s\n' "$pipefail_grep_hits" >&2
  fail "branch-guard.sh pipes a producer into grep -q under pipefail"
fi

# Exercise the hardened path with input much larger than a typical pipe
# buffer. The fake jq consumes stdin fully before returning deterministic
# fields, so this test adds no jq dependency to the offline required suite.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
case "${2:-}" in
  '.tool_input.command // ""') printf '%s\n' 'git commit' ;;
  '.cwd // ""') printf '%s\n' "$FAKE_JQ_CWD" ;;
  '.tool_input.workdir // ""') printf '\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/jq"

GUARD_REPO="$TEST_DIR/branch-guard-repo"
mkdir -p "$GUARD_REPO"
git -C "$GUARD_REPO" init -q
git -C "$GUARD_REPO" symbolic-ref HEAD refs/heads/main
set +e
{
  printf '{"tool_name":"Bash","tool_input":{"command":"git commit '
  awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "x" }'
  printf '"}}'
} | PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_JQ_CWD="$GUARD_REPO" \
  bash "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" \
  >"$TEST_DIR/branch-guard.out" 2>"$TEST_DIR/branch-guard.err"
guard_status=$?
set -e
if [ "$guard_status" -ne 2 ]; then
  sed -n '1,20p' "$TEST_DIR/branch-guard.err" >&2
  fail "large git commit input on main must be blocked (status $guard_status)"
fi

echo "==> stacked-PR recovery uses the retained remote parent ref"
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git fetch origin'
assert_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git rebase --onto "origin/$DEFAULT" "origin/<parent-branch>" <child-branch>'
assert_not_contains "$TOUCHSTONE_ROOT/principles/git-workflow.md" \
  'git rebase --onto "$DEFAULT" <parent-branch> <child-branch>'

# Prove the documented old-base anchor works in the exact recovery state: the
# child exists, the local parent is gone, local main is stale, and the two
# remote-tracking refs hold the authoritative old and new bases.
STACK_REPO="$TEST_DIR/stacked-recovery-repo"
mkdir -p "$STACK_REPO"
git -C "$STACK_REPO" init -q
git -C "$STACK_REPO" config user.email "test@touchstone.invalid"
git -C "$STACK_REPO" config user.name "Touchstone Test"
printf 'base\n' >"$STACK_REPO/base.txt"
git -C "$STACK_REPO" add base.txt
git -C "$STACK_REPO" commit -qm "base"
git -C "$STACK_REPO" branch -M main
base_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" checkout -qb parent
printf 'parent\n' >"$STACK_REPO/parent.txt"
git -C "$STACK_REPO" add parent.txt
git -C "$STACK_REPO" commit -qm "parent"
parent_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" update-ref refs/remotes/origin/parent "$parent_oid"
git -C "$STACK_REPO" checkout -qb child
printf 'child\n' >"$STACK_REPO/child.txt"
git -C "$STACK_REPO" add child.txt
git -C "$STACK_REPO" commit -qm "child"
git -C "$STACK_REPO" checkout -q main
git -C "$STACK_REPO" cherry-pick "$parent_oid" >/dev/null
merged_main_oid="$(git -C "$STACK_REPO" rev-parse HEAD)"
git -C "$STACK_REPO" update-ref refs/remotes/origin/main "$merged_main_oid"
git -C "$STACK_REPO" checkout -q child
git -C "$STACK_REPO" branch -f main "$base_oid"
git -C "$STACK_REPO" branch -D parent >/dev/null
git -C "$STACK_REPO" rebase --onto origin/main origin/parent child >/dev/null 2>&1
if git -C "$STACK_REPO" show-ref --verify --quiet refs/heads/parent; then
  fail "stacked recovery fixture must not retain a local parent branch"
fi
if ! git -C "$STACK_REPO" show-ref --verify --quiet refs/remotes/origin/parent; then
  fail "stacked recovery fixture lost the retained remote parent ref"
fi
if [ ! -f "$STACK_REPO/child.txt" ] || [ ! -f "$STACK_REPO/parent.txt" ]; then
  fail "remote-anchor rebase did not preserve merged parent and child content"
fi
if ! git -C "$STACK_REPO" merge-base --is-ancestor origin/main child; then
  fail "stacked child was not rebased onto the fetched remote default branch"
fi

echo "==> canonical AI delivery architecture describes the PR review loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Agentic PR Review Loop"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "PR creation is not completion"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Merge is allowed only after PR-visible review and check approval"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Parallel file-writing agents use worktrees by default"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" "Touchstone does not invoke a local semantic reviewer or model router"

echo "==> active product surfaces do not reintroduce the retired model router"
# The two compatibility helpers may name retired paths solely to back them up
# and remove them; every executable/guidance surface remains prohibited.
active_router_refs="$(grep -Rin "conductor" \
  "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/README.md" \
  "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/hooks" \
  "$TOUCHSTONE_ROOT/principles" \
  "$TOUCHSTONE_ROOT/scripts" \
  "$TOUCHSTONE_ROOT/skills" \
  "$TOUCHSTONE_ROOT/templates" 2>/dev/null \
  || true)"
if [ -n "$active_router_refs" ]; then
  printf '%s\n' "$active_router_refs" >&2
  fail "retired model-router reference found on an active product surface"
fi

echo "==> Pre-implementation gate covers migration-state enumeration (issue #558)"
# The canonical checklist and its user-scoped skill must stay in sync on the
# subsystem-removal gate: states are derived from the subsystem's own
# persistence boundary (not a fixed global matrix), each supported state names
# its source of truth and fail-closed behavior, and shims are explicitly
# inert and time-bounded.
for file in \
  "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "$TOUCHSTONE_ROOT/skills/touchstone-pre-impl/SKILL.md"; do
  assert_contains "$file" "removing or replacing a subsystem"
  assert_contains "$file" "persistence boundary"
  assert_contains "$file" "source of truth"
  assert_contains "$file" "fail-closed"
  assert_contains "$file" "before the first review request"
  assert_contains "$file" "time-bounded migration shims"
  assert_contains "$file" "unmatched"
done
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "migration-state matrix"
# The principle syncs into downstream projects, where Touchstone-local PR and
# issue numbers are meaningless or point at unrelated work.
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "PR #554"
assert_not_contains "$TOUCHSTONE_ROOT/principles/pre-implementation-checklist.md" \
  "issue #558"

# Memory hygiene moved out of TOUCHSTONE.md into a routed principle to buy
# header room. Routing content out is only safe if the route itself is pinned:
# without these assertions the row, the file, or the copy in the managed blocks
# could each disappear while the whole suite stayed green, and every driver
# would silently lose the guidance.
echo "==> memory hygiene is routed, not inlined, and the route is intact"
assert_contains "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "principles/memory-hygiene.md"
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/GEMINI.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_contains "$file" "principles/memory-hygiene.md"
done
# The index downstream projects receive must list it, or they get an
# incomplete catalog immediately after bootstrap.
assert_contains "$TOUCHSTONE_ROOT/principles/README.md" "memory-hygiene.md"
# The routed doc has to actually carry the rules the router promises.
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "cached guidance, not canonical truth"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "YYYY-MM-DD"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "canonical owner"
assert_contains "$TOUCHSTONE_ROOT/principles/memory-hygiene.md" "timestamped backup"

# The purpose statement is the contract's thesis; if it is ever reduced back to
# a vague "reviewed and tested" line, the division of labour that every other
# rule depends on stops being stated anywhere.
echo "==> the three-role purpose is stated in every driver's contract"
for file in "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "$TOUCHSTONE_ROOT/AGENTS.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md" "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_contains "$file" "Humans approve plans"
  assert_contains "$file" "GitHub reviews code"
  # The gate's conditions are load-bearing: an incomplete list here has already
  # been read as licence to drop the unlisted checks. What must be stated is
  # what GitHub ACTUALLY enforces — and, separately, that review is not among
  # it. Asserting the old "trusted author / CHANGES_REQUESTED" phrasing kept
  # the contract describing a binding check that no longer exists, which is
  # the P1 the strip's own review caught: a driver reads the gate as proof an
  # unreviewed merge is impossible, and it is not.
  assert_contains "$file" "What GitHub enforces today"
  assert_contains "$file" "every review thread resolved"
  assert_contains "$file" "not an enforced gate"
done

# Touchstone's product strategy must guide this repository without leaking
# into the universal steering copied to consumer projects. Consumer agents own
# their project's product scope; they must not be routed into our portfolio plan.
echo "==> product strategy stays project-owned"
for file in "$TOUCHSTONE_ROOT/TOUCHSTONE.md" \
  "$TOUCHSTONE_ROOT/templates/AGENTS.md" \
  "$TOUCHSTONE_ROOT/templates/GEMINI.md"; do
  assert_not_contains "$file" "product-contract.md"
  assert_not_contains "$file" "Adoption is set-and-forget"
done
for file in "$TOUCHSTONE_ROOT/AGENTS.md" "$TOUCHSTONE_ROOT/CLAUDE.md" \
  "$TOUCHSTONE_ROOT/GEMINI.md"; do
  assert_contains "$file" "docs/product-contract.md"
done
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "An adopted repository remains correct if Touchstone never rewrites it again"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "not universal engineering guidance"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Adoption is compilation"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Explicit non-goals"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Deterministic offline fixtures"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "presence alone is not compliance evidence"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "Live-provider trials never"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "versioned operator journeys"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "not merely when its"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "organization ruleset required workflow"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "A consumer PR cannot"
assert_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "resolution alone cannot satisfy"
assert_not_contains "$TOUCHSTONE_ROOT/docs/product-contract.md" \
  "A small workflow calls"

# Linear owns volatile implementation order. The durable README may link to
# that plan, but naming its current issue decomposition duplicates state and
# becomes stale when work is split or reordered.
echo "==> durable overview does not duplicate Linear issue mappings"
assert_contains "$TOUCHSTONE_ROOT/README.md" "canonical Linear execution plan"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "AUT-282"
assert_not_contains "$TOUCHSTONE_ROOT/README.md" "AUT-283"

# PR #818's late exact-head review found a surviving architectural claim about
# a deleted merge helper. The path-integrity test cannot catch prose-only names,
# so pin the semantic correction directly.
echo "==> active architecture names the real review-evidence consumer"
assert_not_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "merge helper can verify"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "review-binding"
assert_contains "$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md" \
  "can evaluate from GitHub"

# Every surface that describes the merge gate must also say that review is not
# part of what GitHub enforces.
#
# This guard exists because the same defect was filed as a P1 twice on the
# strip. Fixing the Purpose paragraph left the identical claim standing in the
# three-jobs list, in git-workflow.md, and in the skill — each one enough on its
# own to convince a driver that an unreviewed merge is impossible. It is not,
# and a driver who believes it is will not check.
#
# TWO checks, because either alone is insufficient — and the first version of
# this guard shipped with only the positive half.
#
# I argued a denylist would be endless and would pass the moment someone
# phrased enforcement a new way. That is true, and it is not a reason to omit
# it: a file can carry the caveat in one paragraph and contradict it in
# another, which is exactly what shipped — README.md said "you cannot merge
# without review" twenty-seven lines above "review enforcement is advisory."
# A reader who stops at the first statement is misled, and the caveat's
# presence proved nothing about the rest of the file.
#
# So: the caveat must be PRESENT (catches a gate described afresh without it),
# AND the known enforcement phrasings must be ABSENT (catches a contradiction
# beside a compliant paragraph). Delete both in the commit that restores
# enforcement.
GATE_FILES="
$TOUCHSTONE_ROOT/TOUCHSTONE.md
$TOUCHSTONE_ROOT/AGENTS.md
$TOUCHSTONE_ROOT/GEMINI.md
$TOUCHSTONE_ROOT/templates/AGENTS.md
$TOUCHSTONE_ROOT/templates/GEMINI.md
$TOUCHSTONE_ROOT/README.md
$TOUCHSTONE_ROOT/principles/git-workflow.md
$TOUCHSTONE_ROOT/principles/ai-delivery-architecture.md
$TOUCHSTONE_ROOT/skills/touchstone-git-workflow/SKILL.md
"

echo "==> every gate description states that review is not enforced"
for file in $GATE_FILES; do
  [ -f "$file" ] || continue
  if ! grep -qiE 'not an enforced gate|not currently enforce|nothing currently enforces|nothing enforces|is advisory|not enforced|but unenforced' "$file"; then
    fail "$(basename "$file") describes the merge gate without stating that review is unenforced"
  fi
done

echo "==> no gate description claims review is enforced"
# Anchored on the specific claim: that merging without a review is prevented.
#
# POSIX ERE only. The first draft used `(is |)` — an empty alternation, which
# BSD grep rejects outright, so the whole pattern failed to compile and matched
# nothing. The probe below caught it immediately, which is the entire argument
# for writing the probe: a guard that silently matches nothing looks identical
# to a clean tree.
#
# Round 4 found the pattern was still too narrow: it keyed on the phrase
# "merge without review" and missed a whole vocabulary saying the same thing —
# an "Approval Gate" stage, "Required reviews approved" as a gate condition,
# and "merging only after the required GitHub review ... approve". Enforcement
# has more synonyms than one pattern will ever enumerate, which is the known
# weakness of the denylist half and the reason the positive half exists beside
# it. This list is a floor, not a proof.
CONTRADICTION='cannot[^.]*merge[^.]*without[^.]*review|merg[a-z]*[^.]*without[^.]*review[^.]*(blocked|prevented|refused)|without[^.]*review[^.]*cannot merge|[Aa]pproval [Gg]ate|[Rr]equired reviews approved|merging only after[^.]*review'
for file in $GATE_FILES; do
  [ -f "$file" ] || continue
  hits="$(grep -inE "$CONTRADICTION" "$file" || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "$(basename "$file") claims merging without review is prevented; it is not"
  fi
done

# Both halves must be able to fail, on this platform, or their silence is not
# evidence. The CLI-reference guard shipped without this and was broken.
probe="$TEST_DIR/gate-probe.md"
printf 'You cannot commit to main, merge without review, or bypass hooks.\n' >"$probe"
if grep -qiE "$CONTRADICTION" "$probe"; then
  echo "  OK: the contradiction pattern detects the claim it exists to catch"
else
  fail "the contradiction pattern does not match a known enforcement claim; the check above proves nothing"
fi
printf 'Review happens here.\n' >"$probe"
if grep -qiE 'not an enforced gate|not currently enforce|nothing currently enforces|nothing enforces|is advisory|not enforced|but unenforced' "$probe"; then
  fail "the caveat pattern matches text containing no caveat; the check above proves nothing"
else
  echo "  OK: the caveat pattern does not match a file lacking the caveat"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "==> FAIL: $ERRORS agent steering contract check(s) failed"
  exit 1
fi

echo ""
echo "==> PASS: agent steering contracts are explicit and testable"
