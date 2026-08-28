# review-gate evidence contract, version 4.
#
# This is a pure evaluator. The required workflow owns GitHub API collection
# and passes one complete document here; missing or partial inputs fail
# closed. Version 2 derived review requests from the driver's own comments --
# the `touchstone:pr-open` marker, or a bare request posted after the head
# was pushed -- instead of a commit status a publisher had to mint, so it can
# run from a pinned source in any repository with a read-only token. Version 3
# authorizes driver requests and answers through effective repository
# permission supplied by that workflow, not GitHub's contribution association.
# The verdict's additive `state` field separates evidence that can still
# arrive (`waiting-request` or `waiting-review`) from a terminal `failure`.
# `conclusion` remains fail-closed for consumers that do not implement waiting.
# An optional `evidenceCutoffAt` evaluates the collected GitHub evidence as of
# that UTC instant. This lets polling workflows enforce a deadline without
# accepting evidence posted or edited after it.
#
# Version 4 requires every answer to record a disposition in a versioned
# marker. Version 3 accepted any authorized reply in a finding's thread, so a
# reply whose prose claimed "fixed in <sha>" answered the finding while the
# evaluated head did not contain that commit -- Vesper PR #1047 passed the
# gate on the unfixed head and GitHub queued it (AUT-800). Prose is still
# never parsed. The marker is the contract:
#
#   <!-- touchstone:review-answer v=1 id=<FINDING_ID> disposition=fixed fix=<40-HEX> -->
#   <!-- touchstone:review-answer v=1 id=<FINDING_ID> disposition=no-code-change -->
#
# A `fixed` disposition is an answer only while `fixCommitReachability` -- the
# workflow's own comparison against the evaluated head, never this client's
# word -- reports its commit reachable. An unmarked, malformed, or unsupported
# answer is not an answer, so an answer written under version 3 is re-recorded
# by running the same `touchstone pr answer` again with its disposition.

def trusted($authors):
  (.user.login // "") as $login
  | any($authors[]; . == $login);

def driver_action_authorized($permissions):
  (.user.login // "") as $login
  | ($permissions[$login] // "") as $permission
  | $permission == "write"
    or $permission == "maintain"
    or $permission == "admin";

def review_request:
  (.body // "") | test("^[[:space:]]*@codex[[:space:]]+review([[:space:]]|$)"; "i");

def provisional_quota_notice:
  (.body // "") | test("^[[:space:]]*Security review[[:space:]]+(usage limit|quota)([[:space:]:-]|$)"; "i");

def reviewed_sha:
  (.body // "") as $body
  | (.resolved_review_sha // "") as $resolved
  | (if ($resolved | test("^[0-9a-fA-F]{40}$")) then $resolved else
      ($body | (capture("/blob/(?<sha>[0-9a-fA-F]{40})/")? // {}) | (.sha // ""))
    end)
  | ascii_downcase;

def binds_head($head):
  reviewed_sha as $reviewed
  | $reviewed != "" and ($head | ascii_downcase) == $reviewed;

def standard_codex_review_body:
  (.body // "") as $body
  | ($body | contains("### 💡 Codex Review"))
    and ($body | contains("Reviewed commit:"));

# GitHub stamps a review's updated_at with the time its inline comments
# attach -- exactly the latest attached comment's created_at, observed on
# autumngarage/touchstone#931 -- so updated_at alone does not distinguish
# that from an author edit. An edit is identified exactly: updated_at later
# than the submission and later than every attached inline comment. Edits
# within the same second as the last attachment share its timestamp and are
# not distinguishable; that is GitHub's granularity, not a window chosen here.
def edited_after_submission($root):
  . as $review
  | ([$review.submitted_at // empty]
     + [$root.reviewComments[]?
        | select(((.pull_request_review_id // 0) | tostring) == ($review.id | tostring))
        | .created_at // empty]
     | map(fromdateiso8601) | max) as $settled
  | (($review.updated_at // "") | if . == "" then null else fromdateiso8601 end) as $updated
  | $updated != null and $settled != null and $updated > $settled;

# Every version-1 marker in one body. A single answer may dispose of several
# findings, so each is matched independently and bound to its own finding id.
# Anything that is not one of the two supported shapes yields no marker at
# all: an unsupported disposition must never read as an answer.
def answer_markers:
  (.body // "") as $body
  | [$body
     | match("<!--[ \t]*touchstone:review-answer[ \t]+v=1[ \t]+id=(?<id>[0-9]+)[ \t]+disposition=fixed[ \t]+fix=(?<fix>[0-9a-fA-F]{40})[ \t]*-->"; "g")
     | {id: .captures[0].string, disposition: "fixed", fix: (.captures[1].string | ascii_downcase)}]
  + [$body
     | match("<!--[ \t]*touchstone:review-answer[ \t]+v=1[ \t]+id=(?<id>[0-9]+)[ \t]+disposition=no-code-change[ \t]*-->"; "g")
     | {id: .captures[0].string, disposition: "no-code-change", fix: null}];

# Does this comment dispose of finding $id? A fixed disposition additionally
# requires the workflow to have proved the commit reachable from the evaluated
# head; an unknown SHA is absent from the map and fails closed.
def answers_finding($id; $reachable):
  answer_markers
  | any(.[];
      .id == ($id | tostring)
      and (.disposition == "no-code-change"
        or (.disposition == "fixed" and (($reachable[.fix] // false) == true))));

def observed_at:
  .updated_at // .submitted_at // .created_at // "";

. as $input
| (if (($input.fixCommitReachability // null) | type) == "object"
   then ($input.fixCommitReachability | with_entries(.key |= ascii_downcase))
   else {} end) as $reachable
| (if ($input | has("evidenceCutoffAt")) then $input.evidenceCutoffAt else null end) as $raw_cutoff
| ($raw_cutoff == null
   or (($raw_cutoff | type) == "string"
       and ($raw_cutoff | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
       and (try (($raw_cutoff | fromdateiso8601 | todateiso8601) == $raw_cutoff) catch false))) as $cutoff_valid
| (if $cutoff_valid then $raw_cutoff else "0000-00-00T00:00:00Z" end) as $cutoff
| (($input.issueComments // []) | if type == "array" then . else [] end) as $current_issue_comments
| (($input.priorIssueComments // []) | if type == "array" then . else [] end) as $prior_issue_comments
| (($input.reviewComments // []) | if type == "array" then . else [] end) as $current_review_comments
| (($input.priorReviewComments // []) | if type == "array" then . else [] end) as $prior_review_comments
| ($input
   # GitHub's issue-comment API exposes only the current mutable body. At a
   # cutoff, reconstruct every post-cutoff edit from the workflow's last
   # complete pre-cutoff snapshot. A missing current comment has no deletion
   # timestamp, so it cannot be proven to have survived through the cutoff;
   # mark that ambiguity explicitly. Any unavailable prior version likewise
   # fails closed instead of silently accepting older evidence.
   | .issueComments = ([
       $current_issue_comments[]?
       | select($cutoff == null or (.created_at // "") <= $cutoff)
       | . as $current
       | if $cutoff != null and observed_at > $cutoff then
           ([
              $prior_issue_comments[]?
              | select((.id | tostring) == ($current.id | tostring))
              | select((.created_at // "") <= $cutoff and observed_at <= $cutoff)
            ] | sort_by(observed_at) | last) as $prior
           | if $prior == null
             then ($current | ._touchstoneCutoffUncertain = true)
             else $prior
             end
         else $current
         end
     ] + [
       $prior_issue_comments[]?
       | . as $prior
       | select($cutoff != null)
       | select((.created_at // "") <= $cutoff and observed_at <= $cutoff)
       | select(any($current_issue_comments[]?; (.id | tostring) == ($prior.id | tostring)) | not)
       | ._touchstoneCutoffUncertain = true
     ] | unique_by(.id))
   # A review or inline finding that existed by the cutoff remains evidence
   # even if GitHub reports a later edit. Its post-cutoff updated_at then keeps
   # answers from laundering the mutation. Removing it would hide a finding.
   | .reviews = [(.reviews // [])[] | select($cutoff == null or (.submitted_at // "") <= $cutoff)]
   | .reviewComments = ([
       $current_review_comments[]?
       | select($cutoff == null or (.created_at // "") <= $cutoff)
     ] + [
       # GitHub exposes no deletion timestamp for inline review comments. A
       # prior finding absent from the current response may have disappeared
       # on either side of the cutoff, so retain only an uncertainty tombstone.
       $prior_review_comments[]?
       | . as $prior
       | select($cutoff != null)
       | select((.created_at // "") <= $cutoff and observed_at <= $cutoff)
       | select(any($current_review_comments[]?; (.id | tostring) == ($prior.id | tostring)) | not)
       | ._touchstoneCutoffUncertain = true
     ] | unique_by(.id))) as $root
| ($root.trustedAuthors // []) as $trusted
| (($root.authorPermissions // {}) | if type == "object" then . else {} end) as $permissions
| (([
      $root.issueComments[]?
      | select(
          review_request
          or ((.body // "") | test("<!--[[:space:]]*touchstone:review-answer[[:space:]]")))
      | .user.login // empty
    ] + [
      $root.reviewComments[]?
      | select(.in_reply_to_id != null)
      | .user.login // empty
    ]) | unique) as $driver_authors
| ($root.pr.headSha // "") as $head
| ($root.pr.baseSha // "") as $base
| ($root.pr.number // 0) as $number
# A request binds the base it was made against. The base may advance
# underneath it -- every merge to main moves the tip -- and a review of this
# head against an ancestor of the current base is still a review of this
# head: the merged combination is the required workflow's job, not the
# reviewer's. The workflow supplies the acceptable bases (the current tip and
# any request base that is its ancestor); absent that list, only the exact
# tip qualifies. A retargeted ref is still refused through the ref hash.
| (($root.pr.acceptableBaseShas // [$base]) | map(ascii_downcase)) as $acceptable_bases
| ($root.pr.headCurrentSince // "") as $head_current_since
| ($root.pr.baseRetargetedAt // "") as $base_retargeted_at
| [
    $root.issueComments[]?
    | select(review_request)
    | select($cutoff == null or observed_at <= $cutoff)
    | select(driver_action_authorized($permissions) | not)
  ] as $unauthorized_requests
| [
    $root.issueComments[]?
    | select(driver_action_authorized($permissions) and review_request)
    | select($cutoff == null or observed_at <= $cutoff)
    | . as $comment
    | ((.body // "") | capture("<!-- touchstone:pr-open head=(?<head>[0-9a-fA-F]{40}) base=(?<ref>[^ ]+) base_sha=(?<base>[0-9a-fA-F]{40}) -->")? // null) as $marker
    # A comment that names the sequencer but carries no well-formed marker is
    # a corrupted explicit binding, never a bare request.
    | {
        comment: $comment,
        binds: (
          if $marker != null then
            ($marker.head | ascii_downcase) == ($head | ascii_downcase)
            and $marker.ref == ($root.pr.baseRef // "")
            and (($marker.base | ascii_downcase) as $request_base | $acceptable_bases | any(. == $request_base))
          elif (($comment.body // "") | contains("touchstone:pr-open")) then false
          else
            # A bare request binds the head and base that were current when it
            # was posted: only one posted after this SHA last became the head
            # (its commit, or the force-push that restored it), and after the
            # last base retarget, can be about this head on this base.
            $head_current_since != "" and (($comment.updated_at // $comment.created_at // "") > $head_current_since)
            and (($comment.updated_at // $comment.created_at // "") > $base_retargeted_at)
          end
        )
      }
  ] as $request_candidates
| [
    $request_candidates[]
    | select(.binds)
    | .comment
    # An edited request counts from its edit: comments are mutable, and a
    # request back-dated by editing an older comment must not make earlier
    # evidence look like it answered it.
    | {at: (.updated_at // .created_at), id: .id, author: .user.login}
  ] | unique_by(.id) | sort_by(.at) as $requests
| ([$request_candidates[] | select(.binds | not)] + $unauthorized_requests) as $rejected_requests
| ($requests[-1].at // "") as $threshold
| [
    $root.reviews[]?
    | select(trusted($trusted))
    | select((.commit_id // "" | ascii_downcase) == ($head | ascii_downcase))
    | select((.state // "") != "DISMISSED")
  ] as $head_reviews
| [
    $root.reviews[]?
    | select(trusted($trusted))
    | select((.submitted_at // "") > $threshold)
  ] as $review_candidates
| [
    $review_candidates[]
    | select((.commit_id // "" | ascii_downcase) == ($head | ascii_downcase))
    | select((.state // "") != "DISMISSED")
  ] as $reviews
| [
    $root.issueComments[]?
    | select(trusted($trusted))
    | select((.created_at // "") > $threshold)
    | select(
        reviewed_sha != ""
        or ((.body // "") | contains("Reviewed commit:"))
        or ((.body // "") | test("^[[:space:]]*Codex Review:"; "i"))
      )
    | select(provisional_quota_notice | not)
  ] as $result_candidates
| [
    $result_candidates[]
    | select(binds_head($head))
    | select($cutoff == null or observed_at <= $cutoff)
  ] as $result_comments
| [
    $review_candidates[]
    | select(
        ((.commit_id // "" | ascii_downcase) != ($head | ascii_downcase))
        or ((.state // "") == "DISMISSED")
      )
  ] as $rejected_reviews
| [
    # Derive the cutoff tombstone before current-state filtering. A formal
    # review dismissed after the cutoff still existed at the cutoff and may
    # have carried an unanswered body-only finding.
    $review_candidates[]
    | select((.commit_id // "" | ascii_downcase) == ($head | ascii_downcase))
    | select($cutoff != null)
    | select((.submitted_at // "") <= $cutoff and (.updated_at // .submitted_at // "") > $cutoff)
    | {
        kind: "formal review changed after evidence cutoff",
        id: .id,
        at: (.updated_at // .submitted_at),
        answered: false
      }
  ] as $cutoff_mutated_reviews
| [
    $result_candidates[]
    | select(binds_head($head) | not)
  ] as $rejected_result_comments
| [
    $root.reviewComments[]? as $finding
    | select($finding.in_reply_to_id == null)
    # A later same-head recovery request raises the threshold for fresh
    # completion evidence, but it cannot erase an inline finding already
    # attached to this exact head.
    | $head_reviews[]
    | select((.id | tostring) == ($finding.pull_request_review_id | tostring))
    | ($finding.updated_at // $finding.created_at // "") as $finding_at
    | {
        id: $finding.id,
        at: $finding_at,
        author: $finding.user.login,
        answered: any($root.reviewComments[]?;
          ((.in_reply_to_id // 0) | tostring) == ($finding.id | tostring)
          and (.created_at // "") > $finding_at
          # Contract 4 reads the reply body, so an edit can now change a
          # verdict. GitHub exposes no prior body for an inline comment, so a
          # reply observed after the deadline is not evidence -- otherwise a
          # disposition could be added to a pre-cutoff reply once the gate had
          # stopped collecting.
          and ($cutoff == null or observed_at <= $cutoff)
          and driver_action_authorized($permissions)
          and answers_finding($finding.id; $reachable))
      }
  ] | unique_by(.id) as $inline_findings
| [
    $reviews[]
    | select((.body // "" | gsub("[[:space:]]"; "")) != "")
    | . as $finding
    | ($finding.updated_at // $finding.submitted_at // "") as $finding_at
    | select(
        (standard_codex_review_body | not)
        or ($finding | edited_after_submission($root))
        or (any($root.reviewComments[]?;
          .in_reply_to_id == null
          and ((.pull_request_review_id // 0) | tostring) == ($finding.id | tostring)) | not)
      )
    | {
        kind: "review body",
        id: $finding.id,
        at: $finding_at,
        answered: (
          any($root.issueComments[]?;
            (.created_at // "") > $finding_at
            and ($cutoff == null or observed_at <= $cutoff)
            and driver_action_authorized($permissions)
            and answers_finding($finding.id; $reachable))
          or any($reviews[]?;
            (.submitted_at // "") > $finding_at)
          or any($result_comments[]?;
            (.created_at // "") > $finding_at)
        )
      }
  ] as $review_body_findings
| [
    $result_comments[]
    | select(
        (
          (((.body // "") | contains("Didn't find any major issues")) | not)
          and (standard_codex_review_body | not)
        )
        or ((.updated_at // .created_at // "") > (.created_at // ""))
      )
    | . as $finding
    | ($finding.updated_at // $finding.created_at // "") as $finding_at
    | {
        kind: "result comment",
        id: $finding.id,
        at: $finding_at,
        answered: (
          any($root.issueComments[]?;
            (.created_at // "") > $finding_at
            and ($cutoff == null or observed_at <= $cutoff)
            and driver_action_authorized($permissions)
            and answers_finding($finding.id; $reachable))
          or any($reviews[]?;
            (.submitted_at // "") > $finding_at)
          or any($result_comments[]?;
            (.created_at // "") > $finding_at)
        )
      }
  ] as $comment_body_findings
| ($review_body_findings + $comment_body_findings + $cutoff_mutated_reviews) as $body_findings
| [
    if ($root.contractVersion // 0) != 4 then "unsupported or missing evidence contract version" else empty end,
    if (($input.fixCommitReachability // null) | type) != "object"
      then "fix-commit reachability evidence is missing" else empty end,
    if ($root.complete // false) != true then "GitHub evidence collection was incomplete" else empty end,
    if $cutoff_valid | not then "evidence cutoff is not a UTC whole-second timestamp" else empty end,
    if $cutoff != null and (($input | has("priorIssueComments")) | not)
      then "evidence cutoff requires a prior issue-comment snapshot" else empty end,
    if $cutoff != null and (($input.priorIssueComments | type) != "array")
      then "prior issue-comment snapshot is not an array" else empty end,
    if $cutoff != null and (($input | has("priorReviewComments")) | not)
      then "evidence cutoff requires a prior review-comment snapshot" else empty end,
    if $cutoff != null and (($input.priorReviewComments | type) != "array")
      then "prior review-comment snapshot is not an array" else empty end,
    if any($root.issueComments[]?; ._touchstoneCutoffUncertain == true)
      then "issue-comment state at the evidence cutoff cannot be reconstructed" else empty end,
    if any($root.reviewComments[]?; ._touchstoneCutoffUncertain == true)
      then "review-comment state at the evidence cutoff cannot be reconstructed" else empty end,
    if ($root.authorPermissions | type) != "object"
      or any($driver_authors[]; . as $author | ($permissions | has($author) | not))
      then "effective permission evidence is missing for one or more driver comment authors" else empty end,
    if ($root.pr.state // "") != "open" then "pull request is not open" else empty end,
    if ($head | test("^[0-9a-fA-F]{40}$") | not) then "current head SHA is missing or invalid" else empty end,
    if ($base | test("^[0-9a-fA-F]{40}$") | not) then "current base SHA is missing or invalid" else empty end,
    if ($trusted | length) == 0 then "trusted reviewer allowlist is empty" else empty end,
    if ($root.pr.openHeadPulls // [] | length) != 1
      or (($root.pr.openHeadPulls[0] // 0) != $number)
      then "head commit is not uniquely scoped to this open pull request" else empty end
  ] as $invariant_reasons
| [
    if ($requests | length) == 0 then "no trusted review request binds this head to the current base" else empty end,
    if (($reviews | length) + ($result_comments | length)) == 0 then
      if any($root.issueComments[]?;
          trusted($trusted)
          and (.created_at // "") > $threshold
          and provisional_quota_notice)
      then "the security-review quota notice is provisional; continue waiting for trusted exact-head review evidence"
      else "no trusted exact-head review evidence postdates the bound request"
      end
    else empty end
  ] as $progress_reasons
| [
    if ($requests | length) == 0 and ($rejected_requests | length) > 0 then
      "authorized review request evidence does not bind the current head and base"
    else empty end,
    if ($requests | length) > 0
      and (($reviews | length) + ($result_comments | length)) == 0
      and (($rejected_reviews | length) + ($rejected_result_comments | length)) > 0
      then "trusted review response evidence does not bind the exact head after the request"
    else empty end
  ] as $rejected_evidence_reasons
| [
    if any($inline_findings[]; .answered | not) then
      "inline finding(s) "
        + ([$inline_findings[] | select(.answered | not) | (.id | tostring)] | join(", "))
        + " have no qualifying later driver answer recording a disposition"
        + " (`<!-- touchstone:review-answer v=1 id=FINDING_ID disposition=fixed fix=SHA -->`"
        + " with SHA reachable from this head, or `disposition=no-code-change`);"
        + " re-run `touchstone pr answer` with its disposition"
    else empty end,
    if any($body_findings[]; .answered | not) then
      "body-only finding(s) "
        + ([$body_findings[] | select(.answered | not) | (.id | tostring)] | join(", "))
        + " have no later answer recording a disposition"
        + " (`<!-- touchstone:review-answer v=1 id=FINDING_ID disposition=fixed fix=SHA -->`"
        + " with SHA reachable from this head, or `disposition=no-code-change`) or re-review"
    else empty end
  ] as $finding_reasons
| ($invariant_reasons + $progress_reasons + $rejected_evidence_reasons + $finding_reasons) as $reasons
| (if ($reasons | length) == 0 then "success"
   elif (($invariant_reasons | length) + ($rejected_evidence_reasons | length) + ($finding_reasons | length)) > 0 then "failure"
   elif ($requests | length) == 0 then "waiting-request"
   else "waiting-review"
   end) as $state
| {
    contractVersion: 4,
    evidenceCutoffAt: $raw_cutoff,
    state: $state,
    conclusion: (if ($reasons | length) == 0 then "success" else "failure" end),
    title: (if $state == "success"
      then "Exact head reviewed; every finding answered"
      elif ($state | startswith("waiting-"))
      then "Review gate is waiting for evidence"
      else "Review gate failed closed"
      end),
    summary: (if $state == "success"
      then "Trusted review evidence covers head `\($head)` on base `\($base)` after request comment #\($requests[-1].id). All \($inline_findings | length) inline and \($body_findings | length) body-only finding(s) have later qualifying answers. Thread resolution is enforced independently by GitHub conversation resolution."
      elif ($state | startswith("waiting-"))
      then "Review gate is waiting:\n\n" + ($reasons | map("- " + .) | join("\n")) + "\n\nHead: `\($head)`\nBase: `\($base)`"
      else "Review gate failed closed:\n\n" + ($reasons | map("- " + .) | join("\n")) + "\n\nHead: `\($head)`\nBase: `\($base)`"
      end),
    reasons: $reasons,
    counts: {
      requests: ($requests | length),
      rejectedRequests: ($rejected_requests | length),
      formalReviews: ($reviews | length),
      resultComments: ($result_comments | length),
      rejectedReviewEvidence: (($rejected_reviews | length) + ($rejected_result_comments | length)),
      inlineFindings: ($inline_findings | length),
      unansweredInline: ([$inline_findings[] | select(.answered | not)] | length),
      bodyFindings: ($body_findings | length),
      unansweredBody: ([$body_findings[] | select(.answered | not)] | length)
    }
  }
