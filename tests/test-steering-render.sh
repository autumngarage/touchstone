#!/usr/bin/env bash
#
# tests/test-steering-render.sh — the managed steering blocks must equal
# TOUCHSTONE.md.
#
# Ten consumer repositories were measured on 2026-08-18 and none carried a
# managed block matching this contract. Several had drifted far enough to
# instruct agents to do things the contract forbids. Nothing detected it,
# because nothing compared them. This is that comparison, for the four copies
# this repository owns.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$REPO_ROOT/scripts/render-steering.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-render-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}
pass() { echo "  ok: $*"; }

[ -x "$RENDER" ] || {
  echo "ERROR: missing or non-executable $RENDER" >&2
  exit 1
}

echo "==> Managed blocks match TOUCHSTONE.md"
if bash "$RENDER" --check >/dev/null 2>&1; then
  pass "every managed block matches the canonical contract"
else
  bash "$RENDER" --check 2>&1 | head -25 >&2
  fail "a managed block drifted; run: bash scripts/render-steering.sh"
fi

# A checker that cannot fail is decoration. Copy the repository, introduce a
# single-word divergence inside a managed block, and require detection.
echo "==> The drift check can actually fail"
WORK="$TMP_DIR/repo"
mkdir -p "$WORK/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$WORK/TOUCHSTONE.md"
cp "$REPO_ROOT/AGENTS.md" "$WORK/AGENTS.md"
cp "$REPO_ROOT/GEMINI.md" "$WORK/GEMINI.md"
cp "$RENDER" "$WORK/scripts/render-steering.sh"

# Change content inside the block only.
awk '
  /<!-- touchstone:steering:start -->/ { inside = 1 }
  /<!-- touchstone:steering:end -->/   { inside = 0 }
  inside && !done && /^## Purpose$/ { print "## Purpose DRIFTED"; done = 1; next }
  { print }
' "$WORK/AGENTS.md" >"$WORK/AGENTS.md.tmp" && mv "$WORK/AGENTS.md.tmp" "$WORK/AGENTS.md"

if grep -q "## Purpose DRIFTED" "$WORK/AGENTS.md"; then
  if bash "$WORK/scripts/render-steering.sh" --check >/dev/null 2>&1; then
    fail "the drift check passed a block containing an injected change"
  else
    pass "an injected in-block change is detected"
  fi
else
  fail "could not inject drift into the test copy; the assertion proves nothing"
fi

# Content outside the markers is the project's own and must survive rendering,
# and the render must actually repair the drift injected above -- a renderer
# that validates and reports success without installing the result would
# otherwise pass every remaining check against two unchanged, still-drifted
# files.
echo "==> Rendering repairs drift and preserves content outside the markers"
printf '\n<!-- sentinel-outside-block -->\n' >>"$WORK/GEMINI.md"
if ! bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render failed on the drifted work copy"
fi
if bash "$WORK/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  pass "the injected drift is repaired: --check passes after the render"
else
  fail "render reported success but --check still sees drift; nothing was installed"
fi
if grep -q "## Purpose DRIFTED" "$WORK/AGENTS.md"; then
  fail "the drifted line survived the render"
else
  pass "the drifted line was replaced"
fi
if grep -q "sentinel-outside-block" "$WORK/GEMINI.md"; then
  pass "text after the end marker survives a render"
else
  fail "rendering discarded content outside the managed markers"
fi

# Rendering twice must produce the same bytes, or the check would flap.
echo "==> Rendering is idempotent"
bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1 \
  || fail "second render failed on a just-rendered tree"
cp "$WORK/AGENTS.md" "$TMP_DIR/first"
bash "$WORK/scripts/render-steering.sh" >/dev/null 2>&1 \
  || fail "third render failed; idempotence not exercised"
if cmp -s "$TMP_DIR/first" "$WORK/AGENTS.md"; then
  pass "a second render changes nothing"
else
  fail "rendering is not idempotent"
fi

# A file missing its markers must fail loudly rather than being silently skipped.
echo "==> A target without markers fails closed"
grep -v "touchstone:steering" "$WORK/GEMINI.md" >"$WORK/GEMINI.md.tmp" && mv "$WORK/GEMINI.md.tmp" "$WORK/GEMINI.md"
if bash "$WORK/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "a target with no markers was accepted"
else
  pass "a target with no markers is rejected"
fi

# An indented marker satisfies a substring count but not whole-line
# extraction; the old validation accepted it and rendered a duplicate block
# with exit 0. Both modes must refuse it. Reported as P2 on PR #919.
echo "==> An indented marker is refused, not silently duplicated"
INDENTED="$TMP_DIR/indented"
mkdir -p "$INDENTED/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$INDENTED/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$INDENTED/$f"
done
cp "$RENDER" "$INDENTED/scripts/render-steering.sh"
sed 's/^<!-- touchstone:steering:start -->$/  <!-- touchstone:steering:start -->/' "$INDENTED/AGENTS.md" >"$INDENTED/AGENTS.md.tmp" && mv "$INDENTED/AGENTS.md.tmp" "$INDENTED/AGENTS.md"
before_hash="$(cksum "$INDENTED/AGENTS.md")"
if bash "$INDENTED/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render accepted an indented start marker"
else
  pass "render refuses an indented start marker"
fi
after_hash="$(cksum "$INDENTED/AGENTS.md")"
if [ "$before_hash" = "$after_hash" ]; then
  pass "the refused file was not modified"
else
  fail "render modified a file it refused"
fi
if bash "$INDENTED/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "--check accepted an indented start marker"
else
  pass "--check refuses an indented start marker"
fi

echo "==> Reversed marker order is refused"
REVERSED="$TMP_DIR/reversed"
mkdir -p "$REVERSED/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$REVERSED/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$REVERSED/$f"
done
cp "$RENDER" "$REVERSED/scripts/render-steering.sh"
awk '
  /^<!-- touchstone:steering:start -->$/ { print "<!-- touchstone:steering:end -->"; next }
  /^<!-- touchstone:steering:end -->$/   { print "<!-- touchstone:steering:start -->"; next }
  { print }
' "$REVERSED/GEMINI.md" >"$REVERSED/GEMINI.md.tmp" && mv "$REVERSED/GEMINI.md.tmp" "$REVERSED/GEMINI.md"
if bash "$REVERSED/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  fail "--check accepted an end marker before the start marker"
else
  pass "--check refuses reversed marker order"
fi

# Two byte-exactness regressions from PR #919 review. A source lacking a
# final newline used to weld the end marker to its last line -- render
# reported success, the very next --check rejected every target. And the awk
# tail extraction appended a newline to project content that ended without
# one, mutating bytes outside the markers the script promises not to touch.
echo "==> A newline-less source still renders a valid, re-checkable block"
NONL="$TMP_DIR/nonl"
mkdir -p "$NONL/scripts"
printf '%s' "$(cat "$REPO_ROOT/TOUCHSTONE.md")" >"$NONL/TOUCHSTONE.md" # strips final newline
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$NONL/$f"
done
cp "$RENDER" "$NONL/scripts/render-steering.sh"
if bash "$NONL/scripts/render-steering.sh" >/dev/null 2>&1 && bash "$NONL/scripts/render-steering.sh" --check >/dev/null 2>&1; then
  pass "render then --check both succeed without a source trailing newline"
else
  fail "a newline-less source produced a block its own --check rejects"
fi

echo "==> Rendering leaves a newline-less project tail byte-identical"
printf '\ntrailing-sentinel-no-newline' >>"$NONL/GEMINI.md" # tail now ends without newline
last_before="$(tail -c 1 "$NONL/GEMINI.md" | od -An -c | tr -d ' \n')"
if ! bash "$NONL/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render failed on a target with a newline-less tail; preservation not exercised"
fi
last_after="$(tail -c 1 "$NONL/GEMINI.md" | od -An -c | tr -d ' \n')"
if [ "$last_before" = "$last_after" ]; then
  pass "the tail's final byte is unchanged by a render"
else
  fail "render mutated the trailing byte outside the markers ($last_before -> $last_after)"
fi

# A marker line inside the canonical source would be copied into every block
# and rejected by the very next validation. Both modes must refuse up front.
echo "==> A marker line in the canonical source is refused"
MARKED="$TMP_DIR/marked"
mkdir -p "$MARKED/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$MARKED/TOUCHSTONE.md"
printf '\n<!-- touchstone:steering:end -->\n' >>"$MARKED/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$MARKED/$f"
done
cp "$RENDER" "$MARKED/scripts/render-steering.sh"
before_marked="$(cksum "$MARKED/AGENTS.md")"
if bash "$MARKED/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render accepted a source containing a marker line"
else
  pass "render refuses a source containing a marker line"
fi
if [ "$before_marked" = "$(cksum "$MARKED/AGENTS.md")" ]; then
  pass "no target was touched by the refused render"
else
  fail "the refused render modified a target"
fi

# A malformed later target must not leave earlier targets replaced: rendering
# is all-or-nothing across the target set.
echo "==> A malformed later target leaves every earlier target untouched"
PARTIAL="$TMP_DIR/partial"
mkdir -p "$PARTIAL/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$PARTIAL/TOUCHSTONE.md"
printf '\n<!-- force a drift so a real render would rewrite AGENTS.md -->\n# Drift %s\n' "$$" >>"$PARTIAL/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$PARTIAL/$f"
done
cp "$RENDER" "$PARTIAL/scripts/render-steering.sh"
grep -v '^<!-- touchstone:steering:end -->$' "$PARTIAL/GEMINI.md" >"$PARTIAL/GEMINI.md.tmp" \
  && mv "$PARTIAL/GEMINI.md.tmp" "$PARTIAL/GEMINI.md"
agents_before="$(cksum "$PARTIAL/AGENTS.md")"
if bash "$PARTIAL/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render succeeded despite a malformed final target"
else
  pass "render refuses when any target is malformed"
fi
if [ "$agents_before" = "$(cksum "$PARTIAL/AGENTS.md")" ]; then
  pass "the first target was not replaced before the refusal"
else
  fail "a malformed later target left an earlier target already replaced"
fi

# Staging failures must also be all-or-nothing: an unwritable later target
# directory discovered at copy time leaves earlier targets untouched.
echo "==> An unwritable later destination leaves every earlier target untouched"
STAGEFAIL="$TMP_DIR/stagefail"
mkdir -p "$STAGEFAIL/scripts"
cp "$REPO_ROOT/TOUCHSTONE.md" "$STAGEFAIL/TOUCHSTONE.md"
printf '\n# drift %s\n' "$$" >>"$STAGEFAIL/TOUCHSTONE.md"
for f in AGENTS.md GEMINI.md; do
  cp "$REPO_ROOT/$f" "$STAGEFAIL/$f"
done
cp "$RENDER" "$STAGEFAIL/scripts/render-steering.sh"
# Deterministic staging fault, independent of UID: permission bits do not
# stop root (the required workflow's container), so a PATH shim fails cp for
# exactly the final destination and delegates everything else.
mkdir -p "$STAGEFAIL/bin"
cat >"$STAGEFAIL/bin/cp" <<'SHIM'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    */GEMINI.md.render-steering.*)
      echo "cp: simulated staging failure for $argument" >&2
      exit 1
      ;;
  esac
done
exec /bin/cp "$@"
SHIM
chmod +x "$STAGEFAIL/bin/cp"
agents_before2="$(cksum "$STAGEFAIL/AGENTS.md")"
if PATH="$STAGEFAIL/bin:$PATH" bash "$STAGEFAIL/scripts/render-steering.sh" >/dev/null 2>&1; then
  fail "render succeeded despite a failing stage for the final destination"
else
  pass "render refuses when a destination cannot be staged"
fi
if [ "$agents_before2" = "$(cksum "$STAGEFAIL/AGENTS.md")" ]; then
  pass "no earlier target was replaced before the staging failure"
else
  fail "a staging failure left an earlier target already replaced"
fi

# ---------------------------------------------------------------------------
# Machine-level steering distribution (AUT-304). Same subject as the renderer
# -- managed blocks and the bytes around them -- so the assertions live here
# rather than in a sibling file.
INSTALL="$REPO_ROOT/scripts/touchstone-steering-install.sh"

DRIVER_FILES=(".claude/CLAUDE.md" ".codex/AGENTS.md" ".gemini/GEMINI.md")

echo "==> a clean install reaches every supported driver"
H1="$TMP_DIR/h1"
bash "$INSTALL" install --home "$H1" >/dev/null
for f in "${DRIVER_FILES[@]}"; do
  if grep -qF '## Touchstone — Shared Agent Steering' "$H1/$f" 2>/dev/null; then
    pass "$f carries the contract"
  else
    fail "$f did not receive the contract"
  fi
done

echo "==> installing twice changes nothing"
cp "$H1/.claude/CLAUDE.md" "$TMP_DIR/first"
bash "$INSTALL" install --home "$H1" >/dev/null
if cmp -s "$TMP_DIR/first" "$H1/.claude/CLAUDE.md"; then
  pass "a second install is a no-op"
else
  fail "install is not idempotent"
fi

echo "==> operator content survives, including a newline-less tail"
H2="$TMP_DIR/h2"
mkdir -p "$H2/.claude"
printf 'MY HEADER\nkeep me\n' >"$H2/.claude/CLAUDE.md"
printf 'TRAILING NO NEWLINE' >>"$H2/.claude/CLAUDE.md"
before_head="$(head -2 "$H2/.claude/CLAUDE.md")"
bash "$INSTALL" install --home "$H2" >/dev/null
if [ "$(head -2 "$H2/.claude/CLAUDE.md")" = "$before_head" ]; then
  pass "content before the block is unchanged"
else
  fail "install rewrote content above the block"
fi
# On first install the block is appended, so pre-existing content -- including
# a newline-less final line -- ends up above it, intact. What must never
# happen is losing or mangling those bytes.
if grep -qF 'TRAILING NO NEWLINE' "$H2/.claude/CLAUDE.md"; then
  pass "a newline-less final line survives the append"
else
  fail "install lost the operator's newline-less trailing content"
fi
if [ "$(grep -c 'TRAILING NO NEWLINE' "$H2/.claude/CLAUDE.md")" = 1 ]; then
  pass "the trailing content is not duplicated"
else
  fail "install duplicated the operator's trailing content"
fi

echo "==> uninstall restores the file to the operator's own content"
bash "$INSTALL" uninstall --home "$H2" >/dev/null
expected="$(printf 'MY HEADER\nkeep me\nTRAILING NO NEWLINE')"
if [ "$(cat "$H2/.claude/CLAUDE.md")" = "$expected" ]; then
  pass "uninstall leaves exactly what the operator wrote"
else
  fail "uninstall did not restore the original content"
fi

echo "==> a newline-less file survives an install/uninstall round trip byte-for-byte"
H2B="$TMP_DIR/h2b"
mkdir -p "$H2B/.claude"
printf 'MY HEADER\nno trailing newline here' >"$H2B/.claude/CLAUDE.md"
chmod 600 "$H2B/.claude/CLAUDE.md"
before_sum="$(cksum <"$H2B/.claude/CLAUDE.md")"
before_mode="$(ls -l "$H2B/.claude/CLAUDE.md" | cut -c1-10)"
bash "$INSTALL" install --home "$H2B" >/dev/null
after_mode="$(ls -l "$H2B/.claude/CLAUDE.md" | cut -c1-10)"
bash "$INSTALL" uninstall --home "$H2B" >/dev/null
if [ "$before_sum" = "$(cksum <"$H2B/.claude/CLAUDE.md")" ]; then
  pass "install then uninstall restores the exact original bytes"
else
  fail "the round trip changed the operator's file"
fi
if [ "$before_mode" = "$after_mode" ]; then
  pass "restrictive permissions survive an install"
else
  fail "install widened permissions ($before_mode -> $after_mode)"
fi

echo "==> a symlinked instruction file is written through, not replaced"
HSYM="$TMP_DIR/hsym"
SYMREAL="$TMP_DIR/symreal"
mkdir -p "$HSYM/.claude" "$SYMREAL"
printf 'DOTFILES CONTENT\n' >"$SYMREAL/claude.md"
ln -s "$SYMREAL/claude.md" "$HSYM/.claude/CLAUDE.md"
bash "$INSTALL" install --home "$HSYM" >/dev/null 2>&1
if [ -L "$HSYM/.claude/CLAUDE.md" ]; then
  pass "the symlink itself is preserved"
else
  fail "install replaced a symlink with a regular file"
fi
if grep -qF '## Touchstone — Shared Agent Steering' "$SYMREAL/claude.md"; then
  pass "the referent received the block"
else
  fail "install wrote past the symlink without updating its referent"
fi

echo "==> a multi-hop symlink chain is followed to its final referent"
HCHAIN="$TMP_DIR/hchain"
CHAINREAL="$TMP_DIR/chainreal"
mkdir -p "$HCHAIN/.gemini" "$CHAINREAL"
printf 'REAL CONTENT\n' >"$CHAINREAL/real.md"
ln -s "$CHAINREAL/real.md" "$CHAINREAL/mid.md"
ln -s "$CHAINREAL/mid.md" "$HCHAIN/.gemini/GEMINI.md"
bash "$INSTALL" install --home "$HCHAIN" >/dev/null 2>&1
if [ -L "$HCHAIN/.gemini/GEMINI.md" ] && [ -L "$CHAINREAL/mid.md" ]; then
  pass "every link in the chain survives"
else
  fail "install replaced a link in a multi-hop chain"
fi
if grep -qF '## Touchstone — Shared Agent Steering' "$CHAINREAL/real.md"; then
  pass "the final referent received the block"
else
  fail "install did not reach the end of the symlink chain"
fi

echo "==> operator content matching the separator hint does not collide"
HCOL="$TMP_DIR/hcol"
mkdir -p "$HCOL/.claude"
printf 'X\n<!-- touchstone:steering:no-trailing-newline -->\n' >"$HCOL/.claude/CLAUDE.md"
col_before="$(cksum <"$HCOL/.claude/CLAUDE.md")"
bash "$INSTALL" install --home "$HCOL" >/dev/null 2>&1
bash "$INSTALL" uninstall --home "$HCOL" >/dev/null 2>&1
if [ "$col_before" = "$(cksum <"$HCOL/.claude/CLAUDE.md")" ]; then
  pass "a line resembling install metadata is preserved verbatim"
else
  fail "install metadata collided with operator content"
fi

echo "==> uninstall distinguishes malformed markers from an absent block"
HNONE="$TMP_DIR/hnone"
mkdir -p "$HNONE/.claude"
printf 'just my notes\n' >"$HNONE/.claude/CLAUDE.md"
none_out="$(bash "$INSTALL" uninstall --home "$HNONE" 2>&1)"
none_status=$?
case "$none_out" in
  *"no managed block"*)
    [ "$none_status" -eq 0 ] \
      && pass "a file with no managed block is reported absent, not an error" \
      || fail "uninstall exited $none_status on a block-free file"
    ;;
  *) fail "uninstall did not report the block-free file: $none_out" ;;
esac
HMAL="$TMP_DIR/hmal"
mkdir -p "$HMAL/.claude"
printf 'a\n<!-- touchstone:steering:end -->\nb\n<!-- touchstone:steering:start -->\nc\n' \
  >"$HMAL/.claude/CLAUDE.md"
if bash "$INSTALL" uninstall --home "$HMAL" >/dev/null 2>&1; then
  fail "uninstall accepted malformed markers"
else
  pass "malformed markers refuse loudly rather than reporting absence"
fi

echo "==> uninstall refuses a file with malformed markers"
HBAD="$TMP_DIR/hbad"
mkdir -p "$HBAD/.gemini"
printf 'keep\n<!-- touchstone:steering:end -->\nmid\n<!-- touchstone:steering:start -->\ntail\n' \
  >"$HBAD/.gemini/GEMINI.md"
bad_before="$(cksum <"$HBAD/.gemini/GEMINI.md")"
bash "$INSTALL" uninstall --home "$HBAD" >/dev/null 2>&1 || true
if [ "$bad_before" = "$(cksum <"$HBAD/.gemini/GEMINI.md")" ]; then
  pass "reversed markers leave the file untouched"
else
  fail "uninstall mangled a file with reversed markers"
fi

echo "==> check distinguishes operator edits from real drift"
H3="$TMP_DIR/h3"
bash "$INSTALL" install --home "$H3" >/dev/null
printf '\nmy own note outside the block\n' >>"$H3/.claude/CLAUDE.md"
if bash "$INSTALL" check --home "$H3" >/dev/null 2>&1; then
  pass "an edit outside the markers is not drift"
else
  fail "check called an operator edit outside the block drift"
fi
python3 - "$H3/.codex/AGENTS.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("## Purpose", "## Purpose TAMPERED", 1))
PY
if bash "$INSTALL" check --home "$H3" >/dev/null 2>&1; then
  fail "check passed a tampered managed block"
else
  pass "a changed managed block is detected"
fi

echo "==> a missing install is reported, not silently tolerated"
H4="$TMP_DIR/h4"
mkdir -p "$H4"
if bash "$INSTALL" check --home "$H4" >/dev/null 2>&1; then
  fail "check passed a machine with no steering installed"
else
  pass "an unsteered machine fails check"
fi

echo "==> --dry-run writes nothing"
H5="$TMP_DIR/h5"
bash "$INSTALL" install --home "$H5" --dry-run >/dev/null
if [ -e "$H5/.claude/CLAUDE.md" ]; then
  fail "--dry-run created files"
else
  pass "--dry-run leaves the filesystem alone"
fi

echo "==> unknown actions and arguments fail closed"
if bash "$INSTALL" nonsense --home "$TMP_DIR/h6" >/dev/null 2>&1; then
  fail "an unknown action was accepted"
else
  pass "an unknown action is rejected"
fi
if bash "$INSTALL" install --home "$TMP_DIR/h7" --bogus >/dev/null 2>&1; then
  fail "an unknown argument was accepted"
else
  pass "an unknown argument is rejected"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "==> PASS: managed steering blocks are rendered, not hand-mirrored"
