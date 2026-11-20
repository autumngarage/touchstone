# `touchstone pr wait` fixtures

Responses GitHub returned on 2026-11-20, served by `tests/test-pr-wait.sh`'s fake `gh`. The wait reads only these
fields, so a field the tool invents fails the test.

| File | What it is |
|---|---|
| `graphql-merged.json` | GraphQL answer for a merged pull request (autumngarage/touchstone#1311), as returned. |
| `graphql-closed.json` | GraphQL answer for a pull request closed without merging (autumngarage/touchstone#1233), as returned. |
| `graphql-removed.json` | GraphQL answer for an open pull request whose newest queue event is a removal with reason `failed_checks`. |
| `graphql-queued.json` | GraphQL answer for an open pull request with a live queue entry (`QUEUED`, position 1), caught on a busy queue. |
| `graphql-open-idle.json` | GraphQL answer for an open pull request that was never queued and has no auto-merge. |
| `runs-merge-group.json` | The merge-group run list, with the failed queue run of a removed pull request (run 44694118552). |
| `jobs-failed-run.json` | The job list of that run: its failed `validate-groups (checks-b, checks-b)` job and the `validate` aggregate. Per-step detail is left out. |

The `removed`, `queued`, `open-idle`, `runs` and `jobs` files come from a private repository: commit ids are replaced by
stable stand-ins, the repository's name by `example/repo`, and the people and repository blocks of each run
are removed. Nothing the command reads was changed. `removed` and the run belong to different pull requests, so the
test asks for the run's pull request number; the command only asks GitHub by number.

The wait follows one head, so the tests set `headRefOid` of the queued and idle captures to the head under test. The
only field not taken from a live read is `autoMergeRequest.enabledAt` on an armed pull request (`graphql-open-idle.json`
with that one field filled, as GitHub fills it); replace it with a live capture when one is available.
