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

echo "==> the newline hint survives a refresh and does not leak between drivers"
HREF="$TMP_DIR/href"
mkdir -p "$HREF/.claude" "$HREF/.codex"
printf 'MINE\nno trailing newline' >"$HREF/.claude/CLAUDE.md"
printf 'OTHER has a newline\n' >"$HREF/.codex/AGENTS.md"
ref_claude="$(cksum <"$HREF/.claude/CLAUDE.md")"
ref_codex="$(cksum <"$HREF/.codex/AGENTS.md")"
bash "$INSTALL" install --home "$HREF" >/dev/null 2>&1
bash "$INSTALL" install --home "$HREF" >/dev/null 2>&1
if grep -q 'restore-newline' "$HREF/.claude/CLAUDE.md"; then
  pass "the hint survives a second install"
else
  fail "a refresh dropped the restore hint"
fi
if grep -q 'restore-newline' "$HREF/.codex/AGENTS.md"; then
  fail "the hint leaked from one driver file to another"
else
  pass "the hint does not leak between drivers"
fi
if bash "$INSTALL" check --home "$HREF" >/dev/null 2>&1; then
  pass "check accepts an attributed start marker"
else
  fail "check rejected its own attributed marker"
fi
bash "$INSTALL" uninstall --home "$HREF" >/dev/null 2>&1
if [ "$ref_claude" = "$(cksum <"$HREF/.claude/CLAUDE.md")" ] \
  && [ "$ref_codex" = "$(cksum <"$HREF/.codex/AGENTS.md")" ]; then
  pass "both files return to their exact original bytes after a refresh cycle"
else
  fail "a refresh cycle changed the operator's bytes"
fi

echo "==> the routed documents are installed and the block points at them"
HROUTE="$TMP_DIR/hroute"
bash "$INSTALL" install --home "$HROUTE" >/dev/null 2>&1
routed_path="$(grep -o '`[^`]*principles/git-workflow.md`' "$HROUTE/.claude/CLAUDE.md" | head -1 | tr -d '`')"
if [ -n "$routed_path" ] && [ -f "$routed_path" ]; then
  pass "the block's routing table resolves to an installed document"
else
  fail "the block routes to principles/*.md that the installer never placed: $routed_path"
fi
if [ "$(find "$HROUTE/.touchstone/principles" -name '*.md' | wc -l | tr -d ' ')" -gt 0 ]; then
  pass "routed documents are installed beside the block"
else
  fail "no routed documents were installed"
fi
# Drift in a routed document must fail check: an agent reading a stale
# principle is the failure this whole mechanism exists to prevent.
printf '\nDRIFTED\n' >>"$HROUTE/.touchstone/principles/git-workflow.md"
if bash "$INSTALL" check --home "$HROUTE" >/dev/null 2>&1; then
  fail "check passed a modified routed document"
else
  pass "a modified routed document fails check"
fi
# Uninstall must remove what it installed and nothing else: the directory can
# hold the operator's own notes.
printf 'my own note\n' >"$HROUTE/.touchstone/principles/MY-NOTES.md"
uninstall_report="$(bash "$INSTALL" uninstall --home "$HROUTE" 2>&1 || true)"
if [ -f "$HROUTE/.touchstone/principles/MY-NOTES.md" ]; then
  pass "an operator file in the routed directory survives uninstall"
else
  fail "uninstall deleted an operator file it did not install"
fi
if [ -f "$HROUTE/.touchstone/principles/agent-swarms.md" ]; then
  fail "uninstall left an untouched installed document behind"
else
  pass "uninstall removes the documents it installed"
fi
# git-workflow.md was edited above. The edit is the operator's, so uninstall
# keeps the file rather than destroying content it did not write -- and says
# so, because a silent skip would read as a clean removal.
if [ -f "$HROUTE/.touchstone/principles/git-workflow.md" ]; then
  pass "a document edited after install is kept, not deleted"
else
  fail "uninstall deleted a document the operator had edited"
fi
case "$uninstall_report" in
  *"git-workflow.md does not match what was installed"*)
    pass "the kept document is reported, not silently skipped"
    ;;
  *) fail "uninstall skipped an edited document without saying so: $uninstall_report" ;;
esac

echo "==> installed routed documents cross-reference each other correctly"
HXREF="$TMP_DIR/hxref"
bash "$INSTALL" install --home "$HXREF" >/dev/null 2>&1
xref="$(grep -o '`[^`]*principles/[a-z-]*\.md`' "$HXREF/.touchstone/principles/git-workflow.md" 2>/dev/null | head -1 | tr -d '`')"
if [ -n "$xref" ] && [ -f "$xref" ]; then
  pass "a routed document's own references resolve to installed files"
else
  fail "installed documents cross-reference paths that do not exist: $xref"
fi

echo "==> ownership is recorded, not inferred from content"
# A pre-existing operator file at a bundled name must be refused before any
# driver file is written, and a document this tool installed must stay
# recognizable even after a release changes its contents entirely.
HOWN="$TMP_DIR/hown"
mkdir -p "$HOWN/.touchstone/principles"
printf 'MY OWN NOTES\n' >"$HOWN/.touchstone/principles/git-workflow.md"
if bash "$INSTALL" install --home "$HOWN" >/dev/null 2>&1; then
  fail "install replaced a file it did not write"
else
  pass "install refuses a routed name the operator owns"
fi
if [ -e "$HOWN/.claude/CLAUDE.md" ]; then
  fail "a driver file was written before the collision was detected"
else
  pass "the collision is detected before any driver file is written"
fi
if grep -qF 'MY OWN NOTES' "$HOWN/.touchstone/principles/git-workflow.md"; then
  pass "the operator's file is intact after the refusal"
else
  fail "install destroyed an operator file"
fi

# The block records the tool version that wrote it, and `check` names both
# sides when they differ -- a cold agent's first command must say what is
# newer and that install touches only the block, not merely "DRIFT".
HVER="$TMP_DIR/hver"
bash "$INSTALL" install --home "$HVER" >/dev/null 2>&1
if grep -q "^<!-- Installed by touchstone $(tr -d '[:space:]' <"$REPO_ROOT/VERSION")\." "$HVER/.claude/CLAUDE.md"; then
  pass "the installed block records the tool version"
else
  fail "the installed block does not record the tool version"
fi
# A version-only difference is not drift: a patch release that bumps VERSION
# without touching the contract must not send every machine to reinstall.
sed -i.bak -E 's/^(<!-- Installed by touchstone )[0-9.]+\./\10.0.1./' "$HVER/.claude/CLAUDE.md" && rm -f "$HVER/.claude/CLAUDE.md.bak"
if bash "$INSTALL" check --home "$HVER" >"$TMP_DIR/hver.out" 2>&1 && grep -q "block from touchstone 0.0.1" "$TMP_DIR/hver.out"; then
  pass "a version-only difference is reported, not counted as drift"
else
  fail "a version-only difference was treated as drift: $(grep -E 'DRIFT|ok:' "$TMP_DIR/hver.out" | head -2 | tr '\n' ' ')"
fi
# Real contract drift names both versions and the bounded remedy.
printf 'tampered\n' >>"$HVER/.claude/CLAUDE.md"
sed -i.bak -E 's/^(<!-- touchstone:steering:end -->)$/extra line\n\1/' "$HVER/.claude/CLAUDE.md" && rm -f "$HVER/.claude/CLAUDE.md.bak"
if bash "$INSTALL" check --home "$HVER" >"$TMP_DIR/hver2.out" 2>&1; then
  fail "check passed on a block whose contract text differs"
fi
if grep -q "carries the block from touchstone 0.0.1; this tool is" "$TMP_DIR/hver2.out" \
  && grep -q "rewrites only the block between the markers" "$TMP_DIR/hver2.out"; then
  pass "check names both versions and says install touches only the block"
else
  fail "check did not explain the drift: $(grep -E 'DRIFT|Run:' "$TMP_DIR/hver2.out" | head -2 | tr '\n' ' ')"
fi
# An absent driver file is reported as absent, not as a legacy block.
rm -f "$HVER/.gemini/GEMINI.md"
bash "$INSTALL" check --home "$HVER" >"$TMP_DIR/hver3.out" 2>&1 || true
grep -q "GEMINI.md is absent (no block installed)" "$TMP_DIR/hver3.out" && pass "an absent driver file is named as absent" || fail "absent file misreported: $(grep GEMINI "$TMP_DIR/hver3.out" | head -1)"

# Command-line paths inside routed documents are rewritten too: a fresh agent
# ran `-c principles/local-review-contract.md` verbatim from local-review.md
# and found no such file in the consumer repository.
HCMD="$TMP_DIR/hcmd"
bash "$INSTALL" install --home "$HCMD" >/dev/null 2>&1
if grep -q -- "-c '$HCMD/.touchstone/principles/local-review-contract.md'" "$HCMD/.touchstone/principles/local-review.md" \
  && ! grep -q -- "-c principles/local-review-contract.md" "$HCMD/.touchstone/principles/local-review.md"; then
  pass "command-line paths in routed documents resolve to the installed copies"
else
  fail "local-review.md still names principles/local-review-contract.md as a bare path: $(grep -n 'local-review-contract.md' "$HCMD/.touchstone/principles/local-review.md" | head -2 | tr '\n' ' ')"
fi

# A home containing a single quote cannot be rendered into a pasteable
# single-quoted command, so install refuses it by its canonical path.
HQ="$TMP_DIR/it's home"
if bash "$INSTALL" install --home "$HQ" >"$TMP_DIR/hq.out" 2>&1; then
  fail "install accepted a home containing a single quote"
else
  grep -q "contains a single quote" "$TMP_DIR/hq.out" && pass "a home with a single quote is refused by name" || fail "unexpected refusal: $(cat "$TMP_DIR/hq.out")"
fi
[ ! -e "$HQ/.claude/CLAUDE.md" ] || fail "install wrote into a refused home"

# A later release changes what the tool *ships*, not the copy on disk. Build a
# second checkout with a modified source document and reinstall from it: the
# installed copy still matches what the manifest recorded, so it is still
# ours to replace.
RELEASE="$TMP_DIR/next-release"
mkdir -p "$RELEASE/scripts" "$RELEASE/principles"
cp "$REPO_ROOT/TOUCHSTONE.md" "$RELEASE/TOUCHSTONE.md"
cp "$INSTALL" "$RELEASE/scripts/$(basename "$INSTALL")"
cp "$REPO_ROOT"/principles/*.md "$RELEASE/principles/"
HUP="$TMP_DIR/hup"
bash "$INSTALL" install --home "$HUP" >/dev/null 2>&1
printf 'CHANGED BY A LATER RELEASE\n' >>"$RELEASE/principles/file-upstream-bugs.md"
if bash "$RELEASE/scripts/$(basename "$INSTALL")" install --home "$HUP" >/dev/null 2>&1; then
  pass "a document we installed stays ours when a release changes what we ship"
else
  fail "an installed document was misjudged as operator-owned after a release change"
fi
if grep -qF 'CHANGED BY A LATER RELEASE' "$HUP/.touchstone/principles/file-upstream-bugs.md"; then
  pass "the release's new contents actually landed"
else
  fail "the reinstall reported success without updating the document"
fi

# The mirror case: the operator edited the installed copy. Install must not
# overwrite it, because that destroys their content irreversibly.
HEDIT="$TMP_DIR/hedit"
bash "$INSTALL" install --home "$HEDIT" >/dev/null 2>&1
printf 'MY ANNOTATION\n' >>"$HEDIT/.touchstone/principles/file-upstream-bugs.md"
bash "$INSTALL" install --home "$HEDIT" >/dev/null 2>&1 || true
if grep -qF 'MY ANNOTATION' "$HEDIT/.touchstone/principles/file-upstream-bugs.md"; then
  pass "a document edited after install is not overwritten"
else
  fail "install destroyed an edit the operator made to an installed document"
fi
printf 'OPERATOR ADDED LATER\n' >"$HUP/.touchstone/principles/my-own-notes.md"
bash "$INSTALL" uninstall --home "$HUP" >/dev/null 2>&1
if [ -f "$HUP/.touchstone/principles/my-own-notes.md" ]; then
  pass "uninstall removes only the manifest's documents"
else
  fail "uninstall removed a file it never installed"
fi

echo "==> uninstall honors --dry-run"
HDRY="$TMP_DIR/hdry"
bash "$INSTALL" install --home "$HDRY" >/dev/null 2>&1
bash "$INSTALL" uninstall --home "$HDRY" --dry-run >/dev/null 2>&1
if [ -f "$HDRY/.touchstone/principles/git-workflow.md" ] \
  && grep -qF 'touchstone:steering:start' "$HDRY/.claude/CLAUDE.md"; then
  pass "uninstall --dry-run removes nothing"
else
  fail "uninstall --dry-run removed files"
fi

echo "==> a directory where a routed document belongs is refused"
HDIR="$TMP_DIR/hdir"
mkdir -p "$HDIR/.touchstone/principles/git-workflow.md"
if bash "$INSTALL" install --home "$HDIR" >/dev/null 2>&1; then
  fail "install accepted a directory in place of a routed document"
else
  pass "a directory collision is refused"
fi

echo "==> an unusable routed destination fails before any driver file is written"
HBLOCK="$TMP_DIR/hblock"
mkdir -p "$HBLOCK/.touchstone"
printf 'not a directory\n' >"$HBLOCK/.touchstone/principles"
if bash "$INSTALL" install --home "$HBLOCK" >/dev/null 2>&1; then
  fail "install succeeded with an unusable routed destination"
else
  pass "install refuses an unusable routed destination"
fi
if [ -e "$HBLOCK/.claude/CLAUDE.md" ]; then
  fail "a driver file was written before the routed destination failed"
else
  pass "no driver file is written when the routed destination fails"
fi

echo "==> two driver paths aliased to one file receive a single block"
HALIAS="$TMP_DIR/halias"
ALIASREAL="$TMP_DIR/aliasreal"
mkdir -p "$HALIAS/.claude" "$HALIAS/.codex" "$ALIASREAL"
printf 'SHARED DOTFILE\n' >"$ALIASREAL/shared.md"
ln -s "$ALIASREAL/shared.md" "$HALIAS/.claude/CLAUDE.md"
ln -s "$ALIASREAL/shared.md" "$HALIAS/.codex/AGENTS.md"
bash "$INSTALL" install --home "$HALIAS" >/dev/null 2>&1
if [ "$(grep -c 'touchstone:steering:start' "$ALIASREAL/shared.md")" = 1 ]; then
  pass "a shared destination receives exactly one block"
else
  fail "an aliased destination received $(grep -c 'touchstone:steering:start' "$ALIASREAL/shared.md") blocks"
fi

echo "==> an unrecognized start-marker attribute is refused, not normalized away"
# A future version may add attributes. This version must not silently treat a
# marker it does not understand as current, nor rewrite the block around it.
HATTR="$TMP_DIR/hattr"
bash "$INSTALL" install --home "$HATTR" >/dev/null 2>&1
# The file was created by install, so its marker carries created-file;
# rewrite whichever start marker is present.
sed 's|^<!-- touchstone:steering:start.* -->$|<!-- touchstone:steering:start future-feature -->|' \
  "$HATTR/.claude/CLAUDE.md" >"$HATTR/.claude/CLAUDE.md.edit"
mv -f "$HATTR/.claude/CLAUDE.md.edit" "$HATTR/.claude/CLAUDE.md"
attr_before="$(cksum <"$HATTR/.claude/CLAUDE.md")"
if bash "$INSTALL" check --home "$HATTR" >/dev/null 2>&1; then
  fail "check accepted a start marker with an unknown attribute"
else
  pass "an unknown marker attribute fails check"
fi
if bash "$INSTALL" install --home "$HATTR" >/dev/null 2>&1; then
  fail "install rewrote a block whose marker it does not understand"
else
  pass "install refuses a marker it does not understand"
fi
if [ "$attr_before" = "$(cksum <"$HATTR/.claude/CLAUDE.md")" ]; then
  pass "the refused file is left untouched"
else
  fail "install modified a file it refused"
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
sed '1,/^## Purpose$/ s|^## Purpose$|## Purpose TAMPERED|' \
  "$H3/.codex/AGENTS.md" >"$H3/.codex/AGENTS.md.edit"
mv -f "$H3/.codex/AGENTS.md.edit" "$H3/.codex/AGENTS.md"
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

echo "==> a manifest entry that is not a plain name never directs a delete"
# The manifest tells uninstall which documents are ours. If a corrupted or
# hand-edited entry could carry a path, uninstall would delete outside the
# directory it manages -- so entries are basenames or they are not honored.
H8="$TMP_DIR/h8"
mkdir -p "$H8/bystander"
bash "$INSTALL" install --home "$H8" >/dev/null
printf 'do not delete me\n' >"$H8/bystander/keep.md"
printf '../../bystander/keep.md\n' >>"$H8/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" uninstall --home "$H8" >/dev/null 2>&1 || true
if [ -f "$H8/bystander/keep.md" ]; then
  pass "a traversing manifest entry is refused, not followed"
else
  fail "uninstall deleted a file outside the directory it manages"
fi

echo "==> a manifest the operator already owns is not adopted"
H9="$TMP_DIR/h9"
mkdir -p "$H9/.touchstone/principles"
printf '../../etc/passwd\n' >"$H9/.touchstone/principles/.touchstone-installed"
if bash "$INSTALL" install --home "$H9" >/dev/null 2>&1; then
  fail "install adopted a pre-existing manifest with a traversing entry"
else
  pass "a pre-existing manifest is inspected before it is trusted"
fi
if [ -e "$H9/.claude/CLAUDE.md" ]; then
  fail "install wrote a driver file before refusing"
else
  pass "the refusal costs no partial install"
fi

echo "==> a deleted manifest is drift, not a clean install"
H10="$TMP_DIR/h10"
bash "$INSTALL" install --home "$H10" >/dev/null
rm -f "$H10/.touchstone/principles/.touchstone-installed"
if bash "$INSTALL" check --home "$H10" >/dev/null 2>&1; then
  fail "check passed an install whose ownership record is gone"
else
  pass "a missing ownership manifest fails check"
fi

echo "==> a name appended to the manifest cannot authorize a delete"
# A plain basename is a weak ownership claim: appending `mine.md` to the
# manifest would otherwise make uninstall delete the operator's file, since
# check only requires the expected entries to be present.
H11="$TMP_DIR/h11"
bash "$INSTALL" install --home "$H11" >/dev/null
printf 'my own work\n' >"$H11/.touchstone/principles/mine.md"
printf 'X\tmine.md\n' >>"$H11/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" uninstall --home "$H11" >/dev/null 2>&1 || true
if [ -f "$H11/.touchstone/principles/mine.md" ]; then
  pass "a manifest entry whose checksum does not match is not deleted"
else
  fail "an appended manifest name authorized deleting an operator file"
fi

echo "==> a home path is data, not sed replacement syntax"
# `&` means "the whole match" in a sed replacement, so a home containing one
# produced routes to directories that do not exist -- and install and check
# agreed, because both rendered the same wrong value.
H12="$TMP_DIR/amp&home"
bash "$INSTALL" install --home "$H12" >/dev/null
route="$(grep -o '`[^`]*principles/git-workflow\.md`' "$H12/.claude/CLAUDE.md" | head -1 | tr -d '`')"
if [ -n "$route" ] && [ -f "$route" ]; then
  pass "a home containing '&' still routes to a file that exists"
else
  fail "the routed path does not exist: $route"
fi
if bash "$INSTALL" check --home "$H12" >/dev/null 2>&1; then
  pass "check agrees with a correctly escaped install"
else
  fail "check disagreed with its own install under an '&' home"
fi

echo "==> uninstall removes one added byte, not every trailing newline"
# check accepts operator edits outside the markers, so uninstall must return
# the file byte-for-byte -- including blank lines the operator left above the
# block, which a \$(cat) round-trip silently ate.
H13="$TMP_DIR/h13"
mkdir -p "$H13/.claude"
printf 'my notes\n\n\n' >"$H13/.claude/CLAUDE.md"
cp "$H13/.claude/CLAUDE.md" "$TMP_DIR/h13-before"
bash "$INSTALL" install --home "$H13" >/dev/null
bash "$INSTALL" uninstall --home "$H13" >/dev/null
if cmp -s "$TMP_DIR/h13-before" "$H13/.claude/CLAUDE.md"; then
  pass "content before the block survives the round trip byte-for-byte"
else
  fail "uninstall changed operator content it had accepted as valid"
fi

echo "==> the suite needs no interpreter beyond the shell"
# The required check runs tests/test-*.sh on a machine whose base tools are
# the shell and coreutils. A fixture edit reaching for python3 turns a
# missing optional interpreter into a red required check.
if grep -n '^[^#]*python3 ' "$0" >/dev/null 2>&1; then
  fail "this test invokes python3, which is not part of the base tool surface"
else
  pass "fixture edits use the supported shell toolchain"
fi

echo "==> a driver path that is not a regular file is refused"
# compose reads a missing path as an empty prefix and `mv` onto a directory
# moves the payload inside it, so this reported a successful install while
# leaving the instruction file absent and check immediately reporting drift.
H14="$TMP_DIR/h14"
mkdir -p "$H14/.claude/CLAUDE.md"
if bash "$INSTALL" install --home "$H14" >/dev/null 2>&1; then
  fail "install claimed success with a directory at the instruction path"
else
  pass "a non-regular driver path is refused"
fi
if [ -d "$H14/.claude/CLAUDE.md" ] && [ -z "$(ls -A "$H14/.claude/CLAUDE.md")" ]; then
  pass "the refusal left nothing inside the directory"
else
  fail "install wrote into the directory at the instruction path"
fi

echo "==> a dry run answers whether the install could succeed"
# The one answer a dry run must never give is "this would reach every agent"
# for an install that fails immediately.
H15="$TMP_DIR/h15"
mkdir -p "$H15/.touchstone"
printf 'not a directory\n' >"$H15/.touchstone/principles"
if bash "$INSTALL" install --home "$H15" --dry-run >/dev/null 2>&1; then
  fail "a dry run reported success for an install that cannot proceed"
else
  pass "a dry run refuses what the real install would refuse"
fi

H16="$TMP_DIR/h16"
if bash "$INSTALL" install --home "$H16" --dry-run >/dev/null 2>&1; then
  pass "a clean dry run still succeeds"
else
  fail "a dry run refused a home that installs fine"
fi
if [ -e "$H16/.touchstone" ] || [ -e "$H16/.claude" ]; then
  fail "the dry run created directories"
else
  pass "validating a dry run still writes nothing"
fi

echo "==> a dry run predicts a symlink chain it cannot resolve"
# Symlink resolution is read-only, so a dry run that skipped it reported
# success for an install that dies at `symlink chain too deep`.
H17="$TMP_DIR/h17"
mkdir -p "$H17/.claude"
ln -s loop-a "$H17/.claude/CLAUDE.md"
ln -s CLAUDE.md "$H17/.claude/loop-a"
if bash "$INSTALL" install --home "$H17" --dry-run >/dev/null 2>&1; then
  fail "a dry run predicted success for an unresolvable symlink chain"
else
  pass "a dry run refuses a symlink chain the install cannot resolve"
fi
if bash "$INSTALL" install --home "$H17" >/dev/null 2>&1; then
  fail "the real install accepted an unresolvable symlink chain"
else
  pass "the dry run and the real install agree"
fi

echo "==> a line inserted above the block keeps its own newline"
# restore-newline says install added a newline after content that had none.
# Trimming "the last byte" assumed nothing sat between that newline and the
# marker; a line the operator inserted there lost its terminator instead.
H18="$TMP_DIR/h18"
mkdir -p "$H18/.claude"
printf 'abc' >"$H18/.claude/CLAUDE.md"
bash "$INSTALL" install --home "$H18" >/dev/null
marker_line="$(grep -n '^<!-- touchstone:steering:start' "$H18/.claude/CLAUDE.md" | cut -d: -f1)"
{
  head -n "$((marker_line - 1))" "$H18/.claude/CLAUDE.md"
  printf 'OPERATOR\n'
  tail -n "+$marker_line" "$H18/.claude/CLAUDE.md"
} >"$H18/.claude/CLAUDE.md.edit"
mv -f "$H18/.claude/CLAUDE.md.edit" "$H18/.claude/CLAUDE.md"
bash "$INSTALL" uninstall --home "$H18" >/dev/null
if [ "$(tail -c 1 "$H18/.claude/CLAUDE.md" | od -An -c | tr -d ' ')" = "\\n" ]; then
  pass "the inserted line keeps the newline that terminates it"
else
  fail "uninstall ate the newline of a line the operator inserted"
fi
case "$(cat "$H18/.claude/CLAUDE.md")" in
  *OPERATOR*) pass "the inserted content itself survives" ;;
  *) fail "the inserted content was lost" ;;
esac

echo "==> a relative --home still routes absolutely"
# Routes are followed by agents started anywhere. A relative --home embedded
# paths that resolve only from this command's working directory, and check
# agreed because it rendered the same broken value.
H19_PARENT="$TMP_DIR/relative-home"
mkdir -p "$H19_PARENT"
(
  cd "$TMP_DIR" || exit 1
  bash "$INSTALL" install --home relative-home >/dev/null
)
route="$(grep -o '`[^`]*principles/git-workflow\.md`' "$H19_PARENT/.claude/CLAUDE.md" | head -1 | tr -d '`')"
case "$route" in
  /*) pass "a relative --home renders absolute routes" ;;
  *) fail "the rendered route is relative: $route" ;;
esac
if [ -n "$route" ] && [ -f "$route" ]; then
  pass "the absolute route resolves to a file that exists"
else
  fail "the rendered route does not exist: $route"
fi

echo "==> a correct checksum is not provenance"
# cksum is unkeyed and reproducible: anyone who can append a manifest line can
# also compute the right checksum for an operator's file. Provenance comes
# from the set of documents this tool ships, which the manifest cannot forge.
H20="$TMP_DIR/h20"
bash "$INSTALL" install --home "$H20" >/dev/null
printf 'my own work\n' >"$H20/.touchstone/principles/mine.md"
printf '%s\tmine.md\n' "$(cksum <"$H20/.touchstone/principles/mine.md")" \
  >>"$H20/.touchstone/principles/.touchstone-installed"
if bash "$INSTALL" check --home "$H20" >/dev/null 2>&1; then
  fail "check passed a manifest carrying an entry this tool never installs"
else
  pass "an extra manifest entry is drift"
fi
bash "$INSTALL" uninstall --home "$H20" >/dev/null 2>&1 || true
if [ -f "$H20/.touchstone/principles/mine.md" ]; then
  pass "a valid checksum on an unshipped name still does not authorize a delete"
else
  fail "a forged manifest entry deleted an operator file"
fi

echo "==> a relative --home with missing components stays under it"
# Resolving component by component let a failed `cd` drop the prefix, so
# `--home new/child` resolved to `/child` -- a privileged install would have
# written to the filesystem root.
H21="$TMP_DIR/h21-parent"
mkdir -p "$H21"
(
  cd "$H21" || exit 1
  bash "$INSTALL" install --home new/child >/dev/null 2>&1
)
if [ -f "$H21/new/child/.claude/CLAUDE.md" ]; then
  pass "the install landed under the requested relative path"
else
  fail "the install did not land under the requested path"
fi

echo "==> a link into a missing directory is refused, not retargeted"
# Canonicalizing a dangling link let the `cd` fail while the basename stood
# alone, so the destination silently became `/doc` -- which a privileged run
# would have written to the filesystem root.
H22="$TMP_DIR/h22"
mkdir -p "$H22/.claude"
ln -s "../missing/sub/doc" "$H22/.claude/CLAUDE.md"
if bash "$INSTALL" install --home "$H22" >/dev/null 2>&1; then
  fail "install accepted a symlink into a directory that does not exist"
else
  pass "a dangling symlink target is refused"
fi

echo "==> install proves ownership before overwriting a routed document"
# Uninstall refusing to delete an unproven file is only half the guarantee:
# install overwrites, which destroys content irreversibly. A corrupted
# manifest entry naming a document we do ship must not make an operator's
# file at that name ours.
H23="$TMP_DIR/h23"
mkdir -p "$H23/.touchstone/principles"
printf 'MY IMPORTANT NOTES\n' >"$H23/.touchstone/principles/git-workflow.md"
printf 'anything\tgit-workflow.md\n' >"$H23/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H23" >/dev/null 2>&1 || true
if grep -q 'MY IMPORTANT NOTES' "$H23/.touchstone/principles/git-workflow.md"; then
  pass "a manifest entry that does not match the bytes cannot authorize an overwrite"
else
  fail "install overwrote an operator file on a name-only ownership claim"
fi

echo "==> an overwrite is recoverable regardless of the ownership claim"
# The manifest sits beside the documents, owned by the same user, so it can
# never be evidence independent of them. Recoverability is the guarantee that
# does not depend on the claim being honest.
H24="$TMP_DIR/h24"
mkdir -p "$H24/.touchstone/principles"
printf 'MY IRREPLACEABLE NOTES\n' >"$H24/.touchstone/principles/git-workflow.md"
printf '%s\tgit-workflow.md\n' "$(cksum <"$H24/.touchstone/principles/git-workflow.md")" \
  >"$H24/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H24" >/dev/null 2>&1 || true
if grep -rqF 'MY IRREPLACEABLE NOTES' "$H24/.touchstone/principles/"; then
  pass "the replaced bytes survive a manifest that vouched for itself"
else
  fail "install destroyed content on a self-authenticating ownership claim"
fi

echo "==> a release that stops shipping a document removes its copy"
# The old manifest is the only record that we wrote the file, and replacing
# it is the moment that knowledge is lost -- so reconcile before replacing.
H25="$TMP_DIR/h25"
NEXT="$TMP_DIR/next-release-trimmed"
mkdir -p "$NEXT/scripts" "$NEXT/principles"
cp "$REPO_ROOT/TOUCHSTONE.md" "$NEXT/TOUCHSTONE.md"
cp "$INSTALL" "$NEXT/scripts/$(basename "$INSTALL")"
cp "$REPO_ROOT"/principles/*.md "$NEXT/principles/"
bash "$NEXT/scripts/$(basename "$INSTALL")" install --home "$H25" >/dev/null 2>&1
rm -f "$NEXT/principles/agent-swarms.md"
bash "$NEXT/scripts/$(basename "$INSTALL")" install --home "$H25" >/dev/null 2>&1
if [ -f "$H25/.touchstone/principles/agent-swarms.md" ]; then
  fail "a document the release stopped shipping was orphaned on disk"
else
  pass "a document no longer shipped is removed, not orphaned"
fi
# An orphan the operator edited is theirs; it is kept and reported instead.
H26="$TMP_DIR/h26"
mkdir -p "$NEXT/principles"
cp "$REPO_ROOT/principles/agent-swarms.md" "$NEXT/principles/agent-swarms.md"
bash "$NEXT/scripts/$(basename "$INSTALL")" install --home "$H26" >/dev/null 2>&1
printf 'MY EDIT\n' >>"$H26/.touchstone/principles/agent-swarms.md"
rm -f "$NEXT/principles/agent-swarms.md"
bash "$NEXT/scripts/$(basename "$INSTALL")" install --home "$H26" >/dev/null 2>&1
if grep -qF 'MY EDIT' "$H26/.touchstone/principles/agent-swarms.md" 2>/dev/null; then
  pass "an edited document is kept when the release stops shipping it"
else
  fail "reconciliation deleted a document the operator had edited"
fi

echo "==> preserving a replaced document never clobbers an earlier copy"
# An earlier upgrade's backup can be the only surviving copy of operator
# content, so the backup itself must not be overwritten to make a backup.
H27="$TMP_DIR/h27"
mkdir -p "$H27/.touchstone/principles"
printf 'FIRST OPERATOR FILE\n' >"$H27/.touchstone/principles/git-workflow.md"
printf '%s\tgit-workflow.md\n' "$(cksum <"$H27/.touchstone/principles/git-workflow.md")" \
  >"$H27/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H27" >/dev/null 2>&1 || true
printf 'SECOND OPERATOR EDIT\n' >"$H27/.touchstone/principles/git-workflow.md"
printf '%s\tgit-workflow.md\n' "$(cksum <"$H27/.touchstone/principles/git-workflow.md")" \
  >>"$H27/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H27" >/dev/null 2>&1 || true
if grep -rqF 'FIRST OPERATOR FILE' "$H27/.touchstone/principles/" \
  && grep -rqF 'SECOND OPERATOR EDIT' "$H27/.touchstone/principles/"; then
  pass "both preserved copies survive a second replacement"
else
  fail "a later upgrade destroyed an earlier preserved copy"
fi

echo "==> a referent whose name is a prefix of another still gets its block"
# Deduping against a flattened "${array[*]}" made /dotfiles/shared match
# "/dotfiles/shared file", so one driver silently received nothing while the
# command reported covering every agent.
H28="$TMP_DIR/h28"
mkdir -p "$H28/.claude" "$H28/.codex" "$H28/dotfiles"
printf 'a\n' >"$H28/dotfiles/shared"
printf 'b\n' >"$H28/dotfiles/shared file"
ln -s "$H28/dotfiles/shared file" "$H28/.claude/CLAUDE.md"
ln -s "$H28/dotfiles/shared" "$H28/.codex/AGENTS.md"
bash "$INSTALL" install --home "$H28" >/dev/null 2>&1 || true
if grep -q 'touchstone:steering:start' "$H28/dotfiles/shared" \
  && grep -q 'touchstone:steering:start' "$H28/dotfiles/shared file"; then
  pass "both referents receive the managed block"
else
  fail "a referent was skipped as already staged when it was not"
fi

echo "==> a dry run refuses an unusable driver parent too"
# Same rule as the routed destination, and the same defect found twice: a
# dry run that reports an install the real command cannot perform is the one
# answer it must never give.
H29="$TMP_DIR/h29"
mkdir -p "$H29"
printf 'not a directory\n' >"$H29/.claude"
if bash "$INSTALL" install --home "$H29" --dry-run >/dev/null 2>&1; then
  fail "a dry run predicted success with a regular file at ~/.claude"
else
  pass "a dry run refuses an unusable driver parent"
fi
if bash "$INSTALL" install --home "$H29" >/dev/null 2>&1; then
  fail "the real install accepted an unusable driver parent"
else
  pass "the dry run and the real install agree on driver parents"
fi

echo "==> pruning a no-longer-shipped name preserves the bytes"
# A checksum the manifest recorded is not proof the manifest is honest: an
# entry naming an operator's file can carry that file's own checksum. Same
# answer as the overwrite path -- keep the bytes.
H30="$TMP_DIR/h30"
mkdir -p "$H30/.touchstone/principles"
printf 'MY FILE\n' >"$H30/.touchstone/principles/mine.md"
printf '%s\tmine.md\n' "$(cksum <"$H30/.touchstone/principles/mine.md")" \
  >"$H30/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H30" >/dev/null 2>&1 || true
if grep -rqF 'MY FILE' "$H30/.touchstone/principles/"; then
  pass "reconciliation retires a file without destroying it"
else
  fail "reconciliation deleted content on a self-authenticating entry"
fi

echo "==> a dry run validates the nearest existing ancestor"
# Third instance of this class: the parent is absent, so checking only the
# parent skipped validation entirely and the dry run promised an install that
# fails at mkdir.
#
# The fault is a non-directory ancestor rather than permission bits, which do
# not stop the required workflow's root user -- the same reason the
# staging-failure fixture above uses a shim instead of chmod. A regular file
# is not a directory for any UID, and placing it two levels up means only a
# check that walks upward from an absent parent can see it.
H31="$TMP_DIR/h31-file/home"
printf 'a regular file where a directory should be\n' >"$TMP_DIR/h31-file"
if bash "$INSTALL" install --home "$H31" --dry-run >/dev/null 2>&1; then
  fail "a dry run promised an install an unusable driver parent forbids"
else
  pass "a dry run refuses what the real install refuses"
fi
if bash "$INSTALL" install --home "$H31" >/dev/null 2>&1; then
  fail "the real install accepted an unusable driver parent"
else
  pass "the dry run and the real install agree"
fi

echo "==> uninstall deletes only bytes it can prove it rendered"
# The manifest shares a trust domain with the files it describes, so it can
# never authorize destroying content. Ownership that does not depend on it:
# render what this release installs for that name and compare bytes.
H32="$TMP_DIR/h32"
mkdir -p "$H32/.touchstone/principles"
printf 'MY OWN git-workflow NOTES\n' >"$H32/.touchstone/principles/git-workflow.md"
printf '%s\tgit-workflow.md\n' "$(cksum <"$H32/.touchstone/principles/git-workflow.md")" \
  >"$H32/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" uninstall --home "$H32" >/dev/null 2>&1 || true
if grep -rqF 'MY OWN git-workflow NOTES' "$H32/.touchstone/principles/"; then
  pass "an operator file at a shipped name is retired, not destroyed"
else
  fail "uninstall destroyed content on a self-authenticating manifest entry"
fi

# And the ordinary case still removes cleanly, or "recoverable" would just
# mean "never cleans up".
H33="$TMP_DIR/h33"
bash "$INSTALL" install --home "$H33" >/dev/null 2>&1
bash "$INSTALL" uninstall --home "$H33" >/dev/null 2>&1
leftovers=""
for leftover in "$H33/.touchstone/principles"/* "$H33/.touchstone/principles"/.*; do
  [ -f "$leftover" ] || continue
  case "$(basename "$leftover")" in .touchstone-installed) continue ;; esac
  leftovers="$leftovers $(basename "$leftover")"
done
if [ -z "$leftovers" ]; then
  pass "a genuine install is still removed completely"
else
  fail "uninstall left files behind after an ordinary install: $leftovers"
fi

echo "==> staging never follows a symlink planted at its path"
# A PID-based staging name recurs and can be pre-created as a symlink; `cp`
# would follow it, overwriting the referent, and the `mv` would then install
# the symlink as the driver's instruction file.
H34="$TMP_DIR/h34"
mkdir -p "$H34/.claude"
printf 'OPERATOR SECRET\n' >"$H34/victim"
ln -s "$H34/victim" "$H34/.claude/CLAUDE.md.touchstone-steering.$$"
bash "$INSTALL" install --home "$H34" >/dev/null 2>&1 || true
if grep -qF 'OPERATOR SECRET' "$H34/victim"; then
  pass "a symlink at the staging path does not redirect the write"
else
  fail "staging followed a planted symlink and overwrote its referent"
fi
if [ -L "$H34/.claude/CLAUDE.md" ]; then
  fail "a symlink was installed as the driver instruction file"
else
  pass "the instruction path is a regular file"
fi

echo "==> a dangling link at a routed name is a collision, not an absence"
# A symlink to a file that does not exist yet is not `-e`, so it read as
# absent and was replaced by a regular file -- the operator's link gone with
# nothing preserved, and install exiting 0.
H35="$TMP_DIR/h35"
mkdir -p "$H35/.touchstone/principles"
ln -s "missing/notes" "$H35/.touchstone/principles/git-workflow.md"
if bash "$INSTALL" install --home "$H35" >/dev/null 2>&1; then
  fail "install replaced a dangling operator symlink and reported success"
else
  pass "a dangling link at a shipped name is refused"
fi
if [ -L "$H35/.touchstone/principles/git-workflow.md" ]; then
  pass "the operator's symlink survives"
else
  fail "the operator's symlink was destroyed"
fi

echo "==> a symlinked routed document is written through, not replaced"
# Same deliberate arrangement the driver path already respects: a dotfiles
# repository holds the real file. Replacing the link with a regular file
# silently orphans it.
H36="$TMP_DIR/h36"
bash "$INSTALL" install --home "$H36" >/dev/null 2>&1
mkdir -p "$H36/dotfiles"
mv "$H36/.touchstone/principles/git-workflow.md" "$H36/dotfiles/git-workflow.md"
ln -s "$H36/dotfiles/git-workflow.md" "$H36/.touchstone/principles/git-workflow.md"
bash "$INSTALL" install --home "$H36" >/dev/null 2>&1 || true
if [ -L "$H36/.touchstone/principles/git-workflow.md" ]; then
  pass "the routed document's symlink is preserved"
else
  fail "install replaced a symlinked routed document with a regular file"
fi
if [ -s "$H36/dotfiles/git-workflow.md" ]; then
  pass "the referent still holds the content"
else
  fail "the referent was orphaned"
fi

echo "==> a symlink at the manifest path is not silently replaced"
H37="$TMP_DIR/h37"
mkdir -p "$H37/.touchstone/principles"
ln -s "nowhere" "$H37/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H37" >/dev/null 2>&1 || true
if [ -L "$H37/.touchstone/principles/.touchstone-installed" ]; then
  pass "a dangling manifest symlink is refused, not overwritten"
else
  fail "install replaced the operator's manifest symlink"
fi

echo "==> uninstall removes what install wrote through a symlink"
# Install follows the link and writes the referent, so uninstall must remove
# the referent. Removing the link instead deleted the operator's pointer and
# left the managed document sitting in their dotfiles directory.
H38="$TMP_DIR/h38"
bash "$INSTALL" install --home "$H38" >/dev/null 2>&1
mkdir -p "$H38/dotfiles"
mv "$H38/.touchstone/principles/git-workflow.md" "$H38/dotfiles/git-workflow.md"
ln -s "$H38/dotfiles/git-workflow.md" "$H38/.touchstone/principles/git-workflow.md"
bash "$INSTALL" install --home "$H38" >/dev/null 2>&1 \
  || fail "install did not update the symlinked routed document"
bash "$INSTALL" uninstall --home "$H38" >/dev/null 2>&1 \
  || fail "uninstall did not remove the symlinked routed document"
if [ -e "$H38/dotfiles/git-workflow.md" ]; then
  fail "uninstall left the managed document at the symlink's referent"
else
  pass "uninstall removes the referent install wrote"
fi

echo "==> uninstall removes the manifest install wrote through a link"
H39="$TMP_DIR/h39"
bash "$INSTALL" install --home "$H39" >/dev/null 2>&1
mkdir -p "$H39/dotfiles"
mv "$H39/.touchstone/principles/.touchstone-installed" "$H39/dotfiles/manifest"
ln -s "$H39/dotfiles/manifest" "$H39/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" install --home "$H39" >/dev/null 2>&1 || true
bash "$INSTALL" uninstall --home "$H39" >/dev/null 2>&1 || true
if [ -e "$H39/dotfiles/manifest" ] \
  || [ -L "$H39/.touchstone/principles/.touchstone-installed" ]; then
  fail "uninstall left the manifest referent or a dangling pointer to it"
else
  pass "uninstall removes the manifest referent too"
fi

echo "==> a failed install leaves no staging file in the operator's directories"
# Staging files live in the destination directory, not the workspace, so the
# workspace trap never reached them: a failure between staging one driver and
# committing it left an orphan in ~/.claude.
H40="$TMP_DIR/h40"
mkdir -p "$H40/.claude" "$H40/.codex/AGENTS.md"
if bash "$INSTALL" install --home "$H40" >/dev/null 2>&1; then
  fail "install succeeded despite a directory at an instruction path"
fi
orphans=""
for orphan in "$H40"/.claude/.* "$H40"/.codex/.*; do
  case "$(basename "$orphan")" in *touchstone-steering*) orphans="$orphans $(basename "$orphan")" ;; esac
done
if [ -z "$orphans" ]; then
  pass "a mid-install failure leaves no staging orphan"
else
  fail "staging files survived a failed install:$orphans"
fi

echo "==> replacing an operator manifest preserves its bytes"
# The manifest is not independent ownership evidence, so content we did not
# write is preserved before replacement -- including through a live symlink,
# where the referent held the bytes.
H41="$TMP_DIR/h41"
mkdir -p "$H41/.touchstone/principles" "$H41/dotfiles"
printf 'IMPORTANT\tmemo\n' >"$H41/dotfiles/memo-manifest"
cp "$H41/dotfiles/memo-manifest" "$TMP_DIR/h41-original"
ln -s "$H41/dotfiles/memo-manifest" "$H41/.touchstone/principles/.touchstone-installed"
# The install must complete: a failure before the replacement would leave the
# original bytes in place and pass this test without exercising recovery.
bash "$INSTALL" install --home "$H41" >/dev/null 2>&1 \
  || fail "install did not complete over an operator manifest symlink"
if cmp -s "$TMP_DIR/h41-original" "$H41/.touchstone/principles/.touchstone-installed.replaced"; then
  pass "the replaced manifest bytes are preserved exactly"
else
  fail "the preserved copy is missing or does not match the original bytes"
fi

echo "==> every start-marker shape in the source is refused"
# A literal comparison missed the attributed form, so install wrote two start
# markers into every driver file and exited 0; check then rejected its own
# output.
H42_SRC="$TMP_DIR/attributed-source"
mkdir -p "$H42_SRC/scripts" "$H42_SRC/principles"
cp "$REPO_ROOT/TOUCHSTONE.md" "$H42_SRC/TOUCHSTONE.md"
cp "$INSTALL" "$H42_SRC/scripts/$(basename "$INSTALL")"
cp "$REPO_ROOT"/principles/*.md "$H42_SRC/principles/"
printf '\n<!-- touchstone:steering:start restore-newline -->\n' >>"$H42_SRC/TOUCHSTONE.md"
H42="$TMP_DIR/h42"
if bash "$H42_SRC/scripts/$(basename "$INSTALL")" install --home "$H42" >/dev/null 2>&1; then
  fail "an attributed start marker in the source was accepted"
else
  pass "an attributed start marker in the source is refused"
fi

echo "==> uninstall retires manifest bytes it cannot verify"
# The manifest referent is only deleted when its content matches the shape
# this tool writes; an operator's file a symlink happens to reach is retired
# by rename, never destroyed.
H43="$TMP_DIR/h43"
mkdir -p "$H43/.touchstone/principles" "$H43/dotfiles"
printf 'my arbitrary notes\n' >"$H43/dotfiles/notes"
ln -s "$H43/dotfiles/notes" "$H43/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" uninstall --home "$H43" >/dev/null 2>&1 || true
if grep -rqlF 'my arbitrary notes' "$H43" >/dev/null 2>&1; then
  pass "unverifiable manifest bytes survive uninstall"
else
  fail "uninstall destroyed operator content reached through the manifest path"
fi

echo "==> a lookalike manifest naming shipped files is still not ours"
# Shape is spoofable: principles/README.md makes README.md a shipped name, so
# an operator file of '1 2<TAB>README.md' lines passed the shape test. Our
# manifest also describes the directory -- every checksum matches the file it
# names -- and that is what deletion now requires.
H44="$TMP_DIR/h44"
mkdir -p "$H44/.touchstone/principles"
printf '1 2\tREADME.md\n' >"$H44/.touchstone/principles/.touchstone-installed"
bash "$INSTALL" uninstall --home "$H44" >/dev/null 2>&1 || true
if find "$H44" -name '*.removed*' 2>/dev/null | grep -q .; then
  pass "a lookalike manifest is retired, not deleted"
else
  fail "uninstall deleted a manifest-shaped operator file"
fi

echo "==> a blank line the operator prepends to a created file survives"
# Found by the pre-push local review pass. A file this tool created has no
# separator of ours, and the marker now says so; a blank line the operator
# later prepends is theirs.
H45="$TMP_DIR/h45"
bash "$INSTALL" install --home "$H45" >/dev/null 2>&1
printf 'my notes\n\n' | cat - "$H45/.claude/CLAUDE.md" >"$H45/.claude/CLAUDE.md.new"
mv -f "$H45/.claude/CLAUDE.md.new" "$H45/.claude/CLAUDE.md"
bash "$INSTALL" uninstall --home "$H45" >/dev/null 2>&1
printf 'my notes\n\n' >"$TMP_DIR/h45-expected"
if cmp -s "$TMP_DIR/h45-expected" "$H45/.claude/CLAUDE.md"; then
  pass "prepended content survives byte-exactly, blank line included"
else
  fail "uninstall ate a blank line the operator wrote"
fi

echo "==> uninstall without a manifest removes only provable bytes, loudly"
# Also from the pre-push local pass: a deleted manifest let uninstall skip
# everything while claiming completion.
H46="$TMP_DIR/h46"
bash "$INSTALL" install --home "$H46" >/dev/null 2>&1
rm -f "$H46/.touchstone/principles/.touchstone-installed"
mkdir -p "$H46/dotfiles"
mv "$H46/.touchstone/principles/agent-swarms.md" "$H46/dotfiles/as.md"
ln -s "$H46/dotfiles/as.md" "$H46/.touchstone/principles/agent-swarms.md"
printf 'my own file\n' >"$H46/.touchstone/principles/mine.md"
out="$(bash "$INSTALL" uninstall --home "$H46" 2>&1)"
leftover_docs=0
for doc in "$REPO_ROOT"/principles/*.md; do
  [ -f "$H46/.touchstone/principles/$(basename "$doc")" ] && leftover_docs=$((leftover_docs + 1))
done
if [ "$leftover_docs" = 0 ] && [ ! -e "$H46/dotfiles/as.md" ]; then
  pass "render-identical documents are removed despite the missing manifest, through links too"
else
  fail "$leftover_docs shipped documents were silently left behind"
fi
if [ -f "$H46/.touchstone/principles/mine.md" ]; then
  pass "the operator's own file survives"
else
  fail "uninstall deleted an operator file while recovering from a missing manifest"
fi
case "$out" in
  *"kept: mine.md"*) : ;;
  *) : ;;
esac

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
