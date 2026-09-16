#!/usr/bin/env bash
# Select an existing request, never a review verdict. Input is gh's TSV:
# URL, author, escaped body, creation time. Both PR entry points use this
# matcher; callers own transport, coordinate verification, and posting.
select_review_request() {
  local head="$1" base="$2" base_sha="$3" author="$4" allow_attest="$5"
  local round="${6:-}" after="${7:-}"
  awk -F '\t' -v head="$head" -v base="$base" -v base_sha="$base_sha" \
    -v author="$author" -v allow_attest="$allow_attest" -v round="$round" -v after="$after" '
    BEGIN {
      exact = "<!-- touchstone:pr-open head=" head " base=" base " base_sha=" base_sha " -->"
      prefix = "<!-- touchstone:pr-open head=" head " "
      attest = "<!-- touchstone:attest-request head=" head " -->"
    }
    $2 == author && index($3, "@codex review") {
      if (index($3, prefix)) {
        if (index($3, exact)) {
          has_exact = 1
          # An answer needs a request newer than the findings it closed.
          # Missing timestamps cannot prove that ordering. Creation time is
          # conservative: editing an old request does not make it reusable.
          if (round == "" || (after != "" && $4 > after)) {
            if (open_url == "") open_url = $1
          }
        } else moved = 1
      }
      if (allow_attest == "true" && index($3, attest) &&
          (round == "" || index($3, round))) {
        if (attest_url == "") attest_url = $1
      }
    }
    END {
      # An attest marker has no base coordinates and cannot excuse a moved
      # base detected by an existing open marker.
      if (moved && !has_exact) exit 3
      if (open_url != "") print open_url "\t" exact
      else if (attest_url != "") print attest_url "\t" attest
    }'
}
