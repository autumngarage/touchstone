# review-gate evidence contract, version 3 of the gate behavior contract.
#
# This is a pure evaluator. The required workflow owns GitHub API collection
# and passes one complete document here; missing or partial inputs fail
# closed. It derives exactly one normalized reviewer verdict for the current
# pull-request head and nothing else:
#
#   waiting   no trusted completed verdict binds the current head
#   findings  the latest trusted verdict for the current head reports findings
#   clean     the latest trusted verdict for the current head is an explicit,
#             unedited clean result
#   invalid   evidence is ambiguous, edited, or otherwise untrustworthy
#
# Only `clean` succeeds. Findings are answered on their GitHub threads and a
# fresh review request supplies the clean exact-head verdict; GitHub's own
# conversation-resolution rule and the merge queue own everything after that.
#
# Contract 4 (the previous behavior, gate behavior contract version 2)
# adjudicated whether historical findings had been answered: it reconstructed
# request bases, resolved abbreviated SHAs through the API, proved fix-commit
# reachability, collected author permissions, and replayed prior comment
# snapshots under an evidence cutoff. All of that work was proportional to the
# pull request's mutable review history and exhausted the gate's own request
# budget on heavily reviewed pull requests (AUT-1106, Vesper #1112/#1113).
# Version 3 deletes historical adjudication: every verdict the trusted
# reviewer publishes is already bound to one commit by the reviewer itself,
# so the only question is whether the latest verdict for the current head is
# an explicit clean result. AUT-1132 owns this contract; the 52-PR audit that
# proved the adapter unambiguous is audits/2026-09-01-exact-head-verdict.md.
#
# Adapter boundary (the only provider-shaped knowledge in the gate):
#   - A trusted formal review is a findings verdict for the commit GitHub
#     bound it to (`commit_id`). Prose is never parsed for binding; the one
#     observed review without a "Reviewed commit:" line still carried
#     GitHub's own commit binding.
#   - A trusted issue comment naming "Reviewed commit: `<sha>`" is a verdict
#     for the head when the SHA is the full head, or when it is a prefix of
#     the head and the workflow resolved it (`resolved_review_sha`) to the
#     full head — a prefix alone is a candidate, never a binding, because a
#     rewritten head could be mined to share one. Resolution is O(1): only
#     head-prefix-matching candidates need it, and an unresolved candidate
#     fails closed. A binding comment is clean when it contains the explicit
#     clean sentence, carries whole-second UTC timestamps, and is unedited;
#     otherwise it fails closed as invalid.
#   - The reviewer's mutable status dashboard (first line
#     `<!-- codex-pull-request-review-summary -->`) and provisional
#     security-review quota notices are never evidence.
#
# Safety shape: success requires a positive, current artifact. A deleted
# clean comment simply stops existing and the verdict falls back to waiting;
# an edited clean fails closed; a rewritten head has no inherited verdict
# because nothing binds the new SHA. No prior-state snapshot, cutoff, or
# permission model is needed to make deletion and edit safe.

def trusted($authors):
  (.user.login // "") as $login
  | any($authors[]; . == $login);

def dashboard_comment:
  (.body // "") | test("^[[:space:]]*<!--[[:space:]]*codex-pull-request-review-summary[[:space:]]*-->");

def provisional_quota_notice:
  (.body // "") | test("^[[:space:]]*Security review[[:space:]]+(usage limit|quota)([[:space:]:-]|$)"; "i");

def clean_sentence:
  (.body // "") | contains("Didn't find any major issues");

def valid_at:
  type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def reviewed_abbrev:
  (.body // "")
  | (capture("Reviewed commit:[*]*[[:space:]]*`(?<sha>[0-9a-fA-F]{7,40})`")? // {sha: ""})
  | .sha | ascii_downcase;

# A review request grants the workflow's full evidence window. It is a wait
# hint only: it cannot create success, so it needs no authorization model —
# the worst an unauthorized request can do is extend waiting to the same
# bounded deadline.
def review_request:
  (.body // "") | test("^[[:space:]]*@codex[[:space:]]+review([[:space:]]|$)"; "i");

. as $input
| ($input.trustedAuthors // []) as $trusted
| (($input.pr.headSha // "") | ascii_downcase) as $head
| ($input.pr.number // 0) as $number
| ($input.pr.baseRetargetedAt) as $base_retargeted_at
| (if ($input.issueComments | type) == "array" then $input.issueComments else null end) as $issue_comments
| (if ($input.reviews | type) == "array" then $input.reviews else null end) as $reviews
# Verdict events for the current head, in evidence-time order. A later
# verdict supersedes an earlier one; nothing outside this list participates.
| ([
    # A dismissed findings review stays a findings event: dismissal is not an
    # answer and not a fresh clean verdict, so it must keep blocking success.
    (($reviews // [])[]
     | select(trusted($trusted))
     | select((.commit_id // "" | ascii_downcase) == $head)
     | {at: (.submitted_at // ""),
        kind: (if (.submitted_at | valid_at) then "findings" else "malformed" end)}),
    (($issue_comments // [])[]
     | select(trusted($trusted))
     | select(dashboard_comment | not)
     | select(provisional_quota_notice | not)
     | reviewed_abbrev as $abbrev
     | select($abbrev != "" and ($head | startswith($abbrev)))
     | ((.resolved_review_sha // "") | ascii_downcase) as $resolved
     # A full-length SHA binds by identity. A prefix is only a candidate:
     # the workflow must have resolved it, and only a resolution equal to
     # the head binds — anything else is a stale commit sharing a prefix.
     | (if ($abbrev | length) == 40 then "bound"
        elif $resolved == $head then "bound"
        elif ($resolved | test("^[0-9a-f]{40}$")) then "stale"
        else "unresolved" end) as $binding
     | select($binding != "stale")
     | {at: (.created_at // ""),
        kind: (if $binding == "unresolved" then "unresolved"
               elif ((.created_at | valid_at) and (.updated_at | valid_at)) | not then "malformed"
               elif clean_sentence | not then "unclassifiable"
               elif (.updated_at > .created_at) then "edited-clean"
               else "clean" end)})
  ]
  # A verdict reviews the diff against the base the pull request had; after a
  # base retarget that diff no longer exists, so earlier verdicts are stale.
  # Only an event with a proven timestamp can be proven stale: unorderable
  # events must survive this cutoff to reach the fail-closed check below.
  | map(select((.kind == "malformed" or .kind == "unresolved")
        or $base_retargeted_at == "" or .at > $base_retargeted_at))
  | sort_by(.at)) as $events
| ($events | map(select(.kind == "clean")) | length) as $clean_count
| ($events | map(select(.kind == "findings")) | length) as $findings_count
| ($events | last) as $latest
# An event whose timestamps are missing or malformed, or whose abbreviated
# SHA the workflow failed to resolve, cannot be ordered or trusted at all —
# it poisons the whole evaluation rather than silently losing to sort order.
| ($events | map(select(.kind == "unresolved")) | length > 0) as $any_unresolved
| ($events | map(select(.kind == "malformed")) | length > 0) as $any_malformed
# Verdicts in the same second cannot be ordered; every event sharing the
# latest timestamp must agree, or ambiguity decides instead of sort order.
| ($latest != null
   and ([$events[] | select(.at == $latest.at) | .kind] | unique | length) > 1) as $tied
| [
    if ($input.gateBehaviorContractVersion // 0) != 3
      then "unsupported or missing gate behavior contract version" else empty end,
    if ($input.complete // false) != true
      then "GitHub evidence collection was incomplete" else empty end,
    if ($issue_comments == null) then "issue-comment evidence is missing" else empty end,
    if ($reviews == null) then "review evidence is missing" else empty end,
    if ($input.pr.state // "") != "open" then "pull request is not open" else empty end,
    if ($head | test("^[0-9a-f]{40}$") | not)
      then "current head SHA is missing or invalid" else empty end,
    if ($trusted | length) == 0 then "trusted reviewer allowlist is empty" else empty end,
    # Absent retarget evidence is not proof that no retarget occurred: the
    # collector must assert it explicitly — the empty-string sentinel for
    # "never retargeted", or the whole-second UTC instant of the last one.
    if (($input.pr | type) != "object"
        or (($input.pr | has("baseRetargetedAt")) | not)
        or ($base_retargeted_at | type) != "string"
        or ($base_retargeted_at != "" and (($base_retargeted_at | valid_at) | not)))
      then "base-retarget evidence is missing or malformed" else empty end,
    if (($input.pr.openHeadPulls // []) != [$number])
      then "head commit is not uniquely scoped to this open pull request" else empty end
  ] as $invariant_failures
| (if ($invariant_failures | length) > 0 then "invalid"
   elif $latest == null then "waiting"
   elif $any_unresolved or $any_malformed or $tied then "invalid"
   elif $latest.kind == "clean" then "clean"
   elif $latest.kind == "findings" then "findings"
   else "invalid"
   end) as $verdict
| (if $verdict == "invalid" then
     (if ($invariant_failures | length) > 0 then $invariant_failures[0]
      elif $any_unresolved then "a trusted result comment for head `\($head)` names an abbreviated commit the workflow did not resolve; evidence collection must resolve head-prefix candidates"
      elif $any_malformed then "a trusted verdict for head `\($head)` carries missing or malformed timestamps; its order and edit state cannot be proven"
      elif $tied then "the latest trusted verdicts for head `\($head)` are simultaneous and conflicting; post a fresh review request so a later verdict supersedes them"
      elif $latest.kind == "edited-clean" then "the latest trusted clean result for head `\($head)` was edited after posting; post a fresh review request for an unedited verdict"
      else "the latest trusted comment binding head `\($head)` is not a recognized verdict; post a fresh review request"
      end)
   elif $verdict == "waiting" then "no trusted completed verdict binds head `\($head)`; post `@codex review` and wait for the exact-head result"
   elif $verdict == "findings" then "the latest trusted verdict for head `\($head)` reports findings; answer and resolve them on their threads, then post a fresh review request for a clean exact-head verdict"
   else "the latest trusted verdict for head `\($head)` is an explicit clean result"
   end) as $reason
| {
    gateBehaviorContractVersion: 3,
    verdict: $verdict,
    # Workflow mapping: only `clean` concludes success. `waiting` and
    # `findings` remain open states the polling workflow may retry until its
    # deadline; `invalid` is terminal.
    state: (if $verdict == "clean" then "success"
            elif $verdict == "invalid" then "failure"
            elif $verdict == "findings" then "waiting-review"
            elif any(($issue_comments // [])[]; review_request) then "waiting-review"
            else "waiting-request"
            end),
    conclusion: (if $verdict == "clean" then "success" else "failure" end),
    reason: $reason,
    summary: (if $verdict == "clean"
      then "Trusted review evidence: the latest verdict for head `\($head)` is an explicit clean result. Thread resolution and merge-queue validation are enforced independently by GitHub."
      else "Review gate is not passing (\($verdict)):\n\n- \($reason)\n\nHead: `\($head)`"
      end),
    counts: {
      verdictEvents: ($events | length),
      cleanVerdicts: $clean_count,
      findingsVerdicts: $findings_count,
      requestsObserved: ([($issue_comments // [])[] | select(review_request)] | length)
    }
  }
