# Issue tracker: GitHub

Issues, specs, and tickets for this repo live as GitHub issues at `https://github.com/ZeroSegFault/CachyOS-OneXPlayer3`. Use the [`gh`](https://cli.github.com/) CLI for all operations; inside a clone `gh` infers the repository from the `origin` remote, and `{owner}/{repo}` in `gh api` paths resolves to it.

## Capabilities

- **Native issue dependencies:** `enabled` — GitHub's blocked-by API (`repos/{owner}/{repo}/issues/<n>/dependencies/blocked_by`). The `## Blocked by` body record is still written and must equal the native set.
- **Native parent/sub-issue links:** `enabled` — GitHub sub-issues (`repos/{owner}/{repo}/issues/<parent>/sub_issues`). The `## Parent` body record is still written and must agree.
- **Merge-time lifecycle freshness:** `unavailable` — no branch protection, no required checks, no CI. See "Pull-request delivery freshness" below.
- **Cross-clone claims:** ordered claim comments plus assignment, as defined below.

**Lease timing:** use a 15-minute lease, renew and verify at most every five minutes, use the mandatory 30-second command timeout with a further 30-second lease safety margin, and wait a two-minute missed-renewal grace before takeover.

## Conventions

**Always wrap `gh` calls as `timeout 30s gh <args> < /dev/null`.** `gh` reads bodies from stdin when given `-` and can prompt when stdin is a terminal; a finite stdin and a timeout keep agent runs from hanging. Read-only calls may retry up to three times with a short backoff. After a timed-out or failed write, query the resulting state first and repeat the write only when the comment, issue, dependency, label, or close transition is absent.

Pass Markdown bodies with `--body-file <file>` (a temporary file, removed after the write is verified), never through shell-escaped `--body` strings for anything multiline. Use `--paginate` on every `gh api` list call and de-duplicate by stable id.

- **Create an issue**: generate one UUID and append `<!-- agent-operation:<uuid> -->` to the body before the first attempt, then `timeout 30s gh issue create --title "..." --body-file <file> --label "<category>,<state>" < /dev/null`. After a timeout, search open and closed issues for the marker (`timeout 30s gh issue list --state all --search "agent-operation:<uuid> in:body" --json number < /dev/null`) before retrying with the same marker.
- **Read an issue completely**: `timeout 30s gh issue view <n> --comments --json number,id,state,stateReason,title,body,author,url,createdAt,updatedAt,assignees,labels,comments < /dev/null`.
- **List issues exhaustively**: `timeout 30s gh issue list --state open --limit 1000 --json number,state,title,body,labels,assignees,createdAt,updatedAt,url < /dev/null`, adding `--label` filters as needed.
- **Comment on an issue**: `timeout 30s gh issue comment <n> --body-file <file> < /dev/null`.
- **Apply / remove labels**: `timeout 30s gh issue edit <n> --add-label "..." < /dev/null` / `--remove-label "..."`; multiple labels are comma-separated. A state transition is one logical replace operation: preserve category and unrelated labels, remove every old state label, add exactly one target state, refetch, and do not expose the item to selection until the exact final set is verified. Repair pre-existing zero/multiple-state conflicts first.
  - **State-replacement operation** (one call; list in `--remove-label` every state label *except* the target): `timeout 30s gh issue edit <n> --remove-label "<all other states>" --add-label "<target-state>" < /dev/null`, then run the complete read and verify the label set equals the prior non-state labels plus exactly `<target-state>`. If verification fails, rerun the same call (it is idempotent).
- **Ensure labels**: for each label in `docs/agents/triage-labels.md`, `timeout 30s gh label create "<name>" --color "<hex without #>" --description "<meaning>" --force < /dev/null` (`--force` updates an existing label, so this is idempotent).
- **Outcome record and close**: post a comment beginning `AGENT-OUTCOME: delivered commit=<sha>` or `AGENT-OUTCOME: already-satisfied`, followed by reproducible evidence; then `timeout 30s gh issue close <n> --reason completed < /dev/null` and refetch. The delivered record includes the short commit SHA (and the PR link when there is one). A merged closing PR plus merge SHA is also delivered. Closures with reason `not planned`, manual, and unclassified closures are not successful blockers.
- **Auto-close keywords**: a commit closes an issue automatically only when a keyword precedes the number — `close`/`closes`/`closed`, `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved` (e.g. `Closes #12`) — **and the commit reaches the default branch**. A bare `#12` only references the issue. Still post the outcome comment, then verify the issue closed.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; the `triage` skill reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues: read with `timeout 30s gh pr view <n> --comments --json number,state,author,url,title,body,labels,assignees,comments,files < /dev/null`, list with `timeout 30s gh pr list --state open --limit 1000 --json ... < /dev/null` (keeping only PRs whose `authorAssociation` is not `OWNER`/`MEMBER`/`COLLABORATOR`), and comment/label/close with the `gh pr` equivalents. Issues and PRs share one number space; resolve a bare `#42` with `gh pr view 42`, falling back to `gh issue view 42`.

## Pull-request delivery freshness

Setup must record the exact human owner or required protected check that, immediately before merge, refreshes the target branch and repeats the shared candidate gate and runtime lifecycle when the target moved, and that obtains explicit human runtime evidence whenever required automated runtime verification was unavailable. If this capability is unavailable, an agent may open a PR for visibility but must return a non-automerged human handoff rather than a delivery receipt.

**Recorded state for this repo: `unavailable`.** The repository has no branch protection, no required checks and no CI. Agents must not merge PRs or treat an open PR as delivered; return a human handoff to the maintainer (`ZeroSegFault`) naming the PR, candidate SHA, and the checks and runtime verification that were and were not run. Rerun setup if a protected check is added.

## When a skill says "publish to the issue tracker"

Use the create command above.

## When a skill says "fetch the relevant ticket"

Run the complete read command above.

## Dependency and hierarchy operations

Used by `to-tickets`, `triage`, `grilling`, `drain-backlog`, and `wayfinder`. The native APIs take an issue's numeric REST `id`, not its number and not the GraphQL node id that `gh issue view --json id` returns: get it with `timeout 30s gh api repos/{owner}/{repo}/issues/<n> --jq .id < /dev/null`.

- **Parent**: put `## Parent` with the source issue in every child, append an `## Implementation tickets` list to the parent, and add the native link: `timeout 30s gh api -X POST repos/{owner}/{repo}/issues/<parent>/sub_issues -F sub_issue_id=<child id> < /dev/null`. Verify with `timeout 30s gh api --paginate repos/{owner}/{repo}/issues/<parent>/sub_issues < /dev/null`.
- **Blocking body record**: `## Blocked by` lists the exact blocker identifiers.
- **Native blocking**: add an edge with `timeout 30s gh api -X POST repos/{owner}/{repo}/issues/<child>/dependencies/blocked_by -F issue_id=<blocker id> < /dev/null`. Read the set with `timeout 30s gh api --paginate repos/{owner}/{repo}/issues/<child>/dependencies/blocked_by < /dev/null`, normalise to issue numbers, and require it to equal the body set. Blockers outside GitHub (e.g. an upstream kernel series) live only in the body record.
- **Fallback**: if a native call fails as unsupported, the body set is authoritative. An unknown capability blocks promotion.

## Cross-clone claim operations

Comments provide a total order that assignment alone cannot:

1. Post `AGENT-CLAIM token=<uuid> owner=<run-id> ttl=900` with `timeout 30s gh issue comment <n> --body "..." < /dev/null`; `ttl` must equal the configured lease duration.
2. Refetch all comments with `timeout 30s gh api --include --paginate "repos/{owner}/{repo}/issues/<n>/comments?per_page=100" < /dev/null`, de-duplicate by comment id, and read authoritative server time from the HTTP `Date` header. Order records by server `created_at`, then id. Effective expiry is the record's server `created_at` plus the TTL, never a client-authored timestamp. An owner's `AGENT-RENEW token=<uuid> ttl=900` extends expiry only when that token is the current winner and its server timestamp precedes the then-current expiry; an expired or losing token cannot renew or revive itself. `AGENT-RELEASE token=<uuid> owner=<run-id>` ends only that owner's exact token. The earliest active claim wins. If server time is unavailable, do not expire or take over a claim automatically.
3. Claim acquisition and exact-token release are housekeeping allowed without winning. Only the winner assigns the issue (`timeout 30s gh issue edit <n> --add-assignee @me < /dev/null`), starts work, renews, or performs protected writes. Renew before half the lease elapses and verify with server timestamps; a loser releases only its own token and leaves the issue untouched.
4. Before every integration, state change, PR creation, or close, ensure the remaining lease exceeds the 30-second operation timeout plus the safety margin, renewing first when needed; then refetch ownership and run the operation. A runner whose token expired or lost may not resume side effects without a new winning claim.
5. Reclaim only after the missed-renewal grace, a final exhaustive comment refetch, and checks for a live worker, branch, PR, or in-flight request. An ambiguous timed-out write blocks takeover until reconciled.
6. On every exit path, release only the actor's own token, then refetch to verify it is inactive.

## Wayfinding operations

Used by the `wayfinder` skill. Every `gh` command uses the timeout and stdin wrapper above.

- **Map**: create an issue labelled `wayfinder:map` holding Destination, Notes, Decisions so far, Not yet specified, Out of scope, and Superseded.
- **Child ticket**: use the shared `## Parent` record and native sub-issue link to the map, and apply one `wayfinder:<type>` label.
- **Blocking**: use the shared dependency operations above.
- **Frontier**: list the map's open sub-issues, then drop any with a non-successful blocker or active claim; first in map order wins.
- **Claim**: use the ordered claim protocol, then assign.
- **Map writes**: serialise body edits (`gh issue edit <map> --body-file <file>`) with the Wayfinder map-lease protocol; use comments for lease records.
- **Resolve**: post `WAYFINDER-OUTCOME: resolved` with the answer, close the child, then update Decisions so far under the map lease. Index `out-of-scope` and `superseded` outcomes in their map sections; an unclassified closure is not a successful blocker.
