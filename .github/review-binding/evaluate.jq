# review-binding evidence contract, version 1.
#
# This is a pure evaluator. The workflow owns GitHub API collection and passes
# one complete document here; missing or partial inputs fail closed.

def trusted($authors):
  (.user.login // "") as $login
  | any($authors[]; . == $login);

def driver_answer:
  (.author_association // "") as $association
  | $association == "OWNER"
    or $association == "MEMBER"
    or $association == "COLLABORATOR";

def review_request:
  (.body // "") | test("^[[:space:]]*@codex[[:space:]]+review([[:space:]]|$)"; "i");

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

def answers_body_finding($id):
  (.body // "") | contains("<!-- touchstone:review-answer id=\($id) -->");

. as $root
| ($root.trustedAuthors // []) as $trusted
| ($root.pr.headSha // "") as $head
| ($root.pr.baseSha // "") as $base
| ($root.pr.baseRefHash // "") as $base_ref_hash
| ($root.pr.number // 0) as $number
| [
    $root.statuses[]?
    | select(.context == "touchstone/review-request-v1")
    | select(.state == "success")
    | select((.creator.login // "") == "github-actions[bot]")
    | (try ((.description // "")
        | capture("^v1 p=(?<pr>[0-9]+) r=(?<ref>[0-9a-fA-F]{40}) b=(?<base>[0-9a-fA-F]{40}) c=(?<comment>[0-9]+)$"))
       catch empty)
    | select(
        (.pr | tonumber) == $number
        and (.ref | ascii_downcase) == ($base_ref_hash | ascii_downcase)
        and (.base | ascii_downcase) == ($base | ascii_downcase)
      )
    | . as $marker
    | $root.issueComments[]?
    | select((.id | tostring) == $marker.comment)
    | select(driver_answer and review_request)
    | {at: .created_at, id: .id, author: .user.login}
  ] | unique_by(.id) | sort_by(.at) as $requests
| ($requests[-1].at // "") as $threshold
| [
    $root.reviews[]?
    | select(trusted($trusted))
    | select((.commit_id // "" | ascii_downcase) == ($head | ascii_downcase))
    | select((.submitted_at // "") > $threshold)
    | select((.state // "") != "DISMISSED")
  ] as $reviews
| [
    $root.issueComments[]?
    | select(trusted($trusted))
    | select((.created_at // "") > $threshold)
    | select(binds_head($head))
  ] as $result_comments
| [
    $root.reviewComments[]? as $finding
    | select($finding.in_reply_to_id == null)
    | $reviews[]
    | select((.id | tostring) == ($finding.pull_request_review_id | tostring))
    | ($finding.updated_at // $finding.created_at // "") as $finding_at
    | {
        id: $finding.id,
        at: $finding_at,
        author: $finding.user.login,
        answered: any($root.reviewComments[]?;
          ((.in_reply_to_id // 0) | tostring) == ($finding.id | tostring)
          and (.created_at // "") > $finding_at
          and driver_answer)
      }
  ] | unique_by(.id) as $inline_findings
| [
    $reviews[]
    | select((.body // "" | gsub("[[:space:]]"; "")) != "")
    | . as $finding
    | [
        $root.statuses[]?
        | select(.context == "touchstone/review-edit-v1")
        | select(.state == "success")
        | select((.creator.login // "") == "github-actions[bot]")
        | . as $edit_status
        | (try ((.description // "")
            | capture("^v1 p=(?<pr>[0-9]+) r=(?<review>[0-9]+)$"))
           catch empty)
        | select((.pr | tonumber) == $number and (.review | tostring) == ($finding.id | tostring))
        | $edit_status.created_at
      ] as $edit_times
    | (($edit_times | max) // ($finding.submitted_at // "")) as $finding_at
    | select(
        (standard_codex_review_body | not)
        or ($edit_times | length) > 0
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
            and driver_answer
            and answers_body_finding($finding.id))
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
        (((.body // "") | contains("Didn't find any major issues")) | not)
        or ((.updated_at // .created_at // "") > (.created_at // ""))
      )
    | select(standard_codex_review_body | not)
    | . as $finding
    | ($finding.updated_at // $finding.created_at // "") as $finding_at
    | {
        kind: "result comment",
        id: $finding.id,
        at: $finding_at,
        answered: (
          any($root.issueComments[]?;
            (.created_at // "") > $finding_at
            and driver_answer
            and answers_body_finding($finding.id))
          or any($reviews[]?;
            (.submitted_at // "") > $finding_at)
          or any($result_comments[]?;
            (.created_at // "") > $finding_at)
        )
      }
  ] as $comment_body_findings
| ($review_body_findings + $comment_body_findings) as $body_findings
| [
    if ($root.contractVersion // 0) != 1 then "unsupported or missing evidence contract version" else empty end,
    if ($root.complete // false) != true then "GitHub evidence collection was incomplete" else empty end,
    if ($root.pr.state // "") != "open" then "pull request is not open" else empty end,
    if ($head | test("^[0-9a-fA-F]{40}$") | not) then "current head SHA is missing or invalid" else empty end,
    if ($base | test("^[0-9a-fA-F]{40}$") | not) then "current base SHA is missing or invalid" else empty end,
    if ($trusted | length) == 0 then "trusted reviewer allowlist is empty" else empty end,
    if ($root.pr.openHeadPulls // [] | length) != 1
      or (($root.pr.openHeadPulls[0] // 0) != $number)
      then "head commit is not uniquely scoped to this open pull request" else empty end,
    if ($requests | length) == 0 then "no trusted review request binds this head to the current base" else empty end,
    if (($reviews | length) + ($result_comments | length)) == 0 then
      if any($root.issueComments[]?;
          trusted($trusted)
          and (.created_at // "") > $threshold
          and ((.body // "") | test("usage limit|quota|try again later|could not review"; "i")))
      then "the review provider reported quota or no-review instead of binding evidence"
      else "no trusted exact-head review evidence postdates the bound request"
      end
    else empty end,
    if any($inline_findings[]; .answered | not) then
      "inline finding(s) "
        + ([$inline_findings[] | select(.answered | not) | (.id | tostring)] | join(", "))
        + " have no qualifying later driver answer"
    else empty end,
    if any($body_findings[]; .answered | not) then
      "body-only finding(s) "
        + ([$body_findings[] | select(.answered | not) | (.id | tostring)] | join(", "))
        + " have no later marked answer (`<!-- touchstone:review-answer id=FINDING_ID -->`) or re-review"
    else empty end
  ] as $reasons
| {
    contractVersion: 1,
    conclusion: (if ($reasons | length) == 0 then "success" else "failure" end),
    title: (if ($reasons | length) == 0
      then "Exact head reviewed; every finding answered"
      else "Review binding is incomplete"
      end),
    summary: (if ($reasons | length) == 0
      then "Trusted review evidence covers head `\($head)` on base `\($base)` after request comment #\($requests[-1].id). All \($inline_findings | length) inline and \($body_findings | length) body-only finding(s) have later qualifying answers. Thread resolution is enforced independently by GitHub conversation resolution."
      else "Review binding failed closed:\n\n" + ($reasons | map("- " + .) | join("\n")) + "\n\nHead: `\($head)`\nBase: `\($base)`"
      end),
    reasons: $reasons,
    counts: {
      requests: ($requests | length),
      formalReviews: ($reviews | length),
      resultComments: ($result_comments | length),
      inlineFindings: ($inline_findings | length),
      unansweredInline: ([$inline_findings[] | select(.answered | not)] | length),
      bodyFindings: ($body_findings | length),
      unansweredBody: ([$body_findings[] | select(.answered | not)] | length)
    }
  }
